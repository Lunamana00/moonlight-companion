import AppKit
import CoreGraphics
import Foundation

struct CompanionSettings {
    static let orderedKeys = [
        "WINDOWS_SSH",
        "MOONLIGHT_HOST",
        "MOONLIGHT_APP",
        "MOONLIGHT_STREAM_APP",
        "MOONLIGHT_RESOLUTION",
        "MOONLIGHT_FPS",
        "MOONLIGHT_BITRATE",
        "MOONLIGHT_DISPLAY_MODE",
        "MOONLIGHT_DISPLAY_INDEX",
        "MOONLIGHT_DISPLAY_PLACEMENT_TIMEOUT_SECONDS",
        "MOONLIGHT_VIDEO_CODEC",
        "MOONLIGHT_CAPTURE_SYSTEM_KEYS",
        "MOONLIGHT_ABSOLUTE_MOUSE",
        "MOONLIGHT_QUIT_EXISTING",
        "MOONLIGHT_CAPSLOCK_HANGUL",
        "MOONLIGHT_SHORTCUT_REMAP",
        "MOONLIGHT_CAPSLOCK_HANGUL_TCP_PORT",
        "MOONLIGHT_CAPSLOCK_HANGUL_TCP_LOCAL_PORT",
        "MOONLIGHT_CLIPBOARD_TCP",
        "MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_PORT",
        "MOONLIGHT_CLIPBOARD_MAC_TO_WINDOWS_TCP_LOCAL_PORT",
        "MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_PORT",
        "MOONLIGHT_CLIPBOARD_WINDOWS_TO_MAC_TCP_LOCAL_PORT",
        "MOONLIGHT_CLIPBOARD_MAX_BYTES",
        "MOONLIGHT_TRANSFER_MAC_DIR",
        "MOONLIGHT_TRANSFER_WINDOWS_DIR",
        "MOONLIGHT_TRANSFER_AUTO_PASTE"
    ]

    var values: [String: String]

    subscript(key: String) -> String {
        get { values[key] ?? "" }
        set { values[key] = newValue }
    }

    func bool(_ key: String) -> Bool {
        switch self[key].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "y", "yes", "true", "on":
            return true
        default:
            return false
        }
    }

    mutating func setBool(_ key: String, _ enabled: Bool) {
        values[key] = enabled ? "yes" : "no"
    }
}

