import AppKit
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

    func start() {
        nowPlaying.start()
        clipboard.start()
        calendar.start()
        localSend.start()
    }

    /// The panel opened on a page: bring what it shows up to date.
    func panelOpened(on tab: PanelTab) {
        nowPlaying.refresh()
        tray.refresh()
        calendar.load()
        if tab == .localSend {
            localSend.session.refresh()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let app = AppState()
    private var capsule: CapsuleController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        app.start()
        capsule = CapsuleController(app: app)
        capsule?.show()
        setUpStatusItem()
    }

    /// Muna was started again (Finder, Launchpad, Spotlight) while it runs: open the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        capsule?.open(on: .home)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.nowPlaying.stop()
        app.localSend.setReceiving(false)
    }

    // --- the menu-bar item: the way to the settings and to quit (Muna has no Dock icon) ---------

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Muna")
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// The menu is built each time it opens, so the ticks show the current settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for tab in PanelTab.allCases {
            let entry = add(menu, "Open \(tab.title)", #selector(openTab(_:)))
            entry.representedObject = tab.rawValue
            entry.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
        }
        menu.addItem(.separator())
        add(menu, "Receive files (LocalSend)", #selector(toggleReceiving)).state = app.localSend.receiving ? .on : .off
        if let problem = app.localSend.receiveProblem {
            let note = NSMenuItem(title: problem, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        add(menu, "Keep clipboard history", #selector(toggleClipboardHistory)).state = app.clipboard.keepHistory ? .on : .off
        add(menu, "Keep the Tray after a restart", #selector(toggleKeepTray)).state =
            Settings.bool(Settings.keepTrayKey, default: true) ? .on : .off
        add(menu, "Open at login", #selector(toggleLoginItem)).state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        add(menu, "About Muna", #selector(showAbout))
        let quit = NSMenuItem(title: "Quit Muna", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func openTab(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tab = PanelTab(rawValue: raw) else { return }
        capsule?.open(on: tab)
    }

    @objc private func toggleReceiving() {
        app.localSend.setReceiving(!app.localSend.receiving)
    }

    @objc private func toggleClipboardHistory() {
        app.clipboard.keepHistory.toggle()
    }

    @objc private func toggleKeepTray() {
        Settings.set(Settings.keepTrayKey, !Settings.bool(Settings.keepTrayKey, default: true))
        app.tray.applyKeepSetting()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Muna could not change “Open at login”"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
