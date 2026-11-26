import AppKit
import ApplicationServices
import CoreGraphics

/// Cleaning mode, as on Linux: every screen goes black and the keyboard and mouse do nothing,
/// so they can be wiped. Hold Esc for 1.5 s to leave; it ends by itself after 60 s.
final class CleaningMode {
    static let shared = CleaningMode()

    private(set) var isOn = false

    private let duration: TimeInterval = 60
    private let holdToLeave: TimeInterval = 1.5
    private let escapeKey: Int64 = 53

    private var windows: [NSWindow] = []
    private var labels: [NSTextField] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tick: Timer?
    private var endsAt = Date()
    private var escapeSince: Date?

    func start() {
        guard !isOn else { return }
        let mask = CleaningMode.eventMask()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: CleaningMode.callback,
            userInfo: nil
        ) else {
            // The tap needs the Accessibility permission.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        isOn = true
        escapeSince = nil
        endsAt = Date().addingTimeInterval(duration)
        showWindows()
        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.update()
        }
        update()
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        tick?.invalidate()
        tick = nil
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port = tap { CFMachPortInvalidate(port) }
        tap = nil
        source = nil
        for window in windows { window.orderOut(nil) }
        windows = []
        labels = []
        escapeSince = nil
    }

    // MARK: - Screens

    private func showWindows() {
        // Settings → Cleaning Mode → Keep screen visible: a small sign in a corner instead of black
        let visible = Preferences.shared.bool("cleaning-visible")
        for screen in NSScreen.screens {
            let frame = visible ? NSRect(x: screen.frame.maxX - 380, y: screen.frame.minY + 30, width: 350, height: 44) : screen.frame
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.setFrame(frame, display: true)

            let label = NSTextField(labelWithString: "")
            label.font = NSFont.systemFont(ofSize: 15, weight: .medium)
            label.textColor = NSColor.white.withAlphaComponent(0.45)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.withAlphaComponent(visible ? 0.8 : 1).cgColor
            content.layer?.cornerRadius = visible ? 12 : 0
            if visible { window.isOpaque = false; window.backgroundColor = .clear }
            content.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])
            window.contentView = content
            window.orderFrontRegardless()
            windows.append(window)
            labels.append(label)
        }
    }

    private func update() {
        guard isOn else { return }
        let left = endsAt.timeIntervalSinceNow
        if left <= 0 { stop(); return }
        if let since = escapeSince, Date().timeIntervalSince(since) >= holdToLeave { stop(); return }
        let text: String
        if escapeSince != nil {
            text = "Keep holding Esc…"
        } else {
            text = "Cleaning mode — hold Esc to leave · \(Int(left.rounded(.up))) s"
        }
        for label in labels { label.stringValue = text }
    }

    // MARK: - Event tap

    private static func eventMask() -> CGEventMask {
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
        ]
        var mask: CGEventMask = 0
        for type in types { mask |= CGEventMask(1) << CGEventMask(type.rawValue) }
        return mask
    }

    /// Swallows every event; only watches Esc. No captured context: it goes through `shared`.
    private static let callback: CGEventTapCallBack = { _, type, event, _ in
        let mode = CleaningMode.shared
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = mode.tap { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == mode.escapeKey {
                if type == .keyDown {
                    if mode.escapeSince == nil { mode.escapeSince = Date() }
                } else {
                    mode.escapeSince = nil
                }
            }
        }
        return nil
    }
}
