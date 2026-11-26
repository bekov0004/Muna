import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// Brightness of every screen, as Linux's Displays widget: the built-in screen through macOS's own
/// control (DisplayServices, loaded at run time), the others by Muna dimming their picture (as on
/// Linux for monitors without a control). And a picture of where the screens stand.
final class DisplaysModel: ObservableObject {
    struct Display: Identifiable, Equatable {
        let id: CGDirectDisplayID
        let name: String
        let builtIn: Bool
        let frame: CGRect
        /// 0…1
        var brightness: Double
        /// true: the screen's real brightness; false: Muna dims the picture.
        let hardware: Bool
    }

    @Published private(set) var displays: [Display] = []

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let getBrightness: GetBrightness?
    private let setBrightness: SetBrightness?
    /// How much Muna dims each screen without a control (1: not at all).
    private var dimming: [CGDirectDisplayID: Double] = [:]

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        if let handle, let get = dlsym(handle, "DisplayServicesGetBrightness"), let set = dlsym(handle, "DisplayServicesSetBrightness") {
            getBrightness = unsafeBitCast(get, to: GetBrightness.self)
            setBrightness = unsafeBitCast(set, to: SetBrightness.self)
        } else {
            getBrightness = nil
            setBrightness = nil
        }
    }

    func refresh() {
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let builtIn = CGDisplayIsBuiltin(id) != 0
            var level: Float = 0
            let hardware = builtIn && getBrightness?(id, &level) == 0
            return Display(id: id, name: screen.localizedName, builtIn: builtIn, frame: screen.frame,
                           brightness: hardware ? Double(level) : (dimming[id] ?? 1), hardware: hardware)
        }
    }

    func set(_ display: Display, _ value: Double) {
        let value = min(max(value, 0), 1)
        if display.hardware {
            _ = setBrightness?(display.id, Float(value))
        } else {
            // never fully black: the screen must stay readable
            let level = 0.15 + 0.85 * value
            dimming[display.id] = value
            CGSetDisplayTransferByFormula(display.id, 0, Float(level), 1, 0, Float(level), 1, 0, Float(level), 1)
        }
        if let index = displays.firstIndex(where: { $0.id == display.id }) {
            displays[index].brightness = value
        }
    }

    /// Gives every dimmed screen its own colours back (when Muna quits).
    func restore() {
        if !dimming.isEmpty { CGDisplayRestoreColorSyncSettings() }
        dimming = [:]
    }
}

struct DisplaysPage: View {
    @EnvironmentObject var displays: DisplaysModel

    var body: some View {
        VStack(spacing: 10) {
            ArrangementBlock()
            QuickBlock {
                ForEach(displays.displays) { display in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: display.builtIn ? "laptopcomputer" : "display")
                            Text(display.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text(display.hardware ? "\(Int(display.brightness * 100))%" : "picture \(Int(display.brightness * 100))%")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundColor(MunaColor.secondary)
                        }
                        Slider(value: Binding(get: { display.brightness }, set: { displays.set(display, $0) }), in: 0...1)
                    }
                }
                if displays.displays.contains(where: { !$0.hardware }) {
                    Text("Screens without a brightness control: Muna dims their picture.")
                        .font(.system(size: 10))
                        .foregroundColor(MunaColor.secondary)
                }
            }
            DisplaySwitches()
            if displays.displays.count > 1 {
                QuickBlock {
                    Arrangement(displays: displays.displays)
                        .frame(height: 90)
                }
            }
        }
        .onAppear { displays.refresh() }
    }
}

/// Where the screens stand, drawn small.
struct Arrangement: View {
    let displays: [DisplaysModel.Display]

    var body: some View {
        GeometryReader { proxy in
            let union = displays.reduce(CGRect.null) { $0.union($1.frame) }
            let scale = min(proxy.size.width / max(union.width, 1), proxy.size.height / max(union.height, 1)) * 0.95
            ZStack(alignment: .topLeading) {
                ForEach(displays) { display in
                    let x = (display.frame.minX - union.minX) * scale
                    let y = (union.maxY - display.frame.maxY) * scale
                    RoundedRectangle(cornerRadius: 4)
                        .fill(display.builtIn ? MunaColor.accent.opacity(0.35) : Color.white.opacity(0.12))
                        .overlay(Text(display.name).font(.system(size: 9)).lineLimit(1).padding(2))
                        .frame(width: display.frame.width * scale, height: display.frame.height * scale)
                        .offset(x: x, y: y)
                }
            }
        }
    }
}

/// Linux's arrangement of the monitors: the main one, the side each other one stands on, joined or
/// mirrored (Core Graphics' display configuration; "only one screen" is not something macOS lets
/// an app do: mirroring is the nearest).
enum DisplayArrangement {
    private static var main: CGDirectDisplayID { CGMainDisplayID() }

