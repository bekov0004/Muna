import AppKit

// Muna lives in the capsule at the top of the screen and in a small menu-bar item; while one of its
// windows is open it is in the Dock too (AppPresence).
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
