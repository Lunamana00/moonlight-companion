import AppKit
import CryptoKit
import Foundation

struct Manifest: Codable {
    struct Item: Codable {
        let name: String
        let path: String
        let isDirectory: Bool
        let bytes: UInt64
    }

    let version: Int
    let origin: String
    let kind: String
    let id: String
    let bytes: UInt64
    let textFile: String?
    let imageFile: String?
    let files: [Item]?
}

struct ImportResult {
    let manifest: Manifest
    let fileURLs: [URL]
}

enum ClipError: Error, CustomStringConvertible {
    case usage
    case unsupported
    case missingManifest
    case invalidManifest
    case importFailed(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: moonclipctl export|import|info <payload-dir> | export-paths|set-files <payload-dir> <path>..."
        case .unsupported:
            return "unsupported-or-empty-clipboard"
        case .missingManifest:
            return "missing-manifest"
        case .invalidManifest:
            return "invalid-manifest"
        case .importFailed(let message):
            return "import-failed: \(message)"
        }
    }
}

let fm = FileManager.default
let filenamesPasteboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

func sha256Hex(_ data: Data) -> String {
    hexString(SHA256.hash(data: data))
}

func sha256Hex(_ string: String) -> String {
    sha256Hex(Data(string.utf8))
}

func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func ensureCleanDirectory(_ url: URL) throws {
    if fm.fileExists(atPath: url.path) {
        try fm.removeItem(at: url)
    }
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
}

func writeJSON(_ manifest: Manifest, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(manifest)
    try data.write(to: url)
}

func readManifest(from dir: URL) throws -> Manifest {
    let url = dir.appendingPathComponent("manifest.json")
    guard fm.fileExists(atPath: url.path) else {
        throw ClipError.missingManifest
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(Manifest.self, from: data)
}

func fileBytes(_ url: URL) -> UInt64 {
    guard let attrs = try? fm.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? NSNumber else {
        return 0
    }
    return size.uint64Value
}

func directoryBytes(_ url: URL) -> UInt64 {
    var total: UInt64 = 0
    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
        for case let item as URL in enumerator {
            if let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true {
                total += UInt64(values.fileSize ?? 0)
            }
        }
    }
    return total
}

func windowsSafeFileName(_ name: String) -> String {
    let originalName = name.isEmpty ? "file" : name
    let normalizedName = originalName.precomposedStringWithCanonicalMapping
    let invalidScalars = CharacterSet(charactersIn: #"<>:"/\|?*"#).union(.controlCharacters)
    var safeName = normalizedName.unicodeScalars.map { scalar in
        invalidScalars.contains(scalar) ? "_" : String(scalar)
    }.joined()

    while safeName.last == " " || safeName.last == "." {
        safeName.removeLast()
    }

    if safeName.isEmpty || safeName == "." || safeName == ".." {
        safeName = "file"
    }

    let stem = (safeName as NSString).deletingPathExtension
    let reservedNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
    ]
    if reservedNames.contains(stem.uppercased()) {
        safeName = "_\(safeName)"
    }

    return safeName
}

func uniqueDestination(for source: URL, in directory: URL, used: inout Set<String>) -> URL {
    let baseName = windowsSafeFileName(source.lastPathComponent)
    let ext = (baseName as NSString).pathExtension
    let stem = (baseName as NSString).deletingPathExtension
    var candidate = baseName
    var index = 2
    while used.contains(candidate.lowercased()) || fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
        if ext.isEmpty {
            candidate = "\(stem)-\(index)"
        } else {
            candidate = "\(stem)-\(index).\(ext)"
        }
        index += 1
    }
    used.insert(candidate.lowercased())
    return directory.appendingPathComponent(candidate)
}

func uniqueSibling(named name: String, in directory: URL) -> URL {
    let safeName = windowsSafeFileName(name)
    let ext = (safeName as NSString).pathExtension
    let stem = (safeName as NSString).deletingPathExtension
    var candidate = safeName
    var index = 2
    while fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
        if ext.isEmpty {
            candidate = "\(stem)-\(index)"
        } else {
            candidate = "\(stem)-\(index).\(ext)"
        }
        index += 1
    }
    return directory.appendingPathComponent(candidate)
}

