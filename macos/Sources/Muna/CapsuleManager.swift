import AppKit
import Combine
import MunaCore
import SwiftUI

/// The capsules of all screens (Settings → General → Screens: every screen, the main one, or the
/// built-in one with the notch), as Muna on Linux has one per chosen monitor. What happens once for
/// the whole app (a card, a file coming in, the Command Bar) is handled here; the capsule that
/// opens for it is the one of the screen with the pointer.
final class CapsuleManager {
    private let app: AppState
    private let preferences = Preferences.shared
    private var controllers: [CapsuleController] = []
    private var observers: [AnyCancellable] = []
    private var screenObserver: NSObjectProtocol?
    private var lastIncomingState: IncomingTransfer.State?
    /// The gear of a capsule.
    var onSettings: () -> Void = {} {
        didSet { controllers.forEach { $0.model.onSettings = onSettings } }
    }

    init(app: AppState) {
        self.app = app
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() }
        preferences.$capsuleScreens.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuild() }
        }.store(in: &observers)

        app.localSend.notify = { [weak self] title, details, ok in
            self?.tell(title, details, symbol: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", ok: ok)
        }
        app.localSend.onIncoming = { [weak self] in
            guard let capsule = self?.current else { return }
            capsule.model.tab = .localSend
            capsule.openNow()
        }
        app.localSend.incomingPublisher.dropFirst().sink { [weak self] incoming in
            self?.incomingChanged(incoming)
        }.store(in: &observers)
        app.timer.onFinished = { [weak self] in
            self?.tell("Time is up", "The timer ended", symbol: "timer", ok: true)
        }
        app.command.onDone = { [weak self] in
            self?.controllers.filter { $0.model.isOpen && $0.model.tab == .command }.forEach { $0.close() }
        }
    }

    /// Shows the capsules, and once where Muna is (it has no window and no Dock icon).
    func show() {
        rebuild()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let capsule = self?.current else { return }
            let place = capsule.model.geometry.hasNotch ? "Point at the notch or click it" : "Point at the capsule or click it"
            capsule.showCard(CapsuleCard(title: "Muna is here", details: place, symbol: "sparkles", ok: true))
        }
    }

    /// The screens that get a capsule.
    private var screens: [NSScreen] {
        let all = NSScreen.screens
        switch preferences.capsuleScreens {
        case "main":
            return Array(all.prefix(1))
        case "notch":
            let notched = all.filter { $0.safeAreaInsets.top > 0 }
            return notched.isEmpty ? Array(all.prefix(1)) : notched
        default:
            return all
        }
    }

    /// Makes, keeps or removes a capsule for each screen.
    private func rebuild() {
        let wanted = screens
        let wantedIds = wanted.map { CapsuleGeometry.id(of: $0) }
        for controller in controllers where !wantedIds.contains(controller.screenId) {
            controller.remove()
        }
        var kept = controllers.filter { wantedIds.contains($0.screenId) }
        for screen in wanted {
            let id = CapsuleGeometry.id(of: screen)
            if let controller = kept.first(where: { $0.screenId == id }) {
                controller.update(screen: screen)
            } else {
                let controller = CapsuleController(app: app, screen: screen)
                controller.model.onSettings = onSettings
                controller.show()
                kept.append(controller)
            }
        }
        controllers = kept
    }

    /// The capsule of the screen with the pointer (else the first one).
    var current: CapsuleController? {
        let pointer = NSEvent.mouseLocation
        return controllers.first { $0.contains(pointer) } ?? controllers.first
    }

    /// Opens a section in the capsule under the pointer.
    func open(on tab: PanelTab) {
        current?.open(on: tab)
    }

    /// The Command Bar in the capsule under the pointer (again: it closes).
    func openCommand() {
        if let open = controllers.first(where: { $0.model.isOpen && $0.model.tab == .command }) {
            open.close()
            return
        }
        current?.openCommand()
    }

    /// Something happened: a card in every closed capsule, and a line in the Alerts section.
    func tell(_ title: String, _ details: String, symbol: String, ok: Bool) {
        app.alerts.add(title, details, symbol: symbol, ok: ok)
        let card = CapsuleCard(title: title, details: details, symbol: symbol, ok: ok)
        controllers.forEach { $0.showCard(card) }
    }

    private func incomingChanged(_ incoming: IncomingSnapshot?) {
        defer { lastIncomingState = incoming?.state }
        guard let incoming, incoming.state != lastIncomingState else { return }
        let count = incoming.fileNames.count
        let files = "\(count) file\(count == 1 ? "" : "s")"
        switch incoming.state {
        case .done:
            tell("Received from \(incoming.sender)", files, symbol: "checkmark.circle.fill", ok: true)
        case .failed:
            tell("From \(incoming.sender)", incoming.error ?? "The transfer stopped", symbol: "exclamationmark.triangle.fill", ok: false)
        default:
            break
        }
    }
}
