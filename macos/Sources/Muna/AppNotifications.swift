import AppKit
import Foundation
import SQLite3

/// The notifications of the other apps, for the Alerts section (Linux shows GNOME's). macOS keeps
/// them for Notification Centre in a database of the user's own; Muna reads the new ones from it
/// every 3 seconds (macOS asks once for Full Disk Access, without it nothing is read). Only the app,
/// the title and the text are read; nothing is written there.
final class AppNotifications {
    private let alerts: AlertsModel
    private var timer: Timer?
    private var lastId: Int64 = -1
    private var stamp: Date?
    private(set) var problem: String?

    init(alerts: AlertsModel) { self.alerts = alerts }

    /// The database: in the group container since macOS 15, before that in the user's temporary folder.
    static var database: String? {
        let group = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db").path
        if FileManager.default.fileExists(atPath: group) { return group }
        var buffer = [CChar](repeating: 0, count: 1024)
        if confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 {
            let old = String(cString: buffer) + "com.apple.notificationcenter/db2/db"
            if FileManager.default.fileExists(atPath: old) { return old }
        }
        return nil
    }

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Opens System Settings at Full Disk Access.
    static func askForAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    private func poll() {
        guard let path = Self.database else { problem = "No notification list found"; return }
        let wal = path + "-wal"
        let modified = [path, wal].compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max()
        guard modified != stamp || lastId < 0 else { return }
        stamp = modified
        let after = lastId
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (rows, last, problem) = Self.read(path, after: after)
            DispatchQueue.main.async {
                guard let self else { return }
                self.problem = problem
                guard problem == nil else { return }
                // the first time only remembers where the list is: what came before Muna is not news
                let first = self.lastId < 0
                self.lastId = max(self.lastId, last)
                if first { return }
                for row in rows { self.alerts.addFromApp(bundle: row.bundle, title: row.title, body: row.body, at: row.at) }
            }
        }
    }

    private struct Row { let bundle: String; let title: String; let body: String; let at: Date }

    private static func read(_ path: String, after: Int64) -> ([Row], Int64, String?) {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            return ([], after, "Allow Muna in System Settings → Privacy & Security → Full Disk Access to show other apps' notifications")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)
        let sql = after < 0 ? "SELECT MAX(rec_id) FROM record"
            : "SELECT r.rec_id, a.identifier, r.data, r.delivered_date FROM record r JOIN app a ON r.app_id = a.app_id WHERE r.rec_id > ?1 ORDER BY r.rec_id"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return ([], after, "Allow Muna in System Settings → Privacy & Security → Full Disk Access to show other apps' notifications")
        }
        defer { sqlite3_finalize(statement) }
        if after >= 0 { sqlite3_bind_int64(statement, 1, after) }
        var rows: [Row] = []
        var last = after
        while sqlite3_step(statement) == SQLITE_ROW {
            if after < 0 { last = sqlite3_column_int64(statement, 0); break }
            let id = sqlite3_column_int64(statement, 0)
            last = max(last, id)
            guard let text = sqlite3_column_text(statement, 1), let blob = sqlite3_column_blob(statement, 2) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 2)))
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let request = plist["req"] as? [String: Any] else { continue }
            let title = [request["titl"] as? String, request["subt"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let body = request["body"] as? String ?? ""
            guard !title.isEmpty || !body.isEmpty else { continue }
            let at = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3))
            rows.append(Row(bundle: String(cString: text), title: title.isEmpty ? body : title, body: title.isEmpty ? "" : body, at: at))
        }
        return (rows, last, nil)
    }
}
