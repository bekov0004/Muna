import AppKit

/// Muna is an app with a window like any other while one of its windows is open (settings, agents,
/// scratchpad, the phone): its icon is in the Dock and in ⌘Tab, and it has a menu bar of its own.
/// With every window closed it goes back to living in the capsule and the menu-bar item only, as on
/// Linux, where the settings are an app and the capsule is part of the desktop.
final class AppPresence {
    static let shared = AppPresence()
    private var observers: [NSObjectProtocol] = []

    func start() {
        NSApp.mainMenu = Self.menu()
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.update() })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            // the window is still listed while it closes
            DispatchQueue.main.async { self?.update(closing: note.object as? NSWindow) }
        })
        observers.append(center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { [weak self] _ in self?.update() })
    }

    /// A window of Muna's own: titled, not a panel (the capsule, the popover and the Command Bar are panels).
    private static func isAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel) && window.className != "NSStatusBarWindow"
            && !window.className.contains("Popover")
    }

    private func update(closing: NSWindow? = nil) {
        let open = NSApp.windows.contains { window in
            window !== closing && Self.isAppWindow(window) && (window.isVisible || window.isMiniaturized)
        }
        let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if open { NSApp.activate(ignoringOtherApps: true) }
    }

    /// The menus every Mac app has; Edit also makes ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z work in Muna's text fields.
    private static func menu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector?, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        let settings = item("Settings…", #selector(AppDelegate.openSettingsFromMenu), ",")
        settings.target = NSApp.delegate
        add("Muna", [
            item("About Muna", #selector(AppDelegate.openAboutFromMenu), ""),
            .separator(),
            settings,
            .separator(),
            item("Hide Muna", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Muna", #selector(NSApplication.terminate(_:)), "q"),
        ])
        add("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        main.items.first?.submenu?.items.first?.target = NSApp.delegate
        if let window = main.items.last?.submenu { NSApp.windowsMenu = window }
        return main
    }
}
