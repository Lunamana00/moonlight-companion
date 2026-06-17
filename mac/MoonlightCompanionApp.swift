import AppKit
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
        "MOONLIGHT_CLIPBOARD_MAX_BYTES"
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var progressIndicator: NSProgressIndicator!
    private var startButton: NSButton!
    private var stopMoonlightButton: NSButton!
    private var saveButton: NSButton!
    private var stopButton: NSButton!
    private var output = Data()
    private var process: Process?
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

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        process?.terminate()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
