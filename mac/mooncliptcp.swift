import CryptoKit
import Darwin
import Foundation

enum ClipTcpError: Error, CustomStringConvertible {
    case usage
    case invalidPort
    case unsupportedHost(String)
    case socket(String)
    case protocolError(String)
    case payloadTooLarge(UInt64, UInt64)
    case commandFailed(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: mooncliptcp send <host> <port> <zip-path> | listen <host> <port> <runtime-dir> <helper> <max-bytes> <log-path>"
        case .invalidPort:
            return "invalid-port"
        case .unsupportedHost(let host):
            return "unsupported-host: \(host)"
        case .socket(let message):
            return "socket-error: \(message)"
        case .protocolError(let message):
            return "protocol-error: \(message)"
        case .payloadTooLarge(let size, let max):
            return "payload-too-large: \(size) > \(max)"
        case .commandFailed(let message):
            return "command-failed: \(message)"
        }
    }
}

let fm = FileManager.default

func parsePort(_ value: String) throws -> UInt16 {
    guard let port = UInt16(value), port > 0 else {
        throw ClipTcpError.invalidPort
    }
    return port
}

func log(_ message: String, to path: String?) {
    guard let path else { return }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(formatter.string(from: Date())) \(message)\n"
    if let data = line.data(using: .utf8) {
        if fm.fileExists(atPath: path), let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
            } catch {
                return
            }
            try? handle.write(contentsOf: data)
        } else {
            try? fm.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func sha256Hex(file path: String) throws -> String {
    try sha256Hex(Data(contentsOf: URL(fileURLWithPath: path)))
}

func makeSocket() throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 {
        throw ClipTcpError.socket("socket failed")
    }

    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

func sockaddr(host: String, port: UInt16) throws -> sockaddr_in {
    guard host == "127.0.0.1" || host == "localhost" else {
        throw ClipTcpError.unsupportedHost(host)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
    return address
}

func connectSocket(host: String, port: UInt16) throws -> Int32 {
    let fd = try makeSocket()
    var address = try sockaddr(host: host, port: port)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }

    if result != 0 {
        Darwin.close(fd)
        throw ClipTcpError.socket("connect failed")
    }

    return fd
}

func bindSocket(host: String, port: UInt16) throws -> Int32 {
    let fd = try makeSocket()
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var address = try sockaddr(host: host, port: port)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }

    if result != 0 {
        Darwin.close(fd)
        throw ClipTcpError.socket("bind failed")
    }

    if Darwin.listen(fd, 16) != 0 {
        Darwin.close(fd)
        throw ClipTcpError.socket("listen failed")
    }

    return fd
}

func writeAll(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var sent = 0
        while sent < rawBuffer.count {
            let count = Darwin.write(fd, baseAddress.advanced(by: sent), rawBuffer.count - sent)
            if count <= 0 {
                throw ClipTcpError.socket("write failed")
            }
            sent += count
        }
    }
}

func readLine(fd: Int32, maxBytes: Int = 256) throws -> String {
    var bytes: [UInt8] = []
    while bytes.count < maxBytes {
        var byte: UInt8 = 0
        let count = Darwin.read(fd, &byte, 1)
        if count <= 0 {
            throw ClipTcpError.protocolError("unexpected eof")
        }
        if byte == 10 {
            break
        }
        bytes.append(byte)
    }

    guard let line = String(bytes: bytes, encoding: .utf8) else {
        throw ClipTcpError.protocolError("header is not utf8")
    }
    return line
}

func setReceiveTimeout(fd: Int32, milliseconds: Int) {
    var timeout = timeval(
        tv_sec: milliseconds / 1000,
        tv_usec: Int32((milliseconds % 1000) * 1000)
    )
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

func readOptionalLine(fd: Int32, maxBytes: Int = 512) throws -> String? {
    var bytes: [UInt8] = []
    while bytes.count < maxBytes {
        var byte: UInt8 = 0
        let count = Darwin.read(fd, &byte, 1)
        if count == 0 {
            return bytes.isEmpty ? nil : String(bytes: bytes, encoding: .utf8)
        }
        if count < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                return nil
            }
            throw ClipTcpError.socket("read failed")
        }
        if byte == 10 {
            guard let line = String(bytes: bytes, encoding: .utf8) else {
                throw ClipTcpError.protocolError("response is not utf8")
            }
            return line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }
        bytes.append(byte)
    }
    throw ClipTcpError.protocolError("response line too long")
}

func parseAckLine(_ line: String) -> [String: String]? {
    let parts = line.split(separator: " ")
    guard parts.count >= 2, parts[0] == "MOONCLIPACK", parts[1] == "1" else {
        return nil
    }

    var result: [String: String] = [:]
    for part in parts.dropFirst(2) {
        let fields = part.split(separator: "=", maxSplits: 1)
        if fields.count == 2 {
            result[String(fields[0])] = String(fields[1])
        }
    }
    return result
}

