import AppKit
import LocalAuthentication
import Combine
import MunaCore
import SwiftUI

/// The capsules of all screens (Settings → General → Screens: every screen, the main one, or the
/// built-in one with the notch), as Muna on Linux has one per chosen monitor. What happens once for
/// the whole app (a card, a file coming in, the Command Bar) is handled here; the capsule that
/// opens for it is the one of the screen with the pointer.
final class CapsuleManager {
    private var meetingTimer: Timer?
    private var butterflyTimer: Timer?
    private var toldMeetings: Set<String> = []
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
    var onAgents: () -> Void = {} {
        didSet { controllers.forEach { $0.model.onAgents = onAgents } }
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
        app.focus.onPhaseEnd = { [weak self] title, details in
            self?.tell(title, details, symbol: "target", ok: true)
        }
        app.reminders.onDue = { [weak self] text in
            if Preferences.shared.bool("reminder-sound") { NSSound(named: "Glass")?.play() }
            self?.tell("Reminder", text, symbol: "bell.badge.fill", ok: true)
        }
        // Live Activities: the next meeting from 10 minutes before it, files added to the tray
        app.tray.onAdded = { [weak self] count in
            guard Preferences.shared.bool("activity-files") else { return }
            self?.tell(count == 1 ? "Added a file" : "Added \(count) files", "To the Tray", symbol: "tray.and.arrow.down.fill", ok: true,
                       seconds: Preferences.shared.double("peek-files-seconds"))
        }
        // the butterfly's reminders of Settings → Appearance (once, every day, weekdays)
        butterflyTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            let p = Preferences.shared
            var list = ButterflyReminders.parseList(p.string("reminders"))
            let now = Date()
            var changed = false
            for index in list.indices where ButterflyReminders.isDue(list[index], now: now) {
                if p.bool("reminder-sound") { NSSound(named: "Glass")?.play() }
                self?.tell("Reminder", list[index].text, symbol: "bell.badge.fill", ok: true, seconds: 8)
                list[index] = ButterflyReminders.rang(list[index], now: now)
                changed = true
            }
            if changed { p.set("reminders", ButterflyReminders.toJSON(list)) }
        }
        meetingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, Preferences.shared.bool("activity-calendar") else { return }
            for event in self.app.calendar.events(on: Date()) where !event.allDay {
                let minutes = event.start.timeIntervalSinceNow / 60
                if minutes > 0, minutes <= 10, self.toldMeetings.insert(event.id + "\(event.start.timeIntervalSince1970)").inserted {
                    self.tell(event.title, "In \(Int(minutes.rounded(.up))) min · \(event.start.formatted(date: .omitted, time: .shortened))", symbol: "calendar", ok: true,
                              seconds: Preferences.shared.double("peek-calendar-seconds"))
                }
            }
        }
        app.downloads.onFinished = { [weak self] url in
            guard Preferences.shared.bool("activity-downloads") else { return }
            self?.tell("Downloaded", url.lastPathComponent, symbol: "arrow.down.circle.fill", ok: true)
        }
        app.agents.onPermission = { [weak self] task, permission in
            guard let self else { return }
            if let capsule = self.current {
                capsule.model.tab = .agent
                capsule.openNow()
            }
            // Settings → Touch ID → Claude Code's questions: a finger on the reader allows it
            if Preferences.shared.bool("fingerprint-agents") { self.confirmWithTouchID(task, permission) }
        }
        app.agents.onFinished = { [weak self] task, ok in
            guard Preferences.shared.bool("agents-alerts") else { return }
            self?.tell(ok ? "\(task.project) is done" : "\(task.project) stopped", ok ? task.current : task.error,
                       symbol: ok ? "sparkles" : "exclamationmark.triangle.fill", ok: ok)
        }
        app.command.onDone = { [weak self] in
            self?.controllers.filter { $0.model.isOpen && $0.model.tab == .command }.forEach { $0.close() }
        }
    }

    private func confirmWithTouchID(_ task: ClaudeTask, _ permission: ClaudeTask.Permission) {
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &problem) else { return }
        context.localizedCancelTitle = "Answer in the capsule"
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "allow Claude to \(permission.verb.lowercased()) \(permission.detail)") { [weak self] ok, _ in
            DispatchQueue.main.async {
                guard ok, let agents = self?.app.agents, agents.waiting?.permission.requestId == permission.requestId else { return }
                agents.answer(task, permission, .allow)
            }
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
                controller.model.onAgents = onAgents
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
    func tell(_ title: String, _ details: String, symbol: String, ok: Bool, seconds: Double? = nil) {
        app.alerts.add(title, details, symbol: symbol, ok: ok)
        app.companion.surprise()
        let card = CapsuleCard(title: title, details: details, symbol: symbol, ok: ok, seconds: seconds)
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
