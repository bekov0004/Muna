import AppKit
import ApplicationServices
import Combine
import MunaCore
import ScreenCaptureKit
import SwiftUI

/// Linux's window map and tiling (linux/src/windows/windowMap.js, layout.js): the windows of a screen
/// with their live pictures (ScreenCaptureKit, after macOS asks once for Screen Recording); drag one
/// to move it (let go at an edge: half or a quarter, at the top: all of it), click to bring it forward,
/// ✕ closes it; all windows at once in columns, rows, a grid or main + side, and undo.
final class WindowMapModel: ObservableObject {
    struct Item: Identifiable {
        let id: String
        let element: AXUIElement
        let pid: pid_t
        let windowId: CGWindowID?
        let title: String
        let app: String
        let frame: CGRect      // Cocoa coordinates
    }

    @Published var screenIndex = 0
    @Published private(set) var items: [Item] = []
    @Published private(set) var pictures: [CGWindowID: NSImage] = [:]
    private var before: [(AXUIElement, CGRect)] = []
    private var timer: Timer?
    let windows: WindowsModel

    init(windows: WindowsModel) { self.windows = windows }

    var screen: NSScreen { NSScreen.screens.indices.contains(screenIndex) ? NSScreen.screens[screenIndex] : (NSScreen.main ?? NSScreen.screens[0]) }

    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindow? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    func watch() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func unwatch() {
        timer?.invalidate()
        timer = nil
    }

    /// The windows on the chosen screen, front to back (not minimised, not Muna's).
    func refresh() {
        guard AXIsProcessTrusted() else { items = []; return }
        let me = ProcessInfo.processInfo.processIdentifier
        var found: [Item] = []
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != me && !app.isHidden {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success, let list = value as? [AXUIElement] else { continue }
            for window in list {
                var minimized: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success, (minimized as? Bool) == true { continue }
                guard let frame = windows.frame(of: window), frame.width > 40, frame.height > 40, screen.frame.intersects(frame) else { continue }
                var id = CGWindowID(0)
                let windowId = Self.getWindow?(window, &id) == .success ? id : nil
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                found.append(Item(id: "\(app.processIdentifier)-\(windowId ?? 0)-\(found.count)", element: window, pid: app.processIdentifier, windowId: windowId,
                                  title: title as? String ?? "", app: app.localizedName ?? "", frame: frame))
            }
        }
        // front to back as the window server stacks them
        items = found.sorted { (order.firstIndex(of: $0.windowId ?? 0) ?? .max) < (order.firstIndex(of: $1.windowId ?? 0) ?? .max) }
        takePictures()
    }