enum SettingsFile {
    static let userURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MoonlightCompanion/moonlight-companion.conf")
    }()

    static func bundledURL(resourceURL: URL) -> URL {
        let local = resourceURL.appendingPathComponent("config/moonlight-companion.conf")
        if FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        return resourceURL.appendingPathComponent("config/moonlight-companion.conf.example")
    }

    static func load(resourceURL: URL) -> CompanionSettings {
        let example = resourceURL.appendingPathComponent("config/moonlight-companion.conf.example")
        let local = resourceURL.appendingPathComponent("config/moonlight-companion.conf")
        var values = parse(url: example)
        if FileManager.default.fileExists(atPath: local.path) {
            values.merge(parse(url: local)) { _, new in new }
        }
        if FileManager.default.fileExists(atPath: userURL.path) {
            values.merge(parse(url: userURL)) { _, new in new }
        }
        return CompanionSettings(values: values)
    }

    static func parse(url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }

        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }

            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
                value = value.replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            values[key] = value
        }
        return values
    }

    static func save(_ settings: CompanionSettings) throws {
        try FileManager.default.createDirectory(
            at: userURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var lines = ["# Moonlight Companion settings", ""]
        for key in CompanionSettings.orderedKeys {
            let value = settings[key]
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("\(key)=\"\(value)\"")
        }
        lines.append("")
        try lines.joined(separator: "\n").write(to: userURL, atomically: true, encoding: .utf8)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var dropStripWindow: NSPanel?
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var progressIndicator: NSProgressIndicator!
    private var startButton: NSButton!
    private var stopMoonlightButton: NSButton!
    private var saveButton: NSButton!
    private var stopButton: NSButton!
    private var dropStripButton: NSButton!
    private var output = Data()
    private var process: Process?
    private var transferProcess: Process?
    private var settings = CompanionSettings(values: [:])
    private var resourceURL: URL!

    private var textFields: [String: NSTextField] = [:]
    private var popups: [String: NSPopUpButton] = [:]
    private var popupValues: [String: [String]] = [:]
    private var checks: [String: NSButton] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        guard let resourceURL = Bundle.main.resourceURL else {
            buildWindow()
            fail("Missing app resources.")
            return
        }
        self.resourceURL = resourceURL
        settings = SettingsFile.load(resourceURL: resourceURL)
        buildWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Moonlight Companion"
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        let header = NSTextField(labelWithString: "Moonlight Companion")
        header.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        header.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "Ready")
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel = NSTextField(labelWithString: SettingsFile.userURL.path)
        detailLabel.font = NSFont.systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .regular
        progressIndicator.isHidden = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 14
        form.translatesAutoresizingMaskIntoConstraints = false

        form.addArrangedSubview(sectionTitle("Connection"))
        form.addArrangedSubview(row("Windows SSH", text("WINDOWS_SSH")))
        form.addArrangedSubview(row("Moonlight Host", text("MOONLIGHT_HOST")))
        form.addArrangedSubview(row("Stream App", text("MOONLIGHT_STREAM_APP")))
        form.addArrangedSubview(row("Moonlight App", text("MOONLIGHT_APP")))

        form.addArrangedSubview(sectionTitle("Stream"))
        form.addArrangedSubview(row("Resolution", text("MOONLIGHT_RESOLUTION")))
        form.addArrangedSubview(row("FPS", text("MOONLIGHT_FPS", width: 96)))
        form.addArrangedSubview(row("Bitrate", text("MOONLIGHT_BITRATE", width: 120)))
        form.addArrangedSubview(row("Display Mode", popup("MOONLIGHT_DISPLAY_MODE", items: ["windowed", "fullscreen", "borderless"])))
        form.addArrangedSubview(row("Launch Display", popup("MOONLIGHT_DISPLAY_INDEX", options: displayOptions())))
        form.addArrangedSubview(row("Video Codec", popup("MOONLIGHT_VIDEO_CODEC", items: ["HEVC", "H264", "AV1"])))
        form.addArrangedSubview(row("System Keys", popup("MOONLIGHT_CAPTURE_SYSTEM_KEYS", items: ["always", "fullscreen", "never"])))

        form.addArrangedSubview(sectionTitle("Controls"))
        form.addArrangedSubview(check("MOONLIGHT_ABSOLUTE_MOUSE", title: "Absolute mouse"))
        form.addArrangedSubview(check("MOONLIGHT_QUIT_EXISTING", title: "Quit existing Moonlight before launch"))
        form.addArrangedSubview(check("MOONLIGHT_CAPSLOCK_HANGUL", title: "Caps Lock toggles Windows Han/Eng"))
        form.addArrangedSubview(check("MOONLIGHT_SHORTCUT_REMAP", title: "Map Command shortcuts to Windows Control shortcuts"))
        form.addArrangedSubview(check("MOONLIGHT_CLIPBOARD_TCP", title: "Use TCP clipboard channels"))

        form.addArrangedSubview(sectionTitle("Transfer"))
        form.addArrangedSubview(row("Mac Receive Dir", text("MOONLIGHT_TRANSFER_MAC_DIR", width: 520)))
        form.addArrangedSubview(row("Windows Receive Dir", text("MOONLIGHT_TRANSFER_WINDOWS_DIR", width: 520)))
        form.addArrangedSubview(check("MOONLIGHT_TRANSFER_AUTO_PASTE", title: "Paste into Moonlight after sending dropped files"))
        let dropView = FileDropView()
        dropView.delegate = self
        form.addArrangedSubview(row("Companion Drop", dropView))
        dropStripButton = NSButton(title: "Show Moonlight Drop Strip", target: self, action: #selector(toggleMoonlightDropStrip))
        dropStripButton.translatesAutoresizingMaskIntoConstraints = false
        let openReceiveButton = NSButton(title: "Open Mac Receive Folder", target: self, action: #selector(openMacReceiveFolder))
        openReceiveButton.translatesAutoresizingMaskIntoConstraints = false
        let transferButtons = NSStackView(views: [dropStripButton, openReceiveButton])
        transferButtons.orientation = .horizontal
        transferButtons.alignment = .centerY
        transferButtons.spacing = 10
        transferButtons.translatesAutoresizingMaskIntoConstraints = false
        form.addArrangedSubview(row("", transferButtons))

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = form

        startButton = NSButton(title: "Start Moonlight", target: self, action: #selector(startMoonlight))
        startButton.keyEquivalent = "\r"
        startButton.translatesAutoresizingMaskIntoConstraints = false

        stopMoonlightButton = NSButton(title: "Stop Moonlight", target: self, action: #selector(stopMoonlight))
        stopMoonlightButton.translatesAutoresizingMaskIntoConstraints = false

        saveButton = NSButton(title: "Save", target: self, action: #selector(saveOnly))
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        stopButton = NSButton(title: "Stop Services", target: self, action: #selector(stopServices))
        stopButton.translatesAutoresizingMaskIntoConstraints = false

        let logsButton = NSButton(title: "Logs", target: self, action: #selector(openLogs))
        logsButton.translatesAutoresizingMaskIntoConstraints = false

        let permissionsButton = NSButton(title: "Permissions", target: self, action: #selector(openAccessibilitySettings))
        permissionsButton.translatesAutoresizingMaskIntoConstraints = false

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(statusLabel)
        content.addSubview(detailLabel)
        content.addSubview(progressIndicator)
        content.addSubview(scrollView)
        content.addSubview(startButton)
        content.addSubview(stopMoonlightButton)
        content.addSubview(saveButton)
        content.addSubview(stopButton)
        content.addSubview(permissionsButton)
        content.addSubview(logsButton)
        content.addSubview(quitButton)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),

            progressIndicator.leadingAnchor.constraint(equalTo: header.trailingAnchor, constant: 12),
            progressIndicator.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 18),
            progressIndicator.heightAnchor.constraint(equalToConstant: 18),

            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            statusLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            detailLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            detailLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            scrollView.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 18),
            scrollView.bottomAnchor.constraint(equalTo: startButton.topAnchor, constant: -18),

            startButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            startButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),

            stopMoonlightButton.leadingAnchor.constraint(equalTo: startButton.trailingAnchor, constant: 10),
            stopMoonlightButton.centerYAnchor.constraint(equalTo: startButton.centerYAnchor),

            saveButton.leadingAnchor.constraint(equalTo: stopMoonlightButton.trailingAnchor, constant: 10),
            saveButton.centerYAnchor.constraint(equalTo: startButton.centerYAnchor),

            stopButton.leadingAnchor.constraint(equalTo: saveButton.trailingAnchor, constant: 10),
            stopButton.centerYAnchor.constraint(equalTo: startButton.centerYAnchor),
            stopButton.trailingAnchor.constraint(lessThanOrEqualTo: permissionsButton.leadingAnchor, constant: -16),

            quitButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            quitButton.centerYAnchor.constraint(equalTo: startButton.centerYAnchor),

            logsButton.trailingAnchor.constraint(equalTo: quitButton.leadingAnchor, constant: -10),
            logsButton.centerYAnchor.constraint(equalTo: startButton.centerYAnchor),

            permissionsButton.trailingAnchor.constraint(equalTo: logsButton.leadingAnchor, constant: -10),
            permissionsButton.centerYAnchor.constraint(equalTo: startButton.centerYAnchor)
        ])

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 128).isActive = true

        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func text(_ key: String, width: CGFloat = 360) -> NSTextField {
        let field = NSTextField(string: settings[key])
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        textFields[key] = field
        return field
    }

    private func popup(_ key: String, items: [String]) -> NSPopUpButton {
        popup(key, options: items.map { ($0, $0) })
    }

    private func popup(_ key: String, options: [(String, String)]) -> NSPopUpButton {
        let popup = NSPopUpButton()
        let titles = options.map { $0.1 }
        let values = options.map { $0.0 }
        popup.addItems(withTitles: titles)
        popupValues[key] = values
        if let index = values.firstIndex(of: settings[key]) {
            popup.selectItem(at: index)
        } else {
            popup.selectItem(at: 0)
        }
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        popups[key] = popup
        return popup
    }

    private func displayOptions() -> [(String, String)] {
        var result: [(String, String)] = [("default", "Default Display")]
        for (index, screen) in NSScreen.screens.enumerated() {
            let frame = screen.frame
            let name = screen.localizedName
            result.append(("\(index)", "\(index + 1). \(name) (\(Int(frame.width))x\(Int(frame.height)))"))
        }
        return result
    }

    private func check(_ key: String, title: String) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = settings.bool(key) ? .on : .off
        button.translatesAutoresizingMaskIntoConstraints = false
        checks[key] = button
        return button
    }

    private func collectSettings() -> CompanionSettings {
        var next = settings
        for (key, field) in textFields {
            next[key] = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (key, popup) in popups {
            let index = popup.indexOfSelectedItem
            if let values = popupValues[key], index >= 0, index < values.count {
                next[key] = values[index]
            } else {
                next[key] = popup.titleOfSelectedItem ?? next[key]
            }
        }
        for (key, button) in checks {
            next.setBool(key, button.state == .on)
        }
        return next
    }

    @discardableResult
    private func saveSettings() -> Bool {
        do {
            settings = collectSettings()
            try SettingsFile.save(settings)
            statusLabel.stringValue = "Saved"
            detailLabel.stringValue = SettingsFile.userURL.path
            return true
        } catch {
            fail("Could not save settings: \(error.localizedDescription)")
            return false
        }
    }

    @objc private func saveOnly() {
        _ = saveSettings()
    }

    @objc private func startMoonlight() {
        guard saveSettings() else { return }
        runLauncher()
    }

    private func runLauncher() {
        let launcherURL = resourceURL.appendingPathComponent("mac/moonlight-companion-launch.sh")
        guard FileManager.default.isExecutableFile(atPath: launcherURL.path) else {
            fail("Launcher is missing or not executable: \(launcherURL.path)")
            return
        }

        output = Data()
        setBusy(true, status: "Starting", detail: "Starting clipboard sync, keyboard helper, and Moonlight.")

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [launcherURL.path]
        task.currentDirectoryURL = resourceURL
        task.standardOutput = pipe
        task.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["MOONLIGHT_COMPANION_CONFIG"] = SettingsFile.userURL.path
        task.environment = environment

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.output.append(data)
            }
        }

        task.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.process = nil
                if task.terminationStatus == 0 {
                    self?.setBusy(false, status: "Running", detail: "Moonlight launched with saved settings.")
                } else {
                    self?.setBusy(false, status: "Failed", detail: "Launcher exited with status \(task.terminationStatus).")
                    self?.showFailure("Launcher exited with status \(task.terminationStatus).")
                }
            }
        }

        do {
            try task.run()
            process = task
        } catch {
            setBusy(false, status: "Failed", detail: error.localizedDescription)
            fail(error.localizedDescription)
        }
    }

    private func setBusy(_ busy: Bool, status: String, detail: String) {
        progressIndicator.isHidden = !busy
        if busy {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
        startButton.isEnabled = !busy
        stopMoonlightButton.isEnabled = !busy
        saveButton.isEnabled = !busy
        stopButton.isEnabled = !busy
        dropStripButton?.isEnabled = !busy
        statusLabel.stringValue = status
        detailLabel.stringValue = detail
    }

    private func fail(_ message: String) {
        setBusy(false, status: "Failed", detail: message)
        showFailure(message)
    }

    private func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Moonlight Companion failed"
        alert.informativeText = failureDetails(prefix: message)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func failureDetails(prefix: String) -> String {
        guard let text = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return prefix
        }

        let suffix = text.count > 1800 ? String(text.suffix(1800)) : text
        return "\(prefix)\n\n\(suffix)"
    }

    @objc private func stopServices() {
        let stopURL = resourceURL.appendingPathComponent("mac/stop-moonlight-clipboard-sync.sh")
        guard FileManager.default.isExecutableFile(atPath: stopURL.path) else {
            fail("Stop script is missing or not executable: \(stopURL.path)")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [stopURL.path]
        do {
            try task.run()
            task.waitUntilExit()
            statusLabel.stringValue = task.terminationStatus == 0 ? "Stopped" : "Stop Failed"
            detailLabel.stringValue = task.terminationStatus == 0 ? "Moonlight Companion services stopped." : "Stop script exited with status \(task.terminationStatus)."
        } catch {
            fail(error.localizedDescription)
        }
    }

    @objc private func stopMoonlight() {
        let launcherURL = resourceURL.appendingPathComponent("mac/moonlight-companion-launch.sh")
        guard FileManager.default.isExecutableFile(atPath: launcherURL.path) else {
            fail("Launcher is missing or not executable: \(launcherURL.path)")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [launcherURL.path, "stop-moonlight"]
        var environment = ProcessInfo.processInfo.environment
        environment["MOONLIGHT_COMPANION_CONFIG"] = SettingsFile.userURL.path
        task.environment = environment
        do {
            try task.run()
            task.waitUntilExit()
            statusLabel.stringValue = task.terminationStatus == 0 ? "Moonlight Stopped" : "Stop Failed"
            detailLabel.stringValue = task.terminationStatus == 0 ? "Moonlight was asked to quit." : "Moonlight stop exited with status \(task.terminationStatus)."
        } catch {
            fail(error.localizedDescription)
        }
    }

    @objc private func openLogs() {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        NSWorkspace.shared.open(logDir)
    }

    @objc private func openMacReceiveFolder() {
        let settings = collectSettings()
        let rawPath = settings["MOONLIGHT_TRANSFER_MAC_DIR"].isEmpty
            ? "${HOME}/Downloads/Moonlight Companion"
            : settings["MOONLIGHT_TRANSFER_MAC_DIR"]
        let url = URL(fileURLWithPath: expandedUserPath(rawPath), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch {
            fail("Could not open receive folder: \(error.localizedDescription)")
        }
    }

    private func expandedUserPath(_ rawPath: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = rawPath
            .replacingOccurrences(of: "${HOME}", with: home)
            .replacingOccurrences(of: "$HOME", with: home)
        return (expanded as NSString).expandingTildeInPath
    }

    @objc private func toggleMoonlightDropStrip() {
        guard saveSettings() else { return }
        if let panel = dropStripWindow, panel.isVisible {
            panel.orderOut(nil)
            dropStripButton.title = "Show Moonlight Drop Strip"
            return
        }
        showMoonlightDropStrip()
    }

    private func showMoonlightDropStrip() {
        if dropStripWindow == nil {
            let size = NSSize(width: 260, height: 92)
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = "Moonlight Drop"
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.delegate = self

            let dropView = FileDropView(
                title: "Drop to Windows",
                detail: "Release files here",
                width: size.width - 24,
                height: size.height - 28
            )
            dropView.delegate = self
            let content = NSView(frame: NSRect(origin: .zero, size: size))
            content.addSubview(dropView)
            panel.contentView = content
            NSLayoutConstraint.activate([
                dropView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                dropView.centerYAnchor.constraint(equalTo: content.centerYAnchor)
            ])
            dropStripWindow = panel
        }

        positionDropStrip()
        dropStripWindow?.orderFrontRegardless()
        dropStripButton.title = "Hide Moonlight Drop Strip"
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              let strip = dropStripWindow,
              closingWindow === strip else {
            return
        }
        dropStripWindow = nil
        dropStripButton?.title = "Show Moonlight Drop Strip"
    }

    private func positionDropStrip() {
        guard let panel = dropStripWindow else { return }

        let panelSize = panel.frame.size
        let moonlightFrame = moonlightWindowFrame()
        let targetFrame: NSRect
        if let moonlightFrame {
            targetFrame = NSRect(
                x: moonlightFrame.maxX - panelSize.width - 16,
                y: moonlightFrame.maxY - panelSize.height - 44,
                width: panelSize.width,
                height: panelSize.height
            )
        } else {
            let visibleFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
            targetFrame = NSRect(
                x: visibleFrame.maxX - panelSize.width - 18,
                y: visibleFrame.midY - panelSize.height / 2,
                width: panelSize.width,
                height: panelSize.height
            )
        }

        panel.setFrame(clampedFrame(targetFrame, near: moonlightFrame), display: true)
    }

    private func moonlightWindowFrame() -> NSRect? {
        moonlightWindowFrameFromCoreGraphics() ?? moonlightWindowFrameFromSystemEvents()
    }

    private func moonlightWindowFrameFromCoreGraphics() -> NSRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            guard (window[kCGWindowOwnerName as String] as? String) == "Moonlight",
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 200,
                  bounds.height >= 200 else {
                continue
            }
            return appKitFrameFromTopLeftFrame(
                x: Double(bounds.origin.x),
                y: Double(bounds.origin.y),
                width: Double(bounds.width),
                height: Double(bounds.height)
            )
        }
        return nil
    }

    private func moonlightWindowFrameFromSystemEvents() -> NSRect? {
        let script = """
        tell application "System Events"
            set moonProcesses to processes whose name is "Moonlight"
            if (count of moonProcesses) is 0 then return ""
            tell item 1 of moonProcesses
                if (count of windows) is 0 then return ""
                set windowPosition to position of window 1
                set windowSize to size of window 1
                return (item 1 of windowPosition as text) & "," & (item 2 of windowPosition as text) & "," & (item 1 of windowSize as text) & "," & (item 2 of windowSize as text)
            end tell
        end tell
        """
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else {
            return nil
        }

        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let rawText = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawText.isEmpty else {
            return nil
        }

        let parts = rawText.split(separator: ",").compactMap {
            Double(String($0).trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 4 else {
            return nil
        }

        return appKitFrameFromTopLeftFrame(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    private func appKitFrameFromTopLeftFrame(x: Double, y: Double, width: Double, height: Double) -> NSRect? {
        guard let mainHeight = NSScreen.screens.first?.frame.height else {
            return nil
        }
        return NSRect(x: x, y: mainHeight - y - height, width: width, height: height)
    }

    private func clampedFrame(_ frame: NSRect, near reference: NSRect?) -> NSRect {
        let point = reference.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            return frame
        }

        let minX = visibleFrame.minX + 8
        let maxX = visibleFrame.maxX - frame.width - 8
        let minY = visibleFrame.minY + 8
        let maxY = visibleFrame.maxY - frame.height - 8
        let x = min(max(frame.minX, minX), maxX)
        let y = min(max(frame.minY, minY), maxY)
        return NSRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    private func sendFilesToWindows(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard saveSettings() else { return }

        let senderURL = resourceURL.appendingPathComponent("mac/send-files-to-windows.sh")
        guard FileManager.default.isExecutableFile(atPath: senderURL.path) else {
            fail("File sender is missing or not executable: \(senderURL.path)")
            return
        }

        output = Data()
        setBusy(true, status: "Sending Files", detail: "Sending \(urls.count) item(s) to Windows.")

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [senderURL.path] + urls.map(\.path)
        task.currentDirectoryURL = resourceURL
        task.standardOutput = pipe
        task.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["MOONLIGHT_COMPANION_CONFIG"] = SettingsFile.userURL.path
        task.environment = environment

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.output.append(data)
            }
        }

        task.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.transferProcess = nil
                let text = String(data: self?.output ?? Data(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if task.terminationStatus == 0 {
                    var detail = text?.isEmpty == false ? text! : "Files were sent to Windows."
                    if self?.settings.bool("MOONLIGHT_TRANSFER_AUTO_PASTE") == true {
                        let pasted = self?.pasteIntoMoonlight() == true
                        detail += pasted ? " Sent Ctrl+V to Moonlight." : " Could not send Ctrl+V to Moonlight."
                    }
                    self?.setBusy(false, status: "Files Sent", detail: detail)
                } else {
                    self?.setBusy(false, status: "Send Failed", detail: text?.isEmpty == false ? text! : "File sender exited with status \(task.terminationStatus).")
                    self?.showFailure("File sender exited with status \(task.terminationStatus).")
                }
            }
        }

        do {
            try task.run()
            transferProcess = task
        } catch {
            setBusy(false, status: "Send Failed", detail: error.localizedDescription)
            fail(error.localizedDescription)
        }
    }

    private func pasteIntoMoonlight() -> Bool {
        let script = """
        tell application "Moonlight" to activate
        delay 0.15
        tell application "System Events"
            keystroke "v" using control down
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    @objc private func openAccessibilitySettings() {
        requestKeyboardHelperPermissions()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestKeyboardHelperPermissions() {
        let helperURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Moonlight Caps Lock Hangul.app")
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--request-permissions"]
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.detailLabel.stringValue = "Could not request keyboard helper permission: \(error.localizedDescription)"
            }
        }
    }

    @objc private func quit() {
        process?.terminate()
        transferProcess?.terminate()
        dropStripWindow?.close()
        NSApp.terminate(nil)
    }
}

extension AppDelegate: FileDropViewDelegate {
    func fileDropView(_ view: FileDropView, didReceive urls: [URL]) {
        sendFilesToWindows(urls)
    }
}

protocol FileDropViewDelegate: AnyObject {
    func fileDropView(_ view: FileDropView, didReceive urls: [URL])
}

final class FileDropView: NSView {
    weak var delegate: FileDropViewDelegate?
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let preferredSize: NSSize

    init(
        title: String = "Drop files or folders",
        detail: String = "Sends to Windows clipboard and receive folder",
        width: CGFloat = 520,
        height: CGFloat = 96
    ) {
        titleLabel = NSTextField(labelWithString: title)
        detailLabel = NSTextField(labelWithString: detail)
        preferredSize = NSSize(width: width, height: height)
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        titleLabel = NSTextField(labelWithString: "Drop files or folders")
        detailLabel = NSTextField(labelWithString: "Sends to Windows clipboard and receive folder")
        preferredSize = NSSize(width: 520, height: 96)
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        registerForDraggedTypes([.fileURL])
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: preferredSize.width).isActive = true
        heightAnchor.constraint(equalToConstant: preferredSize.height).isActive = true

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = NSFont.systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else {
            return false
        }
        delegate?.fileDropView(self, didReceive: urls)
        return true
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let pasteboard = sender.draggingPasteboard
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        return objects.compactMap { object in
            if let url = object as? URL, url.isFileURL {
                return url
            }
            if let nsURL = object as? NSURL {
                let url = nsURL as URL
                return url.isFileURL ? url : nil
            }
            return nil
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
