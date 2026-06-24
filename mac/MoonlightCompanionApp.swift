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
        "MOONLIGHT_TRANSFER_DROP_OVERLAY",
        "MOONLIGHT_TRANSFER_SCREEN_DROP_AUTO_PASTE",
        "MOONLIGHT_TRANSFER_AUTO_PASTE",
        "MOONLIGHT_TRANSFER_NOTIFY",
        "MOONLIGHT_TRANSFER_REVEAL_MAC_DIR",
        "MOONLIGHT_TRANSFER_REVEAL_WINDOWS_DIR"
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
    private var dropOverlayWindow: NSPanel?
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var progressIndicator: NSProgressIndicator!
    private var startButton: NSButton!
    private var stopMoonlightButton: NSButton!
    private var saveButton: NSButton!
    private var stopButton: NSButton!
    private var dropStripButton: NSButton!
    private var dropOverlayButton: NSButton!
    private var testTransferButton: NSButton!
    private var openMacReceiveButton: NSButton!
    private var openWindowsReceiveButton: NSButton!
    private var output = Data()
    private var process: Process?
    private var transferProcess: Process?
    private var dropOverlayTimer: Timer?
    private var dropOverlayManuallyShown = false
    private var dropOverlayMouseDownLocation: NSPoint?
    private var dropOverlayLastDragLocation: NSPoint?
    private var dropOverlayMouseDownFrontmostName = ""
    private var dropOverlayMouseDownAt = Date.distantPast
    private var dropOverlayDragCaptured = false
    private var dropOverlayRayHitUntil = Date.distantPast
    private var dropOverlayLastFileDragAt = Date.distantPast
    private let dropOverlayActivationMargin: CGFloat = 128
    private let dropOverlayRefreshInterval: TimeInterval = 0.04
    private let dropOverlayRayHitLatchInterval: TimeInterval = 0.35
    private let dropOverlayFileDragGraceInterval: TimeInterval = 0.45
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
        updateDropOverlayMonitor()
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
        form.addArrangedSubview(check("MOONLIGHT_TRANSFER_DROP_OVERLAY", title: "Use Moonlight window as file drop target"))
        form.addArrangedSubview(check("MOONLIGHT_TRANSFER_SCREEN_DROP_AUTO_PASTE", title: "Paste after Moonlight window or strip drops"))
        form.addArrangedSubview(check("MOONLIGHT_TRANSFER_AUTO_PASTE", title: "Paste after Companion fallback drops"))
        form.addArrangedSubview(check("MOONLIGHT_TRANSFER_NOTIFY", title: "Notify on file transfers"))
        form.addArrangedSubview(check("MOONLIGHT_TRANSFER_REVEAL_MAC_DIR", title: "Reveal received Mac files in Finder"))
        form.addArrangedSubview(check("MOONLIGHT_TRANSFER_REVEAL_WINDOWS_DIR", title: "Reveal sent Windows files in Explorer"))
        let dropView = FileDropView(source: .companion)
        dropView.delegate = self
        form.addArrangedSubview(row("Companion Drop", dropView))
        dropOverlayButton = NSButton(title: "Show Moonlight Drop Overlay", target: self, action: #selector(toggleMoonlightDropOverlay))
        dropOverlayButton.translatesAutoresizingMaskIntoConstraints = false
        dropStripButton = NSButton(title: "Show Moonlight Drop Strip", target: self, action: #selector(toggleMoonlightDropStrip))
        dropStripButton.translatesAutoresizingMaskIntoConstraints = false
        testTransferButton = NSButton(title: "Test File Transfer", target: self, action: #selector(testFileTransfer))
        testTransferButton.translatesAutoresizingMaskIntoConstraints = false
        openMacReceiveButton = NSButton(title: "Open Mac Folder", target: self, action: #selector(openMacReceiveFolder))
        openMacReceiveButton.translatesAutoresizingMaskIntoConstraints = false
        openWindowsReceiveButton = NSButton(title: "Open Windows Folder", target: self, action: #selector(openWindowsReceiveFolder))
        openWindowsReceiveButton.translatesAutoresizingMaskIntoConstraints = false
        let transferButtons = NSStackView(views: [dropOverlayButton, dropStripButton, testTransferButton, openMacReceiveButton, openWindowsReceiveButton])
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
            updateDropOverlayMonitor()
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
        dropOverlayButton?.isEnabled = !busy
        testTransferButton?.isEnabled = !busy
        openMacReceiveButton?.isEnabled = !busy
        openWindowsReceiveButton?.isEnabled = !busy
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

    @objc private func openWindowsReceiveFolder() {
        guard saveSettings() else { return }

        setBusy(true, status: "Opening Windows Folder", detail: "Asking Windows to open the receive folder.")
        requestWindowsReceiveFolderOpen(selectLatestImport: false) { [weak self] succeeded, detail in
            if succeeded {
                self?.setBusy(false, status: "Windows Folder Opened", detail: detail)
            } else {
                self?.setBusy(false, status: "Open Failed", detail: detail)
                self?.showFailure("Windows receive folder opener failed.")
            }
        }
    }

    private func requestWindowsReceiveFolderOpen(
        selectLatestImport: Bool,
        expectedImportID: String? = nil,
        completion: @escaping (Bool, String) -> Void
    ) {
        let openerURL = resourceURL.appendingPathComponent("mac/open-windows-receive-folder.sh")
        guard FileManager.default.isExecutableFile(atPath: openerURL.path) else {
            completion(false, "Windows receive folder opener is missing or not executable: \(openerURL.path)")
            return
        }

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        var arguments = [openerURL.path]
        if selectLatestImport {
            arguments.append("--latest-import")
        }
        if let expectedImportID,
           !expectedImportID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--expected-id", expectedImportID])
        }
        task.arguments = arguments
        task.currentDirectoryURL = resourceURL
        task.standardOutput = pipe
        task.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["MOONLIGHT_COMPANION_CONFIG"] = SettingsFile.userURL.path
        task.environment = environment

        task.terminationHandler = { [weak self] task in
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = text?.isEmpty == false ? text! : "Windows folder opener exited with status \(task.terminationStatus)."
            DispatchQueue.main.async {
                if self?.transferProcess === task {
                    self?.transferProcess = nil
                }
                completion(task.terminationStatus == 0, detail)
            }
        }

        do {
            try task.run()
            transferProcess = task
        } catch {
            completion(false, error.localizedDescription)
        }
    }

    @objc private func testFileTransfer() {
        guard saveSettings() else { return }

        let testURL = resourceURL.appendingPathComponent("mac/test-file-transfer.sh")
        guard FileManager.default.isExecutableFile(atPath: testURL.path) else {
            fail("File transfer test is missing or not executable: \(testURL.path)")
            return
        }

        output = Data()
        setBusy(true, status: "Testing Transfer", detail: "Checking Mac -> Windows and Windows -> Mac file transfer.")

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [testURL.path]
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
                let detail = text?.isEmpty == false ? text! : "File transfer test exited with status \(task.terminationStatus)."
                if task.terminationStatus == 0 {
                    self?.setBusy(false, status: "Transfer OK", detail: detail)
                } else {
                    self?.setBusy(false, status: "Transfer Failed", detail: detail)
                    self?.showFailure("File transfer test failed.")
                }
            }
        }

        do {
            try task.run()
            transferProcess = task
        } catch {
            setBusy(false, status: "Transfer Failed", detail: error.localizedDescription)
            fail(error.localizedDescription)
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

    @objc private func toggleMoonlightDropOverlay() {
        guard saveSettings() else { return }
        if let panel = dropOverlayWindow, panel.isVisible {
            hideMoonlightDropOverlay()
            return
        }
        showMoonlightDropOverlay(manual: true)
    }

    private func updateDropOverlayMonitor() {
        dropOverlayTimer?.invalidate()
        dropOverlayTimer = nil

        guard settings.bool("MOONLIGHT_TRANSFER_DROP_OVERLAY") else {
            if !dropOverlayManuallyShown {
                hideMoonlightDropOverlay()
            }
            return
        }

        let timer = Timer(timeInterval: dropOverlayRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshDropOverlayForFileDrag()
        }
        dropOverlayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshDropOverlayForFileDrag() {
        guard !dropOverlayManuallyShown else {
            if dropOverlayWindow?.isVisible == true {
                positionDropOverlay()
            }
            return
        }

        if shouldShowDropOverlayForCurrentDrag() {
            showMoonlightDropOverlay(manual: false)
        } else if dropOverlayWindow?.isVisible == true {
            hideMoonlightDropOverlay()
        }
    }

    private func shouldShowDropOverlayForCurrentDrag() -> Bool {
        guard settings.bool("MOONLIGHT_TRANSFER_DROP_OVERLAY") else {
            resetDropOverlayDragTracking()
            return false
        }

        guard (NSEvent.pressedMouseButtons & 1) == 1,
              let moonlightFrame = moonlightWindowFrame() else {
            resetDropOverlayDragTracking()
            return false
        }

        let mouseLocation = NSEvent.mouseLocation
        let frontmostName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let hasFileDrag = !FileDropReader.fileURLs(from: NSPasteboard(name: .drag)).isEmpty
        let now = Date()

        if dropOverlayDragCaptured {
            if hasFileDrag {
                dropOverlayLastFileDragAt = now
            }
            return hasFileDrag || now.timeIntervalSince(dropOverlayLastFileDragAt) <= dropOverlayFileDragGraceInterval
        }

        if dropOverlayMouseDownLocation == nil {
            dropOverlayMouseDownLocation = mouseLocation
            dropOverlayLastDragLocation = mouseLocation
            dropOverlayMouseDownFrontmostName = frontmostName
            dropOverlayMouseDownAt = now
            return false
        }

        let previousMouseLocation = dropOverlayLastDragLocation ?? dropOverlayMouseDownLocation ?? mouseLocation
        dropOverlayLastDragLocation = mouseLocation

        if dropOverlayMouseDownFrontmostName == "Moonlight" || dropOverlayMouseDownFrontmostName == "Moonlight Companion" {
            return false
        }

        guard now.timeIntervalSince(dropOverlayMouseDownAt) >= 0.10,
              let mouseDownLocation = dropOverlayMouseDownLocation,
              distance(from: mouseDownLocation, to: mouseLocation) >= 18 else {
            return false
        }

        let activationFrame = moonlightFrame.insetBy(
            dx: -dropOverlayActivationMargin,
            dy: -dropOverlayActivationMargin
        )
        if dragPathHitsDropActivationFrame(
            from: previousMouseLocation,
            to: mouseLocation,
            activationFrame: activationFrame
        ) {
            dropOverlayRayHitUntil = now.addingTimeInterval(dropOverlayRayHitLatchInterval)
        }

        guard now <= dropOverlayRayHitUntil else {
            return false
        }

        if hasFileDrag {
            dropOverlayDragCaptured = true
            dropOverlayLastFileDragAt = now
            return true
        }
        return false
    }

    private func resetDropOverlayDragTracking() {
        dropOverlayMouseDownLocation = nil
        dropOverlayLastDragLocation = nil
        dropOverlayMouseDownFrontmostName = ""
        dropOverlayMouseDownAt = .distantPast
        dropOverlayDragCaptured = false
        dropOverlayRayHitUntil = .distantPast
        dropOverlayLastFileDragAt = .distantPast
    }

    private func dragPathHitsDropActivationFrame(
        from start: NSPoint,
        to end: NSPoint,
        activationFrame: NSRect
    ) -> Bool {
        if activationFrame.contains(start) || activationFrame.contains(end) {
            return true
        }
        return lineSegment(from: start, to: end, intersects: activationFrame)
    }

    private func lineSegment(from start: NSPoint, to end: NSPoint, intersects rect: NSRect) -> Bool {
        let bottomLeft = NSPoint(x: rect.minX, y: rect.minY)
        let bottomRight = NSPoint(x: rect.maxX, y: rect.minY)
        let topRight = NSPoint(x: rect.maxX, y: rect.maxY)
        let topLeft = NSPoint(x: rect.minX, y: rect.maxY)
        let edges = [
            (bottomLeft, bottomRight),
            (bottomRight, topRight),
            (topRight, topLeft),
            (topLeft, bottomLeft)
        ]
        return edges.contains { edge in
            lineSegmentsIntersect(start, end, edge.0, edge.1)
        }
    }

    private func lineSegmentsIntersect(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint, _ d: NSPoint) -> Bool {
        let r = NSPoint(x: b.x - a.x, y: b.y - a.y)
        let s = NSPoint(x: d.x - c.x, y: d.y - c.y)
        let cMinusA = NSPoint(x: c.x - a.x, y: c.y - a.y)
        let denominator = cross(r, s)
        let epsilon: CGFloat = 0.0001

        if abs(denominator) < epsilon {
            return point(a, isOnSegmentFrom: c, to: d)
                || point(b, isOnSegmentFrom: c, to: d)
                || point(c, isOnSegmentFrom: a, to: b)
                || point(d, isOnSegmentFrom: a, to: b)
        }

        let t = cross(cMinusA, s) / denominator
        let u = cross(cMinusA, r) / denominator
        return t >= -epsilon && t <= 1 + epsilon && u >= -epsilon && u <= 1 + epsilon
    }

    private func point(_ point: NSPoint, isOnSegmentFrom start: NSPoint, to end: NSPoint) -> Bool {
        let epsilon: CGFloat = 0.0001
        let pointVector = NSPoint(x: point.x - start.x, y: point.y - start.y)
        let segmentVector = NSPoint(x: end.x - start.x, y: end.y - start.y)
        let segmentCross = cross(pointVector, segmentVector)
        guard abs(segmentCross) < epsilon else {
            return false
        }
        return point.x >= min(start.x, end.x) - epsilon
            && point.x <= max(start.x, end.x) + epsilon
            && point.y >= min(start.y, end.y) - epsilon
            && point.y <= max(start.y, end.y) + epsilon
    }

    private func cross(_ first: NSPoint, _ second: NSPoint) -> CGFloat {
        first.x * second.y - first.y * second.x
    }

    private func distance(from start: NSPoint, to end: NSPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return sqrt(dx * dx + dy * dy)
    }

    private func showMoonlightDropOverlay(manual: Bool) {
        if manual {
            dropOverlayManuallyShown = true
        }
        guard let moonlightFrame = moonlightWindowFrame() else {
            if manual {
                fail("Moonlight window was not found.")
            }
            return
        }

        if dropOverlayWindow == nil {
            let panel = NSPanel(
                contentRect: moonlightFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "Moonlight Drop Overlay"
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.hasShadow = false
            panel.backgroundColor = .clear
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.delegate = self

            let overlayView = MoonlightDropOverlayView(frame: NSRect(origin: .zero, size: moonlightFrame.size))
            overlayView.delegate = self
            panel.contentView = overlayView
            dropOverlayWindow = panel
        }

        positionDropOverlay(frame: moonlightFrame)
        dropOverlayWindow?.orderFrontRegardless()
        dropOverlayButton.title = "Hide Moonlight Drop Overlay"
    }

    private func hideMoonlightDropOverlay() {
        dropOverlayManuallyShown = false
        resetDropOverlayDragTracking()
        dropOverlayWindow?.orderOut(nil)
        dropOverlayButton?.title = "Show Moonlight Drop Overlay"
    }

    private func positionDropOverlay(frame: NSRect? = nil) {
        guard let panel = dropOverlayWindow else { return }
        let targetFrame = frame ?? moonlightWindowFrame()
        guard let targetFrame else { return }
        panel.setFrame(targetFrame, display: true)
        if let overlayView = panel.contentView as? MoonlightDropOverlayView {
            overlayView.frame = NSRect(origin: .zero, size: targetFrame.size)
        }
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
                source: .moonlightSurface,
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
        guard let closingWindow = notification.object as? NSWindow else {
            return
        }
        if let strip = dropStripWindow, closingWindow === strip {
            dropStripWindow = nil
            dropStripButton?.title = "Show Moonlight Drop Strip"
        }
        if let overlay = dropOverlayWindow, closingWindow === overlay {
            dropOverlayWindow = nil
            dropOverlayManuallyShown = false
            dropOverlayButton?.title = "Show Moonlight Drop Overlay"
        }
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

    private func sendFilesToWindows(_ urls: [URL], source: FileDropSource) {
        guard !urls.isEmpty else { return }
        guard saveSettings() else { return }
        let pasteAfterSend = shouldPasteAfterSend(for: source)
        let summary = fileTransferSummary(for: urls)

        let senderURL = resourceURL.appendingPathComponent("mac/send-files-to-windows.sh")
        guard FileManager.default.isExecutableFile(atPath: senderURL.path) else {
            fail("File sender is missing or not executable: \(senderURL.path)")
            return
        }

        output = Data()
        setBusy(true, status: "Sending Files", detail: "Sending \(summary.detail) to Windows.")
        let transferResultStateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moonlight-companion-send-\(UUID().uuidString).state")

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [senderURL.path] + urls.map(\.path)
        task.currentDirectoryURL = resourceURL
        task.standardOutput = pipe
        task.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["MOONLIGHT_COMPANION_CONFIG"] = SettingsFile.userURL.path
        environment["MOONLIGHT_TRANSFER_RESULT_STATE"] = transferResultStateURL.path
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
                    let transferResult = SettingsFile.parse(url: transferResultStateURL)
                    try? FileManager.default.removeItem(at: transferResultStateURL)
                    var detail = text?.isEmpty == false ? text! : "\(summary.detail) sent to Windows."
                    var pasteSummary = "Ready on the Windows clipboard."
                    if pasteAfterSend {
                        let pasted = self?.pasteIntoMoonlight() == true
                        pasteSummary = pasted ? "Pasted into the focused Moonlight app." : "Ready on the Windows clipboard; paste shortcut failed."
                        detail += pasted ? " Sent Ctrl+V to Moonlight." : " Could not send Ctrl+V to Moonlight."
                    }
                    self?.notifyMoonlightDropIfNeeded(source: source, title: "Files sent to Windows", body: "\(summary.notification) transferred. \(pasteSummary)")
                    if self?.settings.bool("MOONLIGHT_TRANSFER_REVEAL_WINDOWS_DIR") == true {
                        self?.setBusy(true, status: "Opening Windows Folder", detail: "\(detail) Opening Windows receive result.")
                        self?.requestWindowsReceiveFolderOpen(
                            selectLatestImport: true,
                            expectedImportID: transferResult["id"]
                        ) { [weak self] succeeded, openDetail in
                            let suffix = succeeded
                                ? " \(openDetail)."
                                : " Windows receive folder open failed: \(openDetail)"
                            self?.setBusy(false, status: "Files Sent", detail: detail + suffix)
                        }
                    } else {
                        self?.setBusy(false, status: "Files Sent", detail: detail)
                    }
                } else {
                    try? FileManager.default.removeItem(at: transferResultStateURL)
                    let detail = text?.isEmpty == false ? text! : "File sender exited with status \(task.terminationStatus)."
                    self?.notifyMoonlightDropIfNeeded(source: source, title: "File transfer failed", body: detail)
                    self?.setBusy(false, status: "Send Failed", detail: detail)
                    self?.showFailure("File sender exited with status \(task.terminationStatus).")
                }
            }
        }

        do {
            try task.run()
            transferProcess = task
        } catch {
            notifyMoonlightDropIfNeeded(source: source, title: "File transfer failed", body: error.localizedDescription)
            setBusy(false, status: "Send Failed", detail: error.localizedDescription)
            fail(error.localizedDescription)
        }
    }

    private struct TransferSummary {
        let detail: String
        let notification: String
    }

    private func fileTransferSummary(for urls: [URL]) -> TransferSummary {
        let itemNames = urls.map { url in
            url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
        }
        let itemText = itemNames.count == 1 ? "1 item" : "\(itemNames.count) items"
        let bytes = urls.reduce(UInt64(0)) { partial, url in
            partial + pathByteCount(url)
        }
        let sizeText = formattedByteCount(bytes)
        let namesText = summarizedNames(itemNames)
        let detail = "\(itemText) (\(sizeText)): \(namesText)"
        let notification = "\(itemText) (\(sizeText))"
        return TransferSummary(detail: detail, notification: notification)
    }

    private func summarizedNames(_ names: [String]) -> String {
        guard !names.isEmpty else {
            return "files"
        }
        let visibleNames = names.prefix(2).joined(separator: ", ")
        let remaining = names.count - min(names.count, 2)
        if remaining > 0 {
            return "\(visibleNames), +\(remaining) more"
        }
        return visibleNames
    }

    private func formattedByteCount(_ bytes: UInt64) -> String {
        let cappedBytes = min(bytes, UInt64(Int64.max))
        return ByteCountFormatter.string(fromByteCount: Int64(cappedBytes), countStyle: .file)
    }

    private func pathByteCount(_ url: URL) -> UInt64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }

        if isDirectory.boolValue {
            return directoryByteCount(url)
        }
        return fileByteCount(url)
    }

    private func fileByteCount(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values?.fileSize ?? 0)
    }

    private func directoryByteCount(_ url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return 0
        }

        var total: UInt64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += UInt64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    private func shouldPasteAfterSend(for source: FileDropSource) -> Bool {
        switch source {
        case .moonlightSurface:
            return settings.bool("MOONLIGHT_TRANSFER_SCREEN_DROP_AUTO_PASTE")
        case .companion:
            return settings.bool("MOONLIGHT_TRANSFER_AUTO_PASTE")
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

    private func notifyMoonlightDropIfNeeded(source: FileDropSource, title: String, body: String) {
        guard source == .moonlightSurface,
              settings.bool("MOONLIGHT_TRANSFER_NOTIFY") else {
            return
        }

        let script = """
        on run argv
            display notification (item 2 of argv) with title "Moonlight Companion" subtitle (item 1 of argv)
        end run
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script, title, body]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
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
        dropOverlayTimer?.invalidate()
        dropOverlayWindow?.close()
        dropStripWindow?.close()
        NSApp.terminate(nil)
    }
}

extension AppDelegate: FileDropViewDelegate {
    func fileDropViewDidReceive(_ urls: [URL], source: FileDropSource) {
        hideMoonlightDropOverlay()
        sendFilesToWindows(urls, source: source)
    }
}

protocol FileDropViewDelegate: AnyObject {
    func fileDropViewDidReceive(_ urls: [URL], source: FileDropSource)
}

enum FileDropSource {
    case companion
    case moonlightSurface
}

enum FileDropReader {
    static let filenamesPasteboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private static let urlPasteboardTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        NSPasteboard.PasteboardType("NSURLPboardType"),
        NSPasteboard.PasteboardType("public.url")
    ]

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []

        if let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) {
            urls.append(contentsOf: objects.compactMap { url(from: $0) })
        }

        if let items = pasteboard.pasteboardItems {
            urls.append(contentsOf: items.compactMap { item in
                urlPasteboardTypes.compactMap { type -> URL? in
                    guard let value = item.string(forType: type),
                          let parsedURL = URL(string: value),
                          parsedURL.isFileURL else {
                        return nil
                    }
                    return parsedURL
                }.first
            })
        }

        if let paths = pasteboard.propertyList(forType: filenamesPasteboardType) as? [String] {
            urls.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
        }

        var seenPaths = Set<String>()
        return urls.compactMap { candidate in
            guard candidate.isFileURL else {
                return nil
            }
            let url = candidate.standardizedFileURL
            let path = url.path
            guard !seenPaths.contains(path) else {
                return nil
            }
            seenPaths.insert(path)
            return url
        }
    }

    static func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        fileURLs(from: sender.draggingPasteboard)
    }

    static func dropSummary(for urls: [URL]) -> String {
        guard !urls.isEmpty else {
            return "No file selected"
        }

        let itemText = urls.count == 1 ? "1 item" : "\(urls.count) items"
        let names = urls.map { url in
            shortenedDisplayName(url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent)
        }
        let visibleNames = names.prefix(2).joined(separator: ", ")
        let remaining = names.count - min(names.count, 2)
        if remaining > 0 {
            return "\(itemText): \(visibleNames), +\(remaining) more"
        }
        return "\(itemText): \(visibleNames)"
    }

    private static func shortenedDisplayName(_ name: String, maxCharacters: Int = 34) -> String {
        guard name.count > maxCharacters, maxCharacters >= 8 else {
            return name
        }

        let prefixCount = (maxCharacters - 1) / 2
        let suffixCount = maxCharacters - prefixCount - 1
        return "\(name.prefix(prefixCount))...\(name.suffix(suffixCount))"
    }

    private static func url(from object: Any) -> URL? {
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

final class MoonlightDropOverlayView: NSView {
    weak var delegate: FileDropViewDelegate?
    private let defaultTitle = "Drop to Windows"
    private let defaultDetail = "Release files anywhere on the Moonlight screen"
    private let titleLabel = NSTextField(labelWithString: "Drop to Windows")
    private let detailLabel = NSTextField(labelWithString: "Release files anywhere on the Moonlight screen")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        setActiveDropURLs([])
        layer?.borderWidth = 3
        registerForDraggedTypes([.fileURL, FileDropReader.filenamesPasteboardType])

        titleLabel.font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.82)
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32)
        ])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setActiveDropURLs([])
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setActiveDropURLs([])
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = FileDropReader.fileURLs(from: sender)
        guard !urls.isEmpty else {
            return false
        }
        setActiveDropURLs([])
        delegate?.fileDropViewDidReceive(urls, source: .moonlightSurface)
        return true
    }

    private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let urls = FileDropReader.fileURLs(from: sender)
        setActiveDropURLs(urls)
        return urls.isEmpty ? [] : .copy
    }

    private func setActiveDropURLs(_ urls: [URL]) {
        if urls.isEmpty {
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.10).cgColor
            layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.70).cgColor
            titleLabel.stringValue = defaultTitle
            detailLabel.stringValue = defaultDetail
        } else {
            layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.18).cgColor
            layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.85).cgColor
            titleLabel.stringValue = defaultTitle
            detailLabel.stringValue = FileDropReader.dropSummary(for: urls)
        }
    }
}

final class FileDropView: NSView {
    weak var delegate: FileDropViewDelegate?
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let defaultTitle: String
    private let defaultDetail: String
    private let source: FileDropSource
    private let preferredSize: NSSize

    init(
        title: String = "Drop files or folders",
        detail: String = "Sends to Windows clipboard and receive folder",
        source: FileDropSource,
        width: CGFloat = 520,
        height: CGFloat = 96
    ) {
        titleLabel = NSTextField(labelWithString: title)
        detailLabel = NSTextField(labelWithString: detail)
        defaultTitle = title
        defaultDetail = detail
        self.source = source
        preferredSize = NSSize(width: width, height: height)
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        titleLabel = NSTextField(labelWithString: "Drop files or folders")
        detailLabel = NSTextField(labelWithString: "Sends to Windows clipboard and receive folder")
        defaultTitle = "Drop files or folders"
        defaultDetail = "Sends to Windows clipboard and receive folder"
        source = .companion
        preferredSize = NSSize(width: 520, height: 96)
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        setActiveDropURLs([])
        registerForDraggedTypes([.fileURL, FileDropReader.filenamesPasteboardType])
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: preferredSize.width).isActive = true
        heightAnchor.constraint(equalToConstant: preferredSize.height).isActive = true

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = NSFont.systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 1
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
        dropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setActiveDropURLs([])
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setActiveDropURLs([])
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else {
            return false
        }
        setActiveDropURLs([])
        delegate?.fileDropViewDidReceive(urls, source: source)
        return true
    }

    private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(from: sender)
        setActiveDropURLs(urls)
        return urls.isEmpty ? [] : .copy
    }

    private func setActiveDropURLs(_ urls: [URL]) {
        if urls.isEmpty {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            titleLabel.stringValue = defaultTitle
            detailLabel.stringValue = defaultDetail
            detailLabel.textColor = .secondaryLabelColor
        } else {
            layer?.borderColor = NSColor.systemGreen.cgColor
            layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.12).cgColor
            titleLabel.stringValue = "Drop to Windows"
            detailLabel.stringValue = FileDropReader.dropSummary(for: urls)
            detailLabel.textColor = .labelColor
        }
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        FileDropReader.fileURLs(from: sender)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
