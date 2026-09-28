import Foundation
import Darwin

struct SwitchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct CommandResult { let status: Int32; let output: String }
struct Display: Equatable {
    let name: String
    let uuid: String
    var isU5226KW: Bool { name.range(of: #"(?:^|\s)U5226KW(?:$|\s)"#, options: [.regularExpression, .caseInsensitive]) != nil }
}
struct InputDefinition: Codable, Equatable {
    let code: Int
    let name: String
}
struct MonitorInput: Hashable {
    let displayID: String
    let rawValue: Int
    let title: String
    let sourceTitle: String
    init(displayID: String, rawValue: Int, title: String, sourceTitle: String? = nil) {
        self.displayID = displayID; self.rawValue = rawValue
        self.title = title; self.sourceTitle = sourceTitle ?? title
    }
    var storageKey: String { "\(displayID):\(rawValue)" }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.storageKey == rhs.storageKey }
    func hash(into hasher: inout Hasher) { hasher.combine(storageKey) }
}
struct MonitorSnapshot {
    let display: Display
    let inputs: [MonitorInput]
    let selected: Int?
    let inputNotice: String?
}

enum InputCatalog {
    static let dell52: [InputDefinition] = [
        .init(code: 0x19, name: "Thunderbolt / USB-C"), .init(code: 0x0f, name: "DisplayPort 1"),
        .init(code: 0x13, name: "DisplayPort 2"), .init(code: 0x11, name: "HDMI 1"), .init(code: 0x12, name: "HDMI 2")]
    static func name(for code: Int, display: Display) -> String {
        if display.isU5226KW, let known = dell52.first(where: { $0.code == code }) { return known.name }
        let standard = [1: "VGA 1", 2: "VGA 2", 3: "DVI 1", 4: "DVI 2", 5: "Composite 1", 6: "Composite 2",
                        7: "S-Video 1", 8: "S-Video 2", 9: "Tuner 1", 10: "Tuner 2", 11: "Tuner 3",
                        12: "Component 1", 13: "Component 2", 14: "Component 3", 15: "DisplayPort 1",
                        16: "DisplayPort 2", 17: "HDMI 1", 18: "HDMI 2"]
        return standard[code] ?? String(format: "Input 0x%02X", code)
    }
    // Extract a balanced named group; don't mistake commands or nested values for VCP features.
    static func group(_ name: String, in text: String) -> String? {
        let pattern = #"(?i)(?:^|[\s()])"# + NSRegularExpression.escapedPattern(for: name) + #"\s*\("#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let start = range.upperBound
        var depth = 1, index = start
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" { depth -= 1; if depth == 0 { return String(text[start..<index]) } }
            index = text.index(after: index)
        }
        return nil
    }
    static func codes(from capabilities: String) -> [Int] {
        guard let vcp = group("vcp", in: capabilities) else { return [] }
        // Remove nested groups attached to other features before searching for 60.
        let chars = Array(vcp)
        var index = 0
        while index < chars.count {
            while index < chars.count && chars[index].isWhitespace { index += 1 }
            let start = index
            while index < chars.count && chars[index].isHexDigit { index += 1 }
            guard index > start else { return [] }
            let token = String(chars[start..<index])
            while index < chars.count && chars[index].isWhitespace { index += 1 }
            if index < chars.count && chars[index] == "(" {
                index += 1
                let contentStart = index
                var depth = 1
                while index < chars.count && depth > 0 {
                    if chars[index] == "(" { depth += 1 }
                    if chars[index] == ")" { depth -= 1 }
                    if depth > 0 { index += 1 }
                }
                guard depth == 0 else { return [] }
                if token.lowercased() == "60" {
                    let values = String(chars[contentStart..<index]).split(whereSeparator: { $0.isWhitespace })
                    var codes: [Int] = []
                    for value in values {
                        guard value.count <= 2, let code = Int(value, radix: 16), code > 0 else { return [] }
                        if !codes.contains(code) { codes.append(code) }
                    }
                    return codes
                }
                index += 1
            }
        }
        return []
    }
    static func parseCustom(_ text: String) throws -> [InputDefinition] {
        var result: [InputDefinition] = []
        for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 48 else {
                throw SwitchError(message: "Use one input per line: HDMI 1 = 11")
            }
            let hex = parts[1].lowercased().hasPrefix("0x") ? String(parts[1].dropFirst(2)) : parts[1]
            guard hex.count <= 2, let code = Int(hex, radix: 16), (1...255).contains(code),
                  !result.contains(where: { $0.code == code }) else {
                throw SwitchError(message: "Input codes must be unique hexadecimal values from 01 to FF.")
            }
            result.append(.init(code: code, name: parts[0]))
        }
        guard !result.isEmpty, result.count <= 32 else { throw SwitchError(message: "Enter between 1 and 32 inputs.") }
        return result
    }
}