func readPayload(fd: Int32, byteCount: UInt64, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try? fm.removeItem(at: url)
    fm.createFile(atPath: path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }

    var remaining = byteCount
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while remaining > 0 {
        let wanted = min(buffer.count, Int(remaining))
        let count = Darwin.read(fd, &buffer, wanted)
        if count <= 0 {
            throw ClipTcpError.protocolError("payload ended early")
        }
        try handle.write(contentsOf: Data(buffer.prefix(count)))
        remaining -= UInt64(count)
    }
}

func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw ClipTcpError.commandFailed(err.isEmpty ? out : err)
    }
    return out
}

func parseMeta(_ output: String) -> [String: String] {
    var result: [String: String] = [:]
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1)
        if parts.count == 2 {
            result[String(parts[0])] = String(parts[1])
        }
    }
    return result
}

func boolEnv(_ key: String, defaultValue: Bool) -> Bool {
    guard let value = ProcessInfo.processInfo.environment[key] else {
        return defaultValue
    }
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "y", "yes", "true", "on":
        return true
    default:
        return false
    }
}

func importedFilePaths(_ imported: [String: String]) -> [String] {
    let count = Int(imported["file_paths"] ?? "") ?? 0
    guard count > 0 else {
        return []
    }
    return (1...count).compactMap { index in
        let rawPath = imported["file_path_\(index)"] ?? ""
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : NSString(string: trimmed).expandingTildeInPath
    }
}

func importedFileNames(_ imported: [String: String]) -> [String] {
    let count = Int(imported["file_paths"] ?? "") ?? 0
    guard count > 0 else {
        return []
    }

    return (1...count).compactMap { index in
        if let rawName = imported["file_name_\(index)"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawName.isEmpty {
            return rawName.precomposedStringWithCanonicalMapping
        }
        let rawPath = imported["file_path_\(index)"] ?? ""
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        return name.isEmpty ? "file" : name.precomposedStringWithCanonicalMapping
    }
}

func summarizedNames(_ names: [String]) -> String {
    guard !names.isEmpty else {
        return "files"
    }

    let visible = names.prefix(2).joined(separator: ", ")
    let remaining = names.count - min(names.count, 2)
    if remaining > 0 {
        return "\(visible), +\(remaining) more"
    }
    return visible
}

func formattedByteCount(_ value: String?) -> String {
    let bytes = UInt64(value ?? "") ?? 0
    if bytes == 0 {
        return "0 bytes"
    }
    let capped = min(bytes, UInt64(Int64.max))
    return ByteCountFormatter.string(fromByteCount: Int64(capped), countStyle: .file)
}

func receivedFileDetail(_ imported: [String: String]) -> String {
    let rawCount = Int(imported["files"] ?? "") ?? 0
    let itemText = rawCount == 1 ? "1 item" : "\(max(rawCount, 1)) items"
    let sizeText = formattedByteCount(imported["bytes"])
    let namesText = summarizedNames(importedFileNames(imported))
    return "\(itemText) (\(sizeText)): \(namesText)"
}

func revealReceivedFiles(_ imported: [String: String]) {
    let paths = importedFilePaths(imported)
    if !paths.isEmpty {
        if (try? run("/usr/bin/open", ["-R"] + paths)) != nil {
            return
        }
    }

    if let directory = ProcessInfo.processInfo.environment["MOONLIGHT_TRANSFER_MAC_DIR"],
       !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        _ = try? run("/usr/bin/open", [NSString(string: directory).expandingTildeInPath])
    }
}

func notifyWindowsFilesReceived(_ imported: [String: String]) {
    guard imported["kind"] == "files" else {
        return
    }

    let detail = receivedFileDetail(imported)
    let revealEnabled = boolEnv("MOONLIGHT_TRANSFER_REVEAL_MAC_DIR", defaultValue: true)

    if boolEnv("MOONLIGHT_TRANSFER_NOTIFY", defaultValue: true) {
        let body = revealEnabled
            ? "Received \(detail) from Windows. Finder will reveal the new file(s). They are also on the Mac clipboard."
            : "Received \(detail) from Windows. Paste in Finder or open the Mac receive folder."
        let script = """
        on run argv
            display notification (item 1 of argv) with title "Moonlight Companion" subtitle "Files received from Windows"
        end run
        """
        _ = try? run("/usr/bin/osascript", ["-e", script, body])
    }

    if revealEnabled {
        revealReceivedFiles(imported)
    }
}

func cleanDirectory(_ path: String) throws {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    if fm.fileExists(atPath: path) {
        try fm.removeItem(at: url)
    }
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
}

func writeState(path: String, values: [String: String]) throws {
    let tmp = "\(path).tmp"
    let text = values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "\n") + "\n"
    try text.write(toFile: tmp, atomically: true, encoding: .utf8)
    if fm.fileExists(atPath: path) {
        try fm.removeItem(atPath: path)
    }
    try fm.moveItem(atPath: tmp, toPath: path)
}

