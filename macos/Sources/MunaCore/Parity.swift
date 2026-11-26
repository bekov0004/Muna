import Foundation

/// How much the agents worked (linux/service/agents/module.js): the token counts and times of the
/// messages in Claude Code's and Codex's logs, read as they grow (only the numbers, never the
/// prompts), summed over the last five hours and the last week.
public final class TokenUsage {
    public struct Summary: Equatable {
        public let agent: String
        public let tokens5h: Int
        public let tokens7d: Int
        public let messages5h: Int
        public let last: Date?
    }

    private final class LogFile {
        let agent: String
        var offset: UInt64 = 0
        var entries: [(at: Date, tokens: Int)] = []
        init(agent: String) { self.agent = agent }
    }

    private var files: [String: LogFile] = [:]
    private static let week: TimeInterval = 7 * 86400, fiveHours: TimeInterval = 5 * 3600

    public init() {}

    public func update(claudeRoot: String = AgentSessions.claudeRoot, codexRoot: String = AgentSessions.codexRoot, now: Date = Date()) -> [Summary] {
        var seen = Set<String>()
        for (agent, root) in [("Claude Code", claudeRoot), ("Codex", codexRoot)] {
            guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard now.timeIntervalSince(modified) <= Self.week else { continue }
                seen.insert(url.path)
                let file = files[url.path] ?? LogFile(agent: agent)
                files[url.path] = file
                read(url, file)
            }
        }
        for key in files.keys where !seen.contains(key) { files.removeValue(forKey: key) }
        var result: [Summary] = []
        for agent in ["Claude Code", "Codex"] {
            let mine = files.values.filter { $0.agent == agent }
            guard !mine.isEmpty else { continue }
            var t5 = 0, t7 = 0, m5 = 0
            var last: Date?
            for file in mine {
                file.entries.removeAll { now.timeIntervalSince($0.at) > Self.week }
                for entry in file.entries {
                    t7 += entry.tokens
                    if now.timeIntervalSince(entry.at) <= Self.fiveHours { t5 += entry.tokens; m5 += 1 }
                    if last == nil || entry.at > last! { last = entry.at }
                }
            }
            result.append(Summary(agent: agent, tokens5h: t5, tokens7d: t7, messages5h: m5, last: last))
        }
        return result
    }

    private func read(_ url: URL, _ file: LogFile) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < file.offset { file.offset = 0; file.entries = [] }
        try? handle.seek(toOffset: file.offset)
        guard let data = try? handle.read(upToCount: Int(min(size - file.offset, 8 * 1024 * 1024))), !data.isEmpty else { return }
        // only whole lines: a half-written one is read next time
        guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        file.offset += UInt64(end - data.startIndex + 1)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for line in data[data.startIndex..<end].split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let usage = ((object["message"] as? [String: Any])?["usage"] as? [String: Any])
                ?? (((object["payload"] as? [String: Any])?["info"] as? [String: Any])?["last_token_usage"] as? [String: Any])
            guard let usage, let stamp = object["timestamp"] as? String, let at = formatter.date(from: stamp) ?? plain.date(from: stamp) else { continue }
            let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
            file.entries.append((at, tokens))
        }
    }

    /// "1.2M", "840K", "512".
    public static func short(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
        if tokens >= 1000 { return "\(tokens / 1000)K" }
        return "\(tokens)"
    }
}

