import Combine
import Foundation
import MunaCore
import SwiftUI

/// Focus: a stopwatch with laps and a focus timer (work, short breaks, a long break every few
/// rounds; each phase starts by itself). Wall-clock times, so both survive a restart; focus.json.
final class FocusModel: ObservableObject {
    struct Config: Codable, Equatable {
        var work = 25
        var short = 5
        var long = 15
        var every = 4
    }

    struct Stopwatch: Codable {
        var state = "idle"
        var since: Double = 0
        var elapsed: Double = 0
        var laps: [Double] = []
    }

    struct Pomo: Codable {
        var state = "idle"
        var phase = "work"
        var endAt: Double = 0
        var remaining: Double = 25 * 60_000
        var round = 1
        var done = 0
        var config = Config()
    }

    private struct File: Codable {
        var version = 1
        var stopwatch: Stopwatch?
        var pomo: Pomo?
    }

    @Published private(set) var stopwatch = Stopwatch()
    @Published private(set) var pomo = Pomo()
    /// Moves every half second while something runs, so the page redraws.
    @Published private(set) var now = Date()
    /// The settings being edited on the page (minutes).
    @Published var editing = Config()
    @Published var showSettings = false

    /// A phase ran out: (title, details).
    var onPhaseEnd: (String, String) -> Void = { _, _ in }

    private let store = JSONStore(name: "focus.json")
    private var ticker: Timer?
    private var phaseTimer: Timer?

    init() {
        load()
        editing = pomo.config
        updateTicker()
    }

    private static func nowMs() -> Double { Double(nowMilliseconds()) }

    private static func clean(_ c: Config) -> Config {
        func n(_ value: Int, _ low: Int, _ high: Int) -> Int { min(high, max(low, value)) }
        return Config(work: n(c.work, 1, 180), short: n(c.short, 1, 60), long: n(c.long, 1, 120), every: n(c.every, 2, 10))
    }

    private func duration(_ phase: String) -> Double {
        let c = pomo.config
        let minutes = phase == "work" ? c.work : phase == "long" ? c.long : c.short
        return Double(minutes) * 60_000
    }

    private func load() {
        guard let file = store.load(File.self) else { return }
        if var sw = file.stopwatch, ["idle", "running", "paused"].contains(sw.state) {
            sw.laps = Array(sw.laps.suffix(50))
            stopwatch = sw
        }
        if var p = file.pomo {
            p.config = FocusModel.clean(p.config)
            if !["work", "break", "long"].contains(p.phase) { p.phase = "work" }
            if !["idle", "running", "paused"].contains(p.state) { p.state = "idle" }
            p.round = max(1, p.round)
            p.done = max(0, p.done)
            p.remaining = max(0, p.remaining)
            pomo = p
            if pomo.state == "running" {
                if pomo.endAt <= FocusModel.nowMs() {
                    resetPomoState()   // it ran out while nobody was there
                } else {
                    armPhaseTimer()
                }
            }
        }
    }

    private func save() {
        try? store.save(File(version: 1, stopwatch: stopwatch, pomo: pomo))
        updateTicker()
    }

