import AppKit
import Combine
import SwiftUI

/// The window of the capsule: borderless, above the menu bar, on every Space and over full-screen
/// apps, never taking the focus from the app in front (it takes the keyboard only for its text fields).
final class CapsulePanel: NSPanel {
    var onResignKey: () -> Void = {}

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey()
    }
}

/// Where the capsule sits on a screen: under the camera notch (same size, so it looks like the notch
/// itself) or, on a screen without one, a small pill in the middle of the menu bar.
struct CapsuleGeometry: Equatable {
    var screenFrame: CGRect
    var closedSize: CGSize
    var hasNotch: Bool

    static let openSize = CGSize(width: 700, height: 330)

    init(screen: NSScreen) {
        screenFrame = screen.frame
        let notchHeight = screen.safeAreaInsets.top
        if notchHeight > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            closedSize = CGSize(width: screen.frame.width - left.width - right.width, height: notchHeight)
        } else {
            hasNotch = false
            let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
            closedSize = CGSize(width: 200, height: max(24, menuBar))
        }
    }

    /// A window of this size hanging from the top edge, centred.
    func frame(for size: CGSize) -> CGRect {
        CGRect(x: (screenFrame.midX - size.width / 2).rounded(), y: screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }
}

/// The pages of the open panel.
enum PanelTab: String, CaseIterable, Identifiable {
    case home, tray, localSend, clipboard, notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Muna"
        case .tray: return "Tray"
        case .localSend: return "LocalSend"
        case .clipboard: return "Clipboard"
        case .notes: return "Notes"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "sparkles"
        case .tray: return "tray.and.arrow.down"
        case .localSend: return "wifi"
        case .clipboard: return "doc.on.clipboard"
        case .notes: return "checklist"
        }
    }
}

/// A short message the closed capsule shows for a few seconds.
struct CapsuleCard: Equatable {
    var title: String
    var details: String
    var symbol: String
    var ok: Bool
}

/// What the capsule shows, shared with its SwiftUI views.
final class CapsuleModel: ObservableObject {
    @Published var isOpen = false
    @Published var geometry: CapsuleGeometry
    @Published var tab = PanelTab.home
    /// A text field has the keyboard: the capsule stays open.
    @Published var isEditing = false
    /// Files are dragged over the capsule: it opens to take them.
    @Published var isDropTarget = false
    @Published var card: CapsuleCard?
    let nowPlaying: NowPlaying

    init(geometry: CapsuleGeometry, nowPlaying: NowPlaying) {
        self.geometry = geometry
        self.nowPlaying = nowPlaying
    }

    static let cardHeight: CGFloat = 34

    /// The closed capsule grows "ears" beside the notch while music plays, and a line under it for a card.
    var closedSize: CGSize {
        var size = geometry.closedSize
        if nowPlaying.track != nil {
            size.width += 2 * CapsuleMetrics.earWidth
        }
        if card != nil {
            size.width = max(size.width, 380)
            size.height += Self.cardHeight
        }
        return size
    }
}

enum CapsuleMetrics {
    static let earWidth: CGFloat = 34
    static let openDelay: TimeInterval = 0.12
    static let closeDelay: TimeInterval = 0.45
    static let animation = Animation.spring(response: 0.38, dampingFraction: 0.82)
    static let animationTime: TimeInterval = 0.42
    static let cardTime: TimeInterval = 4
}

/// Shows the capsule and opens it under the pointer. The window is only as big as what is drawn
/// (closed: the notch, open: the panel), so it never catches clicks meant for the menu bar.
final class CapsuleController {
    let model: CapsuleModel
    private let panel = CapsulePanel()
    private let app: AppState
    private var hovering = false
    private var pending: DispatchWorkItem?
    private var cardTimer: DispatchWorkItem?
    private var observers: [AnyCancellable] = []
    private var screenObserver: NSObjectProtocol?