    private static func configure(_ change: (CGDisplayConfigRef) -> Void) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        change(config)
        CGCompleteDisplayConfiguration(config, .permanently)
    }

    /// The main one moves to 0,0 (it gets the menu bar and the Dock); the others keep their places around it.
    static func makeMain(_ id: CGDirectDisplayID) {
        let origin = CGDisplayBounds(id).origin
        configure { config in
            for display in NSScreen.screens.compactMap(Self.id) {
                let bounds = CGDisplayBounds(display)
                CGConfigureDisplayOrigin(config, display, Int32(bounds.minX - origin.x), Int32(bounds.minY - origin.y))
            }
        }
    }

    /// "left", "right", "above", "below" of the main one.
    static func putBeside(_ id: CGDirectDisplayID, _ side: String) {
        let m = CGDisplayBounds(main), b = CGDisplayBounds(id)
        let origin: CGPoint
        switch side {
        case "left": origin = CGPoint(x: m.minX - b.width, y: m.minY)
        case "above": origin = CGPoint(x: m.minX, y: m.minY - b.height)
        case "below": origin = CGPoint(x: m.minX, y: m.maxY)
        default: origin = CGPoint(x: m.maxX, y: m.minY)
        }
        configure { CGConfigureDisplayOrigin($0, id, Int32(origin.x), Int32(origin.y)) }
    }

    static func sideOf(_ id: CGDirectDisplayID) -> String {
        let m = CGDisplayBounds(main), b = CGDisplayBounds(id)
        let dx = b.midX - m.midX, dy = b.midY - m.midY
        return abs(dx) * m.height >= abs(dy) * m.width ? (dx < 0 ? "left" : "right") : (dy < 0 ? "above" : "below")
    }

    static func mirror(_ on: Bool) {
        configure { config in
            for display in NSScreen.screens.compactMap(Self.id) where display != main {
                CGConfigureDisplayMirrorOfDisplay(config, display, on ? main : kCGNullDirectDisplay)
            }
        }
    }

    static func id(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}

struct ArrangementBlock: View {
    @EnvironmentObject var displays: DisplaysModel

    var body: some View {
        if displays.displays.count > 1 {
            QuickBlock {
                Text("WHERE THE SCREENS STAND").font(.system(size: 10, weight: .heavy)).foregroundColor(MunaColor.caption)
                ForEach(displays.displays.filter { $0.id != CGMainDisplayID() }) { display in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(display.name).font(.system(size: 12, weight: .semibold))
                        HStack {
                            Picker("", selection: Binding(get: { DisplayArrangement.sideOf(display.id) }, set: { DisplayArrangement.putBeside(display.id, $0); displays.refresh() })) {
                                Text("Left").tag("left")
                                Text("Right").tag("right")
                                Text("Above").tag("above")
                                Text("Below").tag("below")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            Pill(label: "Make main") { DisplayArrangement.makeMain(display.id); displays.refresh() }
                        }
                    }
                }
                HStack {
                    Pill(label: "Join") { DisplayArrangement.mirror(false) }
                    Pill(label: "Mirror") { DisplayArrangement.mirror(true) }
                    Spacer()
                    Pill(label: "Display settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!) }
                }
            }
        }
    }
}

/// Night Shift, the keyboard light and automatic brightness, as in Linux's displays tab.
struct DisplaySwitches: View {
    @EnvironmentObject var state: QuickPanelState

    var body: some View {
        QuickBlock {
            if NightShift.available {
                row("moon", "Night Shift", "Warmer colours", on: NightShift.isOn) { NightShift.set($0) }
            }
            if let auto = AutoBrightness.isOn {
                row("sun.max", "Automatic brightness", "The light sensor sets the screen's brightness", on: auto) { on in
                    if !AutoBrightness.set(on) { state.message = "macOS did not allow it" }
                }
            }
            if KeyboardLight.available { VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "light.max").foregroundColor(MunaColor.secondary)
                    Text("Keyboard light").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(Int(KeyboardLight.level * 100))%").font(.system(size: 11).monospacedDigit()).foregroundColor(MunaColor.secondary)
                }
                Slider(value: Binding(get: { KeyboardLight.level }, set: { KeyboardLight.set($0); state.objectWillChange.send() }), in: 0...1)
            } }
        }
    }

    private func row(_ symbol: String, _ title: String, _ details: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundColor(MunaColor.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(details).font(.system(size: 10)).foregroundColor(MunaColor.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: { set($0); state.objectWillChange.send() })).toggleStyle(.switch).labelsHidden()
        }
    }
}
