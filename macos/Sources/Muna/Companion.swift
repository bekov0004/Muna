import AppKit
import Combine
import SwiftUI

/// Companion: a small friend that lives in the capsule. Its eyes follow the pointer, it blinks, it
/// sways to the music, looks surprised when a card pops up, and falls asleep when nothing happens.
final class CompanionModel: ObservableObject {
    /// Seconds since the start, drives the sway.
    @Published private(set) var time: Double = 0
    /// Where the eyes look: a unit-ish vector, y down.
    @Published private(set) var look = CGPoint.zero
    @Published private(set) var blinking = false
    @Published private(set) var surprised = false
    @Published private(set) var asleep = false
    /// Set from outside while music plays.
    @Published var musicPlaying = false {
        didSet { if musicPlaying { idle = 0 } }
    }
    /// The timer runs only while the widget is shown.
    var active = false {
        didSet {
            guard active != oldValue else { return }
            if active { start() } else { stop() }
        }
    }

    private var timer: Timer?
    private var blink: Double = 0
    private var nextBlink: Double = 2.5
    private var surpriseLeft: Double = 0
    private var idle: Double = 0
    private var last = NSEvent.mouseLocation
    private let frame = 0.05

    /// A card arrived: wide eyes for a moment, and awake again.
    func surprise() {
        surpriseLeft = 1.2
        idle = 0
    }

    private func start() {
        last = NSEvent.mouseLocation
        let timer = Timer(timeInterval: frame, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func step() {
        let dt = frame
        time += dt
        let mouse = NSEvent.mouseLocation
        if hypot(mouse.x - last.x, mouse.y - last.y) > 2 { idle = 0 } else { idle += dt }
        last = mouse

        nextBlink -= dt
        if nextBlink <= 0 {
            blink = 0.14
            nextBlink = 2 + Double.random(in: 0...4)
        }
        blink = max(0, blink - dt)
        surpriseLeft = max(0, surpriseLeft - dt)

        // The capsule hangs from the middle of the main screen's top: look from there (y flipped to go down).
        if let screen = NSScreen.main?.frame {
            let dx = mouse.x - screen.midX
            let dy = (screen.maxY - 60) - mouse.y
            let d = max(1, hypot(dx, dy))
            let reach = min(1, d / 200)
            look = CGPoint(x: dx / d * reach, y: dy / d * reach)
        }
        blinking = blink > 0
        surprised = surpriseLeft > 0
        asleep = idle > 25 && !musicPlaying
    }
}

struct CompanionWidget: View {
    @EnvironmentObject var companion: CompanionModel

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let t = companion.time
            let playing = companion.musicPlaying
            let sway = playing ? sin(t * 5) * size * 0.04 : sin(t * 1.5) * size * 0.012
            let bob = playing ? abs(sin(t * 5)) * size * 0.05 : 0
            let face = size * 0.72
            ZStack {
                RoundedRectangle(cornerRadius: face * 0.3, style: .continuous)
                    .fill(MunaColor.muna)
                    .overlay(RoundedRectangle(cornerRadius: face * 0.3, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: size * 0.015))
                    .frame(width: face, height: face)
                HStack(spacing: face * 0.22) {
                    eye(size: face)
                    eye(size: face)
                }
                .offset(y: -face * 0.06)
                mouth(size: face)
                    .offset(y: face * 0.22)
                if companion.asleep {
                    Text("z")
                        .font(.system(size: size * 0.16, weight: .bold, design: .rounded))
                        .foregroundColor(MunaColor.text)
                        .offset(x: face * 0.5, y: -face * 0.55 - CGFloat(sin(t * 2)) * size * 0.03)
                }
            }
            .rotationEffect(.degrees(playing ? sin(t * 5) * 6 : 0))
            .offset(x: sway, y: size * 0.04 - bob)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(width: 88, height: 112)
        .background(Color.black)
        .onAppear { companion.active = true }
        .onDisappear { companion.active = false }
    }

    private func eye(size: CGFloat) -> some View {
        let radius = size * (companion.surprised ? 0.13 : 0.1)
        return ZStack {
            if companion.asleep || companion.blinking {
                Capsule()
                    .fill(Color(red: 0.1, green: 0.12, blue: 0.2))
                    .frame(width: radius * 2, height: size * 0.035)
            } else {
                Circle().fill(Color.white).frame(width: radius * 2, height: radius * 2)
                Circle()
                    .fill(Color(red: 0.1, green: 0.12, blue: 0.2))
                    .frame(width: radius, height: radius)
                    .offset(x: companion.look.x * radius * 0.45, y: companion.look.y * radius * 0.45)
            }
        }
        .frame(width: size * 0.28, height: size * 0.28)
    }

    private func mouth(size: CGFloat) -> some View {
        Group {
            if companion.surprised {
                Circle()
                    .stroke(Color(red: 0.1, green: 0.12, blue: 0.2), lineWidth: size * 0.035)
                    .frame(width: size * 0.12, height: size * 0.12)
            } else {
                SmileShape()
                    .stroke(Color(red: 0.1, green: 0.12, blue: 0.2),
                            style: StrokeStyle(lineWidth: size * 0.035, lineCap: .round))
                    .frame(width: size * 0.24, height: size * 0.08)
            }
        }
    }
}

/// A small smile: a curve from one corner to the other.
private struct SmileShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * 2))
        return path
    }
}
