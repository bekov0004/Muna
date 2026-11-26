import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

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
    let snippets = SnippetsModel()
    lazy var command = CommandModel(clipboard: clipboard, snippets: snippets)
    let monitor = SystemMonitor()
    let awake = KeepAwake()
    let focus = FocusModel()
    let reminders = RemindersModel()
    let downloads = DownloadsModel()
    let sound = SoundModel()
    let agents = AgentsModel()
    let privacy = PrivacyModel()
    let companion = CompanionModel()
    let scratchpad = ScratchpadModel()
    let windows = WindowsModel()
    let displays = DisplaysModel()
    let phone = PhoneModel()
    let pairing = PhonePairing()

    func start() {
        nowPlaying.start()
        clipboard.start()
        calendar.start()
        localSend.start()
        downloads.start()
        nowPlaying.playingPublisher.sink { [weak self] playing in self?.companion.musicPlaying = playing }.store(in: &observers)
    }

    private var observers: [AnyCancellable] = []

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
    private var capsules: CapsuleManager?
    private var settings: SettingsWindowController?
    private var agentsWindow: AgentsWindowController?
    private var scratchpadWindow: ScratchpadWindowController?
    private var statusItem: NSStatusItem?
    private var commandKey: HotKey?
    private var sectionKeys: [HotKey] = []
    private var radialKey: HotKey?
    private var radial: RadialMenu?
    private var keyObserver: Any?
    private let menu = NSMenu()
    private let popover = NSPopover()
    private let quickState = QuickPanelState()
    private var readingsObservers: [AnyCancellable] = []
    private var readingsOn = false
    private var gestures: GestureActions?
    private var systemAlerts: SystemAlerts?
    private var keyboardCards: KeyboardCards?
    private var appNotifications: AppNotifications?
    private var readingsTimer: Timer?
    private lazy var windowMap = WindowMapModel(windows: app.windows)

    func applicationDidFinishLaunching(_ notification: Notification) {
        app.start()
        let settings = SettingsWindowController(app: app)
        self.settings = settings
        let agentsWindow = AgentsWindowController(agents: app.agents)
        self.agentsWindow = agentsWindow
        scratchpadWindow = ScratchpadWindowController(model: app.scratchpad)
        app.command.onScratchpad = { [weak self] in self?.scratchpadWindow?.show() }
        quickState.onScratchpad = { [weak self] in
            self?.popover.performClose(nil)
            self?.scratchpadWindow?.show()
        }
        quickState.onCleaning = { [weak self] in
            self?.popover.performClose(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { CleaningMode.shared.start() }
        }
        quickState.onCommand = { [weak self] in
            self?.popover.performClose(nil)
            self?.capsules?.openCommand()
        }
        let capsules = CapsuleManager(app: app)
        capsules.onSettings = { [weak self] in self?.settings?.show() }
        capsules.onAgents = { [weak self] in self?.agentsWindow?.show() }
        self.capsules = capsules
        capsules.show()
        setUpStatusItem()
        setCommandKey(Preferences.shared.commandHotKey)
        keyObserver = Preferences.shared.$commandHotKey.dropFirst().removeDuplicates().sink { [weak self] on in
            self?.setCommandKey(on)
        }
        setUpRadial()
        setSectionKeys(Preferences.shared.sectionHotKeys)
        Preferences.shared.$sectionHotKeys.dropFirst().removeDuplicates().sink { [weak self] on in
            self?.setSectionKeys(on)
        }.store(in: &readingsObservers)

        // what the settings window's buttons, the trackpad and the radial menu do
        settings.state.run = { [weak self] id in self?.perform(id) }
        quickState.onMic = { [weak self] in self?.app.sound.toggleMicrophone() }
        quickState.onRun = { [weak self] id in
            if !id.hasPrefix("quickpanel") { self?.popover.performClose(nil) }
            self?.perform(id)
        }
        let gestures = GestureActions(app: app)
        gestures.run = { [weak self] id in self?.perform(id) }
        gestures.apply()
        self.gestures = gestures
        let tell: (String, String, String) -> Void = { [weak self] title, details, symbol in
            self?.capsules?.tell(title, details, symbol: symbol, ok: false)
        }
        systemAlerts = SystemAlerts(monitor: app.monitor, tell: tell)
        systemAlerts?.start()
        keyboardCards = KeyboardCards { [weak self] title, symbol in self?.capsules?.tell(title, "", symbol: symbol, ok: true) }
        keyboardCards?.start()
        // other apps' notifications in Alerts (Settings → General → Alerts)
        let notifications = AppNotifications(alerts: app.alerts)
        appNotifications = notifications
        if Preferences.shared.bool("app-notifications") { notifications.start() }
        Preferences.shared.changed.sink { [weak self] key in
            guard key == "app-notifications" || key == "*" else { return }
            DispatchQueue.main.async { if Preferences.shared.bool("app-notifications") { self?.appNotifications?.start() } else { self?.appNotifications?.stop() } }
        }.store(in: &readingsObservers)
    }

    /// One action by its name (Linux's names: the "Try it" buttons, the radial menu, the gestures' "muna:…").
    func perform(_ id: String) {
        switch id {
        case "quickpanel": showQuickPanel(nil)
        case _ where id.hasPrefix("quickpanel:"): showQuickPanel(QuickPage(rawValue: String(id.dropFirst(11))))
        case "command": capsules?.openCommand()
        case "radial": radial?.toggle()
        case "cleaning": DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { CleaningMode.shared.start() }
        case "scratchpad": scratchpadWindow?.show()
        case "screenshot": QuickTools.screenshot()
        case "record", "recording": NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"))
        case "color": QuickTools.pickColor { [weak self] hex in self?.capsules?.tell("Colour copied", hex, symbol: "eyedropper", ok: true) }
        case "dark": QuickTools.toggleDarkMode()
        case "night": NightShift.set(!NightShift.isOn)
        case "output": app.sound.nextOutput()
        case "mic": app.sound.refresh(); app.sound.toggleMicrophone()
        case "awake": if app.awake.isOn { app.awake.stop() } else { app.awake.start(minutes: nil) }
        case "lock": Keyboard.press("<Super><Control>q")
        case "downloads": NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
        case "clipboard": capsules?.open(on: .clipboard)
        case _ where id.hasPrefix("reminder:"): capsules?.tell("Reminder", String(id.dropFirst(9)), symbol: "bell.badge.fill", ok: true, seconds: 8)
        case "muna": capsules?.open(on: .muna)
        case "tray": capsules?.open(on: .tray)
        case "notifications": capsules?.open(on: .alerts)
        case "play-pause": app.nowPlaying.playPause()
        case "next": app.nowPlaying.next()
        case "prev": app.nowPlaying.previous()
        case _ where id.hasPrefix("capsule:"):
            if let tab = PanelTab(rawValue: String(id.dropFirst(8))) { capsules?.open(on: tab) }
        default: break
        }
    }

    /// The quick panel under Muna's item, on a page (or as it was).
    private func showQuickPanel(_ page: QuickPage?) {
        if let page { quickState.page = page }
        guard let button = statusItem?.button else { return }
        if popover.isShown { return }
        app.monitor.watch()
        app.sound.watch()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// ⌃⌥Space: a ring of actions around the pointer.
    private func setUpRadial() {
        // the actions chosen in Settings → Radial menu, in their order
        radial = RadialMenu { [weak self] in
            guard let self else { return [] }
            return Preferences.shared.strings("radial-actions").compactMap { id in
                guard let info = RadialCatalog.info(id) else { return nil }
                let awake = id == "awake" && self.app.awake.isOn
                return RadialAction(id: id, symbol: awake ? "cup.and.saucer.fill" : info.symbol, label: awake ? "Sleep" : info.title) { [weak self] in
                    self?.perform(id)
                }
            }
        }
        let apply: (Bool) -> Void = { [weak self] on in
            self?.radialKey = on
                ? HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), id: 2) { [weak self] in self?.radial?.toggle() }
                : nil
        }
        apply(Preferences.shared.radialHotKey)
        Preferences.shared.$radialHotKey.dropFirst().removeDuplicates().sink { on in apply(on) }.store(in: &readingsObservers)
    }

    /// ⌃⌥1 … ⌃⌥5: the sections, in the order of the tabs.
    private func setSectionKeys(_ on: Bool) {
        sectionKeys = []
        guard on else { return }
        let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5]
        for (index, tab) in PanelTab.visible.enumerated() where index < codes.count {
            sectionKeys.append(HotKey(keyCode: UInt32(codes[index]), modifiers: UInt32(controlKey | optionKey), id: UInt32(11 + index)) { [weak self] in
                self?.capsules?.open(on: tab)
            })
        }
    }

    private func setCommandKey(_ on: Bool) {
        commandKey = on
            ? HotKey(keyCode: HotKey.optionSpace.keyCode, modifiers: HotKey.optionSpace.modifiers, id: 1) { [weak self] in
                self?.capsules?.openCommand()
            }
            : nil
    }

    /// Muna was started again (Finder, Launchpad, Spotlight) while it runs: open the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        capsules?.open(on: .muna)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.nowPlaying.stop()
        app.camera.stop()
        app.awake.stop()
        app.agents.stopAll()
        app.scratchpad.save()
        app.displays.restore()
        CleaningMode.shared.stop()
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
        applyIcon()

        let panel = QuickPanelView(onSettings: { [weak self] in
            self?.popover.performClose(nil)
            self?.settings?.show()
        }, onCommand: { [weak self] in
            self?.popover.performClose(nil)
            self?.capsules?.openCommand()
        }, onAgents: { [weak self] in
            self?.popover.performClose(nil)
            self?.agentsWindow?.show()
        })
        .environmentObject(quickState)
        .environmentObject(Preferences.shared)
        .environmentObject(DisksModel.shared)
        .environmentObject(windowMap)
        .environmentObject(PowerModel.shared)
        .environmentObject(app.monitor)
        .environmentObject(app.awake)
        .environmentObject(app.focus)
        .environmentObject(app.reminders)
        .environmentObject(app.downloads)
        .environmentObject(app.sound)
        .environmentObject(app.agents)
        .environmentObject(app.windows)
        .environmentObject(app.displays)
        .environmentObject(app.phone)
        .environmentObject(app.pairing)
        popover.contentViewController = NSHostingController(rootView: panel)
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self

        setReadings(Preferences.shared.menuBarReadings || !Preferences.shared.strings("bar-metrics").isEmpty)
        Preferences.shared.$menuBarReadings.dropFirst().removeDuplicates().sink { [weak self] on in
            self?.setReadings(on || !Preferences.shared.strings("bar-metrics").isEmpty)
        }.store(in: &readingsObservers)
        // Settings → Monitor (what is written) and Menu bar (the icon)
        Preferences.shared.changed.sink { [weak self] key in
            DispatchQueue.main.async {
                guard let self else { return }
                if key == "bar-metrics" || key == "*" { self.setReadings(Preferences.shared.menuBarReadings || !Preferences.shared.strings("bar-metrics").isEmpty) }
                if key == "bar-icon" || key == "*" { self.applyIcon() }
            }
        }.store(in: &readingsObservers)
        app.monitor.cpuPublisher.sink { [weak self] _ in
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
            // the window tools act on the app that was in front
            if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
                app.windows.target = front
            }
            app.monitor.watch()
            app.sound.watch()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        app.monitor.unwatch()
        app.sound.unwatch()
    }

    /// Settings → Menu bar → Menu bar icon: the butterfly or a symbol.
    private func applyIcon() {
        guard let button = statusItem?.button else { return }
        let choice = Preferences.shared.string("bar-icon")
        if choice != "butterfly", let symbol = NSImage(systemSymbolName: choice, accessibilityDescription: "Muna") {
            button.image = symbol
        } else if let image = ButterflyImage.image?.copy() as? NSImage {
            image.size = NSSize(width: 18, height: 16)
            button.image = image
        }
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
        var chosen = Preferences.shared.strings("bar-metrics")
        if chosen.isEmpty { chosen = ["cpu", "mem"] }
        if chosen.contains(where: { ["cputemp", "gpu", "diskio", "power"].contains($0) }) { Sensors.shared.sample() }
        let small = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let dim = NSFont.systemFont(ofSize: 8, weight: .bold)
        let text = NSMutableAttributedString()
        let pairs: [(String, String)] = Readings.all.filter { chosen.contains($0.id) }.compactMap { reading in reading.value(monitor).map { (reading.label, $0) } }
        for (label, value) in pairs {
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
        add(menu, "Scratchpad", #selector(openScratchpad))
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
        capsules?.open(on: tab)
    }

    @objc private func openCommand() {
        capsules?.openCommand()
    }

    @objc private func toggleReceiving() {
        Preferences.shared.localSendReceive.toggle()
    }

    @objc private func openScratchpad() {
        scratchpadWindow?.show()
    }

    @objc private func openSettings() {
        settings?.show()
    }

    @objc private func showAbout() {
        settings?.show(page: "about")
    }
}
