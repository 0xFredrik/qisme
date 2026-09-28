import AppKit
import ServiceManagement

let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/m1ddc")
let discoveryURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/display-discovery")
let inputSettings = InputSettings()
let switcher = Switcher(settings: inputSettings) { arguments in
    let discovery = arguments == ["display", "list"] || arguments.last == "capabilities"
    return try HelperRunner(executable: discovery ? discoveryURL : helperURL,
                            timeout: arguments.last == "capabilities" ? 30 : 12).run(arguments)
}
let arguments = Array(CommandLine.arguments.dropFirst())

if !arguments.isEmpty && arguments != ["--preferences"] {
    do {
        switch arguments {
        case ["--list"]:
            for display in try switcher.list() { print("\(display.name) (\(display.uuid))") }
        case ["--dry-run"], ["--status"]:
            for monitor in try switcher.snapshots() {
                print("\(monitor.display.name) (\(monitor.display.uuid))")
                for input in monitor.inputs {
                    print(String(format: "  %@ %@ (0x%02X)", monitor.selected == input.rawValue ? "✓" : " ", input.title, input.rawValue))
                }
                if let notice = monitor.inputNotice { print(notice) }
            }
        case ["--login-status"]:
            print("Login item status: \(SMAppService.mainApp.status.rawValue) (0=not registered, 1=enabled, 2=requires approval, 3=not found)")
        case ["--help"]:
            print("Input Selector — automatically detects external monitors.\n--list         List monitors\n--status       Read monitors and inputs (also --dry-run)\n--login-status Read login registration\n--preferences Open Preferences\n--switch       Switch a single connected monitor to DP1\n--switch UUID HEX  Switch a specific monitor to an advertised/configured input")
        default:
            guard arguments.first == "--switch" else { throw SwitchError(message: "Unknown arguments. Use --help.") }
            let monitors = try switcher.snapshots()
            let monitor: MonitorSnapshot
            let code: Int
            if arguments.count == 3, let parsed = Int(arguments[2].lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16),
               let match = monitors.first(where: { $0.display.uuid == arguments[1].uppercased() }) {
                monitor = match; code = parsed
            } else if arguments == ["--switch"] || arguments == ["--switch", "--allow-unknown"] {
                guard monitors.count == 1 else { throw SwitchError(message: "Specify the monitor UUID when more than one monitor is connected.") }
                monitor = monitors[0]; code = 15
            } else { throw SwitchError(message: "Use --switch UUID HEX or --help.") }
            guard let input = monitor.inputs.first(where: { $0.rawValue == code }) else {
                throw SwitchError(message: "That input is not reported or configured for this monitor. Check Preferences → Inputs.")
            }
            let display = try switcher.switchTo(input)
            print("\(input.title) command sent to \(display.name).")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var inputItems: [MonitorInput: NSMenuItem] = [:]
    private var actions: [Int: MonitorInput] = [:]
    private let worker = DispatchQueue(label: "local.input-selector.ddc", qos: .userInitiated)
    private var monitors: [MonitorSnapshot] = []
    private var switching = false
    private var refreshing = false
    private var refreshPending = false
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var shortcuts: ShortcutManager!
    private var preferences: PreferencesController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: {
               $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
           }) { NSApp.terminate(nil); return }
        shortcuts = ShortcutManager()
        shortcuts.onTrigger = { [weak self] input in self?.switchInput(input) }
        shortcuts.onChange = { [weak self] in self?.updateRows() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Input Selector")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "Input Selector"
        menu.autoenablesItems = false; menu.delegate = self
        rebuildMenu()
        statusItem.menu = menu
        if !UserDefaults.standard.bool(forKey: "loginRegistrationAttempted") {
            UserDefaults.standard.set(true, forKey: "loginRegistrationAttempted")
            do { try SMAppService.mainApp.register() }
            catch { showError("Couldn’t enable Start at Login", error.localizedDescription) }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.refresh() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refresh() } })
        refresh()
        if arguments == ["--preferences"] { showPreferences() }
    }
    @discardableResult private func addItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; menu.addItem(item); return item
    }
    private func rebuildMenu() {
        menu.removeAllItems(); inputItems = [:]; actions = [:]
        if monitors.isEmpty { addHeader("No external monitor") }
        for (index, monitor) in monitors.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            let duplicate = monitors.filter { $0.display.name == monitor.display.name }.count > 1
            addHeader(monitor.display.name + (duplicate ? " · \(monitor.display.uuid.suffix(4))" : ""))
            for input in monitor.inputs {
                let item = addItem(input.title, action: #selector(selectInput(_:)))
                let tag = actions.count; actions[tag] = input; item.tag = tag
                inputItems[input] = item
            }
            if monitor.inputs.isEmpty { addItem("Configure Inputs…", action: #selector(showPreferences)) }
        }
        menu.addItem(.separator())
        addItem("Preferences…", action: #selector(showPreferences), key: ",")
        addItem("Quit Input Selector", action: #selector(quit), key: "q")
        updateRows()
    }
    private func addHeader(_ title: String) {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 30))
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold); name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail; name.toolTip = title
        name.frame = NSRect(x: 20, y: 6, width: 225, height: 18)
        view.addSubview(name); item.view = view; menu.addItem(item)
    }
    func menuWillOpen(_ menu: NSMenu) { refresh() }
    private func updateRows() {
        for monitor in monitors {
            for input in monitor.inputs {
                inputItems[input]?.state = monitor.selected == input.rawValue ? .on : .off
                inputItems[input]?.isEnabled = !switching
                inputItems[input]?.toolTip = shortcuts.shortcut(for: input)?.display
            }
        }
    }
    private func refresh() {
        guard !refreshing, !switching else { refreshPending = true; return }
        refreshing = true; refreshPending = false
        let version = generation
        worker.async {
            let values = (try? switcher.snapshots()) ?? []
            DispatchQueue.main.async {
                self.refreshing = false
                if version == self.generation {
                    let old = self.monitors.map { $0.display.name + $0.display.uuid + $0.inputs.map { $0.storageKey + $0.title }.joined() }
                    let new = values.map { $0.display.name + $0.display.uuid + $0.inputs.map { $0.storageKey + $0.title }.joined() }
                    self.monitors = values
                    self.preferences?.update(values)
                    self.shortcuts.configure(values)
                    if old != new { self.rebuildMenu() } else { self.updateRows() }
                }
                if self.refreshPending { self.refresh() }
            }
        }
    }
    @objc private func selectInput(_ sender: NSMenuItem) {
        if let input = actions[sender.tag] { switchInput(input) }
    }
    private func switchInput(_ input: MonitorInput) {
        guard !switching else { return }
        switching = true; generation += 1; updateRows()
        worker.async {
            let result = Result { try switcher.switchTo(input) }
            DispatchQueue.main.async {
                self.switching = false; self.updateRows()
                if case .failure(let error) = result { self.showError("Couldn’t switch input", error.localizedDescription) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
            }
        }
    }
    @objc private func showPreferences() {
        if preferences == nil {
            preferences = PreferencesController(shortcuts: shortcuts, monitors: monitors, settings: inputSettings)
            preferences?.onInputsChanged = { [weak self] in self?.refresh() }
        }
        preferences?.present()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    private func showError(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.alertStyle = .warning; alert.addButton(withTitle: "OK"); alert.runModal()
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory); app.delegate = delegate; app.run()