/// How Linux arranges every window of a screen (linux/src/windows/layout.js tile()): the share of the
/// work area (0–1) each of n windows gets.
public enum TileSlots {
    public static func slots(_ mode: String, _ n: Int) -> [CGRect] {
        var slots: [CGRect] = []
        func cells(_ area: CGRect, _ perRow: [Int]) {
            let height = area.height / CGFloat(perRow.count)
            for (row, count) in perRow.enumerated() {
                for i in 0..<count {
                    slots.append(CGRect(x: area.minX + CGFloat(i) * area.width / CGFloat(count), y: area.minY + CGFloat(row) * height,
                                        width: area.width / CGFloat(count), height: height))
                }
            }
        }
        guard n > 0 else { return [] }
        let all = CGRect(x: 0, y: 0, width: 1, height: 1)
        switch mode {
        case "columns": cells(all, [n])
        case "rows": cells(all, Array(repeating: 1, count: n))
        case "main" where n > 1:
            slots.append(CGRect(x: 0, y: 0, width: 0.6, height: 1))
            cells(CGRect(x: 0.6, y: 0, width: 0.4, height: 1), Array(repeating: 1, count: n - 1))
        default:
            let columns = Int(Double(n).squareRoot().rounded(.up))
            let rows = Int((Double(n) / Double(columns)).rounded(.up))
            var perRow = Array(repeating: columns, count: rows)
            perRow[rows - 1] = n - columns * (rows - 1)
            cells(all, perRow)
        }
        return slots
    }
}

/// Cuts an H.264 byte stream (Annex B, as Android's screenrecord writes it) into access units: the
/// parameter sets and the slice of one picture together. The same as Windows' MunaCore.
public final class AnnexB {
    private var buffer: [UInt8] = []
    private var unit: [UInt8] = []
    private var unitHasPicture = false

    public init() {}

    public func push(_ bytes: [UInt8]) -> [[UInt8]] {
        var done: [[UInt8]] = []
        buffer += bytes
        while true {
            guard let (first, firstLength) = startCode(from: 0) else {
                if buffer.count > 4 * 1024 * 1024 { buffer.removeAll() }
                break
            }
            if first > 0 { buffer.removeFirst(first) }
            guard let (next, _) = startCode(from: firstLength) else { break }
            let nal = Array(buffer[0..<next])
            buffer.removeFirst(next)
            add(nal, startLength: firstLength, &done)
        }
        return done
    }

    private func add(_ nal: [UInt8], startLength: Int, _ done: inout [[UInt8]]) {
        guard nal.count > startLength else { return }
        let type = Int(nal[startLength] & 0x1F)
        let picture = type == 1 || type == 5
        if unitHasPicture && (picture || [6, 7, 8, 9].contains(type)) {
            done.append(unit)
            unit = []
            unitHasPicture = false
        }
        unit += nal
        if picture {
            done.append(unit)
            unit = []
            unitHasPicture = false
        }
    }

    private func startCode(from: Int) -> (Int, Int)? {
        var i = from
        while i + 2 < buffer.count {
            if buffer[i] == 0 && buffer[i + 1] == 0 && buffer[i + 2] == 1 {
                if i > from && buffer[i - 1] == 0 { return (i - 1, 4) }
                return (i, 3)
            }
            i += 1
        }
        return nil
    }

    /// The NAL type of the first NAL of a unit (7 SPS, 8 PPS, 5 IDR picture, 1 picture).
    public static func firstType(_ unit: [UInt8]) -> Int {
        let offset = unit.count > 3 && unit[2] == 1 ? 3 : 4
        return unit.count > offset ? Int(unit[offset] & 0x1F) : -1
    }
}

