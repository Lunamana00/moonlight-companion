import AppKit
import ApplicationServices
import Darwin
import Foundation

let capsLockKeyCode: Int64 = 57
let moonlightBundleIdentifier = "com.moonlight-stream.Moonlight"
let tcpHost = ProcessInfo.processInfo.environment["MOONLIGHT_CAPSLOCK_HANGUL_HOST"] ?? "127.0.0.1"
let tcpPort = UInt16(ProcessInfo.processInfo.environment["MOONLIGHT_CAPSLOCK_HANGUL_PORT"] ?? "") ?? 47321
let capsLockHangulEnabled = normalizeYesNo(ProcessInfo.processInfo.environment["MOONLIGHT_CAPSLOCK_HANGUL"] ?? "yes")
let shortcutRemapEnabled = normalizeYesNo(ProcessInfo.processInfo.environment["MOONLIGHT_SHORTCUT_REMAP"] ?? "yes")
let debounceSeconds = 0.25
let senderQueue = DispatchQueue(label: "com.lunamana.moonlight-capslock-hangul.sender")
let syntheticSource = CGEventSource(stateID: .hidSystemState)

var lastCapsLockEvent = Date.distantPast
var suppressedShortcutKeyUps = Set<Int64>()

func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    FileHandle.standardError.write(Data("\(formatter.string(from: Date())) \(message)\n".utf8))
}

func normalizeYesNo(_ value: String) -> Bool {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "y", "yes", "true", "on":
        return true
    default:
        return false
    }
}

func isMoonlightFrontmost() -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication else {
        return false
    }

    return app.bundleIdentifier == moonlightBundleIdentifier || app.localizedName == "Moonlight"
}

let commandToControlKeyNames: [Int64: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
    11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
    20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
    29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
    39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
    48: "Tab", 50: "`", 51: "Delete"
]

func commandToControlKeyName(_ keyCode: Int64) -> String? {
    commandToControlKeyNames[keyCode]
}

func remappedShortcutFlags(from flags: CGEventFlags) -> CGEventFlags {
    var nextFlags = flags
    nextFlags.remove(.maskCommand)
    nextFlags.insert(.maskControl)
    return nextFlags
}

func sendControlShortcut(keyCode: Int64, flags: CGEventFlags) {
    let nextFlags = remappedShortcutFlags(from: flags)
    guard let down = CGEvent(keyboardEventSource: syntheticSource, virtualKey: CGKeyCode(keyCode), keyDown: true),
          let up = CGEvent(keyboardEventSource: syntheticSource, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
        log("failed to synthesize shortcut for keyCode=\(keyCode)")
        return
    }

    down.flags = nextFlags
    up.flags = nextFlags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)

    if let name = commandToControlKeyName(keyCode) {
        log("remapped Command+\(name) to Control+\(name)")
    }
}

final class CapsLockTcpSender {
    private let host: String
    private let port: UInt16
    private var socketFD: Int32 = -1

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    deinit {
        closeSocket()
    }

    @discardableResult
    func connectIfNeeded() -> Bool {
        if socketFD >= 0 {
            return true
        }

        guard host == "127.0.0.1" || host == "localhost" else {
            log("Caps Lock Hangul TCP unsupported host: \(host)")
            return false
        }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            log("Caps Lock Hangul TCP socket failed")
            return false
        }

        var noDelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if connected != 0 {
            Darwin.close(fd)
            log("Caps Lock Hangul TCP connect failed on 127.0.0.1:\(port)")
            return false
        }

        socketFD = fd
        log("Caps Lock Hangul TCP connected to 127.0.0.1:\(port)")
        return true
    }

    @discardableResult
    func sendToggle() -> Bool {
        if sendToggleOnce() {
            return true
        }

        closeSocket()
        if connectIfNeeded(), sendToggleOnce() {
            return true
        }

        log("Caps Lock Hangul TCP toggle request failed")
        return false
    }

    private func sendToggleOnce() -> Bool {
        guard connectIfNeeded() else {
            return false
        }

        let bytes = Array("toggle\n".utf8)
        let sent = bytes.withUnsafeBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else {
                return -1
            }

            return Darwin.send(socketFD, baseAddress, rawBuffer.count, 0)
        }

        if sent == bytes.count {
            log("sent Caps Lock Hangul toggle request via TCP")
            return true
        }

        return false
    }

    private func closeSocket() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
    }
}

let toggleSender = CapsLockTcpSender(host: tcpHost, port: tcpPort)

if CommandLine.arguments.contains("--send-once") {
    exit(toggleSender.sendToggle() ? 0 : 1)
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

    if type == .keyUp, suppressedShortcutKeyUps.remove(keyCode) != nil {
        return nil
    }

    guard isMoonlightFrontmost() else {
        return Unmanaged.passUnretained(event)
    }

    if type == .flagsChanged, capsLockHangulEnabled, keyCode == capsLockKeyCode {
        let now = Date()
        if now.timeIntervalSince(lastCapsLockEvent) < debounceSeconds {
            return nil
        }
        lastCapsLockEvent = now

        senderQueue.async {
            toggleSender.sendToggle()
        }

        return nil
    }

    if type == .keyDown, shortcutRemapEnabled, commandToControlKeyName(keyCode) != nil {
        let flags = event.flags
        if flags.contains(.maskCommand), !flags.contains(.maskControl) {
            suppressedShortcutKeyUps.insert(keyCode)
            sendControlShortcut(keyCode: keyCode, flags: flags)
            return nil
        }
    }

    return Unmanaged.passUnretained(event)
}

func requestInputPermissionsIfNeeded() {
    let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
    let accessibilityTrusted = AXIsProcessTrusted()
    log("permission state: bundle=\(bundleID) accessibility=\(accessibilityTrusted)")

    let accessibilityOptions = [
        kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true
    ] as CFDictionary

    if !AXIsProcessTrustedWithOptions(accessibilityOptions) {
        log("Accessibility permission is required for Caps Lock Hangul sync.")
    }

}

if CommandLine.arguments.contains("--request-permissions") {
    requestInputPermissionsIfNeeded()
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    exit(0)
}

requestInputPermissionsIfNeeded()

guard let eventTap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue) |
        CGEventMask(1 << CGEventType.keyDown.rawValue) |
        CGEventMask(1 << CGEventType.keyUp.rawValue),
    callback: callback,
    userInfo: nil
) else {
    log("failed to create Caps Lock event tap")
    log("grant Accessibility permission, then restart Moonlight Companion")
    exit(1)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: eventTap, enable: true)

log("Moonlight keyboard sync started; capsLockHangul=\(capsLockHangulEnabled), shortcutRemap=\(shortcutRemapEnabled)")
if capsLockHangulEnabled {
    senderQueue.async {
        toggleSender.connectIfNeeded()
    }
}
CFRunLoopRun()
