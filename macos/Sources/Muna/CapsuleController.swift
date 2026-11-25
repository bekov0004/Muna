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

    /// The closed capsule at rest: exactly the notch (it shows nothing, the menu bar stays free), or the pill.
    var restingSize: CGSize {
        CGSize(width: hasNotch ? notchWidth : Self.pillWidth, height: barHeight)
    }

    /// The closed capsule with something to show: the notch grows an ear on each side.
    var earsSize: CGSize {
        CGSize(width: hasNotch ? notchWidth + 2 * Self.earWidth : Self.pillWidth, height: barHeight)
    }

    /// A stable id of the screen (to keep its capsule when the screens change).
    static func id(of screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? screen.localizedName
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
    case muna, tray, localSend, clipboard, alerts, command, agent, mirror

    /// The tabs on top (the Command Bar has none: the capsule becomes its field).
    static let visible: [PanelTab] = [.muna, .tray, .localSend, .clipboard, .alerts]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .muna: return "Muna"
        case .tray: return "Tray"
        case .localSend: return "LocalSend"
        case .clipboard: return "Clipboard"
        case .alerts: return "Alerts"
        case .command: return "Command Bar"
        case .agent: return "Agent"
        case .mirror: return "Mirror"
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
        case .command: return "magnifyingglass"
        case .agent: return "sparkles"
        case .mirror: return "camera"
        }
    }

    /// The height of the section under the tabs.
    var bodyHeight: CGFloat {
        switch self {
        case .muna, .tray: return PanelLayout.rowHeight
        case .localSend: return 138
        case .clipboard, .alerts: return 236
        case .command: return 250
        case .agent: return 120
        case .mirror: return 300
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
    /// The clipboard item whose note is being written, and the text.
    @Published var noteForClip: String?
    @Published var clipNoteDraft = ""
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
    /// Music, the timer or a sending runs (it shows beside the notch).
    @Published var hasActivity = false
    /// A click on the closed capsule; the gear.
    var onTap: () -> Void = {}
    var onSettings: () -> Void = {}
    /// Open the agents window.
    var onAgents: () -> Void = {}

    static let headerHeight: CGFloat = 36
    /// The Command Bar has no tabs on top.
    var headerHeight: CGFloat { tab == .command || tab == .agent || tab == .mirror ? 8 : Self.headerHeight }
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
        let atLeast = geometry.hasNotch ? geometry.earsSize.width + 2 * CapsuleGeometry.earWidth : 0
        return PanelLayout(screenWidth: geometry.screenFrame.width, widgets: preferences.enabledWidgets,
                           cells: { preferences.cells($0) }, atLeast: atLeast)
    }

    /// Beside a notch, the date and time (or what runs) show only when there is a reason.
    var showsEars: Bool {
        !geometry.hasNotch || hasActivity || isHovering || card != nil
    }

    var closedSize: CGSize {
        var size = showsEars ? geometry.earsSize : geometry.restingSize
        if isHovering && !isOpen { size.width += CapsuleGeometry.hoverGrow }
        if card != nil {
            size.width = max(size.width, 380)
            size.height += Self.cardHeight
        }
        return size
    }

    var openSize: CGSize {
        CGSize(width: layout.width,
               height: geometry.topInset + headerHeight + tab.bodyHeight + Self.bottomPadding)
    }

    var size: CGSize { isOpen ? openSize : closedSize }
}

enum CapsuleMetrics {
    /// Settings → General → Appearance → Animation speed.
    static var animation: Animation {
        .spring(response: 0.38 / Preferences.shared.animationSpeed, dampingFraction: 0.82)
    }
    static var animationTime: TimeInterval { 0.42 / Preferences.shared.animationSpeed }
    static let cardTime: TimeInterval = 4
}

