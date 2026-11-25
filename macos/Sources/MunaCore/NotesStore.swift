import Foundation

/// A quick note (notes.json, shared/formats/data-files.md).
public struct Note: Codable, Equatable, Identifiable {
    public var id: Int
    public var text: String
    public var at: Int64
    public var isPrivate: Bool

    public init(id: Int, text: String, at: Int64, isPrivate: Bool = false) {
        self.id = id
        self.text = text
        self.at = at
        self.isPrivate = isPrivate
    }

    enum CodingKeys: String, CodingKey {
        case id, text, at
        case isPrivate = "private"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        at = (try? c.decode(Int64.self, forKey: .at)) ?? 0
        isPrivate = (try? c.decode(Bool.self, forKey: .isPrivate)) ?? false
    }
}

/// The quick notes, newest first, saved in notes.json.
public final class NotesStore {
    public static let maxNotes = 100
    public static let maxLength = 1000

    public private(set) var notes: [Note] = []
    private let store: JSONStore
    private var nextId = 1

    private struct File: Codable {
        var version = 1
        var notes: [Note]
    }

    private struct LoadedFile: Decodable {
        var notes: LossyList<Note>
    }

    public init(store: JSONStore = JSONStore(name: "notes.json")) {
        self.store = store
        load()
    }

    public func load() {
        var loaded = store.load(LoadedFile.self)?.notes.elements ?? []
        loaded = Array(loaded.prefix(Self.maxNotes)).map { note in
            var note = note
            note.text = String(note.text.prefix(Self.maxLength))
            return note
        }
        nextId = repairIds(&loaded, id: \.id)
        notes = loaded
    }

    /// Adds a note at the top. @returns false for an empty text.
    @discardableResult
    public func add(_ text: String) throws -> Bool {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLength))
        guard !trimmed.isEmpty else { return false }
        notes.insert(Note(id: nextId, text: trimmed, at: nowMilliseconds()), at: 0)
        nextId += 1
        if notes.count > Self.maxNotes {
            notes.removeLast(notes.count - Self.maxNotes)
        }
        try save()
        return true
    }

    public func update(id: Int, text: String) throws {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLength))
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if trimmed.isEmpty {
            notes.remove(at: index)
        } else {
            notes[index].text = trimmed
        }
        try save()
    }

    public func remove(id: Int) throws {
        notes.removeAll { $0.id == id }
        try save()
    }

    public func setPrivate(id: Int, _ on: Bool) throws {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].isPrivate = on
        try save()
    }

    private func save() throws {
        try store.save(File(notes: notes))
    }
}
