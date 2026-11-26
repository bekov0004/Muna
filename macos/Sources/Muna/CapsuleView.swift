import AppKit
import MunaCore
import SwiftUI
import UniformTypeIdentifiers

/// Muna's colours (shared/design/colors.json "capsule", linux/stylesheet.css).
enum MunaColor {
    static let background = Color.black.opacity(0.96)
    static let tile = Color.white.opacity(0.07)
    static let tileHover = Color(red: 77 / 255, green: 141 / 255, blue: 1).opacity(0.28)
    static let text = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.45)
    static let caption = Color.white.opacity(0.55)
    static let divider = Color.white.opacity(0.08)
    static let accent = Color(red: 77 / 255, green: 141 / 255, blue: 1)
    static let muna = Color(red: 179 / 255, green: 154 / 255, blue: 1)
    static let ok = Color(red: 87 / 255, green: 227 / 255, blue: 137 / 255)
    static let warning = Color(red: 1, green: 163 / 255, blue: 72 / 255)
    static let amber = Color(red: 242 / 255, green: 169 / 255, blue: 59 / 255)
}

/// The capsule's outline, as on Linux: it hangs from the top edge, meets it with two concave
/// "ears" (fillets) and has round corners below.
struct CapsuleShape: Shape {
    var radius: CGFloat
    var ear: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, ear) }
        set {
            radius = newValue.first
            ear = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let e = min(ear, rect.width / 4, rect.height / 2)
        let left = rect.minX + e
        let right = rect.maxX - e
        let r = min(radius, rect.height / 2, (right - left) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.minY + e), control: CGPoint(x: right, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: right - r, y: rect.maxY), control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: left + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.maxY - r), control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: left, y: rect.minY + e))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: left, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Muna's butterfly (shared/brand/muna-butterfly.svg, drawn into Resources/butterfly.png).
struct ButterflyImage: View {
    var height: CGFloat = 16

    static let image: NSImage? = Bundle.main.url(forResource: "butterfly", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(72.0 / 64.0, contentMode: .fit)
                .frame(height: height)
        } else {
            Image(systemName: "sparkles").font(.system(size: height * 0.8, weight: .semibold)).foregroundColor(MunaColor.muna)
        }
    }
}

struct CapsuleView: View {
    @EnvironmentObject var model: CapsuleModel
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var tray: TrayModel
    @EnvironmentObject var localSend: LocalSendController

