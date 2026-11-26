import AppKit
import Carbon
import Combine
import MunaCore

/// Reads the fingers on the trackpad (the Mac's own MultitouchSupport, what gesture tools use; no
/// permission is needed to read) and turns them into Linux's gestures with TouchGestures.
/// macOS keeps doing its own three- and four-finger gestures unless they are turned off in System
/// Settings → Trackpad; pinches of three or four fingers, holds and the edges are Muna's alone.
final class Trackpad {
    static let shared = Trackpad()
    let recognizer = TouchGestures()
    var onGesture: (GestureEvent) -> Void = { _ in }
    private(set) var found = false
    private var devices: [UnsafeMutableRawPointer] = []
    private var tick: Timer?
    private var touching = false

    private typealias Callback = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void

    private var register: Register?
    private var unregister: Register?
    private var stop: Stop?

    /// The fingers' records (struct Finger of MultitouchSupport): 96 bytes each; the id at 16, the
    /// state at 20 (4 and 5: touching), the position (0–1, y up) at 32 and 36.
    private static let callback: Callback = { _, data, count, timestamp, _ in
        guard let data else { return 0 }
        var contacts: [Contact] = []
        for i in 0..<Int(max(0, count)) {
            let finger = UnsafeRawPointer(data).advanced(by: i * 96)
            let state = finger.load(fromByteOffset: 20, as: Int32.self)
            guard state == 4 || state == 5 else { continue }
            let id = finger.load(fromByteOffset: 16, as: Int32.self)
            let x = Double(finger.load(fromByteOffset: 32, as: Float.self))
            let y = 1 - Double(finger.load(fromByteOffset: 36, as: Float.self))
            contacts.append(Contact(id: Int(id), x: x, y: y))
        }
        DispatchQueue.main.async { Trackpad.shared.frame(contacts, time: timestamp) }
        return 0
    }

    func start() {
        guard devices.isEmpty else { return }
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
              let create = dlsym(handle, "MTDeviceCreateList"), let registerFn = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startFn = dlsym(handle, "MTDeviceStart") else { return }
        register = unsafeBitCast(registerFn, to: Register.self)
        if let fn = dlsym(handle, "MTUnregisterContactFrameCallback") { unregister = unsafeBitCast(fn, to: Register.self) }
        if let fn = dlsym(handle, "MTDeviceStop") { stop = unsafeBitCast(fn, to: Stop.self) }
        let start = unsafeBitCast(startFn, to: Start.self)
        guard let list = unsafeBitCast(create, to: CreateList.self)()?.takeRetainedValue() as? [AnyObject] else { return }
        for device in list {
            let pointer = Unmanaged.passRetained(device).toOpaque()
            register?(pointer, Self.callback)
            start(pointer, 0)
            devices.append(pointer)
        }
        found = !devices.isEmpty
        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.touching else { return }
            self.recognizer.tick(time: ProcessInfo.processInfo.systemUptime).forEach(self.onGesture)
        }
    }

    func stopAll() {
        tick?.invalidate()
        tick = nil
        for device in devices {
            unregister?(device, Self.callback)
            stop?(device)
            Unmanaged<AnyObject>.fromOpaque(device).release()
        }
        devices.removeAll()
    }

    private func frame(_ contacts: [Contact], time: Double) {
        touching = !contacts.isEmpty
        recognizer.frame(contacts, time: time).forEach(onGesture)
    }
}

/// What a gesture does on the Mac (the actions of GestureCatalog), and the live app switcher:
/// macOS's own ⌘Tab, held while the fingers move, one app per step.
final class GestureActions {
    private let app: AppState
    var run: (String) -> Void = { _ in }       // Muna's own actions (set by the app delegate)
    private var liveGesture: String?
    private var liveTravel = 0.0
    private var observers: [AnyCancellable] = []
    private static let switchStep = 0.09

    init(app: AppState) {
        self.app = app
        Trackpad.shared.onGesture = { [weak self] in self?.handle($0) }
        Preferences.shared.changed.sink { [weak self] key in
            if ["touchpad-gestures", "edge-gestures", "gesture-sensitivity", "*"].contains(key) { DispatchQueue.main.async { self?.apply() } }
        }.store(in: &observers)
    }

    func apply() {
        let p = Preferences.shared
        if p.bool("touchpad-gestures") || p.bool("edge-gestures") {
            Trackpad.shared.start()
        } else {
            Trackpad.shared.stopAll()
        }
        Trackpad.shared.recognizer.edges = p.bool("edge-gestures")
        Trackpad.shared.recognizer.sensitivity = p.double("gesture-sensitivity")
    }

    private func handle(_ event: GestureEvent) {
        let p = Preferences.shared
        let many = p.bool("touchpad-gestures")
        switch event {
        case .swipeLocked(let gesture) where many:
            if GestureCatalog.find(GestureSettings.action(gesture, edge: false)).live { beginLive(gesture) }
        case .swipeMoved(let gesture, let delta) where gesture == liveGesture:
            liveTravel += delta
            while liveTravel >= Self.switchStep { liveTravel -= Self.switchStep; Keyboard.tap(UInt16(kVK_Tab), flags: .maskCommand) }
            while liveTravel <= -Self.switchStep { liveTravel += Self.switchStep; Keyboard.tap(UInt16(kVK_Tab), flags: [.maskCommand, .maskShift]) }
        case .swipeTriggered(let gesture) where many && gesture != liveGesture:
            perform(GestureSettings.action(gesture, edge: false))
        case .swipeEnded(let gesture) where gesture == liveGesture:
            endLive()
        case .pinched(let gesture) where many, .held(let gesture) where many:
            perform(GestureSettings.action(gesture, edge: false))
        case .edgeStep(let edge, let direction):
            perform(GestureSettings.action("edge-\(edge)-\(direction > 0 ? "plus" : "minus")", edge: true))
        case .edgeDoubleTap(let zone):
            perform(GestureSettings.action("edge-tap-\(zone)", edge: true))
        case .edgeHold(let zone):
            perform(GestureSettings.action("edge-hold-\(zone)", edge: true))
        default:
            break
        }
    }

