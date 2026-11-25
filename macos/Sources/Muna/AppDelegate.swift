import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var capsule: CapsuleController?
    private var statusItem: NSStatusItem?
    private let nowPlaying = NowPlaying()

    func applicationDidFinishLaunching(_ notification: Notification) {
        capsule = CapsuleController(nowPlaying: nowPlaying)
        capsule?.show()
        nowPlaying.start()
        setUpStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        nowPlaying.stop()
    }

    /// A small item in the menu bar: the only way to quit an app without a Dock icon.
    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Muna")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "About Muna", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Muna", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