@discardableResult
func sanitizePathTreeNames(_ url: URL) throws -> URL {
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return url
    }

    if isDirectory.boolValue {
        let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
        for child in children {
            try sanitizePathTreeNames(child)
        }
    }

    let safeName = windowsSafeFileName(url.lastPathComponent)
    guard safeName != url.lastPathComponent.precomposedStringWithCanonicalMapping else {
        return url
    }

    let parent = url.deletingLastPathComponent()
    let dest = uniqueSibling(named: safeName, in: parent)
    try fm.moveItem(at: url, to: dest)
    return dest
}

func hashFile(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer {
        try? handle.close()
    }

    var hasher = SHA256()
    while true {
        let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
        if data.isEmpty {
            break
        }
        hasher.update(data: data)
    }
    return hexString(hasher.finalize())
}

func hashDirectory(_ url: URL) throws -> String {
    var lines: [String] = []
    guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) else {
        return sha256Hex("")
    }

    let basePath = url.path
    for case let item as URL in enumerator {
        let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let rel = String(item.path.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if values.isDirectory == true {
            lines.append("d:\(rel)")
        } else if values.isRegularFile == true {
            lines.append("f:\(rel):\(try hashFile(item))")
        }
    }
    return sha256Hex(lines.sorted().joined(separator: "\n"))
}

func pathTreeCanUseMetadataWithoutCopy(_ url: URL) throws -> Bool {
    let safeName = windowsSafeFileName(url.lastPathComponent)
    guard safeName == url.lastPathComponent.precomposedStringWithCanonicalMapping else {
        return false
    }

    let values = try url.resourceValues(forKeys: [.isDirectoryKey])
    guard values.isDirectory == true else {
        return true
    }

    guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else {
        return true
    }

    for case let item as URL in enumerator {
        let itemSafeName = windowsSafeFileName(item.lastPathComponent)
        if itemSafeName != item.lastPathComponent.precomposedStringWithCanonicalMapping {
            return false
        }
    }
    return true
}

func uniqueExportFileName(for source: URL, used: inout Set<String>) -> String {
    let baseName = windowsSafeFileName(source.lastPathComponent)
    let ext = (baseName as NSString).pathExtension
    let stem = (baseName as NSString).deletingPathExtension
    var candidate = baseName
    var index = 2
    while used.contains(candidate.lowercased()) {
        if ext.isEmpty {
            candidate = "\(stem)-\(index)"
        } else {
            candidate = "\(stem)-\(index).\(ext)"
        }
        index += 1
    }
    used.insert(candidate.lowercased())
    return candidate
}

func exportExistingFilesMetadataWithoutCopy(_ urls: [URL]) throws -> Manifest? {
    for source in urls {
        guard source.isFileURL,
              fm.fileExists(atPath: source.path),
              try pathTreeCanUseMetadataWithoutCopy(source) else {
            return nil
        }
    }

    var used = Set<String>()
    var items: [Manifest.Item] = []
    var hashLines: [String] = []
    var total: UInt64 = 0

    for source in urls {
        let exportName = uniqueExportFileName(for: source, used: &used)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = values.isDirectory == true
        let bytes = isDirectory ? directoryBytes(source) : fileBytes(source)
        let itemHash = isDirectory ? try hashDirectory(source) : try hashFile(source)
        let relPath = "files/\(exportName)"

        total += bytes
        items.append(Manifest.Item(name: exportName, path: relPath, isDirectory: isDirectory, bytes: bytes))
        hashLines.append("\(isDirectory ? "d" : "f"):\(exportName):\(itemHash)")
    }

    guard !items.isEmpty else {
        throw ClipError.unsupported
    }

    let contentHash = sha256Hex(hashLines.sorted().joined(separator: "\n"))
    return Manifest(version: 2, origin: "mac", kind: "files", id: "files:\(contentHash)", bytes: total, textFile: nil, imageFile: nil, files: items)
}

