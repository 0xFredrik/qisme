import Foundation
import AppKit
import Carbon

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }; checks += 1
}
func expectFailure(_ fragment: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError("Expected failure: \(fragment)") }
    catch { check(error.localizedDescription.contains(fragment), error.localizedDescription) }
}
let dellID = "11111111-2222-3333-4444-555555555555"
let otherID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
let listing = "[1] Example Display (\(otherID))\n[2] DELL U5226KW (\(dellID))\n"
let caps = "(prot(monitor)cmds(01 02 60)vcp(10 14(01 04) 60(0f 10 11 12 1b) D6(01 04)))"
let suiteName = "local.input-selector.tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }
let settings = InputSettings(defaults: defaults)
var calls: [[String]] = []
let switcher = Switcher(settings: settings) { args in
    calls.append(args)
    if args == ["display", "list"] { return CommandResult(status: 0, output: listing) }
    if args.last == "capabilities" { return CommandResult(status: 0, output: caps) }
    return CommandResult(status: 0, output: args.contains("get") ? (args[1] == dellID ? "6425" : "17") : "Writing")
}
let monitors = try switcher.snapshots()
check(monitors.count == 2, "Must automatically detect both monitors")
check(monitors[0].inputs.map(\.rawValue) == [15,16,17,18,27], "Advertised input discovery")
check(monitors[0].inputs[1].title == "DisplayPort 2", "Generic DP2 must use 0x10")
check(monitors[0].inputs[4].title == "Input 0x1B", "Unknown vendor input must not be falsely named")
check(monitors[1].inputs[2].rawValue == 19 && monitors[1].inputs[2].title == "DisplayPort 2", "Dell DP2 quirk")
check(monitors[1].selected == 25 && monitors[0].selected == 17, "Selected input values")
check(!calls.contains(where: { $0.contains("set") }), "Discovery must not switch monitors")
let before = calls.filter { $0.last == "capabilities" }.count
_ = try switcher.snapshots()
check(calls.filter { $0.last == "capabilities" }.count == before, "Successful capability cache")
for monitor in monitors {
    for input in monitor.inputs {
        _ = try switcher.switchTo(input)
        check(calls.last == ["display", monitor.display.uuid, "set", "input", String(input.rawValue)], "Input must target its own UUID")
    }
}
let absent = Switcher(settings: settings) { args in
    check(args == ["display", "list"], "Disconnected shortcut must not send a write")
    return CommandResult(status: 0, output: "[1] Example Display (\(otherID))")
}
expectFailure("no longer connected") { _ = try absent.switchTo(monitors[1].inputs[0]) }
let failure = Switcher(settings: settings) { args in
    CommandResult(status: args == ["display", "list"] ? 0 : 1, output: args == ["display", "list"] ? listing : "DDC failure")
}
expectFailure("Could not switch") { _ = try failure.switchTo(monitors[0].inputs[0]) }
let unreadable = try failure.snapshots()
check(unreadable[0].inputs.isEmpty && unreadable[0].inputNotice != nil, "No fabricated inputs after capability failure")
check(unreadable[0].selected == nil, "Failed current-input read must stay unknown")
check(unreadable[1].inputs.count == 5, "Known model profile survives failed capability reporting")
check(Switcher.parseDisplays(listing + listing).count == 2, "Deduplicate displays by UUID")
check(Switcher.parseDisplays("[1] Something (bad)").isEmpty, "Reject malformed display identifiers")
check(InputCatalog.codes(from: caps) == [15,16,17,18,27], "Capability parser")
check(InputCatalog.codes(from: "(vcp(60(11 11 0F)))") == [17,15], "Deduplicate inputs")
for text in ["", "60(11 12)", "(cmds(60(11)))", "(vcp(14(60(11))))", "(vcp(60(11 12)", "(vcp(60(11 ZZ)))", "(vcp(60(100)))", "(vcp(60(00)))"] {
    check(InputCatalog.codes(from: text).isEmpty, "Malformed or unrelated capability accepted: \(text)")
}
let custom = try InputCatalog.parseCustom("Work PC = 0x0F\nMac = 1B")
check(custom.map(\.code) == [15,27], "Custom hexadecimal codes")
for text in ["", "No equals", "Port = ZZ", "Port = 00", "Port = 100", "A = 11\nB = 11"] {
    do { _ = try InputCatalog.parseCustom(text); fatalError("Invalid custom inputs accepted") } catch { checks += 1 }
}
try settings.save(custom, for: monitors[0].display)
check(try! switcher.snapshots()[0].inputs.map(\.title) == ["Work PC", "Mac"], "Overrides take priority")
check(settings.custom(for: monitors[1].display) == nil, "Overrides leaked to another monitor")
try settings.save(nil, for: monitors[0].display)
check(try! switcher.snapshots()[0].inputs.count == 5, "Automatic restores detection")

