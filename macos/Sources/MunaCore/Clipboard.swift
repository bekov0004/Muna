import Foundation

/// Something that was copied: text or files (clipboard.json, shared/formats/data-files.md).
public struct ClipItem: Codable, Equatable, Identifiable {
    public var text: String?
    public var files: [String]?
    public var saved: Bool
    public var note: String
    public var isPrivate: Bool
    public var at: Int64

    public var id: String { "\(at)-\(text?.hashValue ?? 0)-\(files?.hashValue ?? 0)" }

    public init(text: String? = nil, files: [String]? = nil, saved: Bool = false, note: String = "", isPrivate: Bool = false,
                at: Int64 = nowMilliseconds()) {
        self.text = text
        self.files = files
        self.saved = saved
        self.note = note
        self.isPrivate = isPrivate
        self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case text, files, saved, note, at
        case isPrivate = "private"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try? c.decode(String.self, forKey: .text)
        files = try? c.decode([String].self, forKey: .files)
        guard text != nil || !(files ?? []).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .text, in: c, debugDescription: "neither text nor files")
        }
        saved = (try? c.decode(Bool.self, forKey: .saved)) ?? false
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
        isPrivate = (try? c.decode(Bool.self, forKey: .isPrivate)) ?? false
        at = (try? c.decode(Int64.self, forKey: .at)) ?? 0
    }

    /// Writes `null` for the missing one of text / files, as Muna on Linux does.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let text { try c.encode(text, forKey: .text) } else { try c.encodeNil(forKey: .text) }
        if let files { try c.encode(files, forKey: .files) } else { try c.encodeNil(forKey: .files) }
        try c.encode(saved, forKey: .saved)
        try c.encode(note, forKey: .note)
        try c.encode(isPrivate, forKey: .isPrivate)
        try c.encode(at, forKey: .at)
    }

    /// Whether two items hold the same thing (whatever their notes and flags).
    func sameContent(_ other: ClipItem) -> Bool { text == other.text && files == other.files }

    /// What a search looks at.
    public var searchText: String { [text ?? "", note, (files ?? []).joined(separator: " ")].joined(separator: " ") }
}

/// The clipboard history, newest first: what was copied joins the top (or moves up if it was there).
/// Pinned ("saved") items always stay; the others only up to `limit`, and they are written to disk
/// only when the history is kept.
public final class ClipboardHistory {
    public static let maxSaved = 100
    public static let maxLength = 20000

    public private(set) var items: [ClipItem] = []
    public var limit = 50 { didSet { trim(); persist() } }
    public var keepHistory = true { didSet { persist() } }

    private let store: JSONStore

    private struct File: Codable {
        var version = 1
        var items: [ClipItem]
    }

    private struct LoadedFile: Decodable {
        var items: LossyList<ClipItem>
    }

    public init(store: JSONStore = JSONStore(name: "clipboard.json")) {
        self.store = store
        items = store.load(LoadedFile.self)?.items.elements ?? []
        trim()
    }

    /// Text was copied.
    public func add(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        add(ClipItem(text: String(text.prefix(Self.maxLength))))
    }

    /// Files were copied.
    public func add(files: [URL]) {
        guard !files.isEmpty else { return }
        add(ClipItem(files: files.map(\.absoluteString)))
    }

    private func add(_ item: ClipItem) {
        if let first = items.first, first.sameContent(item) { return }
        var item = item
        if let index = items.firstIndex(where: { $0.sameContent(item) }) {
            let old = items.remove(at: index)
            item.saved = old.saved
            item.note = old.note
            item.isPrivate = old.isPrivate
        }
        items.insert(item, at: 0)
        trim()
        persist()
    }

    public func setSaved(_ item: ClipItem, _ on: Bool) { change(item) { $0.saved = on } }
    public func setPrivate(_ item: ClipItem, _ on: Bool) { change(item) { $0.isPrivate = on } }
    public func setNote(_ item: ClipItem, _ note: String) { change(item) { $0.note = String(note.prefix(200)) } }

    public func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    /// Forgets everything but the pinned items.
    public func clear() {
        items.removeAll { !$0.saved }
        persist()
    }

    private func change(_ item: ClipItem, _ edit: (inout ClipItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        edit(&items[index])
        trim()
        persist()
    }

    private func trim() {
        var unsaved = 0
        items = items.filter { item in
            if item.saved { return true }
            unsaved += 1
            return unsaved <= limit
        }
        let saved = items.filter(\.saved)
        if saved.count > Self.maxSaved {
            let drop = Set(saved.dropFirst(Self.maxSaved).map(\.id))
            items.removeAll { drop.contains($0.id) }
        }
    }

    private func persist() {
        let kept = items.filter { keepHistory || $0.saved }
        try? store.save(File(items: kept))
    }
}

/// The files waiting in the Tray, as references (tray.json).
public final class TrayStore {
    public private(set) var files: [URL] = []
    /// Keep the tray between sessions (otherwise the file says nothing).
    public var keep = true { didSet { persist() } }
    private let store: JSONStore

    private struct File: Codable {
        var version = 1
        var files: [String]
    }

    private struct LoadedFile: Decodable {
        var files: LossyList<String>
    }

    public init(store: JSONStore = JSONStore(name: "tray.json")) {
        self.store = store
        let uris = store.load(LoadedFile.self)?.files.elements ?? []
        files = uris.compactMap { URL(string: $0) }.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        if files.count != uris.count { persist() }
    }

    public func add(_ urls: [URL]) {
        var fresh: [URL] = []
        for url in urls where url.isFileURL && !files.contains(url) && !fresh.contains(url)
            && FileManager.default.fileExists(atPath: url.path) {
            fresh.append(url)
        }
        guard !fresh.isEmpty else { return }
        files.append(contentsOf: fresh)
        persist()
    }

    public func remove(_ urls: [URL]) {
        files.removeAll { urls.contains($0) }
        persist()
    }

    public func clear() {
        files = []
        persist()
    }

    /// Drops the files that were deleted or moved away meanwhile.
    public func dropMissing() {
        let before = files.count
        files = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        if files.count != before { persist() }
    }

    private func persist() {
        try? store.save(File(files: keep ? files.map(\.absoluteString) : []))
    }
}
