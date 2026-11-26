import Foundation

/// A finger on the trackpad: its id and where it is (0–1 across, 0–1 down).
public struct Contact: Equatable {
    public let id: Int
    public let x: Double
    public let y: Double
    public init(id: Int, x: Double, y: Double) { self.id = id; self.x = x; self.y = y }
}

/// What the fingers did (see TouchGestures).
public enum GestureEvent: Equatable {
    /// Three or four fingers locked to a swipe direction ("swipe3-left").
    case swipeLocked(String)
    /// A locked swipe moved this far along its direction since the last event (trackpad widths, + = the direction).
    case swipeMoved(String, Double)
    /// A locked swipe went far enough for a one-off action.
    case swipeTriggered(String)
    case swipeEnded(String)
    /// "pinch3-in", "pinch4-out".
    case pinched(String)
    /// "hold3": the fingers rested still and lifted.
    case held(String)
    case edgeBegan(String)
    /// A step along an edge: +1 up (left, right edges) or to the right (top, bottom), −1 the other way.
    case edgeStep(String, Int)
    case edgeEnded(String)
    case edgeDoubleTap(String)
    case edgeHold(String)
}

/// Turns trackpad frames into Linux's gestures: three- and four-finger swipes, pinches and holds
/// (linux/src/gestures/recognizer.js), one finger along the edges, double taps and holds at them
/// (linux/service/edges/muna-edges.py). Two fingers stay the system's. The same rules as Windows' MunaCore.
public final class TouchGestures {
    public static let lockDistance = 0.03, triggerDistance = 0.16, pinchIn = 0.78, pinchOut = 1.3, holdSeconds = 0.35
    public static let edgeX = 0.06, edgeY = 0.08, start = 0.035, step = 0.07, tapSeconds = 0.22, doubleSeconds = 0.40, edgeHoldSeconds = 0.55, still = 0.02

    /// Height of the trackpad over its width.
    public var aspect = 0.62
    /// Percent: more is a shorter swipe.
    public var sensitivity = 100.0
    public var edges = true

    private struct Many {
        var fingers: Int, startX: Double, startY: Double, startSpread: Double, time: Double
        var lastAlong = 0.0
        var gesture: String?
        var horizontal = true
        var sign = 1.0
        var triggered = false, moved = false, pinched = false, over = false
    }

    private struct Single {
        var id: Int, x0: Double, y0: Double, t0: Double
        var edge: String?, zone: String?
        var base = 0.0
        var active = false, moved = false, heldDone = false
    }

    private var many: Many?
    private var single: Single?
    private var lastTap: (zone: String, time: Double)?
    private var now = 0.0

    public init() {}

    private var trigger: Double { Self.triggerDistance * 100 / min(max(sensitivity, 25), 400) }

    /// One frame: the fingers touching now (none: all lifted).
    public func frame(_ contacts: [Contact], time: Double) -> [GestureEvent] {
        now = time
        var events: [GestureEvent] = []
        if contacts.count >= 3 {
            finishSingle(&events)
            manyFrame(contacts, &events)
        } else {
            if many != nil { endMany(&events) }
            if contacts.count == 1 && edges { singleFrame(contacts[0], &events) } else { finishSingle(&events) }
        }
        return events
    }

    /// Time passes with nothing new (a finger resting still).
    public func tick(time: Double) -> [GestureEvent] {
        now = time
        var events: [GestureEvent] = []
        holdCheck(&events)
        return events
    }

    // --- three and four fingers --------------------------------------------------------------------