/// The capsule of one screen: shows it and opens it under the pointer. The window is only as big as
/// what is drawn (closed: the notch or its ears, open: the panel), so it never catches clicks meant
/// for the menu bar.
final class CapsuleController {
    let model: CapsuleModel
    let screenId: String
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
    private var clickMonitor: Any?

    init(app: AppState, screen: NSScreen) {
        self.app = app
        screenId = CapsuleGeometry.id(of: screen)
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
            .environmentObject(app.command)
            .environmentObject(app.agents)
            .environmentObject(app.privacy)
            .environmentObject(app.companion)
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
        app.localSend.incomingPublisher.dropFirst().sink { [weak self] _ in
            self?.scheduleUpdate()
        }.store(in: &observers)
        // an agent's question answered: the capsule may close
        app.agents.revisionPublisher.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.agentsChanged() }
        }.store(in: &observers)
        // what runs shows beside the notch
        app.nowPlaying.trackPublisher.sink { [weak self] _ in self?.activityChanged() }.store(in: &observers)
        app.timer.statePublisher.sink { [weak self] _ in self?.activityChanged() }.store(in: &observers)
        app.localSend.revisionPublisher.sink { [weak self] _ in self?.activityChanged() }.store(in: &observers)
        preferences.$activitiesInCollapsed.sink { [weak self] _ in self?.activityChanged() }.store(in: &observers)

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
    }

    /// The screen went away (or no longer gets a capsule).
    func remove() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        observers = []
        panel.orderOut(nil)
    }

    /// The screen moved or changed its size.
    func update(screen: NSScreen) {
        model.geometry = CapsuleGeometry(screen: screen)
        model.refreshLayout()
        if model.isOpen {
            resizeOpen()
        } else {
            placeClosed()
        }
    }

    /// Whether the screen of this capsule holds that point (where the pointer is).
    func contains(_ point: NSPoint) -> Bool {
        model.geometry.screenFrame.contains(point)
    }

    private func agentsChanged() {
        guard model.isOpen, model.tab == .agent, app.agents.waiting == nil else { return }
        pinned = false
        scheduleUpdate()
    }

    private func activityChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let session = self.app.localSend.session
            let active = self.preferences.activitiesInCollapsed
                && (self.app.nowPlaying.track != nil || self.app.timer.active || session.phase == .sending)
            guard active != self.model.hasActivity else { return }
            withAnimation(CapsuleMetrics.animation) { self.model.hasActivity = active }
            self.placeClosed()
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

    /// The Command Bar: the capsule becomes one big field with the keyboard in it.
    func openCommand() {
        if model.isOpen && model.tab == .command {
            close()
            return
        }
        app.command.reset()
        open(on: .command)
        panel.makeKey()
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
        (hovering && preferences.autoCollapse) || pinned || model.isEditing || model.isDropTarget
            || app.localSend.incoming?.state == .asking || (!preferences.autoCollapse && model.isOpen)
            || (model.tab == .agent && app.agents.waiting != nil)
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

    func openNow() {
        guard !model.isOpen else { return }
        cardTimer?.cancel()
        model.card = nil
        model.isHovering = false
        // the window takes the open size at once; the drawing grows into it
        panel.setFrame(model.geometry.frame(for: model.openSize), display: true)
        withAnimation(CapsuleMetrics.animation) { model.isOpen = true }
        app.panelOpened(on: model.tab)
    }

    func close() {
        guard model.isOpen else { return }
        if panel.isKeyWindow {
            // give the keyboard back to the app in front: out and in again, without becoming key
            model.isEditing = false
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        withAnimation(CapsuleMetrics.animation) { model.isOpen = false }
        app.panelClosed()
        // the window shrinks when the drawing has; the Command Bar is not where the next opening goes
        DispatchQueue.main.asyncAfter(deadline: .now() + CapsuleMetrics.animationTime) { [weak self] in
            guard let self else { return }
            if !self.model.isOpen && [.command, .agent, .mirror].contains(self.model.tab) { self.model.tab = .muna }
            self.placeClosed()
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