    private func updateTicker() {
        let running = stopwatch.state == "running" || pomo.state == "running"
        if running && ticker == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.now = Date() }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        } else if !running {
            ticker?.invalidate()
            ticker = nil
        }
        now = Date()
    }

    // MARK: Stopwatch

    /// Milliseconds on the stopwatch now.
    var stopwatchMs: Double {
        stopwatch.elapsed + (stopwatch.state == "running" ? FocusModel.nowMs() - stopwatch.since : 0)
    }

    func stopwatchStart() {
        guard stopwatch.state != "running" else { return }
        stopwatch.state = "running"
        stopwatch.since = FocusModel.nowMs()
        save()
    }

    func stopwatchPause() {
        guard stopwatch.state == "running" else { return }
        stopwatch.elapsed += FocusModel.nowMs() - stopwatch.since
        stopwatch.state = "paused"
        save()
    }

    func stopwatchLap() {
        guard stopwatch.state == "running" else { return }
        stopwatch.laps = Array((stopwatch.laps + [stopwatchMs]).suffix(50))
        save()
    }

    func stopwatchReset() {
        stopwatch = Stopwatch()
        save()
    }

    // MARK: Focus timer

    /// Milliseconds left in the current phase.
    var pomoRemainingMs: Double {
        pomo.state == "running" ? max(0, pomo.endAt - FocusModel.nowMs()) : pomo.remaining
    }

    /// Share of the phase gone, 0...1.
    var pomoProgress: Double {
        let total = duration(pomo.phase)
        return total > 0 ? min(1, max(0, 1 - pomoRemainingMs / total)) : 0
    }

    func pomoStart() {
        guard pomo.state != "running" else { return }
        if pomo.state == "paused" {
            pomo.endAt = FocusModel.nowMs() + pomo.remaining
        } else {
            pomo.config = FocusModel.clean(editing)
            pomo.phase = "work"
            pomo.round = 1
            pomo.done = 0
            pomo.remaining = duration("work")
            pomo.endAt = FocusModel.nowMs() + pomo.remaining
        }
        pomo.state = "running"
        showSettings = false
        armPhaseTimer()
        save()
    }

    func pomoPause() {
        guard pomo.state == "running" else { return }
        pomo.remaining = max(0, pomo.endAt - FocusModel.nowMs())
        pomo.state = "paused"
        disarm()
        save()
    }

    /// Ends the phase now: the next one begins.
    func pomoSkip() {
        guard pomo.state != "idle" else { return }
        advance(announce: false)
    }

    func pomoReset() {
        disarm()
        resetPomoState()
        save()
    }

    /// Applies the edited minutes (only while idle).
    func applySettings() {
        guard pomo.state == "idle" else { return }
        editing = FocusModel.clean(editing)
        pomo.config = editing
        pomo.remaining = duration("work")
        save()
    }

    private func resetPomoState() {
        pomo.state = "idle"
        pomo.phase = "work"
        pomo.round = 1
        pomo.done = 0
        pomo.endAt = 0
        pomo.remaining = duration("work")
    }

    private func armPhaseTimer() {
        disarm()
        let seconds = max(0.05, (pomo.endAt - FocusModel.nowMs()) / 1000)
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            self?.phaseTimer = nil
            self?.advance(announce: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        phaseTimer = timer
    }

    private func disarm() {
        phaseTimer?.invalidate()
        phaseTimer = nil
    }

    /// The current phase is over (it ran out or was skipped): begin the next one.
    private func advance(announce: Bool) {
        let finished = pomo.phase
        let next: String
        if finished == "work" {
            pomo.done += 1
            next = pomo.done % pomo.config.every == 0 ? "long" : "break"
        } else {
            next = "work"
            pomo.round = finished == "long" ? 1 : pomo.round + 1
        }
        pomo.phase = next
        pomo.remaining = duration(next)
        pomo.endAt = FocusModel.nowMs() + pomo.remaining
        pomo.state = "running"
        armPhaseTimer()
        save()
        if announce {
            let minutes = Int(duration(next) / 60_000)
            let title = next == "work" ? "Back to work" : next == "long" ? "Long break" : "Short break"
            let details = next == "work" ? "Round \(pomo.round) · \(minutes) min" : "Work done · \(minutes) min break"
            onPhaseEnd(title, details)
        }
    }

    static func phaseName(_ phase: String) -> String {
        phase == "work" ? "Focus" : phase == "long" ? "Long break" : "Short break"
    }

    /// "12:34" or "1:02:03"; with tenths for the stopwatch.
    static func clock(_ ms: Double, tenths: Bool = false) -> String {
        let total = Int(max(0, ms))
        let seconds = tenths ? total / 1000 : Int((max(0, ms) / 1000).rounded(.up))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        var text = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
        if tenths { text += ".\((total % 1000) / 100)" }
        return text
    }
}

