import AppKit
import MunaCore
import SwiftUI
import UniformTypeIdentifiers

/// Muna's colours (shared/design/colors.json, "capsule").
enum MunaColor {
    static let background = Color.black
    static let tile = Color.white.opacity(0.07)
    static let tileHover = Color(red: 77 / 255, green: 141 / 255, blue: 1).opacity(0.28)
    static let text = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.45)
    static let caption = Color.white.opacity(0.55)
    static let accent = Color(red: 77 / 255, green: 141 / 255, blue: 1)
    static let muna = Color(red: 179 / 255, green: 154 / 255, blue: 1)
    static let ok = Color(red: 87 / 255, green: 227 / 255, blue: 137 / 255)
    static let warning = Color(red: 1, green: 163 / 255, blue: 72 / 255)
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
    @EnvironmentObject var tray: TrayModel
    @EnvironmentObject var localSend: LocalSendController

    var body: some View {
        let size = model.isOpen ? CapsuleGeometry.openSize : model.closedSize
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                CapsuleShape(radius: model.isOpen ? 28 : 10)
                    .fill(MunaColor.background)
                if model.isOpen {
                    OpenPanel()
                        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                } else {
                    ClosedContent()
                        .transition(.opacity)
                }
                if model.isDropTarget {
                    CapsuleShape(radius: model.isOpen ? 28 : 10)
                        .stroke(MunaColor.accent, lineWidth: 2)
                }
            }
            .frame(width: size.width, height: size.height)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDrop(of: [UTType.fileURL], isTargeted: $model.isDropTarget) { providers in
            receive(providers)
            return true
        }
    }

    /// Files dropped on the capsule: to LocalSend when that page is open, else to the Tray.
    private func receive(_ providers: [NSItemProvider]) {
        let toLocalSend = model.isOpen && model.tab == .localSend
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async {
                    if toLocalSend {
                        localSend.session.offer([url])
                    } else {
                        tray.add([url])
                        model.tab = .tray
                    }
                }
            }
        }
    }
}

/// The closed capsule: the time (without a notch), or while music plays its cover on the left and
/// moving bars on the right (beside the notch, where they can be seen); a card under it.
struct ClosedContent: View {
    @EnvironmentObject var model: CapsuleModel
    @EnvironmentObject var nowPlaying: NowPlaying

    var body: some View {
        VStack(spacing: 0) {
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
            .frame(height: model.geometry.closedSize.height)
            if let card = model.card {
                HStack(spacing: 8) {
                    Image(systemName: card.symbol)
                        .foregroundColor(card.ok ? MunaColor.ok : MunaColor.warning)
                    Text(card.title).font(.system(size: 12, weight: .semibold)).foregroundColor(MunaColor.text)
                    Text(card.details).font(.system(size: 11)).foregroundColor(MunaColor.secondary)
                }
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(height: CapsuleModel.cardHeight)
            }
        }
    }
}

/// The open panel: the pages' tabs on top, the page under them.
struct OpenPanel: View {
    @EnvironmentObject var model: CapsuleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(PanelTab.allCases) { tab in
                    TabButton(tab: tab, selected: model.tab == tab) {
                        withAnimation(.easeOut(duration: 0.15)) { model.tab = tab }
                    }
                }
                Spacer()
            }
            Group {
                switch model.tab {
                case .home: HomePage()
                case .tray: TrayPage()
                case .localSend: LocalSendPage()
                case .clipboard: ClipboardPage()
                case .notes: NotesPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // below the notch / menu bar
        .padding(.top, model.geometry.closedSize.height + 6)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .foregroundColor(MunaColor.text)
    }
}

struct TabButton: View {
    let tab: PanelTab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol).font(.system(size: 11, weight: .semibold))
                Text(tab.title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(selected ? .white : MunaColor.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(selected ? Color.white.opacity(0.12) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// --- small pieces used by the pages ------------------------------------------------------------

/// "CAPTION" on the left, small buttons on the right.
struct Caption<Trailing: View>: View {
    let text: String
    let trailing: () -> Trailing

    init(_ text: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .kerning(0.6)
                .foregroundColor(MunaColor.caption)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension Caption where Trailing == EmptyView {
    init(_ text: String) {
        self.init(text) { EmptyView() }
    }
}

/// A small text button of a caption.
struct Pill: View {
    let label: String
    var accent = false
    var active = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(accent || active ? .white : MunaColor.text.opacity(0.82))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(accent ? MunaColor.accent : active ? MunaColor.accent.opacity(0.6) : Color.white.opacity(0.09)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

/// A one-line text field of the capsule: while it has the keyboard, the capsule stays open.
struct CapsuleField: View {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void
    @EnvironmentObject var model: CapsuleModel
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(focused ? 0.14 : 0.08)))
            .focused($focused)
            .onSubmit(onSubmit)
            .onExitCommand { focused = false }
            .onChange(of: focused) { model.isEditing = $0 }
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

/// A little round button with an icon (remove, pin ...).
struct IconButton: View {
    let symbol: String
    var tint = MunaColor.secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .contentShape(Circle())
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
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(MunaColor.accent)
                        .frame(width: 3, height: 14 * Self.level(t, index, playing))
                }
            }
        }
    }

    static func level(_ t: TimeInterval, _ index: Int, _ playing: Bool) -> CGFloat {
        playing ? 0.35 + 0.65 * abs(sin(t * 5 + Double(index) * 1.7)) : 0.3
    }
}

/// The Finder's icon of a file.
struct FileIcon: View {
    let url: URL
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: size, height: size)
    }
}

func sizeText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
