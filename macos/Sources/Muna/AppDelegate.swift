import AppKit
import Combine
import ServiceManagement

/// Everything the app has, made once.
final class AppState {
    let nowPlaying = NowPlaying()
    let notes = NotesModel()
    let todo = TodoModel()
    let tray = TrayModel()
    let clipboard = ClipboardModel()
    let calendar = CalendarModel()
    let localSend = LocalSendController()
    let timer = TimerModel()
    let alerts = AlertsModel()
    let camera = CameraModel()
    lazy var command = CommandModel(clipboard: clipboard)
    let monitor = SystemMonitor()
    let awake = KeepAwake()

    func start() {
        nowPlaying.start()
        clipboard.start()
        calendar.start()
        localSend.start()
    }

    /// The panel opened on a section: bring what it shows up to date.
    func panelOpened(on tab: PanelTab) {
        nowPlaying.refresh()
        tray.refresh()
        calendar.load()
        if tab == .localSend {
            localSend.session.refresh()
        }
    }

    /// The panel closed: the camera goes off at once.
    func panelClosed() {
        camera.stop()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private let app = AppState()
    private var capsule: CapsuleController?
    private var settings: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var commandKey: HotKey?
    private var keyObserver: Any?
    private let menu = NSMenu()
    private let popover = NSPopover()
    private let quickState = QuickPanelState()
    private var readingsObservers: [AnyCancellable] = []
    private var readingsOn = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        app.start()
        let settings = SettingsWindowController(app: app)
        self.settings = settings
        capsule = CapsuleController(app: app)
        capsule?.model.onSettings = { [weak self] in self?.settings?.show() }
        capsule?.show()
        setUpStatusItem()
        setCommandKey(Preferences.shared.commandHotKey)
        keyObserver = Preferences.shared.$commandHotKey.dropFirst().removeDuplicates().sink { [weak self] on in
            self?.setCommandKey(on)
        }
    }

    private func setCommandKey(_ on: Bool) {
        commandKey = on
            ? HotKey(keyCode: HotKey.optionSpace.keyCode, modifiers: HotKey.optionSpace.modifiers, id: 1) { [weak self] in
                self?.capsule?.openCommand()
            }
            : nil
    }

    /// Muna was started again (Finder, Launchpad, Spotlight) while it runs: open the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        capsule?.open(on: .muna)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.nowPlaying.stop()
        app.camera.stop()
        app.awake.stop()
        app.localSend.shutdown()
    }

    // --- the menu-bar item: the sections, the settings and quitting (Muna has no Dock icon) -----

    /// Muna's item in the menu bar: a click opens the quick panel (as the top-bar button on Linux),
    /// a right click the menu.
    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = ButterflyImage.image?.copy() as? NSImage {
                image.size = NSSize(width: 18, height: 16)
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Muna")
            }
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self
        statusItem = item

        let panel = QuickPanelView(onSettings: { [weak self] in
            self?.popover.performClose(nil)
            self?.settings?.show()
        }, onCommand: { [weak self] in
            self?.popover.performClose(nil)
            self?.capsule?.openCommand()
        })
        .environmentObject(quickState)
        .environmentObject(app.monitor)
        .environmentObject(app.awake)
        popover.contentViewController = NSHostingController(rootView: panel)
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self

        setReadings(Preferences.shared.menuBarReadings)
        Preferences.shared.$menuBarReadings.dropFirst().removeDuplicates().sink { [weak self] on in
            self?.setReadings(on)
        }.store(in: &readingsObservers)
        app.monitor.$cpu.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateReadings() }
        }.store(in: &readingsObservers)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            statusItem?.menu = menu
            sender.performClick(nil)
            statusItem?.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            quickState.message = nil
            app.monitor.watch()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        app.monitor.unwatch()
    }

    private func setReadings(_ on: Bool) {
        guard on != readingsOn else { return }
        readingsOn = on
        if on { app.monitor.watch() } else { app.monitor.unwatch() }
        updateReadings()
    }

    private func updateReadings() {
        guard let button = statusItem?.button else { return }
        guard readingsOn else {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        let monitor = app.monitor
        let memory = monitor.memoryTotal > 0 ? Int(Double(monitor.memoryUsed) / Double(monitor.memoryTotal) * 100) : 0
        let small = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let dim = NSFont.systemFont(ofSize: 8, weight: .bold)
        let text = NSMutableAttributedString()
        for (label, value) in [("CPU", "\(Int(monitor.cpu * 100))%"), ("RAM", "\(memory)%")] {
            text.append(NSAttributedString(string: " \(label) ", attributes: [.font: dim, .foregroundColor: NSColor.secondaryLabelColor]))
            text.append(NSAttributedString(string: value, attributes: [.font: small]))
        }
        button.attributedTitle = text
    }

    /// The menu is built each time it opens, so the ticks show the current settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for tab in PanelTab.visible {
            let entry = add(menu, "Open \(tab.title)", #selector(openTab(_:)))
            entry.representedObject = tab.rawValue
            entry.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
        }
        add(menu, "Command Bar", #selector(openCommand)).image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        menu.addItem(.separator())
        let preferences = Preferences.shared
        add(menu, "Receive files (LocalSend)", #selector(toggleReceiving)).state = preferences.localSendReceive ? .on : .off
        if let problem = app.localSend.receiveProblem {
            let note = NSMenuItem(title: problem, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(openSettings), key: ",")
        add(menu, "About Muna", #selector(showAbout))
        let quit = NSMenuItem(title: "Quit Muna", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func openTab(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tab = PanelTab(rawValue: raw) else { return }
        capsule?.open(on: tab)
    }

    @objc private func openCommand() {
        capsule?.openCommand()
    }

    @objc private func toggleReceiving() {
        Preferences.shared.localSendReceive.toggle()
    }

    @objc private func openSettings() {
        settings?.show()
    }

    @objc private func showAbout() {
        settings?.show(page: .about)
    }
}
