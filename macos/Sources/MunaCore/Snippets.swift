import Foundation

/// A text snippet: a short trigger (";mail") that stands for a longer text (snippets.json,
/// shared/formats/data-files.md).
public struct Snippet: Codable, Equatable, Identifiable {
    public var trigger: String
    public var text: String

    public var id: String { trigger }

    public init(trigger: String, text: String) {
        self.trigger = trigger
        self.text = text
    }
}

/// The snippets, newest first, saved in snippets.json (as linux/service/snippets/module.js).
public final class SnippetsStore {
    public static let maxSnippets = 200
    public static let maxLength = 5000

    public enum SnippetError: Error, Equatable {
        case empty
    }

    public private(set) var snippets: [Snippet] = []
    private let store: JSONStore

    private struct File: Codable {
        var version = 1
        var snippets: [Snippet]
    }

    private struct LoadedFile: Decodable {
        var snippets: LossyList<Snippet>
    }

    public init(store: JSONStore = JSONStore(name: "snippets.json")) {
        self.store = store
        load()
    }

    public func load() {
        snippets = Array((store.load(LoadedFile.self)?.snippets.elements ?? []).prefix(Self.maxSnippets))
    }

    /// Adds a snippet at the top; one with the same trigger is replaced. Throws for an empty trigger or text.
    public func add(trigger: String, text: String) throws {
        let trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty, !text.isEmpty else { throw SnippetError.empty }
        let snippet = Snippet(trigger: trigger, text: String(text.prefix(Self.maxLength)))
        snippets = Array(([snippet] + snippets.filter { $0.trigger != trigger }).prefix(Self.maxSnippets))
        try save()
    }

    /// Changes a snippet (its trigger too): the old one is removed and the new one goes on top.
    public func update(trigger oldTrigger: String, to trigger: String, text: String) throws {
        let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !text.isEmpty else { throw SnippetError.empty }
        snippets.removeAll { $0.trigger == oldTrigger }
        try add(trigger: trimmed, text: text)
    }

    public func remove(trigger: String) throws {
        snippets.removeAll { $0.trigger == trigger }
        try save()
    }

    private func save() throws {
        try store.save(File(snippets: snippets))
    }

    /// Fills in {date} (2026-11-25), {time} (14:05) and {datetime} with the local time.
    public static func expand(_ text: String, now: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        func two(_ n: Int?) -> String { let s = String(n ?? 0); return s.count < 2 ? "0" + s : s }
        let date = "\(parts.year ?? 0)-\(two(parts.month))-\(two(parts.day))"
        let time = "\(two(parts.hour)):\(two(parts.minute))"
        return text.replacingOccurrences(of: "{datetime}", with: "\(date) \(time)")
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{time}", with: time)
    }
}
