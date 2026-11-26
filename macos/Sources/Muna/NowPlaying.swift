import AppKit
import Combine
import MunaCore

/// The track a player is on.
struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    var artworkURL: URL?
    var duration: Double
    var player: MusicPlayer
}

/// The players Muna can see and steer. Every player, browsers too, through macOS's "now playing"
/// (`SystemNowPlaying`); when that is not there, Music and Spotify through Apple Events (macOS asks
/// the user once per player).
enum MusicPlayer: String, CaseIterable {
    case spotify = "Spotify"
    case music = "Music"
    /// Whatever macOS says plays now (any app).
    case system = "System"

    var bundleIdentifier: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music: return "com.apple.Music"
        case .system: return ""
        }
    }

    var isRunning: Bool {
        self != .system && !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// One line per field: state, title, artist, album, artwork URL, position (s), duration (s).
    var statusScript: String {
        switch self {
        case .spotify:
            return """
            tell application "Spotify"
                set t to current track
                return (player state as string) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (artwork url of t) & linefeed & (player position as string) & linefeed & ((duration of t) / 1000 as string)
            end tell
            """
        case .music:
            return """
            tell application "Music"
                if player state is stopped then return "stopped"
                set t to current track
                return (player state as string) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & "" & linefeed & (player position as string) & linefeed & (duration of t as string)
            end tell
            """
        case .system:
            return ""
        }
    }

    func command(_ verb: String) -> String {
        "tell application \"\(rawValue)\" to \(verb)"
    }
}

/// Follows the music: which player plays what, and steers it.
final class NowPlaying: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    /// The words of the song, when "show lyrics" is on and lrclib.net knows them.
    @Published private(set) var lyrics: LyricsResult?
    private let lyricsClient = LyricsClient()

    /// When `position` was read: while playing, the position now is position + the time since.
    private(set) var positionTime = Date()

    private var timer: Timer?

    /// Every change of the track (for the capsule's size).
    var trackPublisher: Published<Track?>.Publisher { $track }
    var playingPublisher: Published<Bool>.Publisher { $isPlaying }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private var asking = false

    /// Asks the players now (the panel just opened, a button was pressed): macOS's "now playing"
    /// first (every player), else Music and Spotify themselves.
    func refresh() {
        guard SystemNowPlaying.isAvailable else { askPlayers(); return }
        guard !asking else { return }
        asking = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let now = SystemNowPlaying.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.asking = false
                guard let now else { self.askPlayers(); return }
                let track = Track(title: now.title, artist: now.artist, album: now.album, artworkURL: now.artwork,
                                  duration: now.duration, player: .system)
                if track != self.track {
                    self.track = track
                    self.lookUpLyrics()
                }
                self.isPlaying = now.playing
                self.position = now.elapsed
                self.positionTime = Date()
            }
        }
    }

    private func askPlayers() {
        // A playing player wins over a paused one; Spotify first when both play.
        var best: (track: Track, playing: Bool, position: Double)?
        for player in MusicPlayer.allCases where player.isRunning {
            guard let lines = run(player.statusScript)?.components(separatedBy: "\n"), lines.count >= 7 else { continue }
            let state = lines[0]
            guard state == "playing" || state == "paused" else { continue }
            let track = Track(title: lines[1], artist: lines[2], album: lines[3],
                              artworkURL: URL(string: lines[4]).flatMap { $0.scheme == nil ? nil : $0 },
                              duration: Self.number(lines[6]), player: player)
            let candidate = (track: track, playing: state == "playing", position: Self.number(lines[5]))
            if best == nil || (candidate.playing && !(best?.playing ?? false)) {
                best = candidate
            }
        }
        if best?.track != track {
            track = best?.track
            lookUpLyrics()
        }
        isPlaying = best?.playing ?? false
        position = best?.position ?? 0
        positionTime = Date()
    }

    private func lookUpLyrics() {
        lyrics = nil
        guard let track, Preferences.shared.showLyrics else { return }
        let client = lyricsClient
        Task { [weak self] in
            let found = await client.lookup(artist: track.artist, title: track.title, album: track.album, length: track.duration)
            DispatchQueue.main.async {
                if self?.track == track { self?.lyrics = found }
            }
        }
    }

    /// The line sung now, if the lyrics are timed.
    func lyricLine(at date: Date = Date()) -> String? {
        guard let line = lyrics?.line(at: currentPosition(at: date)), !line.text.isEmpty else { return nil }
        return line.text
    }

    /// Where the track is now (between two questions to the player too).
    func currentPosition(at date: Date = Date()) -> Double {
        guard let track else { return 0 }
        let now = position + (isPlaying ? date.timeIntervalSince(positionTime) : 0)
        return track.duration > 0 ? min(max(0, now), track.duration) : max(0, now)
    }

    /// Jumps to a moment of the track (seconds).
    func seek(to seconds: Double) {
        guard let player = track?.player else { return }
        if player == .system { SystemNowPlaying.send("seek \(seconds)") }
        else { _ = run(player.command("set player position to \(Int(seconds.rounded()))")) }
        position = seconds
        positionTime = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    private func send(_ verb: String) {
        guard let player = track?.player else { return }
        if player == .system {
            SystemNowPlaying.send(["playpause": "playpause", "next track": "next", "previous track": "previous"][verb] ?? verb)
        } else {
            _ = run(player.command(verb))
        }
        // the player needs a moment to answer with its new state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    /// AppleScript runs on the main thread (NSAppleScript is not made for other threads).
    private func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }

    /// AppleScript writes decimals with the user's decimal separator.
    private static func number(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
    }
}