final class InputSettings {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func name(for input: MonitorInput) -> String? {
        defaults.string(forKey: "inputName.\(input.storageKey)")
    }
    func resetNames(for display: Display) {
        let prefix = "inputName.\(display.uuid):"
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
    func saveName(_ text: String, for input: MonitorInput) throws {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count <= 48, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SwitchError(message: "Use a name of up to 48 characters on one line.")
        }
        let key = "inputName.\(input.storageKey)"
        if name.isEmpty || name == input.sourceTitle { defaults.removeObject(forKey: key) }
        else { defaults.set(name, forKey: key) }
    }
    func custom(for display: Display) -> [InputDefinition]? {
        guard let data = defaults.data(forKey: "inputs.\(display.uuid)"),
              let inputs = try? JSONDecoder().decode([InputDefinition].self, from: data),
              !inputs.isEmpty else { return nil }
        return inputs
    }
    func save(_ inputs: [InputDefinition]?, for display: Display) throws {
        if let inputs = inputs { defaults.set(try JSONEncoder().encode(inputs), forKey: "inputs.\(display.uuid)") }
        else { defaults.removeObject(forKey: "inputs.\(display.uuid)") }
    }
}

final class Switcher {
    let run: ([String]) throws -> CommandResult
    let settings: InputSettings
    // Accessed only by the serial DDC worker (or synchronously by CLI/tests).
    private var cache: [String: (Date, [Int])] = [:]
    init(settings: InputSettings = InputSettings(), run: @escaping ([String]) throws -> CommandResult) {
        self.settings = settings; self.run = run
    }
    static func parseDisplays(_ output: String) -> [Display] {
        let regex = try! NSRegularExpression(pattern: #"^\[\d+\] (.+) \(([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})\)$"#)
        var seen = Set<String>()
        return output.components(separatedBy: .newlines).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let name = Range(match.range(at: 1), in: line), let id = Range(match.range(at: 2), in: line) else { return nil }
            let uuid = String(line[id]).uppercased()
            guard seen.insert(uuid).inserted else { return nil }
            return Display(name: String(line[name]), uuid: uuid)
        }
    }
    func list() throws -> [Display] {
        let result = try run(["display", "list"])
        guard result.status == 0 else { throw SwitchError(message: "No accessible external monitor was found. Connect and wake the monitor.\n\n\(result.output)") }
        return Self.parseDisplays(result.output)
    }
    func snapshots() throws -> [MonitorSnapshot] {
        let displays = try list()
        cache = cache.filter { key, _ in displays.contains(where: { $0.uuid == key }) }
        return displays.map { display in
            var definitions: [InputDefinition] = []
            var notice: String?
            if let custom = settings.custom(for: display) { definitions = custom }
            else if display.isU5226KW { definitions = InputCatalog.dell52 }
            else {
                let codes: [Int]
                if let cached = cache[display.uuid], Date().timeIntervalSince(cached.0) < (cached.1.isEmpty ? 30 : 600) { codes = cached.1 }
                else {
                    let result = try? run(["display", display.uuid, "capabilities"])
                    codes = result?.status == 0 ? InputCatalog.codes(from: result!.output) : []
                    cache[display.uuid] = (Date(), codes)
                }
                definitions = codes.map { .init(code: $0, name: InputCatalog.name(for: $0, display: display)) }
                if definitions.isEmpty { notice = "Inputs not reported. Configure in Preferences." }
            }
            let result = try? run(["display", display.uuid, "get", "input"])
            let raw = result?.status == 0 ? UInt16(result!.output.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
            let selected = raw.map { Int($0 & 0xff) }
            return MonitorSnapshot(display: display, inputs: definitions.map {
                let input = MonitorInput(displayID: display.uuid, rawValue: $0.code, title: $0.name)
                return MonitorInput(displayID: display.uuid, rawValue: $0.code,
                                    title: settings.name(for: input) ?? $0.name, sourceTitle: $0.name)
            }, selected: selected, inputNotice: notice)
        }
    }
    func switchTo(_ input: MonitorInput) throws -> Display {
        guard let display = try list().first(where: { $0.uuid == input.displayID }) else {
            throw SwitchError(message: "That monitor is no longer connected. Reconnect it and try again.")
        }
        let result = try run(["display", display.uuid, "set", "input", String(input.rawValue)])
        guard result.status == 0 else { throw SwitchError(message: "Could not switch \(display.name) to \(input.title). Check DDC/CI and the display connection.\n\n\(result.output)") }
        return display
    }
}
struct HelperRunner {
    let executable: URL
    var timeout: TimeInterval = 12

    func run(_ arguments: [String]) throws -> CommandResult {
        // m1ddc reopens /dev/stdout for each line. Use a pipe so those opens
        // cannot truncate earlier lines, and drain concurrently to avoid blocking.
        let output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        try? output.fileHandleForWriting.close()
        let captured = CapturedOutput()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            captured.store(output.fileHandleForReading.readDataToEndOfFile())
            try? output.fileHandleForReading.close()
            drained.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw SwitchError(message: "The display-control helper timed out. Check the monitor and cable, then try again.")
        }
        guard drained.wait(timeout: .now() + 1) == .success else {
            throw SwitchError(message: "The display-control helper did not close its output.")
        }
        let data = captured.load()
        return CommandResult(status: process.terminationStatus,
                             output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private final class CapturedOutput {
    private let lock = NSLock()
    private var data = Data()
    func store(_ value: Data) { lock.lock(); defer { lock.unlock() }; data = value }
    func load() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