func receiveOne(fd: Int32, runtimeDir: String, helper: String, maxBytes: UInt64, logPath: String) throws {
    let header = try readLine(fd: fd)
    let parts = header.split(separator: " ")
    guard parts.count == 3, parts[0] == "MOONCLIP", parts[1] == "1", let byteCount = UInt64(parts[2]) else {
        throw ClipTcpError.protocolError("invalid header")
    }
    if byteCount > maxBytes {
        throw ClipTcpError.payloadTooLarge(byteCount, maxBytes)
    }

    try fm.createDirectory(atPath: runtimeDir, withIntermediateDirectories: true)
    let zipPath = "\(runtimeDir)/windows-to-mac.tcp.zip"
    let payloadDir = "\(runtimeDir)/imported-windows-payload"
    let normalizedDir = "\(runtimeDir)/mac-normalized-payload"
    let statePath = "\(runtimeDir)/clipboard-tcp-windows-state.txt"
    let receiveLockPath = "\(statePath).lock"

    try? "receiving\n".write(toFile: receiveLockPath, atomically: true, encoding: .utf8)
    defer {
        try? fm.removeItem(atPath: receiveLockPath)
    }

    try readPayload(fd: fd, byteCount: byteCount, to: zipPath)
    let archiveHash = try sha256Hex(file: zipPath)
    try cleanDirectory(payloadDir)
    _ = try run("/usr/bin/ditto", ["-x", "-k", "--noqtn", zipPath, payloadDir])

    let imported = parseMeta(try run(helper, ["import", payloadDir]))
    let winID = imported["id"] ?? ""
    try? cleanDirectory(normalizedDir)
    let normalizedOutput = try? run(helper, ["export", normalizedDir])
    let normalized = normalizedOutput.map(parseMeta) ?? [:]

    let normalizedID = normalized["id"] ?? winID
    try writeState(path: statePath, values: [
        "archive_hash": archiveHash,
        "bytes": imported["bytes"] ?? "",
        "kind": imported["kind"] ?? "",
        "normalized_id": normalizedID,
        "windows_id": winID
    ])
    notifyWindowsFilesReceived(imported)
    if imported["kind"] == "files" {
        log("Windows -> Mac TCP files \(receivedFileDetail(imported))", to: logPath)
    } else {
        log("Windows -> Mac TCP \(imported["kind"] ?? "payload") (\(imported["bytes"] ?? "0")B)", to: logPath)
    }
}

func sendPayload(host: String, port: UInt16, zipPath: String) throws -> [String: String]? {
    let data = try Data(contentsOf: URL(fileURLWithPath: zipPath))
    let fd = try connectSocket(host: host, port: port)
    defer { Darwin.close(fd) }

    let header = "MOONCLIP 1 \(data.count)\n"
    try writeAll(fd: fd, data: Data(header.utf8))
    try writeAll(fd: fd, data: data)

    setReceiveTimeout(fd: fd, milliseconds: 8_000)
    guard let ackLine = try readOptionalLine(fd: fd) else {
        return nil
    }
    return parseAckLine(ackLine)
}

func listen(host: String, port: UInt16, runtimeDir: String, helper: String, maxBytes: UInt64, logPath: String) throws {
    let server = try bindSocket(host: host, port: port)
    defer { Darwin.close(server) }
    log("clipboard TCP receiver listening on \(host):\(port)", to: logPath)

    while true {
        let client = Darwin.accept(server, nil, nil)
        if client < 0 {
            continue
        }

        do {
            try receiveOne(fd: client, runtimeDir: runtimeDir, helper: helper, maxBytes: maxBytes, logPath: logPath)
        } catch ClipTcpError.protocolError(let message) where message == "unexpected eof" {
        } catch {
            log("clipboard TCP receive error: \(error)", to: logPath)
        }
        Darwin.close(client)
    }
}

do {
    guard CommandLine.arguments.count >= 2 else { throw ClipTcpError.usage }
    let command = CommandLine.arguments[1]
    switch command {
    case "send":
        guard CommandLine.arguments.count == 5 else { throw ClipTcpError.usage }
        if let ack = try sendPayload(
            host: CommandLine.arguments[2],
            port: try parsePort(CommandLine.arguments[3]),
            zipPath: CommandLine.arguments[4]) {
            for key in ["id", "kind", "bytes", "files", "imported_paths"] {
                if let value = ack[key] {
                    print("\(key)=\(value)")
                }
            }
        }
    case "listen":
        guard CommandLine.arguments.count == 8 else { throw ClipTcpError.usage }
        try listen(
            host: CommandLine.arguments[2],
            port: try parsePort(CommandLine.arguments[3]),
            runtimeDir: CommandLine.arguments[4],
            helper: CommandLine.arguments[5],
            maxBytes: UInt64(CommandLine.arguments[6]) ?? 52_428_800,
            logPath: CommandLine.arguments[7])
    default:
        throw ClipTcpError.usage
    }
} catch let error as ClipTcpError {
    fputs("\(error.description)\n", stderr)
    exit(1)
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
