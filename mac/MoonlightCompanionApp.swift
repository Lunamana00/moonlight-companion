import AppKit
import CoreGraphics
import Darwin
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
        "MOONLIGHT_COMPANION_SHOW_WINDOW_ON_LAUNCH",
        "MOONLIGHT_COMPANION_ACTIVATE_ON_LAUNCH",
        "MOONLIGHT_ACTIVATE_ON_LAUNCH",
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
        "MOONLIGHT_CLIPBOARD_HELPER_TIMEOUT_SECONDS",
        "MOONLIGHT_CLIPBOARD_TCP_IO_TIMEOUT_MS",
        "MOONLIGHT_TRANSFER_MAC_DIR",
        "MOONLIGHT_TRANSFER_WINDOWS_DIR",
        "MOONLIGHT_TRANSFER_DROP_OVERLAY",
        "MOONLIGHT_TRANSFER_OVERSIZE_DIRECT",
        "MOONLIGHT_TRANSFER_SCREEN_DROP_AUTO_PASTE",
        "MOONLIGHT_TRANSFER_ACTIVATE_MOONLIGHT_FOR_PASTE",
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
            let userValues = parse(url: userURL)
            values.merge(userValues) { _, new in new }
            applyQuietDefaultMigration(userValues: userValues, values: &values)
            applyWindowVisibilityMigration(userValues: userValues, values: &values)
        }
        return CompanionSettings(values: values)
    }

    private static func applyQuietDefaultMigration(userValues: [String: String], values: inout [String: String]) {
        guard userValues["MOONLIGHT_COMPANION_ACTIVATE_ON_LAUNCH"] == nil else {
            return
        }

        let revealMacDir = userValues["MOONLIGHT_TRANSFER_REVEAL_MAC_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if revealMacDir == "yes" {
            values["MOONLIGHT_TRANSFER_REVEAL_MAC_DIR"] = "no"
        }
    }

    private static func applyWindowVisibilityMigration(userValues: [String: String], values: inout [String: String]) {
        if userValues["MOONLIGHT_COMPANION_SHOW_WINDOW_ON_LAUNCH"] == nil {
            values["MOONLIGHT_COMPANION_SHOW_WINDOW_ON_LAUNCH"] = "no"
        }
    }

    static func parse(url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }

        return parse(text: text)
    }

    static func parse(text: String) -> [String: String] {
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
    private static let transferProgressPrefix = "__MOONLIGHT_COMPANION_PROGRESS__ "
    private static let queuedDropDetailMarker = " Queued drop: "
    private static let cancellableShellWrapper = #"""
set -m
child_pid=
terminate_child() {
  status="${1:-143}"
  if [ -n "${child_pid}" ]; then
    kill -TERM -"${child_pid}" 2>/dev/null || kill -TERM "${child_pid}" 2>/dev/null || true
    wait "${child_pid}" 2>/dev/null || true
  fi
  exit "${status}"
}
trap 'terminate_child 143' TERM
trap 'terminate_child 130' INT
"$@" &
child_pid=$!
wait "${child_pid}"
status=$?
child_pid=
exit "${status}"
"""#

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
    private var revealMacReceiveButton: NSButton!
    private var copyMacReceiveButton: NSButton!
    private var openWindowsReceiveButton: NSButton!
    private var revealWindowsReceiveButton: NSButton!
    private var copyWindowsReceiveButton: NSButton!
    private var cancelTransferButton: NSButton!
    private var output = Data()
    private var transferProgressLineBuffer = ""
    private var testTransferLineBuffer = ""
    private var queuedFileDrops: [QueuedFileDrop] = []
    private var promisedFileDropSessions: [PromisedFileDropSession] = []
    private var latestMacReceiveURLs: [URL] = []
    private var pendingLatestMacReceiveURLs: [URL] = []
    private var latestWindowsReceiveID = ""
    private var latestWindowsReceiveSummary = ""
    private var latestWindowsReceivePaths: [String] = []
    private var pendingLatestWindowsReceiveSummary = ""
    private var pendingLatestWindowsReceivePathCount = 0
    private var pendingMacFileClipboardFailureDetail = ""
    private var pendingWindowsFileClipboardFailureDetail = ""
    private var process: Process?
    private var transferProcess: Process? {
        didSet {
            updateCancelTransferButtonState()
        }
    }
    private var cancelledTransferProcessIDs = Set<Int32>()
    private var isBusy = false
    private var dropOverlayTimer: Timer?
    private var latestMacReceiveTimer: Timer?
    private var latestWindowsReceiveTimer: Timer?
    private var macFileClipboardFailureTimer: Timer?
    private var windowsFileClipboardFailureTimer: Timer?
    private var latestMacReceiveStateSignature = ""
    private var latestWindowsReceiveStateSignature = ""
    private var macFileClipboardFailureStateSignature = ""
    private var windowsFileClipboardFailureStateSignature = ""
    private var dropOverlayManuallyShown = false
    private var dropOverlayMouseDownLocation: NSPoint?
    private var dropOverlayLastDragLocation: NSPoint?
    private let suppressWindowOnLaunch = AppDelegate.shouldSuppressWindowOnLaunch()
    private var dropOverlayMouseDownFrontmostName = ""
    private var dropOverlayMouseDownAt = Date.distantPast
    private var dropOverlayDragCaptured = false
    private var dropOverlayRayHitUntil = Date.distantPast
    private var dropOverlayLastFileDragAt = Date.distantPast
    private let stalePromisedDropAge: TimeInterval = 6 * 60 * 60
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

    private struct QueuedFileDrop {
        let urls: [URL]
        let source: FileDropSource
        let cleanupURLs: [URL]
    }

    private final class PromisedFileDropSession {
        let destination: URL
        let operationQueue: OperationQueue
        var cancelled = false

        init(destination: URL, operationQueue: OperationQueue) {
            self.destination = destination
            self.operationQueue = operationQueue
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        guard let resourceURL = Bundle.main.resourceURL else {
            buildWindow()
            fail("Missing app resources.")
            return
        }
        self.resourceURL = resourceURL
        settings = SettingsFile.load(resourceURL: resourceURL)
        cleanupStalePromisedDropDirectories()
        buildWindow()
        startLatestWindowsReceiveMonitor()
        updateDropOverlayMonitor()
        startLatestMacReceiveMonitor()
        startMacFileClipboardFailureMonitor()
        startWindowsFileClipboardFailureMonitor()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if suppressWindowOnLaunch {
                if isCurrentProcessFrontmost() {
                    showMainWindow(activate: false)
                }
                return true
            }
            showMainWindow(activate: true)
        }
        return true
    }

    private func isCurrentProcessFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
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
        form.addArrangedSubview(check("MOONLIGHT_COMPANION_SHOW_WINDOW_ON_LAUNCH", title: "Show Companion window on launch"))
        form.addArrangedSubview(check("MOONLIGHT_COMPANION_ACTIVATE_ON_LAUNCH", title: "Bring Companion window forward on launch"))
        form.addArrangedSubview(check("MOONLIGHT_ACTIVATE_ON_LAUNCH", title: "Bring Moonlight forward after launch"))
        form.addArrangedSubview(check("MOONLIGHT_CAPSLOCK_HANGUL", title: "Caps Lock toggles Windows Han/Eng"))
        form.addArrangedSubview(check("MOONLIGHT_SHORTCUT_REMAP", title: "Map Command shortcuts to Windows Control shortcuts"))
        form.addArrangedSubview(check("MOONLIGHT_CLIPBOARD_TCP", title: "Use TCP clipboard channels"))
        form.addArrangedSubview(row("Helper Timeout", text("MOONLIGHT_CLIPBOARD_HELPER_TIMEOUT_SECONDS", width: 96)))
        form.addArrangedSubview(row("TCP I/O Timeout", text("MOONLIGHT_CLIPBOARD_TCP_IO_TIMEOUT_MS", width: 96)))

        form.addArrangedSubview(sectionTitle("Transfer"))
        form.addArrangedSubview(row("Mac Receive Dir", text("MOONLIGHT_TRANSFER_MAC_DIR", width: 520)))
        form.addArrangedSubview(row("Windows Receive Dir", text("MOONLIGHT_TRANSFER_WINDOWS_DIR", width: 520)))
        form.addArrangedSubview(check("MOONLIGHT_TRANSFER_DROP_OVERLAY", title: "Use Moonlight window as file drop target"))
        form.addArrangedSubview(check("MOONLIGHT_TRANSFER_OVERSIZE_DIRECT", title: "Send oversized drops directly to Windows receive folder"))
        form.addArrangedSubview(check("MOONLIGHT_TRANSFER_SCREEN_DROP_AUTO_PASTE", title: "Paste after Moonlight window or strip drops"))
        form.addArrangedSubview(check("MOONLIGHT_TRANSFER_ACTIVATE_MOONLIGHT_FOR_PASTE", title: "Bring Moonlight forward before auto-paste"))
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
        revealMacReceiveButton = NSButton(title: "Reveal Last Mac Receive", target: self, action: #selector(revealLatestMacReceive))
        revealMacReceiveButton.translatesAutoresizingMaskIntoConstraints = false
        revealMacReceiveButton.isEnabled = false
        copyMacReceiveButton = NSButton(title: "Copy Last Mac Receive", target: self, action: #selector(copyLatestMacReceive))
        copyMacReceiveButton.translatesAutoresizingMaskIntoConstraints = false
        copyMacReceiveButton.isEnabled = false
        openWindowsReceiveButton = NSButton(title: "Open Windows Folder", target: self, action: #selector(openWindowsReceiveFolder))
        openWindowsReceiveButton.translatesAutoresizingMaskIntoConstraints = false
        revealWindowsReceiveButton = NSButton(title: "Reveal Last Windows Receive", target: self, action: #selector(revealLatestWindowsReceive))
        revealWindowsReceiveButton.translatesAutoresizingMaskIntoConstraints = false
        revealWindowsReceiveButton.isEnabled = false
        copyWindowsReceiveButton = NSButton(title: "Copy Last Windows Receive", target: self, action: #selector(copyLatestWindowsReceive))
        copyWindowsReceiveButton.translatesAutoresizingMaskIntoConstraints = false
        copyWindowsReceiveButton.isEnabled = false
        cancelTransferButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTransferOperation))
        cancelTransferButton.translatesAutoresizingMaskIntoConstraints = false
        cancelTransferButton.isEnabled = false
        let transferDropButtons = NSStackView(views: [dropOverlayButton, dropStripButton, testTransferButton, cancelTransferButton])
        transferDropButtons.orientation = .horizontal
        transferDropButtons.alignment = .centerY
        transferDropButtons.spacing = 10
        transferDropButtons.translatesAutoresizingMaskIntoConstraints = false
        form.addArrangedSubview(row("Drop Actions", transferDropButtons))
        let transferMacFolderButtons = NSStackView(views: [openMacReceiveButton, revealMacReceiveButton, copyMacReceiveButton])
        transferMacFolderButtons.orientation = .horizontal
        transferMacFolderButtons.alignment = .centerY
        transferMacFolderButtons.spacing = 10
        transferMacFolderButtons.translatesAutoresizingMaskIntoConstraints = false
        form.addArrangedSubview(row("Mac Folders", transferMacFolderButtons))
        let transferWindowsFolderButtons = NSStackView(views: [openWindowsReceiveButton, revealWindowsReceiveButton, copyWindowsReceiveButton])
        transferWindowsFolderButtons.orientation = .horizontal
        transferWindowsFolderButtons.alignment = .centerY
        transferWindowsFolderButtons.spacing = 10
        transferWindowsFolderButtons.translatesAutoresizingMaskIntoConstraints = false
        form.addArrangedSubview(row("Windows Folders", transferWindowsFolderButtons))

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
        let shouldShowWindowOnLaunch = settings.bool("MOONLIGHT_COMPANION_SHOW_WINDOW_ON_LAUNCH") ||
            settings.bool("MOONLIGHT_COMPANION_ACTIVATE_ON_LAUNCH")
        if !suppressWindowOnLaunch && shouldShowWindowOnLaunch {
            showMainWindow(activate: settings.bool("MOONLIGHT_COMPANION_ACTIVATE_ON_LAUNCH"))
        }
    }

    private static func shouldSuppressWindowOnLaunch() -> Bool {
        let launchArguments = Set(CommandLine.arguments.dropFirst())
        if launchArguments.contains("--background") ||
            launchArguments.contains("--quiet-launch") ||
            launchArguments.contains("--no-window") {
            return true
        }
        return boolEnvironment("MOONLIGHT_COMPANION_SUPPRESS_WINDOW_ON_LAUNCH")
    }

    private static func boolEnvironment(_ key: String) -> Bool {
        switch ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "y", "yes", "true", "on":
            return true
        default:
            return false
        }
    }

    private func showMainWindow(activate: Bool) {
        guard let window else { return }
        if activate {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderFront(nil)
        }
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
                    self?.clearQueuedFileDrops()
                    self?.setBusy(false, status: "Failed", detail: "Launcher exited with status \(task.terminationStatus).", startQueuedDropsWhenIdle: false)
                    self?.showFailure("Launcher exited with status \(task.terminationStatus).")
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

    private func setBusy(
        _ busy: Bool,
        status: String,
        detail: String,
        startQueuedDropsWhenIdle: Bool = true,
        showPendingMacReceiveWhenIdle: Bool = true,
        showPendingWindowsReceiveWhenIdle: Bool = true,
        showPendingMacFileClipboardFailureWhenIdle: Bool = true,
        showPendingWindowsFileClipboardFailureWhenIdle: Bool = true
    ) {
        isBusy = busy
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
        revealMacReceiveButton?.isEnabled = !busy && !latestMacReceiveURLs.isEmpty
        copyMacReceiveButton?.isEnabled = !busy && !latestMacReceiveURLs.isEmpty
        openWindowsReceiveButton?.isEnabled = !busy
        revealWindowsReceiveButton?.isEnabled = !busy && !latestWindowsReceiveID.isEmpty
        copyWindowsReceiveButton?.isEnabled = !busy && !latestWindowsReceiveID.isEmpty
        updateCancelTransferButtonState()
        statusLabel.stringValue = status
        detailLabel.stringValue = detail

        if !busy && (
            startQueuedDropsWhenIdle ||
            showPendingMacReceiveWhenIdle ||
            showPendingWindowsReceiveWhenIdle ||
            showPendingMacFileClipboardFailureWhenIdle ||
            showPendingWindowsFileClipboardFailureWhenIdle
        ) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.startNextQueuedFileDropIfIdle(allowStart: startQueuedDropsWhenIdle) {
                    return
                }
                if showPendingMacReceiveWhenIdle,
                   self.showPendingLatestMacReceiveIfIdle() {
                    return
                }
                if showPendingWindowsReceiveWhenIdle,
                   self.showPendingLatestWindowsReceiveIfIdle() {
                    return
                }
                if showPendingMacFileClipboardFailureWhenIdle {
                    if self.showPendingMacFileClipboardFailureIfIdle() {
                        return
                    }
                }
                if showPendingWindowsFileClipboardFailureWhenIdle {
                    self.showPendingWindowsFileClipboardFailureIfIdle()
                }
            }
        }
    }

    private func clearQueuedFileDrops() {
        queuedFileDrops.forEach { cleanupTemporaryDropURLs($0.cleanupURLs) }
        queuedFileDrops.removeAll()
    }

    private func updateCancelTransferButtonState() {
        cancelTransferButton?.isEnabled = transferProcess != nil || !promisedFileDropSessions.isEmpty
    }

    private func cancelPromisedFileDrops() -> Int {
        let sessions = promisedFileDropSessions
        promisedFileDropSessions.removeAll()
        for session in sessions {
            session.cancelled = true
            session.operationQueue.cancelAllOperations()
            cleanupTemporaryDropURLs([session.destination])
        }
        updateCancelTransferButtonState()
        return sessions.count
    }

    private func queueFileDropIfBusy(_ urls: [URL], source: FileDropSource, cleanupURLs: [URL] = []) -> Bool {
        guard isBusy || transferProcess != nil else {
            return false
        }

        queuedFileDrops.append(QueuedFileDrop(urls: urls, source: source, cleanupURLs: cleanupURLs))
        let summary = fileTransferSummary(for: urls)
        let queueText = queuedFileDrops.count == 1
            ? "1 drop queued"
            : "\(queuedFileDrops.count) drops queued"
        appendQueuedDropNotice("\(summary.detail) queued. \(queueText); it will send after the current operation.")
        return true
    }

    private func appendQueuedDropNotice(_ notice: String) {
        let currentDetail = detailWithoutQueuedDropNotice()
        if currentDetail.isEmpty {
            detailLabel.stringValue = notice
        } else {
            detailLabel.stringValue = "\(currentDetail)\(Self.queuedDropDetailMarker)\(notice)"
        }
    }

    private func detailWithoutQueuedDropNotice() -> String {
        let detail = detailLabel.stringValue
        guard let markerRange = detail.range(of: Self.queuedDropDetailMarker) else {
            return detail
        }
        return String(detail[..<markerRange.lowerBound])
    }

    @discardableResult
    private func startNextQueuedFileDropIfIdle(allowStart: Bool = true) -> Bool {
        guard allowStart,
              !isBusy,
              transferProcess == nil,
              !queuedFileDrops.isEmpty else {
            return false
        }

        let nextDrop = queuedFileDrops.removeFirst()
        sendFilesToWindows(nextDrop.urls, source: nextDrop.source, cleanupURLs: nextDrop.cleanupURLs)
        return true
    }

    private func startLatestMacReceiveMonitor() {
        updateLatestMacReceiveStatus(initial: true)
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateLatestMacReceiveStatus(initial: false)
        }
        latestMacReceiveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateLatestMacReceiveStatus(initial: Bool) {
        let stateURL = latestMacReceiveStateURL()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: stateURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date else {
            latestMacReceiveStateSignature = ""
            latestMacReceiveURLs = []
            updateLatestMacReceiveButtonState()
            return
        }

        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let signature = "\(modifiedAt.timeIntervalSince1970):\(size)"
        guard signature != latestMacReceiveStateSignature else {
            refreshLatestMacReceiveAvailability(initial: initial)
            return
        }
        latestMacReceiveStateSignature = signature

        let state = SettingsFile.parse(url: stateURL)
        let urls = latestMacReceiveFileURLs(from: state)
        guard !urls.isEmpty else {
            latestMacReceiveURLs = []
            updateLatestMacReceiveButtonState()
            return
        }
        let existingURLs = existingFileURLs(from: urls)
        guard !existingURLs.isEmpty else {
            latestMacReceiveURLs = []
            updateLatestMacReceiveButtonState()
            if !initial {
                statusLabel.stringValue = "Mac Files Missing"
                detailLabel.stringValue = "The latest received files are no longer in the Mac receive folder."
            }
            return
        }

        latestMacReceiveURLs = existingURLs
        updateLatestMacReceiveButtonState()

        if !initial {
            if isBusy {
                pendingLatestMacReceiveURLs = existingURLs
            } else {
                showLatestMacReceiveStatus(existingURLs, totalCount: urls.count)
            }
        }
    }

    private func refreshLatestMacReceiveAvailability(initial: Bool) {
        guard !latestMacReceiveURLs.isEmpty else {
            return
        }

        let existingURLs = existingFileURLs(from: latestMacReceiveURLs)
        guard existingURLs.count != latestMacReceiveURLs.count else {
            return
        }

        latestMacReceiveURLs = existingURLs
        pendingLatestMacReceiveURLs = existingFileURLs(from: pendingLatestMacReceiveURLs)
        updateLatestMacReceiveButtonState()

        if existingURLs.isEmpty && !initial {
            statusLabel.stringValue = "Mac Files Missing"
            detailLabel.stringValue = "The latest received files are no longer in the Mac receive folder."
        }
    }

    @discardableResult
    private func showPendingLatestMacReceiveIfIdle() -> Bool {
        guard !isBusy,
              transferProcess == nil,
              !pendingLatestMacReceiveURLs.isEmpty else {
            return false
        }

        showLatestMacReceiveStatus(pendingLatestMacReceiveURLs)
        return true
    }

    private func showLatestMacReceiveStatus(_ urls: [URL], totalCount: Int? = nil) {
        pendingLatestMacReceiveURLs = []
        statusLabel.stringValue = "Files Received"
        let summary = FileDropReader.dropSummary(for: urls)
        if let totalCount, totalCount > urls.count {
            detailLabel.stringValue = "\(urls.count) of \(totalCount) received items still available: \(summary)"
        } else {
            detailLabel.stringValue = summary
        }
    }

    private func updateLatestMacReceiveButtonState() {
        revealMacReceiveButton?.isEnabled = !isBusy && !latestMacReceiveURLs.isEmpty
        copyMacReceiveButton?.isEnabled = !isBusy && !latestMacReceiveURLs.isEmpty
    }

    private func latestWindowsReceiveStateURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MoonlightCompanion/latest-windows-receive-state.txt")
    }

    private func startLatestWindowsReceiveMonitor() {
        updateLatestWindowsReceiveStatus(initial: true)
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateLatestWindowsReceiveStatus(initial: false)
        }
        latestWindowsReceiveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateLatestWindowsReceiveStatus(initial: Bool) {
        let stateURL = latestWindowsReceiveStateURL()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: stateURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date else {
            latestWindowsReceiveStateSignature = ""
            latestWindowsReceiveID = ""
            latestWindowsReceiveSummary = ""
            latestWindowsReceivePaths = []
            pendingLatestWindowsReceiveSummary = ""
            pendingLatestWindowsReceivePathCount = 0
            updateLatestWindowsReceiveButtonState()
            return
        }

        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let signature = "\(modifiedAt.timeIntervalSince1970):\(size)"
        guard signature != latestWindowsReceiveStateSignature else {
            return
        }
        latestWindowsReceiveStateSignature = signature
        let previousID = latestWindowsReceiveID
        loadLatestWindowsReceiveState()
        guard !initial,
              !latestWindowsReceiveID.isEmpty,
              latestWindowsReceiveID != previousID else {
            return
        }

        if isBusy || transferProcess != nil {
            pendingLatestWindowsReceiveSummary = latestWindowsReceiveSummary
            pendingLatestWindowsReceivePathCount = latestWindowsReceivePaths.count
        } else {
            showLatestWindowsReceiveStatus(
                summary: latestWindowsReceiveSummary,
                pathCount: latestWindowsReceivePaths.count
            )
        }
    }

    private func loadLatestWindowsReceiveState() {
        let state = SettingsFile.parse(url: latestWindowsReceiveStateURL())
        let id = state["id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        latestWindowsReceiveID = windowsImportConfirmed(state) ? id : ""
        latestWindowsReceiveSummary = windowsImportSummary(state)
        latestWindowsReceivePaths = latestWindowsImportedPaths(from: state)
        updateLatestWindowsReceiveButtonState()
    }

    private func windowsImportConfirmed(_ state: [String: String]) -> Bool {
        let id = state["id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let confirmation = state["confirmation"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let importedPaths = Int(state["imported_paths"] ?? "") ?? 0
        return !id.isEmpty && !confirmation.isEmpty && confirmation != "pending" && importedPaths > 0
    }

    private func windowsClipboardReady(_ state: [String: String]) -> Bool {
        let value = state["clipboard_ready"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return value.isEmpty || value == "1" || value == "y" || value == "yes" || value == "true" || value == "on"
    }

    private func recordLatestWindowsReceiveState(_ state: [String: String]) {
        let id = state["id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let confirmation = state["confirmation"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let importedPaths = Int(state["imported_paths"] ?? "") ?? 0
        guard windowsImportConfirmed(state) else {
            clearLatestWindowsReceiveState()
            return
        }

        latestWindowsReceiveID = id
        latestWindowsReceiveSummary = windowsImportSummary(state)
        latestWindowsReceivePaths = latestWindowsImportedPaths(from: state)
        var values: [String: String] = [
            "bytes": state["bytes"] ?? "",
            "confirmation": confirmation,
            "clipboard_ready": state["clipboard_ready"] ?? "",
            "id": id,
            "imported_names_b64": state["imported_names_b64"] ?? "",
            "imported_paths": "\(importedPaths)",
            "kind": state["kind"] ?? ""
        ]
        for (index, path) in latestWindowsReceivePaths.enumerated() {
            values["imported_path_\(index + 1)"] = path
            values["imported_path_\(index + 1)_b64"] = base64StateValue(path)
        }
        writeSimpleState(values, to: latestWindowsReceiveStateURL())
        updateLatestWindowsReceiveButtonState()
    }

    private func clearLatestWindowsReceiveState() {
        latestWindowsReceiveID = ""
        latestWindowsReceiveSummary = ""
        latestWindowsReceivePaths = []
        pendingLatestWindowsReceiveSummary = ""
        pendingLatestWindowsReceivePathCount = 0
        latestWindowsReceiveStateSignature = ""
        try? FileManager.default.removeItem(at: latestWindowsReceiveStateURL())
        updateLatestWindowsReceiveButtonState()
    }

    private func latestWindowsImportedPaths(from state: [String: String]) -> [String] {
        let importedPaths = Int(state["imported_paths"] ?? "") ?? 0
        guard importedPaths > 0 else { return [] }

        var paths: [String] = []
        for index in 1...importedPaths {
            let path = decodedStateValue(state["imported_path_\(index)_b64"]) ??
                state["imported_path_\(index)"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty {
                paths.append(path)
            }
        }
        return paths
    }

    private func windowsImportSummary(_ state: [String: String]) -> String {
        let encoded = state["imported_names_b64"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !encoded.isEmpty,
              let data = Data(base64Encoded: encoded),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        let names = text
            .split(separator: "\u{1f}", omittingEmptySubsequences: true)
            .map(String.init)
        return summarizedNames(names)
    }

    private func writeSimpleState(_ values: [String: String], to url: URL) {
        let text = values.keys.sorted()
            .map { key in "\(key)=\(values[key] ?? "")" }
            .joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            detailLabel.stringValue = "Could not save receive state: \(error.localizedDescription)"
        }
    }

    private func updateLatestWindowsReceiveButtonState() {
        revealWindowsReceiveButton?.isEnabled = !isBusy && !latestWindowsReceiveID.isEmpty
        copyWindowsReceiveButton?.isEnabled = !isBusy && !latestWindowsReceiveID.isEmpty
    }

    @discardableResult
    private func showPendingLatestWindowsReceiveIfIdle() -> Bool {
        guard !isBusy,
              transferProcess == nil,
              !pendingLatestWindowsReceiveSummary.isEmpty || pendingLatestWindowsReceivePathCount > 0 else {
            return false
        }

        showLatestWindowsReceiveStatus(
            summary: pendingLatestWindowsReceiveSummary,
            pathCount: pendingLatestWindowsReceivePathCount
        )
        return true
    }

    private func showLatestWindowsReceiveStatus(summary: String, pathCount: Int) {
        pendingLatestWindowsReceiveSummary = ""
        pendingLatestWindowsReceivePathCount = 0
        statusLabel.stringValue = "Windows Files Received"
        if summary.isEmpty {
            if pathCount == 1 {
                detailLabel.stringValue = "1 item is ready in the Windows receive folder."
            } else if pathCount > 1 {
                detailLabel.stringValue = "\(pathCount) items are ready in the Windows receive folder."
            } else {
                detailLabel.stringValue = "The latest files are ready in the Windows receive folder."
            }
        } else {
            detailLabel.stringValue = "Ready in the Windows receive folder: \(summary)"
        }
    }

    private func macFileClipboardFailureStateURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MoonlightCompanion/mac-file-clipboard-failure-state.txt")
    }

    private func windowsFileClipboardFailureStateURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MoonlightCompanion/windows-file-clipboard-failure-state.txt")
    }

    private func startMacFileClipboardFailureMonitor() {
        updateMacFileClipboardFailureStatus(initial: true)
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateMacFileClipboardFailureStatus(initial: false)
        }
        macFileClipboardFailureTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateMacFileClipboardFailureStatus(initial: Bool) {
        let stateURL = macFileClipboardFailureStateURL()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: stateURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date else {
            macFileClipboardFailureStateSignature = ""
            pendingMacFileClipboardFailureDetail = ""
            return
        }

        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let signature = "\(modifiedAt.timeIntervalSince1970):\(size)"
        guard signature != macFileClipboardFailureStateSignature else {
            if !initial {
                showPendingMacFileClipboardFailureIfIdle()
            }
            return
        }
        macFileClipboardFailureStateSignature = signature

        let state = SettingsFile.parse(url: stateURL)
        guard let detail = macFileClipboardFailureDetail(from: state) else {
            pendingMacFileClipboardFailureDetail = ""
            return
        }

        if !initial {
            if isBusy || transferProcess != nil {
                pendingMacFileClipboardFailureDetail = detail
            } else {
                showMacFileClipboardFailureStatus(detail)
            }
        }
    }

    private func macFileClipboardFailureDetail(from state: [String: String]) -> String? {
        let status = state["status"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard status == "stale-mac-file-clipboard" else {
            return nil
        }

        let detail = decodedStateValue(state["message_b64"]) ??
            state["message"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detail.isEmpty ? nil : detail
    }

    @discardableResult
    private func showPendingMacFileClipboardFailureIfIdle() -> Bool {
        guard !isBusy,
              transferProcess == nil,
              !pendingMacFileClipboardFailureDetail.isEmpty else {
            return false
        }

        showMacFileClipboardFailureStatus(pendingMacFileClipboardFailureDetail)
        return true
    }

    private func showMacFileClipboardFailureStatus(_ detail: String) {
        pendingMacFileClipboardFailureDetail = ""
        statusLabel.stringValue = "Mac Clipboard File Missing"
        detailLabel.stringValue = "Could not send Mac file clipboard: \(detail)"
    }

    private func startWindowsFileClipboardFailureMonitor() {
        updateWindowsFileClipboardFailureStatus(initial: true)
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateWindowsFileClipboardFailureStatus(initial: false)
        }
        windowsFileClipboardFailureTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateWindowsFileClipboardFailureStatus(initial: Bool) {
        let stateURL = windowsFileClipboardFailureStateURL()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: stateURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date else {
            windowsFileClipboardFailureStateSignature = ""
            pendingWindowsFileClipboardFailureDetail = ""
            return
        }

        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let signature = "\(modifiedAt.timeIntervalSince1970):\(size)"
        guard signature != windowsFileClipboardFailureStateSignature else {
            if !initial {
                showPendingWindowsFileClipboardFailureIfIdle()
            }
            return
        }
        windowsFileClipboardFailureStateSignature = signature

        let state = SettingsFile.parse(url: stateURL)
        guard let detail = windowsFileClipboardFailureDetail(from: state) else {
            pendingWindowsFileClipboardFailureDetail = ""
            return
        }

        if !initial {
            if isBusy || transferProcess != nil {
                pendingWindowsFileClipboardFailureDetail = detail
            } else {
                showWindowsFileClipboardFailureStatus(detail)
            }
        }
    }

    private func windowsFileClipboardFailureDetail(from state: [String: String]) -> String? {
        let status = state["status"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard status == "stale-windows-file-clipboard" else {
            return nil
        }

        let detail = decodedStateValue(state["message_b64"]) ??
            state["message"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detail.isEmpty ? nil : detail
    }

    @discardableResult
    private func showPendingWindowsFileClipboardFailureIfIdle() -> Bool {
        guard !isBusy,
              transferProcess == nil,
              !pendingWindowsFileClipboardFailureDetail.isEmpty else {
            return false
        }

        showWindowsFileClipboardFailureStatus(pendingWindowsFileClipboardFailureDetail)
        return true
    }

    private func showWindowsFileClipboardFailureStatus(_ detail: String) {
        pendingWindowsFileClipboardFailureDetail = ""
        statusLabel.stringValue = "Windows Clipboard File Missing"
        detailLabel.stringValue = "Could not receive Windows file clipboard: \(detail)"
    }

    private func consumeTransferCancellation(for task: Process) -> Bool {
        let processID = task.processIdentifier
        guard cancelledTransferProcessIDs.contains(processID) else {
            return false
        }
        cancelledTransferProcessIDs.remove(processID)
        return true
    }

    private func configureCancellableTransferTask(_ task: Process, scriptURL: URL, arguments: [String] = []) {
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", Self.cancellableShellWrapper, "moonlight-companion-transfer", scriptURL.path] + arguments
    }

    private func appendTransferOutput(_ data: Data, progressStatus: String) {
        output.append(data)
        guard let text = String(data: data, encoding: .utf8) else {
            return
        }

        transferProgressLineBuffer += text
        while let newlineRange = transferProgressLineBuffer.range(of: "\n") {
            let line = String(transferProgressLineBuffer[..<newlineRange.lowerBound])
            let nextIndex = transferProgressLineBuffer.index(after: newlineRange.lowerBound)
            transferProgressLineBuffer.removeSubrange(..<nextIndex)
            updateTransferProgress(from: line, status: progressStatus)
        }
    }

    private func updateTransferProgress(from line: String, status: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.transferProgressPrefix) else {
            return
        }

        let messageStart = trimmed.index(trimmed.startIndex, offsetBy: Self.transferProgressPrefix.count)
        let message = String(trimmed[messageStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return
        }

        statusLabel.stringValue = status
        detailLabel.stringValue = message
    }

    private func filteredTransferOutputText() -> String? {
        guard let text = String(data: output, encoding: .utf8) else {
            return nil
        }

        let filteredLines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                !line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix(Self.transferProgressPrefix)
            }
        let filtered = filteredLines
            .map(String.init)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return filtered.isEmpty ? nil : filtered
    }

    private func appendTestTransferOutput(_ data: Data) {
        output.append(data)
        guard let text = String(data: data, encoding: .utf8) else {
            return
        }

        testTransferLineBuffer += text
        while let newlineRange = testTransferLineBuffer.range(of: "\n") {
            let line = String(testTransferLineBuffer[..<newlineRange.lowerBound])
            let nextIndex = testTransferLineBuffer.index(after: newlineRange.lowerBound)
            testTransferLineBuffer.removeSubrange(..<nextIndex)
            updateTestTransferProgress(from: line)
        }
    }

    private func updateTestTransferProgress(from line: String) {
        let message = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return
        }

        statusLabel.stringValue = "Testing Transfer"
        detailLabel.stringValue = message
    }

    private func fail(_ message: String) {
        clearQueuedFileDrops()
        setBusy(false, status: "Failed", detail: message, startQueuedDropsWhenIdle: false)
        showFailure(message)
    }

    private func showFailure(_ message: String) {
        guard NSApp.isActive, window?.isVisible == true else {
            return
        }
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

    @objc private func cancelTransferOperation() {
        guard let task = transferProcess else {
            let promisedDropCount = cancelPromisedFileDrops()
            guard promisedDropCount > 0 else { return }
            let queuedDropCount = queuedFileDrops.count
            clearQueuedFileDrops()
            setBusy(false, status: "Cancelled", detail: queuedDropCount == 0
                ? "Cancelled \(promisedDropCount) promised file drop(s)."
                : "Cancelled \(promisedDropCount) promised file drop(s) and cleared \(queuedDropCount) queued drop(s).",
                startQueuedDropsWhenIdle: false
            )
            return
        }
        cancelledTransferProcessIDs.insert(task.processIdentifier)
        let queuedDropCount = queuedFileDrops.count
        let promisedDropCount = cancelPromisedFileDrops()
        clearQueuedFileDrops()
        task.terminate()
        cancelTransferButton?.isEnabled = false
        statusLabel.stringValue = "Cancelling"
        var detail = "Stopping the current transfer operation."
        if queuedDropCount > 0 {
            detail += " Clearing \(queuedDropCount) queued drop(s)."
        }
        if promisedDropCount > 0 {
            detail += " Cancelling \(promisedDropCount) promised file drop(s)."
        }
        detailLabel.stringValue = detail
    }

    @objc private func openMacReceiveFolder() {
        openMacReceiveFolderWithStatusUpdate(true)
    }

    private func openMacReceiveFolderWithStatusUpdate(_ updateStatus: Bool) {
        let settings = collectSettings()
        let rawPath = settings["MOONLIGHT_TRANSFER_MAC_DIR"].isEmpty
            ? "${HOME}/Downloads/Moonlight Companion"
            : settings["MOONLIGHT_TRANSFER_MAC_DIR"]
        let url = URL(fileURLWithPath: expandedUserPath(rawPath), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
            if updateStatus {
                statusLabel.stringValue = "Mac Folder Opened"
                detailLabel.stringValue = url.path
            }
        } catch {
            fail("Could not open receive folder: \(error.localizedDescription)")
        }
    }

    @objc private func revealLatestMacReceive() {
        let state = SettingsFile.parse(url: latestMacReceiveStateURL())
        let urls = latestMacReceiveFileURLs(from: state)
        let existingURLs = existingFileURLs(from: urls)
        guard !existingURLs.isEmpty else {
            latestMacReceiveURLs = []
            updateLatestMacReceiveButtonState()
            openMacReceiveFolderWithStatusUpdate(false)
            statusLabel.stringValue = "Mac Folder Opened"
            detailLabel.stringValue = urls.isEmpty
                ? "No latest received Mac file state was found yet."
                : "The latest received file was no longer found; opened the receive folder."
            return
        }

        latestMacReceiveURLs = existingURLs
        updateLatestMacReceiveButtonState()
        NSWorkspace.shared.activateFileViewerSelecting(existingURLs)
        statusLabel.stringValue = "Mac Files Revealed"
        detailLabel.stringValue = FileDropReader.dropSummary(for: existingURLs)
    }

    @objc private func copyLatestMacReceive() {
        let state = SettingsFile.parse(url: latestMacReceiveStateURL())
        let urls = latestMacReceiveFileURLs(from: state)
        let existingURLs = existingFileURLs(from: urls)
        guard !existingURLs.isEmpty else {
            latestMacReceiveURLs = []
            updateLatestMacReceiveButtonState()
            statusLabel.stringValue = "Copy Failed"
            detailLabel.stringValue = urls.isEmpty
                ? "No latest received Mac file state was found yet."
                : "The latest received file was no longer found."
            return
        }

        let result = withLatestMacReceiveClipboardLock {
            restoreLatestMacReceiveToClipboard(existingURLs)
        }

        if result == .copied {
            latestMacReceiveURLs = existingURLs
            updateLatestMacReceiveButtonState()
            statusLabel.stringValue = "Mac Files Copied"
            detailLabel.stringValue = "\(FileDropReader.dropSummary(for: existingURLs)) is ready to paste."
        } else if result == .missingID {
            statusLabel.stringValue = "Copy Failed"
            detailLabel.stringValue = "Could not prepare the latest received files for clipboard restore."
        } else {
            statusLabel.stringValue = "Copy Failed"
            detailLabel.stringValue = "Could not put the latest received files on the Mac clipboard."
        }
    }

    private enum ReceiveClipboardRestoreResult {
        case copied
        case missingID
        case pasteboardFailed
    }

    private func restoreLatestMacReceiveToClipboard(_ urls: [URL]) -> ReceiveClipboardRestoreResult {
        if let restoredID = writeFileURLsToPasteboardUsingHelper(urls) {
            markLatestMacReceiveRestoredToClipboard(restoredID: restoredID)
            return .copied
        }

        guard let restoredID = payloadIDForFileURLs(urls) else {
            return .missingID
        }

        guard writeFileURLsToPasteboardDirectly(urls) else {
            return .pasteboardFailed
        }

        markLatestMacReceiveRestoredToClipboard(restoredID: restoredID)
        return .copied
    }

    private func writeFileURLsToPasteboardUsingHelper(_ urls: [URL]) -> String? {
        let helperURL = clipboardHelperURL()
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return nil
        }

        let payloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moonlight-companion-set-files-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: payloadURL)
        }

        let task = Process()
        let pipe = Pipe()
        task.executableURL = helperURL
        task.arguments = ["set-files", payloadURL.path] + urls.map(\.path)
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return SettingsFile.parse(text: text)["id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeFileURLsToPasteboardDirectly(_ urls: [URL]) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let wroteObjects = pasteboard.writeObjects(urls.map { $0 as NSURL })
        let wroteLegacyPaths = pasteboard.setPropertyList(urls.map(\.path), forType: FileDropReader.filenamesPasteboardType)
        return wroteObjects || wroteLegacyPaths
    }

    private func markLatestMacReceiveRestoredToClipboard(restoredID: String) {
        markMacClipboardRestoreIgnored(restoredID: restoredID)

        var state = SettingsFile.parse(url: latestMacReceiveStateURL())
        guard !state.isEmpty else {
            return
        }

        state["normalized_id"] = restoredID
        if (state["windows_id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state["windows_id"] = restoredID
        }
        writeSimpleState(state, to: latestMacReceiveStateURL())
    }

    private func markMacClipboardRestoreIgnored(restoredID: String) {
        let values = [
            "id": restoredID,
            "reason": "gui-latest-mac-receive-restore"
        ]
        writeSimpleState(values, to: macClipboardIgnoreStateURL())
    }

    private func withLatestMacReceiveClipboardLock<T>(_ body: () -> T) -> T {
        let lockURL = URL(fileURLWithPath: latestMacReceiveStateURL().path + ".lock")
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? "restoring\n".write(to: lockURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: lockURL)
        }
        return body()
    }

    private func payloadIDForFileURLs(_ urls: [URL]) -> String? {
        let helperURL = clipboardHelperURL()
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return nil
        }

        let payloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moonlight-companion-restore-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: payloadURL)
        }

        let task = Process()
        let pipe = Pipe()
        task.executableURL = helperURL
        task.arguments = ["export-paths", payloadURL.path] + urls.map(\.path)
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return SettingsFile.parse(text: text)["id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clipboardHelperURL() -> URL {
        let configuredHelper = settings["MOONLIGHT_CLIPBOARD_HELPER"]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredHelper.isEmpty {
            return URL(fileURLWithPath: expandedUserPath(configuredHelper))
        }

        return clipboardRuntimeDirectory().appendingPathComponent("moonclipctl")
    }

    private func clipboardRuntimeDirectory() -> URL {
        let configuredRuntime = settings["MOONLIGHT_CLIPBOARD_RUNTIME_DIR"]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredRuntime.isEmpty {
            return URL(fileURLWithPath: expandedUserPath(configuredRuntime), isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MoonlightClipboardSync", isDirectory: true)
    }

    private func latestMacReceiveStateURL() -> URL {
        clipboardRuntimeDirectory().appendingPathComponent("clipboard-tcp-windows-state.txt")
    }

    private func macClipboardIgnoreStateURL() -> URL {
        clipboardRuntimeDirectory().appendingPathComponent("clipboard-mac-ignore-state.txt")
    }

    private func latestMacReceiveFileURLs(from state: [String: String]) -> [URL] {
        guard state["kind"] == "files" else {
            return []
        }

        let count = Int(state["file_paths"] ?? "") ?? Int(state["files"] ?? "") ?? 0
        guard count > 0 else {
            return []
        }

        return (1...count).compactMap { index in
            let rawPath = decodedStateValue(state["file_path_\(index)_b64"]) ??
                state["file_path_\(index)"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let path = expandedUserPath(rawPath)
            return path.isEmpty ? nil : URL(fileURLWithPath: path)
        }
    }

    private func base64StateValue(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private func decodedStateValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let data = Data(base64Encoded: value),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }

    private func existingFileURLs(from urls: [URL]) -> [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    @objc private func openWindowsReceiveFolder() {
        guard saveSettings() else { return }

        setBusy(true, status: "Opening Windows Folder", detail: "Asking Windows to open the receive folder.")
        requestWindowsReceiveFolderOpen(selectLatestImport: false) { [weak self] succeeded, detail in
            if detail == "cancelled" {
                self?.clearQueuedFileDrops()
                self?.setBusy(false, status: "Cancelled", detail: "Windows receive folder open was cancelled.", startQueuedDropsWhenIdle: false)
                return
            }
            if succeeded {
                self?.setBusy(false, status: "Windows Folder Opened", detail: detail)
            } else {
                self?.clearQueuedFileDrops()
                self?.setBusy(false, status: "Open Failed", detail: detail, startQueuedDropsWhenIdle: false)
                self?.showFailure("Windows receive folder opener failed.")
            }
        }
    }

    @objc private func revealLatestWindowsReceive() {
        guard saveSettings() else { return }
        loadLatestWindowsReceiveState()
        let expectedImportID = latestWindowsReceiveID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedImportID.isEmpty else {
            clearLatestWindowsReceiveState()
            statusLabel.stringValue = "No Windows Receive"
            detailLabel.stringValue = "No confirmed latest Windows receive state is available yet."
            return
        }

        let revealDetail = latestWindowsReceiveSummary.isEmpty
            ? "Asking Windows to select the latest received item."
            : "Asking Windows to select \(latestWindowsReceiveSummary)."
        setBusy(true, status: "Revealing Windows Files", detail: revealDetail)
        let selectPaths = latestWindowsReceivePaths
        requestWindowsReceiveFolderOpen(
            selectLatestImport: selectPaths.isEmpty,
            expectedImportID: expectedImportID,
            selectPaths: selectPaths
        ) { [weak self] succeeded, detail in
            if detail == "cancelled" {
                self?.clearQueuedFileDrops()
                self?.setBusy(false, status: "Cancelled", detail: "Windows receive reveal was cancelled.", startQueuedDropsWhenIdle: false)
                return
            }
            if succeeded {
                if self?.windowsReceiveRevealStateExpired(detail) == true {
                    self?.clearLatestWindowsReceiveState()
                    self?.setBusy(false, status: "Windows Receive Missing", detail: detail)
                    return
                }
                let status = detail.contains("select") ? "Windows Files Revealed" : "Windows Folder Opened"
                let summary = self?.latestWindowsReceiveSummary ?? ""
                let resultDetail: String
                if summary.isEmpty {
                    resultDetail = detail
                } else if detail.contains("select") {
                    resultDetail = "Selected \(summary) in Windows."
                } else {
                    resultDetail = "Opened the Windows receive folder for \(summary)."
                }
                self?.setBusy(false, status: status, detail: resultDetail)
            } else {
                self?.clearQueuedFileDrops()
                self?.setBusy(false, status: "Reveal Failed", detail: detail, startQueuedDropsWhenIdle: false)
                self?.showFailure("Windows receive reveal failed.")
            }
        }
    }

    @objc private func copyLatestWindowsReceive() {
        guard saveSettings() else { return }
        loadLatestWindowsReceiveState()
        let expectedImportID = latestWindowsReceiveID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedImportID.isEmpty else {
            clearLatestWindowsReceiveState()
            statusLabel.stringValue = "No Windows Receive"
            detailLabel.stringValue = "No confirmed latest Windows receive state is available yet."
            return
        }

        let selectPaths = latestWindowsReceivePaths
        guard !selectPaths.isEmpty else {
            statusLabel.stringValue = "Copy Failed"
            detailLabel.stringValue = "No confirmed Windows receive paths are available for clipboard restore."
            return
        }

        let copyDetail = latestWindowsReceiveSummary.isEmpty
            ? "Asking Windows to put the latest received item on the clipboard."
            : "Asking Windows to put \(latestWindowsReceiveSummary) on the clipboard."
        setBusy(true, status: "Copying Windows Files", detail: copyDetail)
        requestWindowsReceiveClipboardRestore(
            expectedImportID: expectedImportID,
            selectPaths: selectPaths
        ) { [weak self] succeeded, detail in
            if detail == "cancelled" {
                self?.clearQueuedFileDrops()
                self?.setBusy(false, status: "Cancelled", detail: "Windows receive clipboard restore was cancelled.", startQueuedDropsWhenIdle: false)
                return
            }
            if succeeded {
                if self?.windowsReceiveRevealStateExpired(detail) == true {
                    self?.clearLatestWindowsReceiveState()
                    self?.setBusy(false, status: "Windows Receive Missing", detail: detail)
                    return
                }
                let summary = self?.latestWindowsReceiveSummary ?? ""
                let resultDetail = summary.isEmpty
                    ? detail
                    : "\(summary) is ready on the Windows clipboard."
                self?.setBusy(false, status: "Windows Files Copied", detail: resultDetail)
            } else {
                self?.setBusy(false, status: "Copy Failed", detail: detail, startQueuedDropsWhenIdle: false)
            }
        }
    }

    private func windowsReceiveRevealStateExpired(_ detail: String) -> Bool {
        detail.contains("did not match") ||
            detail.contains("state was unavailable") ||
            detail.contains("item was unavailable")
    }

    private func requestWindowsReceiveClipboardRestore(
        expectedImportID: String,
        selectPaths: [String],
        completion: @escaping (Bool, String) -> Void
    ) {
        let copierURL = resourceURL.appendingPathComponent("mac/copy-windows-receive-to-clipboard.sh")
        guard FileManager.default.isExecutableFile(atPath: copierURL.path) else {
            completion(false, "Windows receive clipboard copier is missing or not executable: \(copierURL.path)")
            return
        }

        let task = Process()
        let pipe = Pipe()
        var arguments = [
            copierURL.path,
            "--expected-id",
            expectedImportID
        ]
        for path in selectPaths where !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--select-path", path])
        }
        configureCancellableTransferTask(task, scriptURL: copierURL, arguments: Array(arguments.dropFirst()))
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
            let detail = text?.isEmpty == false ? text! : "Windows clipboard restore exited with status \(task.terminationStatus)."
            DispatchQueue.main.async {
                let cancelled = self?.consumeTransferCancellation(for: task) == true
                if self?.transferProcess === task {
                    self?.transferProcess = nil
                }
                if cancelled {
                    completion(false, "cancelled")
                    return
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

    private func requestWindowsReceiveFolderOpen(
        selectLatestImport: Bool,
        expectedImportID: String? = nil,
        selectPaths: [String] = [],
        completion: @escaping (Bool, String) -> Void
    ) {
        let openerURL = resourceURL.appendingPathComponent("mac/open-windows-receive-folder.sh")
        guard FileManager.default.isExecutableFile(atPath: openerURL.path) else {
            completion(false, "Windows receive folder opener is missing or not executable: \(openerURL.path)")
            return
        }

        let task = Process()
        let pipe = Pipe()
        var arguments = [openerURL.path]
        if selectLatestImport {
            arguments.append("--latest-import")
        }
        if let expectedImportID,
           !expectedImportID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--expected-id", expectedImportID])
        }
        for path in selectPaths where !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--select-path", path])
        }
        configureCancellableTransferTask(task, scriptURL: openerURL, arguments: Array(arguments.dropFirst()))
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
                let cancelled = self?.consumeTransferCancellation(for: task) == true
                if self?.transferProcess === task {
                    self?.transferProcess = nil
                }
                if cancelled {
                    completion(false, "cancelled")
                    return
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
        testTransferLineBuffer = ""
        setBusy(true, status: "Testing Transfer", detail: "Checking Mac -> Windows and Windows -> Mac file transfer.")

        let task = Process()
        let pipe = Pipe()
        configureCancellableTransferTask(task, scriptURL: testURL)
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
                self?.appendTestTransferOutput(data)
            }
        }

        task.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                if self?.consumeTransferCancellation(for: task) == true {
                    self?.transferProcess = nil
                    self?.setBusy(false, status: "Cancelled", detail: "File transfer test was cancelled.", startQueuedDropsWhenIdle: false)
                    return
                }
                self?.transferProcess = nil
                let text = String(data: self?.output ?? Data(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = text?.isEmpty == false ? text! : "File transfer test exited with status \(task.terminationStatus)."
                if task.terminationStatus == 0 {
                    self?.setBusy(false, status: "Transfer OK", detail: detail)
                } else {
                    self?.clearQueuedFileDrops()
                    self?.setBusy(false, status: "Transfer Failed", detail: detail, startQueuedDropsWhenIdle: false)
                    self?.showFailure("File transfer test failed.")
                }
            }
        }

        do {
            try task.run()
            transferProcess = task
        } catch {
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
        let hasFileDrag = FileDropReader.hasFileDropContent(from: NSPasteboard(name: .drag))
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
        dropOverlayWindow?.level = manual ? .statusBar : .floating
        if manual {
            dropOverlayWindow?.orderFrontRegardless()
        } else {
            dropOverlayWindow?.orderFront(nil)
        }
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
        dropStripWindow?.orderFront(nil)
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

    private func sendFilesToWindows(_ urls: [URL], source: FileDropSource, cleanupURLs: [URL] = []) {
        guard !urls.isEmpty else { return }
        guard saveSettings() else {
            cleanupTemporaryDropURLs(cleanupURLs)
            return
        }
        let pasteAfterSend = shouldPasteAfterSend(for: source)
        let summary = fileTransferSummary(for: urls)

        let senderURL = resourceURL.appendingPathComponent("mac/send-files-to-windows.sh")
        guard FileManager.default.isExecutableFile(atPath: senderURL.path) else {
            cleanupTemporaryDropURLs(cleanupURLs)
            fail("File sender is missing or not executable: \(senderURL.path)")
            return
        }

        output = Data()
        transferProgressLineBuffer = ""
        setBusy(true, status: "Sending Files", detail: "Sending \(summary.detail) to Windows.")
        let transferResultStateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moonlight-companion-send-\(UUID().uuidString).state")

        let task = Process()
        let pipe = Pipe()
        configureCancellableTransferTask(task, scriptURL: senderURL, arguments: urls.map(\.path))
        task.currentDirectoryURL = resourceURL
        task.standardOutput = pipe
        task.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["MOONLIGHT_COMPANION_CONFIG"] = SettingsFile.userURL.path
        environment["MOONLIGHT_TRANSFER_RESULT_STATE"] = transferResultStateURL.path
        environment["MOONLIGHT_TRANSFER_PROGRESS_EVENTS"] = "yes"
        if pasteAfterSend || settings.bool("MOONLIGHT_TRANSFER_REVEAL_WINDOWS_DIR") {
            environment["MOONLIGHT_TRANSFER_CONFIRM_TIMEOUT_MS"] = "8000"
        }
        task.environment = environment

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.appendTransferOutput(data, progressStatus: "Sending Files")
            }
        }

        task.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                if self?.consumeTransferCancellation(for: task) == true {
                    self?.transferProcess = nil
                    try? FileManager.default.removeItem(at: transferResultStateURL)
                    self?.cleanupTemporaryDropURLs(cleanupURLs)
                    self?.setBusy(false, status: "Cancelled", detail: "\(summary.detail) send was cancelled.", startQueuedDropsWhenIdle: false)
                    return
                }
                self?.transferProcess = nil
                let text = self?.filteredTransferOutputText()
                self?.cleanupTemporaryDropURLs(cleanupURLs)
                if task.terminationStatus == 0 {
                    let transferResult = SettingsFile.parse(url: transferResultStateURL)
                    try? FileManager.default.removeItem(at: transferResultStateURL)
                    self?.recordLatestWindowsReceiveState(transferResult)
                    var detail = text?.isEmpty == false ? text! : "\(summary.detail) sent to Windows."
                    let importConfirmed = self?.windowsImportConfirmed(transferResult) == true
                    let clipboardReady = self?.windowsClipboardReady(transferResult) == true
                    var pasteSummary = importConfirmed
                        ? (clipboardReady ? "Ready on the Windows clipboard." : "Copied to the Windows receive folder.")
                        : "Windows import confirmation is pending."
                    if pasteAfterSend && importConfirmed && clipboardReady {
                        let allowActivation = self?.settings.bool("MOONLIGHT_TRANSFER_ACTIVATE_MOONLIGHT_FOR_PASTE") == true
                        switch self?.pasteIntoMoonlight(allowActivation: allowActivation) ?? .failed {
                        case .pasted:
                            pasteSummary = "Pasted into Moonlight."
                            detail += " Sent Ctrl+V to Moonlight."
                        case .skippedNotFocused:
                            pasteSummary = "Ready on the Windows clipboard; Moonlight was not focused, so Companion did not bring it forward."
                            detail += " Skipped Ctrl+V because Moonlight was not focused."
                        case .failed:
                            pasteSummary = "Ready on the Windows clipboard; paste shortcut failed."
                            detail += " Could not send Ctrl+V to Moonlight."
                        }
                    } else if pasteAfterSend && importConfirmed {
                        pasteSummary = "Copied to the Windows receive folder; Windows clipboard handoff was unavailable."
                        detail += " Skipped Ctrl+V because Windows clipboard handoff was unavailable."
                    } else if pasteAfterSend {
                        pasteSummary = "Windows import confirmation is pending; paste manually after it lands."
                        detail += " Skipped Ctrl+V because Windows import confirmation is pending."
                    }
                    self?.notifyMoonlightDropIfNeeded(source: source, title: "Files sent to Windows", body: "\(summary.notification) transferred. \(pasteSummary)")
                    if self?.settings.bool("MOONLIGHT_TRANSFER_REVEAL_WINDOWS_DIR") == true && importConfirmed {
                        self?.setBusy(true, status: "Opening Windows Folder", detail: "\(detail) Opening Windows receive result.")
                        self?.requestWindowsReceiveFolderOpen(
                            selectLatestImport: true,
                            expectedImportID: transferResult["id"],
                            selectPaths: self?.latestWindowsImportedPaths(from: transferResult) ?? []
                        ) { [weak self] succeeded, openDetail in
                            if openDetail == "cancelled" {
                                self?.clearQueuedFileDrops()
                                self?.setBusy(false, status: "Cancelled", detail: "Windows receive reveal was cancelled.", startQueuedDropsWhenIdle: false)
                                return
                            }
                            if self?.windowsReceiveRevealStateExpired(openDetail) == true {
                                self?.clearLatestWindowsReceiveState()
                            } else if succeeded {
                                var revealedResult = transferResult
                                if (Int(revealedResult["imported_paths"] ?? "") ?? 0) <= 0 {
                                    revealedResult["imported_paths"] = "1"
                                }
                                let revealConfirmation = revealedResult["confirmation"] ?? ""
                                if revealConfirmation.isEmpty || revealConfirmation == "pending" {
                                    revealedResult["confirmation"] = "windows-reveal"
                                }
                                self?.recordLatestWindowsReceiveState(revealedResult)
                            }
                            let suffix = succeeded
                                ? " \(openDetail)."
                                : " Windows receive folder open failed: \(openDetail)"
                            self?.setBusy(false, status: "Files Sent", detail: detail + suffix)
                        }
                    } else {
                        if self?.settings.bool("MOONLIGHT_TRANSFER_REVEAL_WINDOWS_DIR") == true {
                            detail += " Skipped Windows reveal because import confirmation is pending."
                        }
                        self?.setBusy(false, status: "Files Sent", detail: detail)
                    }
                } else {
                    try? FileManager.default.removeItem(at: transferResultStateURL)
                    let detail = text?.isEmpty == false ? text! : "File sender exited with status \(task.terminationStatus)."
                    self?.notifyMoonlightDropIfNeeded(source: source, title: "File transfer failed", body: detail)
                    self?.clearQueuedFileDrops()
                    self?.setBusy(false, status: "Send Failed", detail: detail, startQueuedDropsWhenIdle: false)
                    self?.showFailure("File sender exited with status \(task.terminationStatus).")
                }
            }
        }

        do {
            try task.run()
            transferProcess = task
        } catch {
            cleanupTemporaryDropURLs(cleanupURLs)
            notifyMoonlightDropIfNeeded(source: source, title: "File transfer failed", body: error.localizedDescription)
            fail(error.localizedDescription)
        }
    }

    private func cleanupTemporaryDropURLs(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func cleanupStalePromisedDropDirectories(now: Date = Date()) {
        let fm = FileManager.default
        let tempURL = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(
            at: tempURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for item in items where item.lastPathComponent.hasPrefix("moonlight-promised-drop-") {
            guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey]),
                  values.isDirectory == true else {
                continue
            }
            let referenceDate = values.contentModificationDate ?? values.creationDate
            guard let referenceDate,
                  now.timeIntervalSince(referenceDate) >= stalePromisedDropAge else {
                continue
            }
            try? fm.removeItem(at: item)
        }
    }

    private func receivePromisedFilesToWindows(_ receivers: [NSFilePromiseReceiver], source: FileDropSource) {
        guard !receivers.isEmpty else { return }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("moonlight-promised-drop-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            fail("Could not prepare promised file drop: \(error.localizedDescription)")
            return
        }

        let wasAlreadyBusy = isBusy || transferProcess != nil
        let itemText = receivers.count == 1 ? "1 promised item" : "\(receivers.count) promised items"
        if wasAlreadyBusy {
            appendQueuedDropNotice("Preparing \(itemText) from the drop; it will send after the current operation.")
        } else {
            setBusy(true, status: "Preparing Drop", detail: "Receiving \(itemText) from the source app.")
        }

        let operationQueue = OperationQueue()
        operationQueue.name = "Moonlight Companion promised file receiver"
        operationQueue.maxConcurrentOperationCount = min(max(receivers.count, 1), 4)
        let session = PromisedFileDropSession(destination: destination, operationQueue: operationQueue)
        promisedFileDropSessions.append(session)
        updateCancelTransferButtonState()
        let group = DispatchGroup()
        let lock = NSLock()
        var promisedURLs = Array<URL?>(repeating: nil, count: receivers.count)
        var errors: [String] = []

        for (index, receiver) in receivers.enumerated() {
            group.enter()
            receiver.receivePromisedFiles(
                atDestination: destination,
                options: [:],
                operationQueue: operationQueue
            ) { url, error in
                lock.lock()
                promisedURLs[index] = url
                if let error {
                    errors.append(error.localizedDescription)
                }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.promisedFileDropSessions.removeAll { $0 === session }
            self.updateCancelTransferButtonState()
            if session.cancelled {
                self.cleanupTemporaryDropURLs([destination])
                return
            }
            let urls = promisedURLs.compactMap { $0 }
            if !errors.isEmpty || urls.count != receivers.count {
                self.cleanupTemporaryDropURLs([destination])
                let detail = self.promisedFileDropFailureDetail(
                    receivedCount: urls.count,
                    expectedCount: receivers.count,
                    errors: errors
                )
                self.reportPromisedFileDropFailure(detail, source: source, wasAlreadyBusy: wasAlreadyBusy)
                return
            }
            guard !urls.isEmpty else {
                self.cleanupTemporaryDropURLs([destination])
                let detail = "The source app did not provide any promised files."
                self.reportPromisedFileDropFailure(detail, source: source, wasAlreadyBusy: wasAlreadyBusy)
                return
            }

            if !wasAlreadyBusy {
                self.setBusy(false, status: "Drop Ready", detail: FileDropReader.dropSummary(for: urls), startQueuedDropsWhenIdle: false)
            }

            if self.queueFileDropIfBusy(urls, source: source, cleanupURLs: [destination]) {
                return
            }
            self.sendFilesToWindows(urls, source: source, cleanupURLs: [destination])
        }
    }

    private func reportPromisedFileDropFailure(_ detail: String, source: FileDropSource, wasAlreadyBusy: Bool) {
        notifyMoonlightDropIfNeeded(source: source, title: "File transfer failed", body: detail)
        let stillBusy = isBusy || transferProcess != nil
        if wasAlreadyBusy && stillBusy {
            return
        }

        setBusy(false, status: "Drop Failed", detail: detail, startQueuedDropsWhenIdle: false)
        showFailure("Promised file drop failed.")
    }

    private func promisedFileDropFailureDetail(receivedCount: Int, expectedCount: Int, errors: [String]) -> String {
        let missingCount = max(expectedCount - receivedCount, 0)
        var detail = expectedCount == 1
            ? "Could not prepare the promised file from the source app."
            : "Could not prepare all \(expectedCount) promised files from the source app."
        if missingCount > 0 {
            detail += " \(missingCount) item(s) were not provided."
        }
        if let firstError = errors.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !firstError.isEmpty {
            detail += " \(firstError)"
        }
        return detail
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
        let sizeText = quickTransferSizeText(for: urls)
        let namesText = summarizedNames(itemNames)
        let detail = sizeText.map { "\(itemText) (\($0)): \(namesText)" }
            ?? "\(itemText): \(namesText)"
        let notification = sizeText.map { "\(itemText) (\($0))" } ?? itemText
        return TransferSummary(detail: detail, notification: notification)
    }

    private func quickTransferSizeText(for urls: [URL]) -> String? {
        var total: UInt64 = 0
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return nil
            }
            if isDirectory.boolValue {
                return nil
            }
            total += fileByteCount(url)
        }
        return formattedByteCount(total)
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

    private func fileByteCount(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values?.fileSize ?? 0)
    }

    private func shouldPasteAfterSend(for source: FileDropSource) -> Bool {
        switch source {
        case .moonlightSurface:
            return settings.bool("MOONLIGHT_TRANSFER_SCREEN_DROP_AUTO_PASTE")
        case .companion:
            return settings.bool("MOONLIGHT_TRANSFER_AUTO_PASTE")
        }
    }

    private enum MoonlightPasteResult {
        case pasted
        case skippedNotFocused
        case failed
    }

    private func pasteIntoMoonlight(allowActivation: Bool) -> MoonlightPasteResult {
        if !allowActivation && !moonlightIsFrontmost() {
            return .skippedNotFocused
        }

        let script: String
        if allowActivation {
            script = """
            tell application "Moonlight" to activate
            delay 0.15
            tell application "System Events"
                keystroke "v" using control down
            end tell
            """
        } else {
            script = """
            tell application "System Events"
                keystroke "v" using control down
            end tell
            """
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0 ? .pasted : .failed
        } catch {
            return .failed
        }
    }

    private func moonlightIsFrontmost() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        if app.localizedName == "Moonlight" {
            return true
        }
        return app.bundleURL?.lastPathComponent == "Moonlight.app"
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
        configuration.activates = false
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
        _ = cancelPromisedFileDrops()
        latestMacReceiveTimer?.invalidate()
        latestWindowsReceiveTimer?.invalidate()
        macFileClipboardFailureTimer?.invalidate()
        windowsFileClipboardFailureTimer?.invalidate()
        dropOverlayTimer?.invalidate()
        dropOverlayWindow?.close()
        dropStripWindow?.close()
        NSApp.terminate(nil)
    }
}

extension AppDelegate: FileDropViewDelegate {
    func fileDropViewDidReceive(_ urls: [URL], source: FileDropSource) {
        hideMoonlightDropOverlay()
        if queueFileDropIfBusy(urls, source: source) {
            return
        }
        sendFilesToWindows(urls, source: source)
    }

    func fileDropViewDidReceiveFilePromises(_ receivers: [NSFilePromiseReceiver], source: FileDropSource) {
        hideMoonlightDropOverlay()
        receivePromisedFilesToWindows(receivers, source: source)
    }
}

protocol FileDropViewDelegate: AnyObject {
    func fileDropViewDidReceive(_ urls: [URL], source: FileDropSource)
    func fileDropViewDidReceiveFilePromises(_ receivers: [NSFilePromiseReceiver], source: FileDropSource)
}

enum FileDropSource {
    case companion
    case moonlightSurface
}

enum FileDropReader {
    static let filenamesPasteboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let urlPasteboardTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL
    ]
    static let fileReferenceTextPasteboardTypes: [NSPasteboard.PasteboardType] = [
        .string,
        NSPasteboard.PasteboardType("public.text")
    ]
    static let filePromisePasteboardTypes = NSFilePromiseReceiver.readableDraggedTypes.map {
        NSPasteboard.PasteboardType($0)
    }
    static let readablePasteboardTypes = urlPasteboardTypes + fileReferenceTextPasteboardTypes + [filenamesPasteboardType] + filePromisePasteboardTypes

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []

        if let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) {
            urls.append(contentsOf: objects.compactMap { url(from: $0) })
        }

        if let items = pasteboard.pasteboardItems {
            urls.append(contentsOf: items.flatMap { item -> [URL] in
                for type in urlPasteboardTypes {
                    guard let value = item.string(forType: type),
                          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }
                    return fileURLs(fromPasteboardString: value, requireEveryLineToBeFile: false)
                }
                for type in fileReferenceTextPasteboardTypes {
                    guard let value = item.string(forType: type),
                          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }
                    return fileURLs(fromPasteboardString: value, requireEveryLineToBeFile: true)
                }
                return []
            })
        }

        urls.append(contentsOf: urlPasteboardTypes.flatMap { type -> [URL] in
            guard let value = pasteboard.string(forType: type) else {
                return []
            }
            return fileURLs(fromPasteboardString: value, requireEveryLineToBeFile: false)
        })

        urls.append(contentsOf: fileReferenceTextPasteboardTypes.flatMap { type -> [URL] in
            guard let value = pasteboard.string(forType: type) else {
                return []
            }
            return fileURLs(fromPasteboardString: value, requireEveryLineToBeFile: true)
        })

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

    private static func fileURLs(fromPasteboardString value: String, requireEveryLineToBeFile: Bool) -> [URL] {
        var urls: [URL] = []
        for part in value.split(whereSeparator: \.isNewline) {
            let line = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            if requireEveryLineToBeFile && (line.isEmpty || line.hasPrefix("#")) {
                continue
            }
            guard let url = fileURL(fromSinglePasteboardString: line) else {
                if requireEveryLineToBeFile {
                    return []
                }
                continue
            }
            if requireEveryLineToBeFile {
                guard plainTextFileReferenceIsUsable(url) else {
                    return []
                }
            }
            urls.append(url)
        }
        return urls
    }

    private static func plainTextFileReferenceIsUsable(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              FileManager.default.isReadableFile(atPath: path) else {
            return false
        }
        return !isDirectory.boolValue || FileManager.default.isExecutableFile(atPath: path)
    }

    private static func fileURL(fromSinglePasteboardString value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsedURL = URL(string: trimmed), parsedURL.isFileURL {
            return parsedURL
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        return nil
    }

    static func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        fileURLs(from: sender.draggingPasteboard)
    }

    static func filePromiseReceivers(from pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver] ?? []
    }

    static func hasFileDropContent(from pasteboard: NSPasteboard) -> Bool {
        if !fileURLs(from: pasteboard).isEmpty {
            return true
        }
        return !filePromiseReceivers(from: pasteboard).isEmpty
    }

    static func filePromiseReceivers(from sender: NSDraggingInfo) -> [NSFilePromiseReceiver] {
        filePromiseReceivers(from: sender.draggingPasteboard)
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

    static func dropSummary(forPromisedFileCount count: Int) -> String {
        count == 1 ? "1 promised item" : "\(count) promised items"
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
        registerForDraggedTypes(FileDropReader.readablePasteboardTypes)

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
        if !urls.isEmpty {
            setActiveDropURLs([])
            delegate?.fileDropViewDidReceive(urls, source: .moonlightSurface)
            return true
        }

        let receivers = FileDropReader.filePromiseReceivers(from: sender)
        guard !receivers.isEmpty else { return false }
        setActiveDropURLs([])
        delegate?.fileDropViewDidReceiveFilePromises(receivers, source: .moonlightSurface)
        return true
    }

    private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let urls = FileDropReader.fileURLs(from: sender)
        if !urls.isEmpty {
            setActiveDropURLs(urls)
            return .copy
        }

        let receivers = FileDropReader.filePromiseReceivers(from: sender)
        setActiveDropURLs([], promisedFileCount: receivers.count)
        return receivers.isEmpty ? [] : .copy
    }

    private func setActiveDropURLs(_ urls: [URL], promisedFileCount: Int = 0) {
        if urls.isEmpty && promisedFileCount == 0 {
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.10).cgColor
            layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.70).cgColor
            titleLabel.stringValue = defaultTitle
            detailLabel.stringValue = defaultDetail
        } else {
            layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.18).cgColor
            layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.85).cgColor
            titleLabel.stringValue = defaultTitle
            detailLabel.stringValue = urls.isEmpty
                ? FileDropReader.dropSummary(forPromisedFileCount: promisedFileCount)
                : FileDropReader.dropSummary(for: urls)
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
        registerForDraggedTypes(FileDropReader.readablePasteboardTypes)
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
        if !urls.isEmpty {
            setActiveDropURLs([])
            delegate?.fileDropViewDidReceive(urls, source: source)
            return true
        }

        let receivers = FileDropReader.filePromiseReceivers(from: sender)
        guard !receivers.isEmpty else { return false }
        setActiveDropURLs([])
        delegate?.fileDropViewDidReceiveFilePromises(receivers, source: source)
        return true
    }

    private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(from: sender)
        if !urls.isEmpty {
            setActiveDropURLs(urls)
            return .copy
        }

        let receivers = FileDropReader.filePromiseReceivers(from: sender)
        setActiveDropURLs([], promisedFileCount: receivers.count)
        return receivers.isEmpty ? [] : .copy
    }

    private func setActiveDropURLs(_ urls: [URL], promisedFileCount: Int = 0) {
        if urls.isEmpty && promisedFileCount == 0 {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            titleLabel.stringValue = defaultTitle
            detailLabel.stringValue = defaultDetail
            detailLabel.textColor = .secondaryLabelColor
        } else {
            layer?.borderColor = NSColor.systemGreen.cgColor
            layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.12).cgColor
            titleLabel.stringValue = "Drop to Windows"
            detailLabel.stringValue = urls.isEmpty
                ? FileDropReader.dropSummary(forPromisedFileCount: promisedFileCount)
                : FileDropReader.dropSummary(for: urls)
            detailLabel.textColor = .labelColor
        }
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        FileDropReader.fileURLs(from: sender)
    }
}

private func runFileDropReaderSelfTest() -> Int32 {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("moonlight-file-drop-reader-\(UUID().uuidString)", isDirectory: true)
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let first = root.appendingPathComponent("first file.txt")
        let second = root.appendingPathComponent("second file.txt")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)

        func withPasteboard(_ body: (NSPasteboard) -> Void) -> NSPasteboard {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("moonlight-file-drop-reader-\(UUID().uuidString)"))
            pasteboard.clearContents()
            body(pasteboard)
            return pasteboard
        }

        func paths(from pasteboard: NSPasteboard) -> [String] {
            FileDropReader.fileURLs(from: pasteboard).map { $0.standardizedFileURL.path }
        }

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() {
                throw NSError(domain: "MoonlightFileDropReaderSelfTest", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: message
                ])
            }
        }

        let urlListPasteboard = withPasteboard { pasteboard in
            pasteboard.setString(
                [first.absoluteString, second.absoluteString].joined(separator: "\n"),
                forType: .URL
            )
        }
        try expect(paths(from: urlListPasteboard) == [first.path, second.path], "public.url list was not parsed as two file URLs")
        urlListPasteboard.releaseGlobally()

        let plainTextPasteboard = withPasteboard { pasteboard in
            pasteboard.setString(
                "# Moonlight Companion self-test\r\n\(first.absoluteString)\r\n\(second.path)\r\n",
                forType: .string
            )
        }
        try expect(paths(from: plainTextPasteboard) == [first.path, second.path], "plain-text file reference list was not parsed as two file URLs")
        plainTextPasteboard.releaseGlobally()

        let plainTextItemPasteboard = withPasteboard { pasteboard in
            let item = NSPasteboardItem()
            item.setString(first.absoluteString, forType: .string)
            pasteboard.writeObjects([item])
        }
        try expect(paths(from: plainTextItemPasteboard) == [first.path], "item-level plain-text file URL was not parsed")
        plainTextItemPasteboard.releaseGlobally()

        let legacyPasteboard = withPasteboard { pasteboard in
            pasteboard.setPropertyList(
                [first.path, second.path, first.path],
                forType: FileDropReader.filenamesPasteboardType
            )
        }
        try expect(paths(from: legacyPasteboard) == [first.path, second.path], "legacy filename pasteboard list was not deduplicated")
        legacyPasteboard.releaseGlobally()

        let mixedTextPasteboard = withPasteboard { pasteboard in
            pasteboard.setString("\(first.absoluteString)\nhttps://example.invalid/not-a-file", forType: .string)
        }
        try expect(!FileDropReader.hasFileDropContent(from: mixedTextPasteboard), "mixed plain text was treated as a file drop")
        mixedTextPasteboard.releaseGlobally()

        let missingTextPasteboard = withPasteboard { pasteboard in
            pasteboard.setString("\(first.absoluteString)\n\(root.appendingPathComponent("missing.txt").path)", forType: .string)
        }
        try expect(!FileDropReader.hasFileDropContent(from: missingTextPasteboard), "missing plain-text path was treated as a file drop")
        missingTextPasteboard.releaseGlobally()

        let unreadable = root.appendingPathComponent("unreadable.txt")
        try "unreadable".write(to: unreadable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        let unreadableTextPasteboard = withPasteboard { pasteboard in
            pasteboard.setString(unreadable.path, forType: .string)
        }
        try expect(!FileDropReader.hasFileDropContent(from: unreadableTextPasteboard), "unreadable plain-text path was treated as a file drop")
        unreadableTextPasteboard.releaseGlobally()

        print("file-drop-reader self-test ok")
        return 0
    } catch {
        fputs("file-drop-reader self-test failed: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

if CommandLine.arguments.contains("--self-test-file-drop-reader") {
    exit(runFileDropReaderSelfTest())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