/// macOS's "now playing" of any player (Linux's MPRIS). macOS gives it to Apple's own programs only
/// since 15.4, so Muna asks /usr/bin/perl (one of them) to load Muna's small library
/// (Resources/MunaNowPlaying.dylib, macos/Helpers/NowPlayingHelper.m) and read it.
enum SystemNowPlaying {
    struct Now {
        let title, artist, album: String
        let duration, elapsed: Double
        let playing: Bool
        let app: String
        let artwork: URL?
    }

    static var library: String? {
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("MunaNowPlaying.dylib").path,
              FileManager.default.fileExists(atPath: path), FileManager.default.fileExists(atPath: "/usr/bin/perl") else { return nil }
        return path
    }

    /// Turned off after it gives nothing usable several times in a row (a macOS that closed this door too).
    private static var failures = 0
    static var isAvailable: Bool { library != nil && failures < 5 }

    private static let script = "use DynaLoader; my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die; "
        + "my $s = DynaLoader::dl_find_symbol($h, $ARGV[1]) or die; DynaLoader::dl_install_xsub('main::f', $s); f();"

    private static func perl(_ symbol: String, environment: [String: String] = [:]) -> String? {
        guard let library else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", script, library, symbol]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    /// What plays now; nil when nothing does (or macOS said nothing).
    static func read() -> Now? {
        guard let line = perl("muna_now_playing"), let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { failures += 1; return nil }
        guard let title = json["title"] as? String, !title.isEmpty else { return nil }
        failures = 0
        let artwork = (json["artwork"] as? String).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return Now(title: title, artist: json["artist"] as? String ?? "", album: json["album"] as? String ?? "",
                   duration: json["duration"] as? Double ?? 0, elapsed: json["elapsed"] as? Double ?? 0,
                   playing: json["playing"] as? Bool ?? false, app: json["app"] as? String ?? "", artwork: artwork)
    }

    /// "playpause", "next", "previous", "play", "pause" or "seek <seconds>".
    static func send(_ command: String) {
        DispatchQueue.global(qos: .userInitiated).async { _ = perl("muna_send", environment: ["MUNA_COMMAND": command]) }
    }
}
