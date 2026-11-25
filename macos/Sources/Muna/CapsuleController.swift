import AppKit
import Combine
import MunaCore
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

/// Where the capsule sits on a screen. With a camera notch the capsule is the notch itself, grown
/// by an "ear" on each side (where the date and the time are, as in the middle of GNOME's top bar);
/// without one it is a small pill in the middle of the menu bar, like Muna on Linux.
struct CapsuleGeometry: Equatable {
    var screenFrame: CGRect
    var hasNotch: Bool
    var notchWidth: CGFloat
    /// The menu bar's height (with a notch: the notch's).
    var barHeight: CGFloat

    static let earWidth: CGFloat = 80
    static let pillWidth: CGFloat = 200
    static let hoverGrow: CGFloat = 14

    init(screen: NSScreen) {
        screenFrame = screen.frame
        let notchHeight = screen.safeAreaInsets.top
        if notchHeight > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            notchWidth = screen.frame.width - left.width - right.width
            barHeight = notchHeight
        } else {
            hasNotch = false
            notchWidth = 0
            barHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
        }
    }

    /// The closed capsule.
    var closedSize: CGSize {
        CGSize(width: hasNotch ? notchWidth + 2 * Self.earWidth : Self.pillWidth, height: barHeight)
    }

    /// Where the open panel's content starts: under the notch, or at the top.
    var topInset: CGFloat { hasNotch ? barHeight : 0 }

    /// A window of this size hanging from the top edge, centred.
    func frame(for size: CGSize) -> CGRect {
        CGRect(x: (screenFrame.midX - size.width / 2).rounded(), y: screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }
}

