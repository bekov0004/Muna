import SwiftUI

/// Muna's colours (shared/design/colors.json, "capsule").
enum MunaColor {
    static let background = Color.black
    static let tile = Color.white.opacity(0.07)
    static let text = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.45)
    static let caption = Color.white.opacity(0.55)
    static let accent = Color(red: 0x4d / 255, green: 0x8d / 255, blue: 0xff / 255)
}

/// The black shape hanging from the top edge: square top corners (it continues the screen's edge),
/// round bottom ones.
struct CapsuleShape: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct CapsuleView: View {
    @EnvironmentObject var model: CapsuleModel
    @EnvironmentObject var nowPlaying: NowPlaying

    var body: some View {
        let size = model.isOpen ? CapsuleGeometry.openSize : model.closedSize
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                CapsuleShape(radius: model.isOpen ? 28 : 10)
                    .fill(MunaColor.background)
                if model.isOpen {
                    OpenPanel()
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                } else {
                    ClosedContent()
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The closed capsule: the time, or while music plays its cover on the left and moving bars on the
/// right (beside the notch, where something can be seen).
struct ClosedContent: View {
    @EnvironmentObject var model: CapsuleModel
    @EnvironmentObject var nowPlaying: NowPlaying

    var body: some View {
        HStack(spacing: 0) {
            if let track = nowPlaying.track {
                Artwork(url: track.artworkURL, size: model.geometry.closedSize.height - 10)
                    .frame(width: CapsuleMetrics.earWidth)
                Spacer(minLength: 0)
                Bars(playing: nowPlaying.isPlaying)
                    .frame(width: CapsuleMetrics.earWidth)
            } else if !model.geometry.hasNotch {
                Spacer(minLength: 0)
                TimelineView(.everyMinute) { context in
                    Text(context.date, style: .time)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundColor(MunaColor.text)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// The open panel: the date and time, and the music.
struct OpenPanel: View {
    @EnvironmentObject var nowPlaying: NowPlaying

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelineView(.everyMinute) { context in
                HStack(alignment: .firstTextBaseline) {
                    Text(context.date, style: .time)
                        .font(.system(size: 26, weight: .bold).monospacedDigit())
                    Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(MunaColor.secondary)
                    Spacer()
                }
                .foregroundColor(MunaColor.text)
            }
            MusicCard()
            Spacer(minLength: 0)
        }
        .padding(.top, 38)
        .padding(.horizontal, 26)
        .padding(.bottom, 18)
    }
}

struct MusicCard: View {
    @EnvironmentObject var nowPlaying: NowPlaying

    var body: some View {
        HStack(spacing: 14) {
            if let track = nowPlaying.track {
                Artwork(url: track.artworkURL, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(track.artist).font(.system(size: 12)).foregroundColor(MunaColor.secondary).lineLimit(1)
                    if track.duration > 0 {
                        ProgressView(value: min(nowPlaying.position, track.duration), total: track.duration)
                            .progressViewStyle(.linear)
                            .tint(MunaColor.accent)
                            .padding(.top, 4)
                    }
                }
                .foregroundColor(MunaColor.text)
                Spacer(minLength: 8)
                HStack(spacing: 18) {
                    ControlButton(symbol: "backward.fill") { nowPlaying.previous() }
                    ControlButton(symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 22) { nowPlaying.playPause() }
                    ControlButton(symbol: "forward.fill") { nowPlaying.next() }
                }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 20))
                    .frame(width: 64, height: 64)
                    .background(RoundedRectangle(cornerRadius: 12).fill(MunaColor.tile))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nothing is playing").font(.system(size: 14, weight: .semibold))
                    Text("Music and Spotify show up here").font(.system(size: 12)).foregroundColor(MunaColor.secondary)
                }
                Spacer()
            }
        }
        .foregroundColor(MunaColor.text)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18).fill(MunaColor.tile))
    }
}

struct ControlButton: View {
    let symbol: String
    var size: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(MunaColor.text)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A track's cover (Spotify gives one), or a note on a tile.
struct Artwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }

    private var placeholder: some View {
        ZStack {
            MunaColor.tile
            Image(systemName: "music.note").font(.system(size: size * 0.45)).foregroundColor(MunaColor.secondary)
        }
    }
}

/// Three bars that move while the music plays.
struct Bars: View {
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<3) { index in
                    let level = playing ? 0.35 + 0.65 * abs(sin(t * 5 + Double(index) * 1.7)) : 0.3
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(MunaColor.accent)
                        .frame(width: 3, height: 14 * level)
                }
            }
        }
    }
}