struct FocusPage: View {
    @EnvironmentObject var focus: FocusModel

    var body: some View {
        VStack(spacing: 10) {
            pomoBlock
            stopwatchBlock
        }
    }

    private var pomoBlock: some View {
        QuickBlock {
            Caption("Focus timer") {
                if focus.pomo.state == "idle" {
                    Pill(label: "Minutes", active: focus.showSettings) { focus.showSettings.toggle() }
                }
            }
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.1), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: CGFloat(focus.pomoProgress))
                        .stroke(focus.pomo.phase == "work" ? MunaColor.accent : MunaColor.ok,
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(FocusModel.clock(focus.pomoRemainingMs))
                        .font(.system(size: 24, weight: .semibold).monospacedDigit())
                        .foregroundColor(MunaColor.text)
                    Text("\(FocusModel.phaseName(focus.pomo.phase)) · round \(focus.pomo.round) · \(focus.pomo.done) done")
                        .font(.system(size: 11))
                        .foregroundColor(MunaColor.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                if focus.pomo.state == "running" {
                    Pill(label: "Pause", accent: true) { focus.pomoPause() }
                } else {
                    Pill(label: focus.pomo.state == "paused" ? "Resume" : "Start", accent: true) { focus.pomoStart() }
                }
                Pill(label: "Skip", disabled: focus.pomo.state == "idle") { focus.pomoSkip() }
                Pill(label: "Reset", disabled: focus.pomo.state == "idle") { focus.pomoReset() }
            }
            if focus.showSettings && focus.pomo.state == "idle" {
                VStack(spacing: 4) {
                    Stepper("Work: \(focus.editing.work) min", value: $focus.editing.work, in: 1...180)
                    Stepper("Short break: \(focus.editing.short) min", value: $focus.editing.short, in: 1...60)
                    Stepper("Long break: \(focus.editing.long) min", value: $focus.editing.long, in: 1...120)
                    Stepper("Long break every \(focus.editing.every) rounds", value: $focus.editing.every, in: 2...10)
                }
                .font(.system(size: 12))
                .onChange(of: focus.editing) { _ in focus.applySettings() }
            }
        }
    }

    private var stopwatchBlock: some View {
        QuickBlock {
            Caption("Stopwatch")
            Text(FocusModel.clock(focus.stopwatchMs, tenths: true))
                .font(.system(size: 24, weight: .semibold).monospacedDigit())
                .foregroundColor(MunaColor.text)
            HStack(spacing: 6) {
                if focus.stopwatch.state == "running" {
                    Pill(label: "Pause", accent: true) { focus.stopwatchPause() }
                    Pill(label: "Lap") { focus.stopwatchLap() }
                } else {
                    Pill(label: focus.stopwatch.state == "paused" ? "Resume" : "Start", accent: true) { focus.stopwatchStart() }
                }
                Pill(label: "Reset", disabled: focus.stopwatch.state == "idle") { focus.stopwatchReset() }
            }
            if !focus.stopwatch.laps.isEmpty {
                let laps = focus.stopwatch.laps
                VStack(spacing: 3) {
                    ForEach(Array(laps.indices.reversed().prefix(8)), id: \.self) { index in
                        HStack {
                            Text("Lap \(index + 1)").foregroundColor(MunaColor.secondary)
                            Spacer()
                            Text("+" + FocusModel.clock(laps[index] - (index > 0 ? laps[index - 1] : 0), tenths: true))
                                .foregroundColor(MunaColor.secondary)
                            Text(FocusModel.clock(laps[index], tenths: true)).foregroundColor(MunaColor.text)
                        }
                        .font(.system(size: 11).monospacedDigit())
                    }
                }
            }
        }
    }
}
