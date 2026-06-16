import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var progressIndicator: NSProgressIndicator!
    private var output = Data()
    private var process: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        runLauncher()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 178),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Moonlight Companion"
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        let titleLabel = NSTextField(labelWithString: "Moonlight Companion")
        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "Starting")
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel = NSTextField(labelWithString: "Preparing clipboard bridge and Moonlight.")
        detailLabel.font = NSFont.systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .regular
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.startAnimation(nil)

        let logsButton = NSButton(title: "Open Logs", target: self, action: #selector(openLogs))
        logsButton.translatesAutoresizingMaskIntoConstraints = false

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(titleLabel)
        content.addSubview(statusLabel)
        content.addSubview(detailLabel)
        content.addSubview(progressIndicator)
        content.addSubview(logsButton)
        content.addSubview(quitButton)

        NSLayoutConstraint.activate([
            progressIndicator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            progressIndicator.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            progressIndicator.widthAnchor.constraint(equalToConstant: 24),
            progressIndicator.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: progressIndicator.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),

            quitButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            quitButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),

            logsButton.trailingAnchor.constraint(equalTo: quitButton.leadingAnchor, constant: -10),
            logsButton.centerYAnchor.constraint(equalTo: quitButton.centerYAnchor)
        ])

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func runLauncher() {
        guard let resourceURL = Bundle.main.resourceURL else {
            fail("Missing app resources.")
            return
        }

        let launcherURL = resourceURL.appendingPathComponent("mac/moonlight-companion-launch.sh")
        guard FileManager.default.isExecutableFile(atPath: launcherURL.path) else {
            fail("Launcher is missing or not executable: \(launcherURL.path)")
            return
        }

        statusLabel.stringValue = "Connecting"
        detailLabel.stringValue = "Starting clipboard sync and Moonlight."

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [launcherURL.path]
        task.currentDirectoryURL = resourceURL
        task.standardOutput = pipe
        task.standardError = pipe

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
                    self?.finish()
                } else {
                    self?.fail("Launcher exited with status \(task.terminationStatus).")
                }
            }
        }

        do {
            try task.run()
            process = task
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func finish() {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        statusLabel.stringValue = "Ready"
        detailLabel.stringValue = "Moonlight is launching."

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSApp.terminate(nil)
        }
    }

    private func fail(_ message: String) {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        statusLabel.stringValue = "Failed"
        detailLabel.stringValue = message

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

    @objc private func openLogs() {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        NSWorkspace.shared.open(logDir)
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
