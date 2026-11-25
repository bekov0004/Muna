import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// Where a window goes, as Linux's Windows widget: halves, quarters, thirds, two-thirds, maximize, center, next screen.
enum WindowLayout: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird
    case leftTwoThirds, rightTwoThirds
    case maximize, center, nextScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: return "Left"
        case .rightHalf: return "Right"
        case .topHalf: return "Top"
        case .bottomHalf: return "Bottom"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .leftThird: return "Left ⅓"
        case .centerThird: return "Middle ⅓"
        case .rightThird: return "Right ⅓"
        case .leftTwoThirds: return "Left ⅔"
        case .rightTwoThirds: return "Right ⅔"
        case .maximize: return "Maximize"
        case .center: return "Center"
        case .nextScreen: return "Next screen"
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .topLeft: return "square.grid.2x2"
        case .topRight: return "square.grid.2x2"
        case .bottomLeft: return "square.grid.2x2"
        case .bottomRight: return "square.grid.2x2"
        case .leftThird: return "rectangle.leadingthird.inset.filled"
        case .centerThird: return "rectangle.center.inset.filled"
        case .rightThird: return "rectangle.trailingthird.inset.filled"
        case .leftTwoThirds: return "rectangle.split.2x1"
        case .rightTwoThirds: return "rectangle.split.2x1"
        case .maximize: return "macwindow"
        case .center: return "rectangle.center.inset.filled"
        case .nextScreen: return "display.2"
        }
    }

    /// The frame inside an area (Cocoa coordinates, origin bottom-left); `current` is the window's frame now.
    func frame(in a: CGRect, current: CGRect) -> CGRect {
        let w2 = a.width / 2, h2 = a.height / 2, w3 = a.width / 3
        switch self {
        case .leftHalf: return CGRect(x: a.minX, y: a.minY, width: w2, height: a.height)
        case .rightHalf: return CGRect(x: a.minX + w2, y: a.minY, width: w2, height: a.height)
        case .topHalf: return CGRect(x: a.minX, y: a.minY + h2, width: a.width, height: h2)
        case .bottomHalf: return CGRect(x: a.minX, y: a.minY, width: a.width, height: h2)
        case .topLeft: return CGRect(x: a.minX, y: a.minY + h2, width: w2, height: h2)
        case .topRight: return CGRect(x: a.minX + w2, y: a.minY + h2, width: w2, height: h2)
        case .bottomLeft: return CGRect(x: a.minX, y: a.minY, width: w2, height: h2)
        case .bottomRight: return CGRect(x: a.minX + w2, y: a.minY, width: w2, height: h2)
        case .leftThird: return CGRect(x: a.minX, y: a.minY, width: w3, height: a.height)
        case .centerThird: return CGRect(x: a.minX + w3, y: a.minY, width: w3, height: a.height)
        case .rightThird: return CGRect(x: a.minX + 2 * w3, y: a.minY, width: w3, height: a.height)
        case .leftTwoThirds: return CGRect(x: a.minX, y: a.minY, width: 2 * w3, height: a.height)
        case .rightTwoThirds: return CGRect(x: a.minX + w3, y: a.minY, width: 2 * w3, height: a.height)
        case .maximize: return a
        case .center, .nextScreen:
            let w = min(current.width, a.width), h = min(current.height, a.height)
            return CGRect(x: a.midX - w / 2, y: a.midY - h / 2, width: w, height: h)
        }
    }
}

/// Moves the focused window of the target app through the Accessibility API.
final class WindowsModel: ObservableObject {
    /// The app that was in front when the quick panel opened.
    var target: NSRunningApplication?
    @Published var message: String?
    @Published var trusted: Bool = AXIsProcessTrusted()

    private var messageTimer: Timer?

    func refreshTrust() {
        trusted = AXIsProcessTrusted()
    }

    func apply(_ layout: WindowLayout) {
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
            if !trusted {
                show("Allow Muna in System Settings → Privacy & Security → Accessibility")
            }
            return
        }
        trusted = true
        guard let app = targetApp() else { show("No window to move"); return }
        guard let window = focusedWindow(of: app), let current = frame(of: window) else {
            show("No window to move"); return
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        // The screen holding most of the window.
        var index = 0
        var best: CGFloat = -1
        for (i, screen) in screens.enumerated() {
            let cut = screen.frame.intersection(current)
            let area = cut.isNull ? 0 : cut.width * cut.height
            if area > best { best = area; index = i }
        }
        if layout == .nextScreen {
            if screens.count < 2 { show("Only one screen"); return }
            index = (index + 1) % screens.count
        }
        let goal = layout.frame(in: screens[index].visibleFrame, current: current)
        setFrame(goal, of: window)
        message = nil
    }

    // MARK: - Accessibility

    private func targetApp() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let app = target, !app.isTerminated, app.processIdentifier != me { return app }
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != me { return app }
        return nil
    }

    private func focusedWindow(of app: NSRunningApplication) -> AXUIElement? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        return nil
    }

    /// The window's frame in Cocoa coordinates.
    private func frame(of window: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let p = posValue, let s = sizeValue,
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(x: point.x, y: primaryHeight() - point.y - size.height, width: size.width, height: size.height)
    }

    /// Sets a Cocoa-coordinate frame. Size, position, size again: some apps clamp to the old screen.
    private func setFrame(_ rect: CGRect, of window: AXUIElement) {
        var point = CGPoint(x: rect.minX, y: primaryHeight() - rect.maxY)
        var size = CGSize(width: rect.width, height: rect.height)
        guard let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
    }

    private func primaryHeight() -> CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    private func show(_ text: String) {
        message = text
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            self?.message = nil
        }
    }
}

/// The Windows page of the quick panel: a grid of layout tiles.
struct WindowsPage: View {
    @EnvironmentObject var windows: WindowsModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuickBlock {
                HStack {
                    Text("Windows")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(MunaColor.text)
                    Spacer()
                    if !windows.trusted {
                        Pill(label: "Allow", accent: true) {
                            windows.apply(.center)
                        }
                    }
                }
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(WindowLayout.allCases) { layout in
                        ToolTile(symbol: layout.symbol, label: layout.title) {
                            windows.apply(layout)
                        }
                    }
                }
                .foregroundColor(MunaColor.text)
                if let message = windows.message {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundColor(MunaColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { windows.refreshTrust() }
    }
}
