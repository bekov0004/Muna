import AppKit
import Combine
import SwiftUI

/// What the capsule's butterfly is doing: how open its wings are, whether it blinks, whether they are warm.
/// One per capsule (CapsuleModel.butterfly), so a redraw does not cut a wing beat.
final class ButterflyMotion: ObservableObject {
    /// 1: wings spread, 0: folded against the body.
    @Published private(set) var open: CGFloat = 1
    @Published private(set) var blinking = false
    /// Something happened (a card came while the capsule was closed): warm wings until it opens.
    @Published var warm = false

    private var flapTimer: Timer?

    /// Two beats of the wings, then a blink (Linux's flap(): 900 ms, a blink 900 ms later).
    func flap() {
        guard flapTimer == nil else { return }
        let duration = 0.9 / max(Preferences.shared.animationSpeed, 0.25)
        let start = Date()
        flapTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = Date().timeIntervalSince(start) / duration
            if t >= 1 {
                timer.invalidate()
                self.flapTimer = nil
                self.open = 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.blink() }
                return
            }
            self.open = 1 - 0.85 * abs(sin(2 * .pi * t))
        }
    }

    /// It closes its eyes for a moment.
    func blink() {
        guard !blinking else { return }
        blinking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.blinking = false }
    }
}

/// The little butterfly of the capsule, looking at you, drawn as Linux draws it (linux/src/ui/butterfly.js):
/// a round face, big eyes, pink cheeks, a smile, round wings and antennae. Coordinates x -38..38, y -32..32.
struct MunaButterflyView: View {
    @EnvironmentObject var motion: ButterflyMotion
    let height: CGFloat

    private static let upper: [CGFloat] = [-20, -6, 16, 12, -25]   // cx, cy, rx, ry, rotation of the left upper wing
    private static let lower: [CGFloat] = [-15, 13, 10, 8, 25]
    private static let face = Color(red: 0xe9 / 255, green: 0xe6 / 255, blue: 1)
    private static let ink = Color(red: 10 / 255, green: 10 / 255, blue: 16 / 255)
    private static let cool = [Color(red: 0x6f / 255, green: 0xe7 / 255, blue: 1), Color(red: 0xc0 / 255, green: 0x8b / 255, blue: 1)]
    private static let hot = [Color(red: 1, green: 0xd3 / 255, blue: 0x6e / 255), Color(red: 1, green: 0x8a / 255, blue: 0x3d / 255),
                              Color(red: 1, green: 0x3d / 255, blue: 0x77 / 255)]

    var body: some View {
        let open = motion.open, blinking = motion.blinking, warm = motion.warm
        Canvas { context, size in
            Self.draw(context, size, open: open, blinking: blinking, warm: warm)
        }
        .frame(width: height * 76 / 64, height: height)
        .allowsHitTesting(false)
    }

    private static func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ degrees: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry))
            .applying(CGAffineTransform(rotationAngle: degrees * .pi / 180).concatenating(CGAffineTransform(translationX: cx, y: cy)))
    }

    private static func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }

    static func draw(_ base: GraphicsContext, _ size: CGSize, open: CGFloat, blinking: Bool, warm: Bool) {
        var context = base
        let scale = min(size.width / 76, size.height / 64)
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.scaleBy(x: scale, y: scale)

        // the wings, folding towards the body
        for sign: CGFloat in [-1, 1] {
            var wings = context
            wings.scaleBy(x: max(0.12, open), y: 1)
            let shading = GraphicsContext.Shading.linearGradient(Gradient(colors: warm ? hot : cool),
                                                                 startPoint: CGPoint(x: sign * -36, y: -18), endPoint: CGPoint(x: sign * -4, y: 22))
            wings.fill(oval(sign * upper[0], upper[1], upper[2], upper[3], sign * upper[4]), with: shading)
            var low = wings
            low.opacity = 0.8
            low.fill(oval(sign * lower[0], lower[1], lower[2], lower[3], sign * lower[4]), with: shading)
        }

        // antennae
        for sign: CGFloat in [-1, 1] {
            var line = Path()
            line.move(to: CGPoint(x: sign * 5, y: -12))
            line.addCurve(to: CGPoint(x: sign * 14, y: -25), control1: CGPoint(x: sign * 7.67, y: -18.67), control2: CGPoint(x: sign * 10.67, y: -23))
            context.stroke(line, with: .color(face), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            context.fill(dot(sign * 14, -25, 2.4), with: .color(face))
        }

        // the face
        context.fill(dot(0, 2, 13), with: .color(face))
        let r: CGFloat = 4.6
        for sign: CGFloat in [-1, 1] {
            let x = sign * 5.4
            if blinking {
                var lid = Path()
                lid.move(to: CGPoint(x: x - r, y: 0))
                lid.addCurve(to: CGPoint(x: x + r, y: 0), control1: CGPoint(x: x - r / 3, y: r * 0.47), control2: CGPoint(x: x + r / 3, y: r * 0.47))
                context.stroke(lid, with: .color(ink), lineWidth: r * 0.45)
                continue
            }
            context.fill(dot(x, 0, r), with: .color(.white))
            context.fill(dot(x, r * 0.1, r * 0.55), with: .color(ink))
            context.fill(dot(x + r * 0.22, -r * 0.15, r * 0.18), with: .color(.white))
        }
        // cheeks and a smile
        for sign: CGFloat in [-1, 1] {
            context.fill(dot(sign * 8.5, 7, 2), with: .color(Color(red: 1, green: 0.62, blue: 0.78).opacity(0.7)))
        }
        var smile = Path()
        smile.move(to: CGPoint(x: -3, y: 8))
        smile.addCurve(to: CGPoint(x: 3, y: 8), control1: CGPoint(x: -1, y: 9.67), control2: CGPoint(x: 1, y: 9.67))
        context.stroke(smile, with: .color(ink), lineWidth: 1.4)
    }
}
