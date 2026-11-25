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