    private func manyFrame(_ contacts: [Contact], _ events: inout [GestureEvent]) {
        let cx = contacts.map(\.x).reduce(0, +) / Double(contacts.count)
        let cy = contacts.map(\.y).reduce(0, +) / Double(contacts.count)
        let spread = contacts.map { hypot($0.x - cx, ($0.y - cy) * aspect) }.reduce(0, +) / Double(contacts.count)
        let fingers = min(4, contacts.count)
        if many == nil || (many!.gesture == nil && !many!.pinched && fingers != many!.fingers) {
            many = Many(fingers: fingers, startX: cx, startY: cy, startSpread: max(spread, 0.001), time: now)
            return
        }
        guard var m = many, !m.over else { return }
        let dx = cx - m.startX, dy = (cy - m.startY) * aspect
        if hypot(dx, dy) > Self.still { m.moved = true }
        if m.gesture == nil && !m.pinched {
            let ratio = spread / m.startSpread
            if ratio < Self.pinchIn || ratio > Self.pinchOut {
                m.pinched = true
                m.over = true
                events.append(.pinched("pinch\(m.fingers)-\(ratio < 1 ? "in" : "out")"))
                many = m
                return
            }
        }
        if m.gesture == nil {
            guard hypot(dx, dy) >= Self.lockDistance else { many = m; return }
            m.horizontal = abs(dx) > abs(dy)
            let direction = m.horizontal ? (dx < 0 ? "left" : "right") : (dy < 0 ? "up" : "down")
            m.sign = (m.horizontal ? dx : dy) < 0 ? -1 : 1
            m.gesture = "swipe\(m.fingers)-\(direction)"
            events.append(.swipeLocked(m.gesture!))
            m.lastAlong = 0
        }
        let along = (m.horizontal ? dx : dy) * m.sign
        if abs(along - m.lastAlong) > 1e-9 {
            events.append(.swipeMoved(m.gesture!, along - m.lastAlong))
            m.lastAlong = along
        }
        if !m.triggered && along >= trigger {
            m.triggered = true
            events.append(.swipeTriggered(m.gesture!))
        }
        many = m
    }

    private func endMany(_ events: inout [GestureEvent]) {
        guard let m = many else { return }
        many = nil
        if let gesture = m.gesture { events.append(.swipeEnded(gesture)); return }
        if !m.pinched && !m.moved && now - m.time >= Self.holdSeconds { events.append(.held("hold\(m.fingers)")) }
    }

    // --- one finger at an edge -----------------------------------------------------------------------

    private func singleFrame(_ c: Contact, _ events: inout [GestureEvent]) {
        guard var s = single, s.id == c.id else {
            finishSingle(&events)
            single = Single(id: c.id, x0: c.x, y0: c.y, t0: now, edge: Self.edgeAt(c.x, c.y), zone: Self.zoneAt(c.x, c.y))
            return
        }
        if max(abs(c.x - s.x0), abs(c.y - s.y0)) > Self.still { s.moved = true }
        single = s
        holdCheck(&events)
        s = single!
        guard let edge = s.edge else { return }
        let vertical = edge == "left" || edge == "right"
        let along = vertical ? s.y0 - c.y : c.x - s.x0
        let across = vertical ? abs(c.x - s.x0) : abs(c.y - s.y0)
        if !s.active {
            if across > Self.start * 1.5 && across > abs(along) { s.edge = nil; single = s; return }
            if abs(along) >= Self.start && abs(along) > 2 * across {
                s.active = true
                s.base = along
                events.append(.edgeBegan(edge))
            }
            single = s
            return
        }
        while along - s.base >= Self.step { s.base += Self.step; events.append(.edgeStep(edge, 1)) }
        while s.base - along >= Self.step { s.base -= Self.step; events.append(.edgeStep(edge, -1)) }
        single = s
    }

    private func holdCheck(_ events: inout [GestureEvent]) {
        guard var s = single, let zone = s.zone, !s.moved, !s.heldDone, !s.active, now - s.t0 >= Self.edgeHoldSeconds else { return }
        s.heldDone = true
        single = s
        events.append(.edgeHold(zone))
    }

    private func finishSingle(_ events: inout [GestureEvent]) {
        guard let s = single else { return }
        single = nil
        if s.active, let edge = s.edge { events.append(.edgeEnded(edge)); return }
        if let zone = s.zone, !s.moved, !s.heldDone, now - s.t0 <= Self.tapSeconds {
            if let last = lastTap, last.zone == zone, s.t0 - last.time <= Self.doubleSeconds {
                events.append(.edgeDoubleTap(zone))
                lastTap = nil
            } else {
                lastTap = (zone, now)
            }
        }
    }

