import AppKit
import SwiftUI

/// The window of the capsule: borderless, above the menu bar, on every Space and over full-screen
/// apps, never taking the focus from the app in front.
final class CapsulePanel: NSPanel {
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

    // text fields (notes, groups) will need the keyboard
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Where the capsule sits on a screen: under the camera notch (same size, so it looks like the notch
/// itself) or, on a screen without one, a small pill in the middle of the menu bar.
struct CapsuleGeometry: Equatable {
    var screenFrame: CGRect
    var closedSize: CGSize
    var hasNotch: Bool

    static let openSize = CGSize(width: 640, height: 236)

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

/// What the capsule shows, shared with its SwiftUI views.
final class CapsuleModel: ObservableObject {
    @Published var isOpen = false
    @Published var geometry: CapsuleGeometry
    let nowPlaying: NowPlaying

    init(geometry: CapsuleGeometry, nowPlaying: NowPlaying) {
        self.geometry = geometry
        self.nowPlaying = nowPlaying
    }

    /// The closed capsule grows "ears" left and right of the notch while music plays.
    var closedSize: CGSize {
        var size = geometry.closedSize
        if nowPlaying.track != nil {
            size.width += 2 * CapsuleMetrics.earWidth
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
}

/// Shows the capsule and opens it under the pointer. The window is only as big as what is drawn
/// (closed: the notch, open: the panel), so it never catches clicks meant for the menu bar.
final class CapsuleController {
    private let panel = CapsulePanel()
    private let model: CapsuleModel
    private var pending: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    private var trackObserver: Any?

    init(nowPlaying: NowPlaying) {
        let screen = NSScreen.screens.first ?? NSScreen.main!
        model = CapsuleModel(geometry: CapsuleGeometry(screen: screen), nowPlaying: nowPlaying)
        let tracking = HoverView { [weak self] inside in self?.pointer(inside: inside) }
        let host = NSHostingView(rootView: CapsuleView().environmentObject(model).environmentObject(nowPlaying))
        host.translatesAutoresizingMaskIntoConstraints = false
        tracking.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: tracking.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: tracking.trailingAnchor),
            host.topAnchor.constraint(equalTo: tracking.topAnchor),
            host.bottomAnchor.constraint(equalTo: tracking.bottomAnchor),
        ])
        panel.contentView = tracking
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }
        // music starting or stopping changes the closed size (the ears)
        trackObserver = nowPlaying.onTrackChange { [weak self] in self?.placeClosed() }
    }

    func show() {
        placeClosed()
        panel.orderFrontRegardless()
    }

    private func screensChanged() {
        let screen = NSScreen.screens.first ?? NSScreen.main!
        model.geometry = CapsuleGeometry(screen: screen)
        model.isOpen ? panel.setFrame(model.geometry.frame(for: CapsuleGeometry.openSize), display: true) : placeClosed()
    }

    private func placeClosed() {
        guard !model.isOpen else { return }
        panel.setFrame(model.geometry.frame(for: model.closedSize), display: true)
    }

    private func pointer(inside: Bool) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in inside ? self?.open() : self?.close() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? CapsuleMetrics.openDelay : CapsuleMetrics.closeDelay), execute: work)
    }

    private func open() {
        guard !model.isOpen else { return }
        // the window takes the open size at once; the drawing grows into it
        panel.setFrame(model.geometry.frame(for: CapsuleGeometry.openSize), display: true)
        withAnimation(CapsuleMetrics.animation) { model.isOpen = true }
        model.nowPlaying.refresh()
    }

    private func close() {
        guard model.isOpen else { return }
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
