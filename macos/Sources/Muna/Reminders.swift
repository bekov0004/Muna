import Combine
import Foundation
import MunaCore
import SwiftUI

/// Reminders: a text and a time (today, or tomorrow when the time has passed); at that time the
/// butterfly brings the text. Kept in reminders.json.
final class RemindersModel: ObservableObject {
    struct Reminder: Codable, Identifiable, Equatable {
        var id: Int
        var text: String
        var at: Int64
        var done: Bool
    }

    private struct File: Codable {
        var version = 1
        var reminders: [Reminder]
    }

    /// Decodes the list entry by entry: a broken entry is skipped.
    private struct Lossy: Decodable {
        var reminders: [Reminder] = []

        private enum Keys: String, CodingKey { case reminders }
        private struct Skip: Decodable {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            guard var list = try? container.nestedUnkeyedContainer(forKey: .reminders) else { return }
            while !list.isAtEnd {
                if let item = try? list.decode(Reminder.self) {
                    reminders.append(item)
                } else {
                    _ = try? list.decode(Skip.self)
                }
            }
        }
    }

    @Published private(set) var reminders: [Reminder] = []
    /// The text and time being written on the page.
    @Published var draftText = ""
    @Published var draftTime = Date().addingTimeInterval(3600)

    /// A reminder is due: its text.
    var onDue: (String) -> Void = { _ in }

    private let store = JSONStore(name: "reminders.json")
    private var timer: Timer?

    init() {
        reminders = (store.load(Lossy.self)?.reminders ?? []).filter { !$0.done }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Reminders missed while Muna was closed come at once.
        DispatchQueue.main.async { [weak self] in self?.check() }
    }

    /// Waiting reminders, soonest first.
    var pending: [Reminder] {
        reminders.filter { !$0.done }.sorted { $0.at < $1.at }
    }

    /// The next moment with the clock time of `time`: today, or tomorrow if it has passed.
    static func nextOccurrence(of time: Date, from now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        let today = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: now) ?? now
        return today > now ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? today)
    }

    func add(text: String, time: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let when = RemindersModel.nextOccurrence(of: time)
        let id = (reminders.map { $0.id }.max() ?? 0) + 1
        let ms = Int64((when.timeIntervalSince1970 * 1000).rounded())
        reminders.append(Reminder(id: id, text: trimmed.isEmpty ? "Reminder" : String(trimmed.prefix(500)), at: ms, done: false))
        save()
    }

    /// Adds the draft from the page.
    func addDraft() {
        add(text: draftText, time: draftTime)
        draftText = ""
    }

    func remove(id: Int) {
        reminders.removeAll { $0.id == id }
        save()
    }

    /// Shows the reminders whose time has come, once each.
    func check() {
        let now = nowMilliseconds()
        let due = reminders.filter { !$0.done && $0.at <= now }
        guard !due.isEmpty else { return }
        let ids = Set(due.map { $0.id })
        reminders.removeAll { ids.contains($0.id) }
        save()
        for item in due.sorted(by: { $0.at < $1.at }) {
            onDue(item.text)
        }
    }

    private func save() {
        try? store.save(File(version: 1, reminders: reminders))
    }

    static func timeText(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        return Calendar.current.isDateInToday(date) ? time : "Tomorrow \(time)"
    }
}

struct RemindersPage: View {
    @EnvironmentObject var reminders: RemindersModel

    var body: some View {
        QuickBlock {
            Caption("Reminders")
            HStack(spacing: 6) {
                TextField("Remind me to…", text: $reminders.draftText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { reminders.addDraft() }
                DatePicker("", selection: $reminders.draftTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .frame(width: 80)
                Pill(label: "Add", accent: true) { reminders.addDraft() }
            }
            if reminders.pending.isEmpty {
                Text("No reminders. Write a text and a time: the butterfly brings it then.")
                    .font(.system(size: 11))
                    .foregroundColor(MunaColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(reminders.pending) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "bell")
                                .font(.system(size: 11))
                                .foregroundColor(MunaColor.amber)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.text)
                                    .font(.system(size: 12))
                                    .foregroundColor(MunaColor.text)
                                    .lineLimit(2)
                                Text(RemindersModel.timeText(item.at))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(MunaColor.secondary)
                            }
                            Spacer(minLength: 4)
                            IconButton(symbol: "xmark") { reminders.remove(id: item.id) }
                        }
                    }
                }
            }
        }
    }
}
