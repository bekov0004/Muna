import AppKit
import SwiftUI

/// The radial menu, as on Linux (linux/src/tools/radialMenu.js): a ring of round buttons around the
/// pointer, opened with a shortcut (⌃⌥Space). A click runs one; Esc or a click elsewhere closes it.
struct RadialAction: Identifiable {
    let id: String
    let symbol: String
    let label: String
    let run: () -> Void
}

final class RadialPanel: NSPanel {
    var onEscape: () -> Void = {}

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: RadialMenu.size, height: RadialMenu.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape()
    }

    override func resignKey() {
        super.resignKey()
        onEscape()
    }
}

final class RadialMenu {
    static let size: CGFloat = 280
    private let panel = RadialPanel()
    private let actions: () -> [RadialAction]

    init(actions: @escaping () -> [RadialAction]) {
        self.actions = actions
        panel.onEscape = { [weak self] in self?.close() }
    }

    var isOpen: Bool { panel.isVisible }

    /// Opens around the pointer (again: closes).
    func toggle() {
        if isOpen {
            close()
            return
        }
        let pointer = NSEvent.mouseLocation
        let view = RadialView(actions: actions()) { [weak self] action in
            self?.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { action.run() }
        } onClose: { [weak self] in
            self?.close()
        }
        panel.contentView = NSHostingView(rootView: view)
        panel.setFrame(NSRect(x: pointer.x - Self.size / 2, y: pointer.y - Self.size / 2, width: Self.size, height: Self.size), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}

struct RadialView: View {
    let actions: [RadialAction]
    let choose: (RadialAction) -> Void
    let onClose: () -> Void

    var body: some View {
        let radius = RadialMenu.size / 2 - 38
        ZStack {
            Circle().fill(Color.black.opacity(0.55)).frame(width: RadialMenu.size - 8, height: RadialMenu.size - 8)
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                let angle = Double(index) / Double(max(actions.count, 1)) * 2 * Double.pi - Double.pi / 2
                Button { choose(action) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: action.symbol).font(.system(size: 16, weight: .semibold))
                        Text(action.label).font(.system(size: 8, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundColor(.white)
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(Color.white.opacity(0.14)))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(action.label)
                .offset(x: CGFloat(cos(angle)) * radius, y: CGFloat(sin(angle)) * radius)
            }
            Button(action: onClose) {
                ButterflyImage(height: 22)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.black))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: RadialMenu.size, height: RadialMenu.size)
    }
}
