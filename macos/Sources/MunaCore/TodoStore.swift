import Foundation

/// A to-do (todo.json, shared/formats/data-files.md).
public struct TodoItem: Codable, Equatable, Identifiable {
    public var id: Int
    public var text: String
    public var done: Bool

    public init(id: Int, text: String, done: Bool = false) {
        self.id = id
        self.text = text
        self.done = done
    }

    enum CodingKeys: String, CodingKey { case id, text, done }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        done = (try? c.decode(Bool.self, forKey: .done)) ?? false
    }
}

/// The to-do list, in the order the items were added, saved in todo.json.
public final class TodoStore {
    public static let maxItems = 200
    public static let maxLength = 200

    public private(set) var items: [TodoItem] = []
    private let store: JSONStore
    private var nextId = 1

    private struct File: Codable {
        var version = 1
        var items: [TodoItem]
    }

    private struct LoadedFile: Decodable {
        var items: LossyList<TodoItem>
    }

    public init(store: JSONStore = JSONStore(name: "todo.json")) {
        self.store = store
        load()
    }

    public var openCount: Int { items.filter { !$0.done }.count }
    public var hasDone: Bool { items.contains { $0.done } }

    public func load() {
        var loaded = Array((store.load(LoadedFile.self)?.items.elements ?? []).prefix(Self.maxItems))
        nextId = repairIds(&loaded, id: \.id)
        items = loaded
    }

    /// @returns false for an empty text or a full list.
    @discardableResult
    public func add(_ text: String) throws -> Bool {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLength))
        guard !trimmed.isEmpty, items.count < Self.maxItems else { return false }
        items.append(TodoItem(id: nextId, text: trimmed))
        nextId += 1
        try save()
        return true
    }

    public func toggle(id: Int) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].done.toggle()
        try save()
    }

    public func remove(id: Int) throws {
        items.removeAll { $0.id == id }
        try save()
    }

    public func clearDone() throws {
        items.removeAll { $0.done }
        try save()
    }

    private func save() throws {
        try store.save(File(items: items))
    }
}