    init(app: AppState) {
        self.app = app
        let screen = NSScreen.screens.first ?? NSScreen.main!
        model = CapsuleModel(geometry: CapsuleGeometry(screen: screen), nowPlaying: app.nowPlaying)
        let tracking = HoverView { [weak self] inside in self?.pointer(inside: inside) }
        let root = CapsuleView()
            .environmentObject(model)
            .environmentObject(app.nowPlaying)
            .environmentObject(app.notes)
            .environmentObject(app.todo)
            .environmentObject(app.tray)
            .environmentObject(app.clipboard)
            .environmentObject(app.calendar)
            .environmentObject(app.localSend)
        let host = NSHostingView(rootView: root)
        host.translatesAutoresizingMaskIntoConstraints = false
        tracking.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: tracking.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: tracking.trailingAnchor),
            host.topAnchor.constraint(equalTo: tracking.topAnchor),
            host.bottomAnchor.constraint(equalTo: tracking.bottomAnchor),
        ])
        panel.contentView = tracking
        panel.onResignKey = { [weak self] in
            self?.model.isEditing = false
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }

        // what keeps the capsule open, or changes its closed size
        model.$isEditing.dropFirst().sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &observers)
        model.$isDropTarget.dropFirst().sink { [weak self] targeted in
            if targeted { self?.openNow() } else { self?.scheduleUpdate() }
        }.store(in: &observers)
        app.localSend.incomingPublisher.dropFirst().sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &observers)
        model.$card.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.placeClosed() }
        }.store(in: &observers)
        app.nowPlaying.trackPublisher.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.placeClosed() }
        }.store(in: &observers)
        app.localSend.notify = { [weak self] title, details, ok in
            self?.showCard(CapsuleCard(title: title, details: details, symbol: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", ok: ok))
        }
        app.localSend.onIncoming = { [weak self] in
            self?.model.tab = .localSend
            self?.openNow()
        }
    }

    func show() {
        placeClosed()
        panel.orderFrontRegardless()
    }

    /// Opens the panel on a page (from the menu-bar menu).
    func open(on tab: PanelTab) {
        model.tab = tab
        openNow()
        scheduleUpdate()
    }

    /// A short message in the closed capsule (when it is open, the panel shows things itself).
    func showCard(_ card: CapsuleCard) {
        guard !model.isOpen else { return }
        withAnimation(CapsuleMetrics.animation) { model.card = card }
        cardTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(CapsuleMetrics.animation) { self?.model.card = nil }
        }
        cardTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CapsuleMetrics.cardTime, execute: work)
    }

    private var keepsOpen: Bool {
        hovering || model.isEditing || model.isDropTarget || app.localSend.incoming?.state == .asking
    }

    private func screensChanged() {
        let screen = NSScreen.screens.first ?? NSScreen.main!
        model.geometry = CapsuleGeometry(screen: screen)
        if model.isOpen {
            panel.setFrame(model.geometry.frame(for: CapsuleGeometry.openSize), display: true)
        } else {
            placeClosed()
        }
    }

    private func placeClosed() {
        guard !model.isOpen else { return }
        panel.setFrame(model.geometry.frame(for: model.closedSize), display: true)
    }

    private func pointer(inside: Bool) {
        hovering = inside
        scheduleUpdate()
    }

    /// Opens or closes after a short wait (a pointer passing by does nothing).
    private func scheduleUpdate() {
        pending?.cancel()
        let open = keepsOpen
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.keepsOpen { self.openNow() } else { self.close() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (open ? CapsuleMetrics.openDelay : CapsuleMetrics.closeDelay), execute: work)
    }

    private func openNow() {
        guard !model.isOpen else { return }
        cardTimer?.cancel()
        model.card = nil
        // the window takes the open size at once; the drawing grows into it
        panel.setFrame(model.geometry.frame(for: CapsuleGeometry.openSize), display: true)
        withAnimation(CapsuleMetrics.animation) { model.isOpen = true }
        app.panelOpened(on: model.tab)
    }

    private func close() {
        guard model.isOpen else { return }
        if panel.isKeyWindow {
            // give the keyboard back to the app in front: out and in again, without becoming key
            model.isEditing = false
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        withAnimation(CapsuleMetrics.animation) { model.isOpen = false }
        // the window shrinks when the drawing has
        DispatchQueue.main.asyncAfter(deadline: .now() + CapsuleMetrics.animationTime) { [weak self] in
            self?.placeClosed()
        }
    }
}

/// Tells when the pointer enters or leaves the capsule, whether Muna is the active app or not
/// (SwiftUI's hover only works in the active app).
final class HoverView: NSView {
    private let onChange: (Bool) -> Void
    private var area: NSTrackingArea?

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { onChange(true) }
    override func mouseExited(with event: NSEvent) { onChange(false) }
}