    private static func edgeAt(_ x: Double, _ y: Double) -> String? {
        var near: [(Double, String)] = []
        if x <= edgeX { near.append((x / edgeX, "left")) }
        if x >= 1 - edgeX { near.append(((1 - x) / edgeX, "right")) }
        if y <= edgeY { near.append((y / edgeY, "top")) }
        if y >= 1 - edgeY { near.append(((1 - y) / edgeY, "bottom")) }
        return near.min { $0.0 < $1.0 }?.1
    }

    private static func zoneAt(_ x: Double, _ y: Double) -> String? {
        if x <= edgeX { return "left" }
        if x >= 1 - edgeX { return "right" }
        if x >= 1.0 / 3 && x <= 2.0 / 3 {
            if y <= edgeY { return "top" }
            if y >= 1 - edgeY { return "bottom" }
        }
        return nil
    }
}

/// What gestures can do (Linux's catalog, linux/src/gestures/catalog.js, with macOS's counterparts).
public enum GestureCatalog {
    public struct Action: Equatable {
        public let id: String, group: String, title: String
        public let live: Bool
        public let keys: String?
        init(_ id: String, _ group: String, _ title: String, live: Bool = false, keys: String? = nil) {
            self.id = id; self.group = group; self.title = title; self.live = live; self.keys = keys
        }
    }

    public static let gestures = ["swipe3-left", "swipe3-right", "swipe3-up", "swipe3-down", "swipe4-left", "swipe4-right", "swipe4-up", "swipe4-down",
                                  "pinch3-in", "pinch3-out", "pinch4-in", "pinch4-out", "hold3", "hold4"]

    public static let actions: [Action] = [
        Action("none", "", "Nothing"),
        Action("app-switcher", "Apps and windows", "Switch apps (like ⌘Tab)", live: true),
        Action("previous-app", "Apps and windows", "Back to the previous app", keys: "<Super>Tab"),
        Action("show-desktop", "Apps and windows", "Show the desktop"),
        Action("window-maximize", "Apps and windows", "Maximize or restore the window"),
        Action("window-minimize", "Apps and windows", "Minimize the window", keys: "<Super>m"),
        Action("window-fullscreen", "Apps and windows", "Full screen on or off", keys: "<Super><Control>f"),
        Action("window-close", "Apps and windows", "Close the window", keys: "<Super>w"),
        Action("tile-left", "Apps and windows", "Window to the left half"),
        Action("tile-right", "Apps and windows", "Window to the right half"),
        Action("workspace-left", "Desktops", "Desktop on the left", keys: "<Control>Left"),
        Action("workspace-right", "Desktops", "Desktop on the right", keys: "<Control>Right"),
        Action("overview-toggle", "Desktops", "Mission Control", keys: "<Control>Up"),
        Action("app-grid", "Desktops", "Launchpad"),
        Action("notifications", "Desktops", "Notification Center"),
        Action("screenshot-ui", "Desktops", "Screenshot (macOS)", keys: "<Super><Shift>5"),
        Action("lock", "Desktops", "Lock the screen", keys: "<Super><Control>q"),
        Action("volume-up", "Sound and light", "Volume up"),
        Action("volume-down", "Sound and light", "Volume down"),
        Action("volume-mute", "Sound and light", "Mute or unmute"),
        Action("brightness-up", "Sound and light", "Brighter screen"),
        Action("brightness-down", "Sound and light", "Darker screen"),
        Action("play-pause", "Sound and light", "Play or pause"),
        Action("next", "Sound and light", "Next track"),
        Action("prev", "Sound and light", "Previous track"),
        Action("back", "Browser and documents", "Back", keys: "<Super>bracketleft"),
        Action("forward", "Browser and documents", "Forward", keys: "<Super>bracketright"),
        Action("tab-next", "Browser and documents", "Next tab", keys: "<Control>Tab"),
        Action("tab-prev", "Browser and documents", "Previous tab", keys: "<Control><Shift>Tab"),
        Action("tab-new", "Browser and documents", "New tab", keys: "<Super>t"),
        Action("tab-close", "Browser and documents", "Close the tab", keys: "<Super>w"),
        Action("tab-reopen", "Browser and documents", "Reopen the closed tab", keys: "<Super><Shift>t"),
        Action("reload", "Browser and documents", "Reload", keys: "<Super>r"),
        Action("zoom-in", "Browser and documents", "Zoom in", keys: "<Super>equal"),
        Action("zoom-out", "Browser and documents", "Zoom out", keys: "<Super>minus"),
        Action("copy", "Browser and documents", "Copy", keys: "<Super>c"),
        Action("paste", "Browser and documents", "Paste", keys: "<Super>v"),
        Action("undo", "Browser and documents", "Undo", keys: "<Super>z"),
        Action("muna:muna", "Muna", "Open Muna"),
        Action("muna:tray", "Muna", "Tray"),
        Action("muna:clipboard", "Muna", "Clipboard history"),
        Action("muna:notifications", "Muna", "Alerts"),
        Action("muna:command", "Muna", "Search (command bar)"),
        Action("muna:quickpanel", "Muna", "Quick panel"),
        Action("muna:radial", "Muna", "Radial menu"),
        Action("muna:screenshot", "Muna", "Screenshot (Muna)"),
        Action("muna:color", "Muna", "Colour picker"),
        Action("muna:mic", "Muna", "Microphone on or off"),
        Action("muna:awake", "Muna", "Keep awake"),
        Action("muna:output", "Muna", "Next sound output"),
        Action("muna:dark", "Muna", "Dark style on or off"),
        Action("muna:night", "Muna", "Night Shift on or off"),
        Action("muna:cleaning", "Muna", "Cleaning mode"),
        Action("muna:recording", "Muna", "Record the screen"),
    ]

