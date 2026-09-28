import AppKit
import ServiceManagement

final class PreferencesController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let shortcuts: ShortcutManager
    private let settings: InputSettings
    private var monitors: [MonitorSnapshot]
    var onInputsChanged: (() -> Void)?
    private let loginCheckbox = NSButton(checkboxWithTitle: "Start at Login", target: nil, action: nil)
    private let loginHelp = NSButton(title: "Approve in System Settings…", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let rows = NSStackView()
    private var scrollHeight: NSLayoutConstraint!
    private var recorders: [MonitorInput: NSButton] = [:]
    private var clears: [MonitorInput: NSButton] = [:]
    private var nameFields: [MonitorInput: NSTextField] = [:]
    private var actions: [Int: MonitorInput] = [:]
    private var recording: MonitorInput?
    private var eventMonitor: Any?
    private var contentHeight: CGFloat = 200

    init(shortcuts: ShortcutManager, monitors: [MonitorSnapshot], settings: InputSettings) {
        self.shortcuts = shortcuts; self.monitors = monitors; self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 380),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Input Selector"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let content = NSView()
        window.contentView = content
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18)
        ])
        loginCheckbox.target = self; loginCheckbox.action = #selector(toggleLogin)
        stack.addArrangedSubview(loginCheckbox)
        loginHelp.isBordered = false; loginHelp.contentTintColor = .linkColor
        loginHelp.target = self; loginHelp.action = #selector(openLoginSettings)
        stack.addArrangedSubview(loginHelp)
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 10
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = rows
        stack.addArrangedSubview(scroll)
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 220)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scrollHeight,
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: 402).isActive = true
        stack.addArrangedSubview(hint)
        rebuildRows()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ newMonitors: [MonitorSnapshot]) {
        let signature: ([MonitorSnapshot]) -> [String] = { values in
            values.map { $0.display.uuid + $0.display.name + $0.inputs.map { $0.storageKey + $0.sourceTitle }.joined() + ($0.inputNotice ?? "") }
        }
        let changed = signature(monitors) != signature(newMonitors)
        monitors = newMonitors
        if changed { finishRecording(); rebuildRows() }
        else {
            // A rename should not destroy the field the user is currently editing.
            let inputs = newMonitors.flatMap(\.inputs)
            for (tag, oldInput) in actions {
                if let input = inputs.first(where: { $0 == oldInput }) { actions[tag] = input }
            }
            for input in inputs {
                if let field = nameFields[input], field.currentEditor() == nil { field.stringValue = input.title }
            }
            reload()
        }
    }
    func present() {
        reload(); showWindow(nil)
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    private func rebuildRows() {
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        recorders = [:]; clears = [:]; nameFields = [:]; actions = [:]
        contentHeight = 0
        if monitors.isEmpty {
            rows.addArrangedSubview(NSTextField(labelWithString: "Connect an external monitor to configure inputs."))
            contentHeight = 50
        }
        for (index, monitor) in monitors.enumerated() {
            let label = NSTextField(labelWithString: monitor.display.name)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.lineBreakMode = .byTruncatingTail
            label.widthAnchor.constraint(equalToConstant: 285).isActive = true
            let edit = NSButton(title: "Inputs…", target: self, action: #selector(editInputs(_:)))
            edit.bezelStyle = .rounded; edit.tag = index
            rows.addArrangedSubview(NSStackView(views: [label, edit]))
            contentHeight += 40
            if let notice = monitor.inputNotice {
                let note = NSTextField(wrappingLabelWithString: notice)
                note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
                note.widthAnchor.constraint(equalToConstant: 370).isActive = true
                rows.addArrangedSubview(note); contentHeight += 40
            }
            for input in monitor.inputs {
                let tag = actions.count; actions[tag] = input
                let label = NSTextField(string: input.title)
                label.delegate = self; label.tag = tag
                label.placeholderString = input.sourceTitle
                label.toolTip = "\(input.sourceTitle) — edit to rename; leave blank to restore."
                label.setAccessibilityLabel("Name for \(input.sourceTitle) on \(monitor.display.name)")
                label.widthAnchor.constraint(equalToConstant: 175).isActive = true
                nameFields[input] = label
                let recorder = NSButton(title: "Record Shortcut", target: self, action: #selector(startRecording(_:)))
                recorder.bezelStyle = .rounded; recorder.tag = tag
                recorder.widthAnchor.constraint(equalToConstant: 155).isActive = true
                recorder.setAccessibilityLabel("Shortcut for \(monitor.display.name), \(input.title)")
                recorders[input] = recorder
                let clear = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear shortcut")!,
                                     target: self, action: #selector(clearShortcut(_:)))
                clear.isBordered = false; clear.contentTintColor = .secondaryLabelColor; clear.tag = tag
                clear.toolTip = "Clear \(input.title) shortcut"; clears[input] = clear
                let row = NSStackView(views: [label, recorder, clear]); row.spacing = 8
                rows.addArrangedSubview(row); contentHeight += 34
            }
            let reset = NSButton(title: "Reset Names", target: self, action: #selector(resetNames(_:)))
            reset.bezelStyle = .rounded; reset.tag = index
            reset.toolTip = "Restore the original input names for \(monitor.display.name)."
            rows.addArrangedSubview(reset); contentHeight += 34
        }
        scrollHeight.constant = min(420, max(50, contentHeight))
        reload()
    }
    private func reload() {
        let status = SMAppService.mainApp.status
        loginCheckbox.allowsMixedState = true
        loginCheckbox.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        loginHelp.isHidden = status != .requiresApproval
        window?.setContentSize(NSSize(width: 450, height: scrollHeight.constant + (loginHelp.isHidden ? 145 : 185)))
        for input in monitors.flatMap(\.inputs) {
            recorders[input]?.title = recording == input ? "Type shortcut…" : (shortcuts.shortcut(for: input)?.display ?? "Record Shortcut")
            clears[input]?.isEnabled = shortcuts.shortcut(for: input) != nil
        }
        hint.stringValue = shortcuts.registrationErrors.first ?? "Edit an input name and press Return to save. Shortcuts use ⌘ or ⌃; Escape cancels recording."
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let input = actions[field.tag] else { return }
        do {
            try settings.saveName(field.stringValue, for: input)
            field.stringValue = settings.name(for: input) ?? input.sourceTitle
            onInputsChanged?()
        } catch {
            field.stringValue = settings.name(for: input) ?? input.sourceTitle
            hint.stringValue = error.localizedDescription
        }
    }
    @objc private func resetNames(_ sender: NSButton) {
        finishRecording()
        guard monitors.indices.contains(sender.tag) else { return }
        // Commit the active field before removing names so it cannot save an old alias afterward.
        window?.makeFirstResponder(nil)
        let monitor = monitors[sender.tag]
        settings.resetNames(for: monitor.display)
        var restored = monitors
        restored[sender.tag] = MonitorSnapshot(display: monitor.display, inputs: monitor.inputs.map {
            MonitorInput(displayID: $0.displayID, rawValue: $0.rawValue, title: $0.sourceTitle)
        }, selected: monitor.selected, inputNotice: monitor.inputNotice)
        update(restored)
        onInputsChanged?()
    }
    @objc private func editInputs(_ sender: NSButton) {
        finishRecording()
        guard monitors.indices.contains(sender.tag), let window = window else { return }
        let monitor = monitors[sender.tag]
        let alert = NSAlert()
        alert.messageText = "Inputs for \(monitor.display.name)"
        alert.informativeText = "One input per line: name = hexadecimal code. Use Automatic to restore the monitor’s reported inputs."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Automatic"); alert.addButton(withTitle: "Cancel")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.string = monitor.inputs.map { String(format: "%@ = %02X", $0.sourceTitle, $0.rawValue) }.joined(separator: "\n")
        scroll.documentView = text; alert.accessoryView = scroll
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response != .alertThirdButtonReturn else { return }
            do {
                if response == .alertSecondButtonReturn { try self.settings.save(nil, for: monitor.display) }
                else { try self.settings.save(InputCatalog.parseCustom(text.string), for: monitor.display) }
                self.onInputsChanged?()
            } catch { self.hint.stringValue = error.localizedDescription }
        }
    }
    @objc private func startRecording(_ sender: NSButton) {
        finishRecording()
        guard let input = actions[sender.tag] else { return }
        recording = input
        shortcuts.suspend()
        reload()
        hint.stringValue = "Press a shortcut for \(input.title). Escape cancels."
        // Local capture only: no Accessibility or Input Monitoring permission.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let input = self.recording else { return event }
            if event.isARepeat { return nil }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 53 && flags.isEmpty { self.finishRecording(); self.reload(); return nil }
            if (event.keyCode == 51 || event.keyCode == 117) && flags.isEmpty {
                self.finishRecording()
                self.save(nil, for: input)
                return nil
            }
            do {
                let shortcut = try InputShortcut.from(event)
                self.finishRecording()
                self.save(shortcut, for: input)
            } catch { self.hint.stringValue = error.localizedDescription }
            return nil
        }
    }

    private func finishRecording() {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
        eventMonitor = nil
        recording = nil
        shortcuts.resume()
    }

    private func save(_ shortcut: InputShortcut?, for input: MonitorInput) {
        do { try shortcuts.set(shortcut, for: input); reload() }
        catch { reload(); hint.stringValue = error.localizedDescription }
    }
    @objc private func clearShortcut(_ sender: NSButton) {
        finishRecording()
        if let input = actions[sender.tag] { save(nil, for: input) }
    }
    @objc private func toggleLogin() {
        finishRecording()
        do {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            } else { try SMAppService.mainApp.register() }
            reload()
        } catch { reload(); hint.stringValue = error.localizedDescription }
    }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    func windowWillClose(_ notification: Notification) { finishRecording() }
    func windowDidResignKey(_ notification: Notification) { finishRecording(); reload() }
    func windowDidBecomeKey(_ notification: Notification) { reload() }
}