/// Muna Phone's link (linux/src/phone/phoneLink.js): the secret is never sent, each side proves it knows it.
public enum PhoneLinkProtocol {
    public static let appId = "dev.muna.phone"
    public static let serverClass = "dev.muna.phone.server.Server"

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }

    public static func fingerprint(_ token: String) -> String { String(hex(SHA256Small.hash(Array(token.utf8))).prefix(8)) }

    public static func proof(_ token: String, _ who: String, _ first: String, _ second: String) -> String {
        hex(SHA256Small.hmac(key: Array(token.utf8), message: Array("\(who)|\(first)|\(second)".utf8)))
    }

    public static func randomToken() -> String { hex((0..<16).map { _ in UInt8.random(in: 0...255) }) }

    /// The computer's answer to a phone's HELLO2 (or nil: refuse, answer NO).
    public static func challenge(hello: String, token: String) -> (nonce: String, line: String, phoneNonce: String, role: Character)? {
        let parts = hello.split(separator: " ").map(String.init)
        guard parts.count == 4, parts[0] == "HELLO2", parts[1] == "C" || parts[1] == "V", parts[2] == fingerprint(token),
              parts[3].count >= 16, parts[3].allSatisfy({ $0.isHexDigit }) else { return nil }
        let nonce = randomToken()
        return (nonce, "CHAL \(nonce) \(proof(token, "srv", parts[3], nonce))", parts[3], parts[1].first!)
    }

    /// Whether the phone's AUTH line proves the secret; what it told about itself.
    public static func check(auth: String, token: String, nonce: String, phoneNonce: String) -> String? {
        let parts = auth.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, parts[0] == "AUTH", parts[1] == proof(token, "cli", nonce, phoneNonce) else { return nil }
        return parts.count > 2 ? parts[2] : ""
    }

    /// The address of this computer in the same network as one of the phone's (`ip -4 addr show` of the phone).
    public static func lanAddress(phone: String, local: [(address: String, prefix: Int)]) -> String? {
        func number(_ ip: String) -> UInt32? {
            let parts = ip.split(separator: ".").compactMap { UInt32($0) }
            return parts.count == 4 ? parts.reduce(0) { $0 << 8 | $1 } : nil
        }
        let pattern = try! NSRegularExpression(pattern: "inet (\\d+\\.\\d+\\.\\d+\\.\\d+)/(\\d+)")
        let phones: [(UInt32, Int)] = pattern.matches(in: phone, range: NSRange(phone.startIndex..., in: phone)).compactMap { match in
            guard let a = Range(match.range(at: 1), in: phone), let p = Range(match.range(at: 2), in: phone), let n = number(String(phone[a])) else { return nil }
            return (n, Int(phone[p]) ?? 32)
        }
        for (address, prefix) in local {
            guard let mine = number(address), mine >> 24 != 127 else { continue }
            for (other, otherPrefix) in phones where other >> 24 != 127 {
                let bits = min(prefix, otherPrefix)
                guard bits >= 8 else { continue }
                let mask: UInt32 = bits >= 32 ? .max : ~(UInt32.max >> UInt32(bits))
                if mine & mask == other & mask { return address }
            }
        }
        return nil
    }
}