    private func takePictures() {
        guard #available(macOS 14.0, *), CGPreflightScreenCaptureAccess() else { return }
        let ids = Set(items.compactMap(\.windowId))
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, _ in
            guard let content else { return }
            for window in content.windows where ids.contains(window.windowID) {
                let configuration = SCStreamConfiguration()
                configuration.width = 320
                configuration.height = max(1, Int(320 * window.frame.height / max(window.frame.width, 1)))
                SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration) { image, _ in
                    guard let image else { return }
                    let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    DispatchQueue.main.async { self?.pictures[window.windowID] = picture }
                }
            }
        }
    }

    /// Asks macOS for Screen Recording (for the pictures; the map works without them).
    func askForPictures() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    // --- acting on windows ---------------------------------------------------------------------------

    func tile(_ mode: String) -> Int {
        let list = items
        guard !list.isEmpty else { return 0 }
        var ordered = list.sorted { ($0.frame.maxY, -$0.frame.minX) > ($1.frame.maxY, -$1.frame.minX) }
        if mode == "main", let front = list.first { ordered.removeAll { $0.id == front.id }; ordered.insert(front, at: 0) }
        before = ordered.map { ($0.element, $0.frame) }
        let area = screen.visibleFrame
        for (item, slot) in zip(ordered, TileSlots.slots(mode, ordered.count)) {
            // slots go from the top; Cocoa from the bottom
            let frame = CGRect(x: area.minX + slot.minX * area.width, y: area.maxY - slot.maxY * area.height, width: slot.width * area.width, height: slot.height * area.height)
            windows.setFrame(frame.integral, of: item.element)
        }
        refresh()
        return ordered.count
    }

    func undo() -> Bool {
        guard !before.isEmpty else { return false }
        for (element, frame) in before { windows.setFrame(frame, of: element) }
        before = []
        refresh()
        return true
    }

    func raise(_ item: Item) {
        AXUIElementPerformAction(item.element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: item.pid)?.activate(options: [])
    }

    func close(_ item: Item) {
        var button: CFTypeRef?
        if AXUIElementCopyAttributeValue(item.element, kAXCloseButtonAttribute as CFString, &button) == .success, let button {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    /// Let go at u, v (0…1 of the map, from the top left): an edge zone, or where it was dropped.
    func drop(_ item: Item, u: CGFloat, v: CGFloat, topLeft: CGPoint) {
        let edge: CGFloat = 0.1
        let area = screen.visibleFrame
        let left = u < edge, right = u > 1 - edge, top = v < edge, bottom = v > 1 - edge
        var zone: CGRect?
        switch (top, left, right, bottom) {
        case (true, true, _, _): zone = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case (true, _, true, _): zone = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case (_, true, _, true): zone = CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case (_, _, true, true): zone = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case (_, true, _, _): zone = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case (_, _, true, _): zone = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case (true, _, _, _): zone = CGRect(x: 0, y: 0, width: 1, height: 1)
        default: zone = nil
        }
        if let z = zone {
            windows.setFrame(CGRect(x: area.minX + z.minX * area.width, y: area.maxY - z.maxY * area.height, width: z.width * area.width, height: z.height * area.height).integral, of: item.element)
        } else {
            let full = screen.frame
            let frame = CGRect(x: full.minX + topLeft.x * full.width, y: full.maxY - topLeft.y * full.height - item.frame.height, width: item.frame.width, height: item.frame.height)
            windows.setFrame(frame.integral, of: item.element)
        }
        refresh()
    }
}

/// The map of one screen: a rectangle per window with its picture.
struct WindowMapView: View {
    @EnvironmentObject var map: WindowMapModel
    @EnvironmentObject var state: QuickPanelState
    static let width: CGFloat = 310

    var body: some View {
        let screen = map.screen.frame
        let scale = Self.width / max(screen.width, 1)
        let height = screen.height * scale
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15)))
            ForEach(Array(map.items.reversed())) { item in
                MapWindow(item: item, scale: scale, screen: screen, size: CGSize(width: Self.width, height: height))
            }
        }
        .frame(width: Self.width, height: height)
        .clipped()
    }
}

struct MapWindow: View {
    @EnvironmentObject var map: WindowMapModel
    let item: WindowMapModel.Item
    let scale: CGFloat
    let screen: CGRect
    let size: CGSize

    var body: some View {
        let x = (item.frame.minX - screen.minX) * scale
        let y = (screen.maxY - item.frame.maxY) * scale
        let w = max(14, item.frame.width * scale), h = max(10, item.frame.height * scale)
        ZStack(alignment: .topTrailing) {
            Group {
                if let id = item.windowId, let picture = map.pictures[id] {
                    Image(nsImage: picture).resizable()
                } else {
                    ZStack {
                        Color(white: 0.17)
                        if let app = NSRunningApplication(processIdentifier: item.pid), let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        }
                    }
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.4)))
            Button { map.close(item) } label: {
                Image(systemName: "xmark").font(.system(size: 6, weight: .bold)).foregroundColor(.white)
                    .frame(width: 12, height: 12).background(Circle().fill(Color.red.opacity(0.85)))
            }
            .buttonStyle(.plain)
            .padding(2)
        }
        .help("\(item.app): \(item.title)")
        .offset(x: x, y: y)
        .gesture(DragGesture(minimumDistance: 4).onEnded { drag in
            let end = CGPoint(x: x + drag.location.x, y: y + drag.location.y)
            map.drop(item, u: end.x / size.width, v: end.y / size.height,
                     topLeft: CGPoint(x: (x + drag.translation.width) / size.width, y: (y + drag.translation.height) / size.height))
        })
        .onTapGesture { map.raise(item) }
    }
}
