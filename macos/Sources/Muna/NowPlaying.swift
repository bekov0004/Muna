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

/// The players Muna can see and steer. macOS gives apps no common "now playing" any more
/// (MediaRemote is closed to other apps since macOS 15.4), so Muna asks the players themselves
/// through Apple Events; macOS asks the user once per player.
enum MusicPlayer: String, CaseIterable {
    case spotify = "Spotify"
    case music = "Music"

    var bundleIdentifier: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music: return "com.apple.Music"
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
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

    /// Asks the players now (the panel just opened, a button was pressed).
    func refresh() {
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
        _ = run(player.command("set player position to \(Int(seconds.rounded()))"))
        position = seconds
        positionTime = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    private func send(_ verb: String) {
        guard let player = track?.player else { return }
        _ = run(player.command(verb))
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
