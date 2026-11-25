import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One timed line of a song's lyrics.
public struct LyricLine: Codable, Equatable {
    /// Milliseconds from the start of the song.
    public let t: Int
    public let text: String

    public init(t: Int, text: String) {
        self.t = t
        self.text = text
    }
}

/// What lrclib.net knows of a song: timed lines, or only the plain text.
public struct LyricsResult: Codable, Equatable {
    public var lines: [LyricLine]?
    public var plain: String?

    public init(lines: [LyricLine]? = nil, plain: String? = nil) {
        self.lines = lines
        self.plain = plain
    }

    /// The line being sung at a moment (seconds), nil before the first one.
    public func line(at seconds: Double) -> LyricLine? {
        guard let lines else { return nil }
        let ms = Int(seconds * 1000)
        return lines.last { $0.t <= ms }
    }
}

/// Lyrics of the song that plays, looked up on lrclib.net (a free lyrics database, no key), as Muna
/// on Linux does it (linux/service/lyrics/module.js): only the artist, title, album and length are
/// sent, and only when the user turns lyrics on. Answers are kept in a cache folder.
public final class LyricsClient {
    public static let maxCacheFiles = 200

    private let base: String
    private let cache: URL
    private let session: URLSession
    private var memory: [String: LyricsResult] = [:]
    private let lock = NSLock()

    public init(base: String = ProcessInfo.processInfo.environment["MUNA_LYRICS_URL"] ?? "https://lrclib.net",
                cache: URL = LyricsClient.defaultCache) {
        self.base = base
        self.cache = cache
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.httpAdditionalHeaders = ["User-Agent": "Muna (https://github.com/bekov0004/Muna)"]
        session = URLSession(configuration: configuration)
    }

    public static var defaultCache: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Muna/lyrics", isDirectory: true)
    }

    /// "[01:23.45] text" lines → timed lines sorted by time.
    public static func parseLrc(_ lrc: String?) -> [LyricLine] {
        guard let lrc, let stamp = try? NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#),
              let tag = try? NSRegularExpression(pattern: #"\[[^\]]*\]"#) else { return [] }
        var lines: [LyricLine] = []
        for raw in lrc.components(separatedBy: "\n") {
            let range = NSRange(raw.startIndex..., in: raw)
            let stamps = stamp.matches(in: raw, range: range)
            guard !stamps.isEmpty else { continue }
            let text = tag.stringByReplacingMatches(in: raw, range: range, withTemplate: "").trimmingCharacters(in: .whitespaces)
            for match in stamps {
                guard let minutes = Range(match.range(at: 1), in: raw).flatMap({ Double(raw[$0]) }),
                      let seconds = Range(match.range(at: 2), in: raw).flatMap({ Double(raw[$0]) }) else { continue }
                lines.append(LyricLine(t: Int(((minutes * 60 + seconds) * 1000).rounded()), text: text))
            }
        }
        // a stable sort, as JavaScript's
        return lines.enumerated().sorted { $0.element.t != $1.element.t ? $0.element.t < $1.element.t : $0.offset < $1.offset }.map(\.element)
    }

    /// The lyrics of a song (length in seconds); an empty result when there are none, nil when the
    /// service could not be reached (then nothing is cached and it is asked again next time).
    public func lookup(artist: String, title: String, album: String, length: Double) async -> LyricsResult? {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return LyricsResult() }
        let key = Self.key(artist: artist, title: title, album: album, length: length)
        lock.lock()
        let remembered = memory[key]
        lock.unlock()
        if let remembered { return remembered }
        if let cached = readCache(key) {
            remember(key, cached)
            return cached
        }
        do {
            var result = LyricsResult()
            if let found = try await fetch(artist: artist, title: title, album: album, length: length) {
                let lines = Self.parseLrc(found["syncedLyrics"] as? String)
                result = LyricsResult(lines: lines.isEmpty ? nil : lines, plain: found["plainLyrics"] as? String)
            }
            writeCache(key, result)
            remember(key, result)
            return result
        } catch {
            return nil
        }
    }

    private func remember(_ key: String, _ result: LyricsResult) {
        lock.lock()
        memory[key] = result
        lock.unlock()
    }

    static func key(artist: String, title: String, album: String, length: Double) -> String {
        // a file name from the song (FNV-1a: the same everywhere, no crypto library needed)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(artist)\n\(title)\n\(album)\n\(Int(length.rounded()))".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private func get(_ path: String, _ query: [(String, String)]) async throws -> Any? {
        var components = URLComponents(string: base + path)
        components?.queryItems = query.filter { !$0.1.isEmpty && $0.1 != "0" }.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components?.url else { return nil }
        let (data, status) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Int), Error>) in
            session.dataTask(with: url) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
                }
            }.resume()
        }
        if status == 404 { return nil }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func fetch(artist: String, title: String, album: String, length: Double) async throws -> [String: Any]? {
        let duration = String(Int(length.rounded()))
        if let exact = try await get("/api/get", [("artist_name", artist), ("track_name", title), ("album_name", album), ("duration", duration)])
            as? [String: Any], exact["syncedLyrics"] is String || exact["plainLyrics"] is String {
            return exact
        }
        let search = try await get("/api/search", [("track_name", title), ("artist_name", artist)]) as? [[String: Any]] ?? []
        return search.first { $0["syncedLyrics"] is String } ?? search.first { $0["plainLyrics"] is String }
    }

    private func readCache(_ key: String) -> LyricsResult? {
        guard let data = try? Data(contentsOf: cache.appendingPathComponent("\(key).json")) else { return nil }
        return try? JSONDecoder().decode(LyricsResult.self, from: data)
    }

    private func writeCache(_ key: String, _ result: LyricsResult) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(result) {
            try? data.write(to: cache.appendingPathComponent("\(key).json"), options: .atomic)
        }
        // keep the newest files only
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? fileManager.contentsOfDirectory(at: cache, includingPropertiesForKeys: keys)) ?? []
        guard files.count > Self.maxCacheFiles else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.maxCacheFiles) {
            try? fileManager.removeItem(at: file)
        }
    }
}