    /// ⌘ goes down and Tab shows the switcher with the next app; each step one more; lifting the fingers lets ⌘ go.
    private func beginLive(_ gesture: String) {
        liveGesture = gesture
        liveTravel = 0
        Keyboard.post(UInt16(kVK_Command), down: true, flags: .maskCommand)
        Keyboard.tap(UInt16(kVK_Tab), flags: .maskCommand)
    }

    private func endLive() {
        guard liveGesture != nil else { return }
        liveGesture = nil
        Keyboard.post(UInt16(kVK_Command), down: false, flags: [])
    }

    func perform(_ id: String) {
        guard !id.isEmpty, id != "none" else { return }
        if id.hasPrefix("keys:") { Keyboard.press(String(id.dropFirst(5))); return }
        if id.hasPrefix("muna:") { run(String(id.dropFirst(5))); return }
        let action = GestureCatalog.find(id)
        if let keys = action.keys { Keyboard.press(keys); return }
        switch id {
        case "app-switcher": Keyboard.press("<Super>Tab")
        case "show-desktop": MissionControl.run("1")
        case "overview-toggle": MissionControl.run(nil)
        case "app-grid": NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Launchpad.app"))
        case "notifications":
            var error: NSDictionary?
            _ = NSAppleScript(source: "tell application \"System Events\" to tell process \"ControlCenter\" to click menu bar item \"Clock\" of menu bar 1")?.executeAndReturnError(&error)
        case "window-maximize": app.windows.target = NSWorkspace.shared.frontmostApplication; app.windows.apply(.maximize)
        case "tile-left": app.windows.target = NSWorkspace.shared.frontmostApplication; app.windows.apply(.leftHalf)
        case "tile-right": app.windows.target = NSWorkspace.shared.frontmostApplication; app.windows.apply(.rightHalf)
        case "volume-up": app.sound.refresh(); app.sound.setVolume(min(1, app.sound.volume + 1.0 / 16))
        case "volume-down": app.sound.refresh(); app.sound.setVolume(max(0, app.sound.volume - 1.0 / 16))
        case "volume-mute": app.sound.refresh(); app.sound.toggleMute()
        case "brightness-up": brightness(0.0625)
        case "brightness-down": brightness(-0.0625)
        case "play-pause": app.nowPlaying.playPause()
        case "next": app.nowPlaying.next()
        case "prev": app.nowPlaying.previous()
        default: break
        }
    }

    /// The screen under the pointer, a step brighter or darker.
    private func brightness(_ step: Double) {
        let displays = app.displays
        displays.refresh()
        let pointer = NSEvent.mouseLocation
        guard let display = displays.displays.first(where: { $0.frame.contains(pointer) }) ?? displays.displays.first else { return }
        displays.set(display, display.brightness + step)
    }
}

/// Mission Control's own program: no argument opens it, "1" shows the desktop, "2" the windows of the app.
enum MissionControl {
    static func run(_ argument: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control")
        if let argument { process.arguments = [argument] }
        try? process.run()
    }
}

/// Key presses for macOS's own shortcuts (CGEvent; macOS asks once for Accessibility).
enum Keyboard {
    static func post(_ key: UInt16, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: key, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    static func tap(_ key: UInt16, flags: CGEventFlags) {
        post(key, down: true, flags: flags)
        post(key, down: false, flags: flags)
    }

    /// Linux's way of writing keys: "<Super><Shift>t", "<Control>Left", "F5".
    static func press(_ accel: String) {
        guard let parsed = GestureCatalog.parseKeys(accel), let key = code(parsed.key) else { return }
        var flags: CGEventFlags = []
        for modifier in parsed.modifiers {
            switch modifier {
            case "shift": flags.insert(.maskShift)
            case "alt": flags.insert(.maskAlternate)
            case "super": flags.insert(.maskCommand)
            default: flags.insert(.maskControl)
            }
        }
        tap(key, flags: flags)
    }

    static func code(_ name: String) -> UInt16? {
        let letters: [Character: Int] = ["a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
                                         "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
                                         "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
                                         "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
                                         "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
                                         "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9]
        if name.count == 1, let c = name.lowercased().first, let code = letters[c] { return UInt16(code) }
        let named: [String: Int] = [
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow, "tab": kVK_Tab, "return": kVK_Return,
            "escape": kVK_Escape, "space": kVK_Space, "delete": kVK_ForwardDelete, "backspace": kVK_Delete, "home": kVK_Home, "end": kVK_End,
            "page_up": kVK_PageUp, "page_down": kVK_PageDown, "equal": kVK_ANSI_Equal, "plus": kVK_ANSI_Equal, "minus": kVK_ANSI_Minus,
            "bracketleft": kVK_ANSI_LeftBracket, "bracketright": kVK_ANSI_RightBracket,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
            "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        ]
        return named[name.lowercased()].map { UInt16($0) }
    }
}
