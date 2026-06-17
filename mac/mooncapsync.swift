import AppKit
import ApplicationServices
import Darwin
import Foundation

let capsLockKeyCode: Int64 = 57
let moonlightBundleIdentifier = "com.moonlight-stream.Moonlight"
let tcpHost = ProcessInfo.processInfo.environment["MOONLIGHT_CAPSLOCK_HANGUL_HOST"] ?? "127.0.0.1"
let tcpPort = UInt16(ProcessInfo.processInfo.environment["MOONLIGHT_CAPSLOCK_HANGUL_PORT"] ?? "") ?? 47321
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
        toggleSender.sendToggle()
    }

    return nil
}

func requestInputPermissionsIfNeeded() {
    let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
    let accessibilityTrusted = AXIsProcessTrusted()
    let inputMonitoringTrusted = CGPreflightListenEventAccess()
    log("permission state: bundle=\(bundleID) accessibility=\(accessibilityTrusted) inputMonitoring=\(inputMonitoringTrusted)")

    let accessibilityOptions = [
        kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true
    ] as CFDictionary

    if !AXIsProcessTrustedWithOptions(accessibilityOptions) {
        log("Accessibility permission is required for Caps Lock Hangul sync.")
    }

    if !inputMonitoringTrusted {
        log("Input Monitoring permission is required for Caps Lock Hangul sync.")
        _ = CGRequestListenEventAccess()
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
senderQueue.async {
    toggleSender.connectIfNeeded()
}
CFRunLoopRun()