func exportFiles(_ urls: [URL], to dir: URL) throws -> Manifest {
    let filesDir = dir.appendingPathComponent("files")
    try fm.createDirectory(at: filesDir, withIntermediateDirectories: true)

    var used = Set<String>()
    var items: [Manifest.Item] = []
    var hashLines: [String] = []
    var total: UInt64 = 0

    for source in urls {
        guard source.isFileURL else { continue }
        var dest = uniqueDestination(for: source, in: filesDir, used: &used)
        try fm.copyItem(at: source, to: dest)
        dest = try sanitizePathTreeNames(dest)

        let values = try dest.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = values.isDirectory == true
        let bytes = isDirectory ? directoryBytes(dest) : fileBytes(dest)
        let itemHash = isDirectory ? try hashDirectory(dest) : try hashFile(dest)
        let relPath = "files/\(dest.lastPathComponent)"

        total += bytes
        items.append(Manifest.Item(name: dest.lastPathComponent, path: relPath, isDirectory: isDirectory, bytes: bytes))
        hashLines.append("\(isDirectory ? "d" : "f"):\(dest.lastPathComponent):\(itemHash)")
    }

    guard !items.isEmpty else {
        throw ClipError.unsupported
    }

    let contentHash = sha256Hex(hashLines.sorted().joined(separator: "\n"))
    return Manifest(version: 2, origin: "mac", kind: "files", id: "files:\(contentHash)", bytes: total, textFile: nil, imageFile: nil, files: items)
}

func exportFilesForClipboardSet(_ urls: [URL], to dir: URL) throws -> Manifest {
    try ensureCleanDirectory(dir)
    if let manifest = try exportExistingFilesMetadataWithoutCopy(urls) {
        return manifest
    }
    return try exportFiles(urls, to: dir)
}

func exportImage(_ image: NSImage, to dir: URL) throws -> Manifest {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw ClipError.unsupported
    }

    let imageFile = "image.png"
    try png.write(to: dir.appendingPathComponent(imageFile))
    let hash = sha256Hex(png)
    return Manifest(version: 2, origin: "mac", kind: "image", id: "image:\(hash)", bytes: UInt64(png.count), textFile: nil, imageFile: imageFile, files: nil)
}

func exportText(_ text: String, to dir: URL) throws -> Manifest {
    guard !text.isEmpty else {
        throw ClipError.unsupported
    }
    let textFile = "text.txt"
    let data = Data(text.utf8)
    try data.write(to: dir.appendingPathComponent(textFile))
    let hash = sha256Hex(data)
    return Manifest(version: 2, origin: "mac", kind: "text", id: "text:\(hash)", bytes: UInt64(data.count), textFile: textFile, imageFile: nil, files: nil)
}

func exportClipboard(to dir: URL) throws -> Manifest {
    try ensureCleanDirectory(dir)
    let pasteboard = NSPasteboard.general

    var fileURLs: [URL] = []

    if let fileObjects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
        fileURLs.append(contentsOf: fileObjects.compactMap { object -> URL? in
            if let url = object as? URL, url.isFileURL {
                return url
            }
            if let nsURL = object as? NSURL {
                let url = nsURL as URL
                return url.isFileURL ? url : nil
            }
            return nil
        })
    }

    if let items = pasteboard.pasteboardItems {
        fileURLs.append(contentsOf: items.compactMap { item -> URL? in
            guard let value = item.string(forType: .fileURL),
                  let url = URL(string: value),
                  url.isFileURL else {
                return nil
            }
            return url
        })
    }

    if let paths = pasteboard.propertyList(forType: filenamesPasteboardType) as? [String] {
        fileURLs.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
    }

    var seenPaths = Set<String>()
    fileURLs = fileURLs.filter { url in
        let path = url.standardizedFileURL.path
        guard !seenPaths.contains(path) else {
            return false
        }
        seenPaths.insert(path)
        return true
    }

    if !fileURLs.isEmpty {
        return try exportFiles(fileURLs, to: dir)
    }

    if let image = NSImage(pasteboard: pasteboard) {
        return try exportImage(image, to: dir)
    }

    if let text = pasteboard.string(forType: .string), !text.isEmpty {
        return try exportText(text, to: dir)
    }

    throw ClipError.unsupported
}

