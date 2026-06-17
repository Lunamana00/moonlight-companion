import AppKit
import ApplicationServices
import Foundation

let capsLockKeyCode: Int64 = 57
let moonlightBundleIdentifier = "com.moonlight-stream.Moonlight"
let remote = ProcessInfo.processInfo.environment["WINDOWS_SSH"] ?? "moonlight-windows"
let debounceSeconds = 0.25
let senderQueue = DispatchQueue(label: "com.lunamana.moonlight-capslock-hangul.sender")

var lastCapsLockEvent = Date.distantPast

func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    FileHandle.standardError.write(Data("\(formatter.string(from: Date())) \(message)\n".utf8))
}

func isMoonlightFrontmost() -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication else {
        return false
    }

    return app.bundleIdentifier == moonlightBundleIdentifier || app.localizedName == "Moonlight"
}

func base64EncodedPowerShell(_ script: String) -> String {
    var data = Data()
    for unit in script.utf16 {
        data.append(UInt8(unit & 0x00ff))
        data.append(UInt8(unit >> 8))
    }
    return data.base64EncodedString()
}

func quotedPowerShellString(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "''"))'"
}

func sendToggleRequest() {
    let requestID = "\(Date().timeIntervalSince1970)-\(UUID().uuidString)"
    let requestValue = quotedPowerShellString(requestID)
    let script = """
    $ErrorActionPreference = 'Stop'
    $dir = Join-Path $env:USERPROFILE '.moonlight-clipboard-sync'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $tmp = Join-Path $dir 'capslock-hangul-toggle.request.tmp'
    $request = Join-Path $dir 'capslock-hangul-toggle.request'
    Set-Content -LiteralPath $tmp -Value \(requestValue) -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $request -Force
    """

    let encoded = base64EncodedPowerShell(script)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    task.arguments = [
        "-q",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=2",
        "-o", "LogLevel=ERROR",
        "-o", "StrictHostKeyChecking=accept-new",
        remote,
        "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand \(encoded)"
    ]

    do {
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus == 0 {
            log("sent Caps Lock Hangul toggle request")
        } else {
            log("Caps Lock Hangul toggle request failed with status \(task.terminationStatus)")
        }
    } catch {
        log("Caps Lock Hangul toggle request failed: \(error.localizedDescription)")
    }
}

if CommandLine.arguments.contains("--send-once") {
    sendToggleRequest()
    exit(0)
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    guard type == .flagsChanged else {
        return Unmanaged.passUnretained(event)
    }

    guard event.getIntegerValueField(.keyboardEventKeycode) == capsLockKeyCode else {
        return Unmanaged.passUnretained(event)
    }

    guard isMoonlightFrontmost() else {
        return Unmanaged.passUnretained(event)
    }

    let now = Date()
    if now.timeIntervalSince(lastCapsLockEvent) < debounceSeconds {
        return nil
    }
    lastCapsLockEvent = now

    senderQueue.async {
        sendToggleRequest()
    }

    return nil
}

func requestInputPermissionsIfNeeded() {
    let accessibilityOptions = [
        kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true
    ] as CFDictionary

    if !AXIsProcessTrustedWithOptions(accessibilityOptions) {
        log("Accessibility permission is required for Caps Lock Hangul sync.")
    }

    if !CGPreflightListenEventAccess() {
        log("Input Monitoring permission is required for Caps Lock Hangul sync.")
        _ = CGRequestListenEventAccess()
    }
}

requestInputPermissionsIfNeeded()

guard let eventTap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
    callback: callback,
    userInfo: nil
) else {
    log("failed to create Caps Lock event tap")
    log("grant Accessibility/Input Monitoring permission, then restart Moonlight Companion")
    exit(1)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: eventTap, enable: true)

log("Caps Lock Hangul sync started")
CFRunLoopRun()