// Friendly names preserve autodetection, numeric input identity and monitor scope.
let dellDP1 = monitors[1].inputs[1]
try settings.saveName("  Work PC  ", for: dellDP1)
let renamed = try switcher.snapshots()[1].inputs[1]
check(renamed.title == "Work PC" && renamed.sourceTitle == "DisplayPort 1", "Display name overlay")
check(renamed == dellDP1 && renamed.storageKey == dellDP1.storageKey, "Rename changed input/shortcut identity")
check(InputSettings(defaults: defaults).name(for: dellDP1) == "Work PC", "Custom name persists")
check(settings.name(for: monitors[0].inputs[0]) == nil, "Name leaked to a different monitor")
check(settings.custom(for: monitors[1].display) == nil, "Naming should not override detected inputs")
_ = try switcher.switchTo(renamed)
check(calls.last == ["display", dellID, "set", "input", "15"], "Renamed input changed switch command")
expectFailure("48 characters") { try settings.saveName(String(repeating: "A", count: 49), for: dellDP1) }
try settings.saveName("", for: dellDP1)
check(try! switcher.snapshots()[1].inputs[1].title == "DisplayPort 1", "Blank name restores default")

let shell = HelperRunner(executable: URL(fileURLWithPath: "/bin/sh"), timeout: 2)
let processResult = try shell.run(["-c", "echo stdout; echo stderr >&2; exit 7"])
check(processResult.status == 7 && processResult.output.contains("stdout") && processResult.output.contains("stderr"), "Process status/output")
let reopened = try shell.run(["-c", "printf 'first\\n' > /dev/stdout; printf 'second\\n' > /dev/stdout"])
check(reopened.output == "first\nsecond", "Reopening stdout lost data")
let large = try shell.run(["-c", "i=0; while [ $i -lt 12000 ]; do echo output; i=$((i+1)); done"])
check(large.output.components(separatedBy: .newlines).count == 12000, "Large pipe output")
let slow = HelperRunner(executable: URL(fileURLWithPath: "/bin/sleep"), timeout: 0.05)
expectFailure("timed out") { _ = try slow.run(["5"]) }

_ = NSApplication.shared
var manager: ShortcutManager? = ShortcutManager(defaults: defaults)
manager!.configure(monitors)
let input = monitors[0].inputs[0]
let otherInput = monitors[1].inputs[1]
let first = InputShortcut(keyCode: 105, modifiers: UInt32(cmdKey | controlKey | optionKey), keyLabel: "F13")
let second = InputShortcut(keyCode: 107, modifiers: UInt32(cmdKey | controlKey | optionKey), keyLabel: "F14")
try manager!.set(first, for: input)
check(manager!.shortcut(for: input) == first, "Save shortcut")
expectFailure("already assigned") { try manager!.set(first, for: otherInput) }
check(manager!.shortcut(for: otherInput) == nil, "No shortcut leakage across displays")
try settings.saveName("Workstation", for: input)
manager!.configure(try switcher.snapshots())
check(manager!.shortcut(for: input) == first, "Renaming lost the registered shortcut")
var triggered: MonitorInput?
manager!.onTrigger = { triggered = $0 }
var event: EventRef?
check(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr, "Create event")
var hotkeyID = EventHotKeyID(signature: 0x49534C43, id: 1)
check(SetEventParameter(event!, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                        MemoryLayout<EventHotKeyID>.size, &hotkeyID) == noErr, "Set event data")
_ = SendEventToEventTarget(event!, GetApplicationEventTarget())
check(triggered == input && triggered?.title == "Workstation", "Hotkey routes to renamed monitor/input")
try settings.saveName("", for: input)
triggered = nil; manager!.suspend()
_ = SendEventToEventTarget(event!, GetApplicationEventTarget())
check(triggered == nil, "No dispatch during recording")
manager!.resume(); ReleaseEvent(event!)
try manager!.set(second, for: input)
check(manager!.shortcut(for: input) == second, "Replace shortcut")
manager!.configure([])
check(manager!.shortcut(for: input) == second, "Keep saved shortcuts when disconnected")
manager!.configure(monitors)
check(manager!.registrationErrors.isEmpty, "Restore hotkey on reconnect")
manager = nil
manager = ShortcutManager(defaults: defaults); manager!.configure(monitors)
check(manager!.shortcut(for: input) == second && manager!.registrationErrors.isEmpty, "Restore on relaunch")
try manager!.set(nil, for: input)
manager = nil
manager = ShortcutManager(defaults: defaults); manager!.configure(monitors)
check(manager!.shortcut(for: input) == nil, "Cleared shortcut stays cleared")
manager = nil
let plainEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
    windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
expectFailure("Include Command") { _ = try InputShortcut.from(plainEvent) }
let modifiedEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
    windowNumber: 0, context: nil, characters: "A", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
check(try! InputShortcut.from(modifiedEvent).display == "⇧⌘A", "Recorder modifiers")
print("Passed \(checks) Swift checks. No monitor writes or physical keyboard events sent.")