    /// Linux's defaults: three fingers switch apps, four the desktops, up is Mission Control.
    public static let defaults: [String: String] = [
        "swipe3-left": "app-switcher", "swipe3-right": "app-switcher", "swipe3-up": "overview-toggle", "swipe3-down": "show-desktop",
        "swipe4-left": "workspace-right", "swipe4-right": "workspace-left", "swipe4-up": "overview-toggle", "swipe4-down": "show-desktop",
    ]

    public static let edgeDefaults: [String: String] = [
        "edge-left-plus": "brightness-up", "edge-left-minus": "brightness-down", "edge-right-plus": "volume-up", "edge-right-minus": "volume-down",
        "edge-top-plus": "brightness-up", "edge-top-minus": "brightness-down", "edge-bottom-plus": "volume-up", "edge-bottom-minus": "volume-down",
        "edge-tap-left": "none", "edge-tap-right": "none", "edge-tap-top": "play-pause", "edge-tap-bottom": "none",
        "edge-hold-left": "none", "edge-hold-right": "none", "edge-hold-top": "play-pause", "edge-hold-bottom": "none",
    ]

    public static func find(_ id: String?) -> Action { actions.first { $0.id == id } ?? actions[0] }

    /// "<Control><Shift>t" → (modifiers, key); nil for an unknown modifier.
    public static func parseKeys(_ accel: String) -> (modifiers: [String], key: String)? {
        var modifiers: [String] = []
        var rest = Substring(accel)
        while rest.hasPrefix("<"), let close = rest.firstIndex(of: ">") {
            modifiers.append(rest[rest.index(after: rest.startIndex)..<close].lowercased())
            rest = rest[rest.index(after: close)...]
        }
        guard modifiers.allSatisfy({ ["control", "ctrl", "primary", "shift", "alt", "super"].contains($0) }) else { return nil }
        return (modifiers, String(rest))
    }
}