    var body: some View {
        let size = model.size
        let open = model.isOpen
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                CapsuleShape(radius: open ? CGFloat(preferences.cornerRadius) : 12, ear: open ? 20 : 7)
                    .fill(Color.black.opacity(preferences.backgroundOpacity))
                if open {
                    OpenPanel()
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else {
                    ClosedContent()
                        .transition(.opacity)
                }
                if model.isDropTarget {
                    CapsuleShape(radius: open ? CGFloat(preferences.cornerRadius) : 12, ear: open ? 20 : 7)
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

    /// Files dropped on the capsule: to LocalSend when that section is open, else to the Tray.
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

/// The closed capsule, as on Linux: the date on the left, the butterfly in the middle (with a notch:
/// the notch itself), the time on the right. Something going on takes both sides over: a sending
/// (an arrow, how far), the timer (its time), the music (the cover, moving bars).
struct ClosedContent: View {
    @EnvironmentObject var model: CapsuleModel
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var nowPlaying: NowPlaying
    @EnvironmentObject var timer: TimerModel
    @EnvironmentObject var localSend: LocalSendController

    private enum Activity { case sending(Int), timer, music(Track) }

    private var activity: Activity? {
        guard preferences.activitiesInCollapsed else { return nil }
        let session = localSend.session
        if session.phase == .sending {
            let total = session.transfers.reduce(Int64(0)) { $0 + $1.total }
            let sent = session.transfers.reduce(Int64(0)) { $0 + $1.sent }
            return .sending(total > 0 ? Int(100 * sent / total) : 0)
        }
        if timer.active { return .timer }
        if let track = nowPlaying.track { return .music(track) }
        return nil
    }

    var body: some View {
        let geometry = model.geometry
        let side = geometry.hasNotch ? CapsuleGeometry.earWidth - 8 : nil
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                left
                    .frame(width: side, alignment: geometry.hasNotch ? .center : .leading)
                Spacer(minLength: 0)
                if !geometry.hasNotch {
                    middle
                    Spacer(minLength: 0)
                }
                right
                    .frame(width: side, alignment: geometry.hasNotch ? .center : .trailing)
            }
            .padding(.horizontal, geometry.hasNotch ? 8 : 16)
            .frame(height: geometry.barHeight)
            // beside a notch at rest: nothing (the capsule is just the notch)
            .opacity(model.showsEars ? 1 : 0)
            if let card = model.card {
                HStack(spacing: 8) {
                    Image(systemName: card.symbol)
                        .foregroundColor(card.ok ? MunaColor.ok : MunaColor.warning)
                    Text(card.title).font(.system(size: 12, weight: .semibold)).foregroundColor(MunaColor.text)
                    Text(card.details).font(.system(size: 11)).foregroundColor(MunaColor.secondary)
                }
                .lineLimit(1)
                .padding(.horizontal, 22)
                .frame(height: CapsuleModel.cardHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { model.onTap() }
    }

    @ViewBuilder private var left: some View {
        switch activity {
        case .some(.sending):
            Image(systemName: "arrow.up.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundColor(MunaColor.accent)
        case .some(.timer):
            Image(systemName: "timer").font(.system(size: 12, weight: .bold)).foregroundColor(MunaColor.amber)
        case .some(.music(let track)):
            Artwork(url: track.artworkURL, size: max(14, model.geometry.barHeight - 12))
        case .none:
            TimelineView(.everyMinute) { context in
                Text(context.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.78))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var right: some View {
        switch activity {
        case .some(.sending(let percent)):
            Text("\(percent)%").font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundColor(.white)
        case .some(.timer):
            Text(TimerModel.text(timer.remaining))
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundColor(timer.state == .done ? MunaColor.amber : .white)
        case .some(.music):
            Bars(playing: nowPlaying.isPlaying)
        case .none:
            TimelineView(.everyMinute) { context in
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
        }
    }

    /// The butterfly, or the small "camera" circle when it is switched off.
    @ViewBuilder private var middle: some View {
        if preferences.capsuleButterfly {
            ButterflyImage(height: max(12, model.geometry.barHeight - 9))
        } else {
            Circle()
                .fill(Color(red: 8 / 255, green: 8 / 255, blue: 12 / 255))
                .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
                .overlay(Circle().fill(Color(red: 70 / 255, green: 110 / 255, blue: 1).opacity(0.55)).frame(width: 4, height: 4))
                .frame(width: 14, height: 14)
        }
    }
}

/// The open capsule: the tabs, the page dots and the gear on top; the section under them.
struct OpenPanel: View {
    @EnvironmentObject var model: CapsuleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.tab == .command || model.tab == .agent || model.tab == .mirror {
                Spacer().frame(height: model.headerHeight)
            } else {
                header
            }
            Group {
                switch model.tab {
                case .muna: MunaPage()
                case .tray: TrayPage()
                case .localSend: LocalSendPage()
                case .clipboard: ClipboardPage()
                case .alerts: AlertsPage()
                case .command: CommandView()
                case .agent: AgentPermissionView(openWindow: { model.onAgents() })
                case .mirror: MirrorLarge()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, model.geometry.topInset)
        .padding(.horizontal, model.layout.inset + 4)
        .padding(.bottom, CapsuleModel.bottomPadding)
        .foregroundColor(MunaColor.text)
    }

    private var header: some View {
            HStack(spacing: 4) {
                ForEach(PanelTab.visible) { tab in
                    TabButton(tab: tab, selected: model.tab == tab) {
                        withAnimation(.easeOut(duration: 0.15)) { model.tab = tab }
                    }
                }
                Spacer(minLength: 8)
                if model.tab == .muna && model.layout.pages.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(0..<model.layout.pages.count, id: \.self) { index in
                            Circle()
                                .fill(Color.white.opacity(index == model.pageIndex ? 0.85 : 0.22))
                                .frame(width: 5, height: 5)
                                .contentShape(Rectangle().size(width: 13, height: 13))
                                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { model.pageIndex = index } }
                        }
                    }
                    .padding(.trailing, 6)
                }
                Button { model.onSettings() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .frame(height: 24)
            .padding(.top, 6)
            .padding(.bottom, 6)
    }
}

struct TabButton: View {
    let tab: PanelTab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if tab == .muna {
                    ButterflyImage(height: 12)
                } else {
                    Image(systemName: tab.symbol).font(.system(size: 11, weight: .semibold))
                }
                Text(tab.title).font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(selected ? .white : Color.white.opacity(0.55))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(selected ? 0.13 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The Muna section: the chosen widgets side by side (thin lines between them), several pages when
/// they do not fit; a swipe or the dots change the page.
struct MunaPage: View {
    @EnvironmentObject var model: CapsuleModel

    var body: some View {
        let pages = model.layout.pages
        let slots = pages.indices.contains(model.pageIndex) ? pages[model.pageIndex] : (pages.first ?? [])
        let layout = model.layout
        HStack(alignment: .top, spacing: layout.spacing) {
            ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                WidgetView(id: slot.id)
                    .frame(width: slot.width, height: layout.height, alignment: .topLeading)
                    .overlay(alignment: .leading) {
                        if index > 0 && layout.look.dividers {
                            Rectangle().fill(MunaColor.divider).frame(width: 1).offset(x: -layout.spacing / 2)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 30).onEnded { drag in
            guard pages.count > 1 else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                if drag.translation.width < -40 { model.pageIndex = min(model.pageIndex + 1, pages.count - 1) }
                if drag.translation.width > 40 { model.pageIndex = max(model.pageIndex - 1, 0) }
            }
        })
    }
}

/// One widget by its id.
struct WidgetView: View {
    let id: String

    var body: some View {
        switch id {
        case "media": MediaWidget()
        case "calendar": CalendarWidget()
        case "mirror": MirrorWidget()
        case "timer": TimerWidget()
        case "todo": TodoWidget()
        case "notes": NotesWidget()
        case "shortcuts": ShortcutsWidget()
        case "companion": CompanionWidget()
        default: EmptyView()
        }
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
    var radius: CGFloat?

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
        .clipShape(RoundedRectangle(cornerRadius: radius ?? size * 0.22))
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
    var color = MunaColor.accent

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<3) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color)
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
