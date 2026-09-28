import AppKit
import Carbon

struct InputShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel
    }
    func matches(_ other: InputShortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
    static func from(_ event: NSEvent) throws -> InputShortcut {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) else {
            throw SwitchError(message: "Include Command (⌘) or Control (⌃) in your shortcut.")
        }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15"]
        let label = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !label.isEmpty else { throw SwitchError(message: "Choose a letter, number, arrow, or function key.") }
        return InputShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
    }
}

final class ShortcutManager {
    private static let signature: OSType = 0x49534C43 // ISLC
    private let defaults: UserDefaults
    private var values: [String: InputShortcut] = [:]
    private var registrations: [MonitorInput: EventHotKeyRef] = [:]
    private var inputs: [MonitorInput] = []
    private var eventInputs: [UInt32: MonitorInput] = [:]
    private var nextEventID: UInt32 = 1
    private var handler: EventHandlerRef?
    private var suspended = false
    private(set) var registrationErrors: [String] = []
    var onTrigger: ((MonitorInput) -> Void)?
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "inputShortcuts"),
           let saved = try? JSONDecoder().decode([String: InputShortcut].self, from: data) { values = saved }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event = event, let context = context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == ShortcutManager.signature else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<ShortcutManager>.fromOpaque(context).takeUnretainedValue()
            if !manager.suspended, let input = manager.eventInputs[id.id], manager.inputs.contains(input) { manager.onTrigger?(input) }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { registrationErrors = ["Couldn’t initialize global shortcuts (\(status))."] }
        else { restoreRegistrations() }
    }

    deinit {
        for ref in registrations.values { UnregisterEventHotKey(ref) }
        if let handler = handler { RemoveEventHandler(handler) }
    }

    func configure(_ monitors: [MonitorSnapshot]) {
        let newInputs = monitors.flatMap(\.inputs)
        guard newInputs != inputs else {
            inputs = newInputs
            for (id, oldInput) in eventInputs {
                if let input = newInputs.first(where: { $0 == oldInput }) { eventInputs[id] = input }
            }
            return
        }
        suspend()
        inputs = newInputs
        resume()
    }

    func shortcut(for input: MonitorInput) -> InputShortcut? { values[input.storageKey] }

    func set(_ shortcut: InputShortcut?, for input: MonitorInput) throws {
        guard !suspended else { throw SwitchError(message: "Finish recording before saving a shortcut.") }
        if let shortcut = shortcut {
            for (key, existing) in values where key != input.storageKey {
                if shortcut.matches(existing) {
                    throw SwitchError(message: "That shortcut is already assigned to another input.")
                }
            }
            if let old = self.shortcut(for: input), old.matches(shortcut), registrations[input] != nil { return }
            // Register the new key first; keep the old binding if macOS rejects it.
            let ref = try register(shortcut, for: input)
            if let previous = registrations[input] { UnregisterEventHotKey(previous) }
            registrations[input] = ref
            values[input.storageKey] = shortcut
        } else {
            if let previous = registrations.removeValue(forKey: input) { UnregisterEventHotKey(previous) }
            values.removeValue(forKey: input.storageKey)
        }
        defaults.set(try JSONEncoder().encode(values), forKey: "inputShortcuts")
        onChange?()
    }

    func suspend() {
        suspended = true
        for ref in registrations.values { UnregisterEventHotKey(ref) }
        registrations.removeAll()
        eventInputs.removeAll()
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        restoreRegistrations()
    }

    private func register(_ shortcut: InputShortcut, for input: MonitorInput) throws -> EventHotKeyRef {
        guard handler != nil else { throw SwitchError(message: "Global keyboard shortcuts are unavailable.") }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: nextEventID)
        nextEventID += 1
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref = ref else {
            throw SwitchError(message: "macOS couldn’t register \(shortcut.display). It may be in use by another app or the system. Choose another shortcut.")
        }
        eventInputs[id.id] = input
        return ref
    }

    private func restoreRegistrations() {
        registrationErrors = []
        for input in inputs {
            guard let shortcut = shortcut(for: input) else { continue }
            do { registrations[input] = try register(shortcut, for: input) }
            catch { registrationErrors.append("\(input.title): \(error.localizedDescription)") }
        }
    }
}