func importClipboard(from dir: URL) throws -> ImportResult {
    let manifest = try readManifest(from: dir)
    let pasteboard = NSPasteboard.general
    var importedFileURLs: [URL] = []

    switch manifest.kind {
    case "text":
        guard let textFile = manifest.textFile else { throw ClipError.invalidManifest }
        let text = try String(contentsOf: dir.appendingPathComponent(textFile), encoding: .utf8)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    case "image":
        guard let imageFile = manifest.imageFile,
              let image = NSImage(contentsOf: dir.appendingPathComponent(imageFile)) else {
            throw ClipError.invalidManifest
        }
        pasteboard.clearContents()
        if !pasteboard.writeObjects([image]) {
            throw ClipError.importFailed("image")
        }
    case "files":
        guard let files = manifest.files else { throw ClipError.invalidManifest }
        var urls = files.map { dir.appendingPathComponent($0.path).standardizedFileURL }
        if let transferDir = transferMacDirectory() {
            urls = try copyFiles(urls, to: transferDir)
        }
        importedFileURLs = urls
        try setFileClipboard(urls)
    default:
        throw ClipError.invalidManifest
    }

    return ImportResult(manifest: manifest, fileURLs: importedFileURLs)
}

func setFileClipboard(_ urls: [URL]) throws {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let items = urls.map { url -> NSPasteboardItem in
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        return item
    }
    let wroteObjects = pasteboard.writeObjects(items)
    let wroteLegacyPaths = pasteboard.setPropertyList(urls.map(\.path), forType: filenamesPasteboardType)
    if !wroteObjects && !wroteLegacyPaths {
        throw ClipError.importFailed("files")
    }
}

func expandedPath(_ value: String) -> String {
    let nsValue = value as NSString
    return nsValue.expandingTildeInPath
}

func transferMacDirectory() -> URL? {
    let raw = ProcessInfo.processInfo.environment["MOONLIGHT_TRANSFER_MAC_DIR"] ?? ""
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return nil
    }
    return URL(fileURLWithPath: expandedPath(trimmed), isDirectory: true)
}

func copyFiles(_ urls: [URL], to directory: URL) throws -> [URL] {
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    var used = Set<String>()
    return try urls.map { source in
        let dest = uniqueDestination(for: source, in: directory, used: &used)
        try fm.copyItem(at: source, to: dest)
        return dest.standardizedFileURL
    }
}

func printManifest(_ manifest: Manifest, fileURLs: [URL] = []) {
    print("id=\(manifest.id)")
    print("kind=\(manifest.kind)")
    print("bytes=\(manifest.bytes)")
    if let files = manifest.files {
        print("files=\(files.count)")
    }
    if !fileURLs.isEmpty {
        print("file_paths=\(fileURLs.count)")
        for (index, url) in fileURLs.enumerated() {
            print("file_path_\(index + 1)=\(url.path)")
            print("file_name_\(index + 1)=\(url.lastPathComponent.precomposedStringWithCanonicalMapping)")
        }
    }
}

do {
    guard CommandLine.arguments.count >= 3 else {
        throw ClipError.usage
    }

    let command = CommandLine.arguments[1]
    let dir = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

    switch command {
    case "export":
        guard CommandLine.arguments.count == 3 else { throw ClipError.usage }
        let manifest = try exportClipboard(to: dir)
        try writeJSON(manifest, to: dir.appendingPathComponent("manifest.json"))
        printManifest(manifest)
    case "export-paths":
        guard CommandLine.arguments.count >= 4 else { throw ClipError.usage }
        try ensureCleanDirectory(dir)
        let urls = CommandLine.arguments.dropFirst(3).map { URL(fileURLWithPath: $0).standardizedFileURL }
        let manifest = try exportFiles(urls, to: dir)
        try writeJSON(manifest, to: dir.appendingPathComponent("manifest.json"))
        printManifest(manifest)
    case "set-files":
        guard CommandLine.arguments.count >= 4 else { throw ClipError.usage }
        let urls = CommandLine.arguments.dropFirst(3).map { URL(fileURLWithPath: $0).standardizedFileURL }
        let manifest = try exportFilesForClipboardSet(urls, to: dir)
        try setFileClipboard(urls)
        try writeJSON(manifest, to: dir.appendingPathComponent("manifest.json"))
        printManifest(manifest, fileURLs: urls)
    case "import":
        guard CommandLine.arguments.count == 3 else { throw ClipError.usage }
        let result = try importClipboard(from: dir)
        printManifest(result.manifest, fileURLs: result.fileURLs)
    case "info":
        guard CommandLine.arguments.count == 3 else { throw ClipError.usage }
        let manifest = try readManifest(from: dir)
        printManifest(manifest)
    default:
        throw ClipError.usage
    }
} catch let error as ClipError {
    fputs("\(error.description)\n", stderr)
    exit(error.description == ClipError.unsupported.description ? 2 : 1)
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