/// SHA-256 and HMAC-SHA256 in plain Swift (MunaCore builds without CryptoKit, also on Linux for the tests).
public enum SHA256Small {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var data = message
        let bits = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in (0..<8).reversed() { data.append(UInt8((bits >> (UInt64(i) * 8)) & 0xff)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunk in stride(from: 0, to: data.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(data[j]) << 24 | UInt32(data[j + 1]) << 16 | UInt32(data[j + 2]) << 8 | UInt32(data[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { v in (0..<4).reversed().map { UInt8((v >> (UInt32($0) * 8)) & 0xff) } }
    }

    public static func hmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var key = key.count > 64 ? hash(key) : key
        key += [UInt8](repeating: 0, count: 64 - key.count)
        let inner = hash(key.map { $0 ^ 0x36 } + message)
        return hash(key.map { $0 ^ 0x5c } + inner)
    }
}

/// The butterfly's reminders (linux/src/utils/reminders.js), kept as JSON in the "reminders" setting.
public enum ButterflyReminders {
    public struct Reminder: Equatable, Identifiable {
        public var id: String
        public var time: String
        public var text: String
        public var repeatMode: String
        public var enabled: Bool
        public var date: String?
        public var lastFired: String?
        public var snoozeUntil: Double = 0
        public init(id: String, time: String, text: String, repeatMode: String, enabled: Bool, date: String? = nil, lastFired: String? = nil) {
            self.id = id; self.time = time; self.text = text; self.repeatMode = repeatMode; self.enabled = enabled; self.date = date; self.lastFired = lastFired
        }
    }

    public static let repeats = ["once", "daily", "weekdays"]
    private static let late: TimeInterval = 3 * 3600

    private static var calendar: Calendar { Calendar.current }

    public static func dayOf(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func parseTime(_ text: String?) -> String? {
        guard let text, let regex = try? NSRegularExpression(pattern: "^\\s*(\\d{1,2})[:.\\s]?(\\d{2})\\s*$"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text),
              let h = Int(text[a]), let m = Int(text[b]), h < 24, m < 60 else { return nil }
        return String(format: "%02d:%02d", h, m)
    }

    public static func parseList(_ json: String) -> [Reminder] {
        guard let data = (json.isEmpty ? "[]" : json).data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { o in
            guard let time = parseTime(o["time"] as? String), let text = o["text"] as? String else { return nil }
            var r = Reminder(id: o["id"] as? String ?? UUID().uuidString, time: time, text: text,
                             repeatMode: repeats.contains(o["repeat"] as? String ?? "") ? o["repeat"] as! String : "once",
                             enabled: o["enabled"] as? Bool ?? true, date: o["date"] as? String, lastFired: o["lastFired"] as? String)
            r.snoozeUntil = (o["snoozeUntil"] as? NSNumber)?.doubleValue ?? 0
            return r
        }
    }

    public static func toJSON(_ list: [Reminder]) -> String {
        let objects: [[String: Any]] = list.map { r in
            var o: [String: Any] = ["id": r.id, "time": r.time, "text": r.text, "repeat": r.repeatMode, "enabled": r.enabled]
            if let date = r.date { o["date"] = date }
            if let last = r.lastFired { o["lastFired"] = last }
            if r.snoozeUntil > 0 { o["snoozeUntil"] = r.snoozeUntil }
            return o
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func at(_ day: String, _ time: String) -> Date {
        let d = day.split(separator: "-").compactMap { Int($0) }, t = time.split(separator: ":").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: d[0], month: d[1], day: d[2], hour: t[0], minute: t[1])) ?? Date.distantFuture
    }

    public static func new(time: String, text: String, repeatMode: String, now: Date) throws -> Reminder {
        guard let t = parseTime(time) else { throw NSError(domain: "Muna", code: 1, userInfo: [NSLocalizedDescriptionKey: "Write the time as 18:30"]) }
        var r = Reminder(id: String(Int(now.timeIntervalSince1970 * 1000), radix: 36), time: t, text: text.trimmingCharacters(in: .whitespaces),
                         repeatMode: repeats.contains(repeatMode) ? repeatMode : "once", enabled: true)
        if r.repeatMode == "once" {
            let today = dayOf(now)
            r.date = at(today, t) > now ? today : dayOf(now.addingTimeInterval(86400))
        }
        return r
    }

    public static func nextRing(_ r: Reminder, now: Date) -> Date? {
        guard r.enabled else { return nil }
        if r.snoozeUntil > 0 { return Date(timeIntervalSince1970: r.snoozeUntil / 1000) }
        if r.repeatMode == "once" { return r.date.map { at($0, r.time) } }
        for i in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: i, to: calendar.startOfDay(for: now)) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            if r.repeatMode == "weekdays" && (weekday == 1 || weekday == 7) { continue }
            let key = dayOf(day)
            let when = at(key, r.time)
            if r.lastFired == key { continue }
            if i == 0 && now.timeIntervalSince(when) > late { continue }
            return when
        }
        return nil
    }

    public static func isDue(_ r: Reminder, now: Date) -> Bool {
        guard let when = nextRing(r, now: now) else { return false }
        return when <= now && now.timeIntervalSince(when) <= late + 60
    }

    public static func rang(_ r: Reminder, now: Date) -> Reminder {
        var next = r
        next.snoozeUntil = 0
        if r.repeatMode == "once" { next.enabled = false } else { next.lastFired = dayOf(now) }
        return next
    }

    public static func whenText(_ r: Reminder, now: Date) -> String {
        switch r.repeatMode {
        case "daily": return "Every day"
        case "weekdays": return "Weekdays"
        default:
            guard let date = r.date else { return "" }
            return date == dayOf(now) ? "Today" : date == dayOf(now.addingTimeInterval(86400)) ? "Tomorrow" : date
        }
    }
}
