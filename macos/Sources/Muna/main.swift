import AppKit

// Muna lives in the capsule at the top of the screen and in a small menu-bar item: no Dock icon.
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