/// The sections of the open capsule, as on Linux.
enum PanelTab: String, CaseIterable, Identifiable {
    case muna, tray, localSend, clipboard, alerts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .muna: return "Muna"
        case .tray: return "Tray"
        case .localSend: return "LocalSend"
        case .clipboard: return "Clipboard"
        case .alerts: return "Alerts"
        }
    }

    /// SF Symbol (Muna's own tab shows the butterfly instead).
    var symbol: String {
        switch self {
        case .muna: return "sparkles"
        case .tray: return "tray.and.arrow.down"
        case .localSend: return "wifi"
        case .clipboard: return "doc.on.clipboard"
        case .alerts: return "bell"
        }
    }

    /// The height of the section under the tabs.
    var bodyHeight: CGFloat {
        switch self {
        case .muna, .tray: return PanelLayout.rowHeight
        case .localSend: return 138
        case .clipboard, .alerts: return 236
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

/// What the pages remember while the panel is open: drafts, the search, the group being named ...
/// (kept here, not in @State: with the command line tools alone, newer SDKs cannot build @State,
/// which became a macro whose plugin only comes with Xcode).
final class PanelState: ObservableObject {
    @Published var noteDraft = ""
    @Published var todoDraft = ""
    @Published var clipboardQuery = ""
    @Published var copiedClip: String?
    @Published var namingGroup = false
    @Published var groupName = ""
    @Published var groupNameError = ""
    @Published var confirmDeleteGroup: String?
    @Published var hoveredTrayFile: URL?
    /// The day the calendar shows.
    @Published var calendarDay = Date()
}

/// What the capsule shows, shared with its SwiftUI views.
final class CapsuleModel: ObservableObject {
    @Published var isOpen = false
    @Published var isHovering = false
    @Published var geometry: CapsuleGeometry
    @Published var tab = PanelTab.muna
    @Published var pageIndex = 0
    @Published private(set) var layout: PanelLayout
    /// A text field has the keyboard: the capsule stays open.
    @Published var isEditing = false
    /// Files are dragged over the capsule: it opens to take them.
    @Published var isDropTarget = false
    @Published var card: CapsuleCard?
    /// A click on the closed capsule; the gear.
    var onTap: () -> Void = {}
    var onSettings: () -> Void = {}

    static let headerHeight: CGFloat = 36
    static let bottomPadding: CGFloat = 12
    static let cardHeight: CGFloat = 34

    init(geometry: CapsuleGeometry) {
        self.geometry = geometry
        layout = Self.makeLayout(geometry)
    }

    func refreshLayout() {
        layout = Self.makeLayout(geometry)
        if pageIndex >= layout.pages.count { pageIndex = 0 }
    }

    private static func makeLayout(_ geometry: CapsuleGeometry) -> PanelLayout {
        let preferences = Preferences.shared
        // with a notch, the tabs must clear it: never narrower than the closed capsule and a bit
        let atLeast = geometry.hasNotch ? geometry.closedSize.width + 2 * CapsuleGeometry.earWidth : 0
        return PanelLayout(screenWidth: geometry.screenFrame.width, widgets: preferences.enabledWidgets,
                           cells: { preferences.cells($0) }, atLeast: atLeast)
    }

    var closedSize: CGSize {
        var size = geometry.closedSize
        if isHovering && !isOpen { size.width += CapsuleGeometry.hoverGrow }
        if card != nil {
            size.width = max(size.width, 380)
            size.height += Self.cardHeight
        }
        return size
    }

    var openSize: CGSize {
        CGSize(width: layout.width,
               height: geometry.topInset + Self.headerHeight + tab.bodyHeight + Self.bottomPadding)
    }

    var size: CGSize { isOpen ? openSize : closedSize }
}

enum CapsuleMetrics {
    static let animation = Animation.spring(response: 0.38, dampingFraction: 0.82)
    static let animationTime: TimeInterval = 0.42
    static let cardTime: TimeInterval = 4
}

/// Shows the capsule and opens it under the pointer. The window is only as big as what is drawn
/// (closed: the notch and its ears, open: the panel), so it never catches clicks meant for the menu bar.
final class CapsuleController {
    let model: CapsuleModel
    private let panel = CapsulePanel()
    private let app: AppState
    private let preferences = Preferences.shared
    private var hovering = false
    /// Opened by a command (a click, the menu, starting Muna again): stays open until the pointer has
    /// come and gone, or a while if it never comes.
    private var pinned = false
    private var pinTimer: DispatchWorkItem?
    private var pending: DispatchWorkItem?
    private var cardTimer: DispatchWorkItem?
    private var observers: [AnyCancellable] = []
    private var screenObserver: NSObjectProtocol?
    private var clickMonitor: Any?

    init(app: AppState) {
        self.app = app
        let screen = NSScreen.screens.first ?? NSScreen.main!
        model = CapsuleModel(geometry: CapsuleGeometry(screen: screen))
        let tracking = HoverView { [weak self] inside in self?.pointer(inside: inside) }
        let root = CapsuleView()
            .environmentObject(model)
            .environmentObject(PanelState())
            .environmentObject(preferences)
            .environmentObject(app.nowPlaying)
            .environmentObject(app.notes)
            .environmentObject(app.todo)
            .environmentObject(app.tray)
            .environmentObject(app.clipboard)
            .environmentObject(app.calendar)
            .environmentObject(app.localSend)
            .environmentObject(app.timer)
            .environmentObject(app.alerts)
            .environmentObject(app.camera)
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

        // what keeps the capsule open, or changes its size
        model.$isEditing.dropFirst().sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &observers)
        model.$isDropTarget.dropFirst().sink { [weak self] targeted in
            if targeted { self?.openNow() } else { self?.scheduleUpdate() }
        }.store(in: &observers)
        model.$tab.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeOpen() }
        }.store(in: &observers)
        model.$card.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.placeClosed() }
        }.store(in: &observers)
        preferences.$enabledWidgets.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.layoutChanged() }
        }.store(in: &observers)
        preferences.$widgetCells.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.layoutChanged() }
        }.store(in: &observers)
        app.localSend.incomingPublisher.dropFirst().sink { [weak self] incoming in
            self?.incomingChanged(incoming)
        }.store(in: &observers)

        app.localSend.notify = { [weak self] title, details, ok in
            self?.tell(title, details, symbol: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", ok: ok)
        }
        app.localSend.onIncoming = { [weak self] in
            self?.model.tab = .localSend
            self?.openNow()
        }
        app.timer.onFinished = { [weak self] in
            self?.tell("Time is up", "The timer ended", symbol: "timer", ok: true)
        }
        model.onTap = { [weak self] in
            guard let self else { return }
            self.open(on: self.model.tab)
        }

        // a click outside closes the capsule that stays open by itself (opened by a command, or
        // "Collapse when the pointer leaves" off)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.model.isOpen, !self.hovering else { return }
            self.pinned = false
            if !self.preferences.autoCollapse || !self.keepsOpen { self.close() }
        }
    }

    func show() {
        placeClosed()
        panel.orderFrontRegardless()
        // say where Muna is: it has no window and no Dock icon
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            let place = self.model.geometry.hasNotch ? "Point at the notch or click it" : "Point at the capsule or click it"
            self.showCard(CapsuleCard(title: "Muna is here", details: place, symbol: "sparkles", ok: true))
        }
    }

    /// Opens the panel on a section (a click, the menu, starting Muna again).
    func open(on tab: PanelTab) {
        model.tab = tab
        pinned = true
        pinTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering else { return }
            self.pinned = false
            self.scheduleUpdate()
        }
        pinTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        openNow()
    }

    /// Something happened: a card in the closed capsule, and a line in the Alerts section.
    func tell(_ title: String, _ details: String, symbol: String, ok: Bool) {
        app.alerts.add(title, details, symbol: symbol, ok: ok)
        showCard(CapsuleCard(title: title, details: details, symbol: symbol, ok: ok))
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

    private var lastIncomingState: IncomingTransfer.State?

    private func incomingChanged(_ incoming: IncomingSnapshot?) {
        defer { lastIncomingState = incoming?.state }
        scheduleUpdate()
        guard let incoming, incoming.state != lastIncomingState else { return }
        let count = incoming.fileNames.count
        let files = "\(count) file\(count == 1 ? "" : "s")"
        switch incoming.state {
        case .done:
            tell("Received from \(incoming.sender)", files, symbol: "checkmark.circle.fill", ok: true)
        case .failed:
            tell("From \(incoming.sender)", incoming.error ?? "The transfer stopped", symbol: "exclamationmark.triangle.fill", ok: false)
        default:
            break
        }
    }

    private var keepsOpen: Bool {
        (hovering && preferences.autoCollapse) || pinned || model.isEditing || model.isDropTarget
            || app.localSend.incoming?.state == .asking || (!preferences.autoCollapse && model.isOpen)
    }

    private func screensChanged() {
        let screen = NSScreen.screens.first ?? NSScreen.main!
        model.geometry = CapsuleGeometry(screen: screen)
        model.refreshLayout()
        if model.isOpen {
            resizeOpen()
        } else {
            placeClosed()
        }
    }

    private func layoutChanged() {
        model.refreshLayout()
        resizeOpen()
    }

    private func placeClosed() {
        guard !model.isOpen else { return }
        panel.setFrame(model.geometry.frame(for: model.closedSize), display: true)
    }

    /// The open panel takes the size of its section (the drawing follows with an animation).
    private func resizeOpen() {
        guard model.isOpen else { return }
        let target = model.geometry.frame(for: model.openSize)
        if target.height >= panel.frame.height && target.width >= panel.frame.width {
            panel.setFrame(target, display: true)
        } else {
            // shrinking: let the drawing shrink first
            DispatchQueue.main.asyncAfter(deadline: .now() + CapsuleMetrics.animationTime) { [weak self] in
                guard let self, self.model.isOpen else { return }
                self.panel.setFrame(self.model.geometry.frame(for: self.model.openSize), display: true)
            }
            // but never cut what is still drawn bigger: grow in the other direction now
            let union = CGRect(x: min(target.minX, panel.frame.minX), y: min(target.minY, panel.frame.minY),
                               width: max(target.width, panel.frame.width), height: max(target.height, panel.frame.height))
            panel.setFrame(model.geometry.frame(for: union.size), display: true)
        }
    }

    private func pointer(inside: Bool) {
        hovering = inside
        if inside {
            pinTimer?.cancel()
        } else if pinned {
            pinned = false
        }
        if !model.isOpen {
            withAnimation(CapsuleMetrics.animation) { model.isHovering = inside }
            if model.card == nil { placeClosed() }
        }
        scheduleUpdate()
    }

    /// Opens or closes after the chosen wait (a pointer passing by does nothing).
    private func scheduleUpdate() {
        pending?.cancel()
        let wantsOpen = keepsOpen || (hovering && preferences.openOnHover && !model.isOpen)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let hoverOpens = self.hovering && self.preferences.openOnHover
            if self.keepsOpen || (hoverOpens && !self.model.isOpen) {
                self.openNow()
            } else if self.model.isOpen && !(self.hovering && !self.preferences.autoCollapse) {
                self.close()
            }
        }
        pending = work
        let delay = wantsOpen ? preferences.openDelay : preferences.closeDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, delay), execute: work)
    }

    private func openNow() {
        guard !model.isOpen else { return }
        cardTimer?.cancel()
        model.card = nil
        model.isHovering = false
        // the window takes the open size at once; the drawing grows into it
        panel.setFrame(model.geometry.frame(for: model.openSize), display: true)
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
        app.panelClosed()
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
