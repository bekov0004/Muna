import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Where Muna keeps the user's data (shared/formats/data-files.md): ~/Library/Application Support/Muna
/// on macOS. MUNA_DATA_DIR replaces it (tests).
public enum DataDirectory {
    public static var url: URL {
        if let override = ProcessInfo.processInfo.environment["MUNA_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Muna", isDirectory: true)
        #else
        let env = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        let base = env.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share", isDirectory: true)
        return base.appendingPathComponent("muna", isDirectory: true)
        #endif
    }
}

/// One small JSON file of the user's data: read whole, written whole and atomically, readable only
/// by the user. The files are a few kilobytes and are written on the user's actions only.
public struct JSONStore {
    public let url: URL

    public init(name: String, directory: URL = DataDirectory.url) {
        url = directory.appendingPathComponent(name)
    }

    /// The parsed file, or nil when it is missing or broken.
    public func load<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func save<T: Encodable>(_ value: T) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        // The new contents go to a private temporary file first, which then takes the place of the old one.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // rename() replaces the old file in one step: a reader sees the old or the new file, never half of one.
        if rename(temporary.path, url.path) != 0 {
            let code = errno
            try? fileManager.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

/// Decodes the entries of a list one by one: a broken entry is skipped instead of losing the whole file.
struct LossyList<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
        self.elements = elements
    }

    private struct Skip: Decodable {}
}

/// Gives a fresh id to entries without one (<= 0) or with one used before, like the Linux version.
func repairIds<T>(_ items: inout [T], id: WritableKeyPath<T, Int>) -> Int {
    var next = 1 + (items.map { $0[keyPath: id] }.max() ?? 0)
    next = max(next, 1)
    var seen = Set<Int>()
    for index in items.indices {
        if items[index][keyPath: id] <= 0 || seen.contains(items[index][keyPath: id]) {
            items[index][keyPath: id] = next
            next += 1
        }
        seen.insert(items[index][keyPath: id])
    }
    return next
}

/// Milliseconds since 1970, the time unit of the data files.
public func nowMilliseconds() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000).rounded())
}
