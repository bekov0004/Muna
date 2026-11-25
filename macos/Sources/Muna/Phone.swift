import AppKit
import Combine
import MunaCore
import SwiftUI

/// An Android phone in Muna's quick panel, through adb (as Linux's Phone widget without its helper
/// and app): the phones connected, the battery, the screen (a picture every second while shown),
/// taps and swipes on it, Back / Home / Recent apps / Wake, and typing.
final class PhoneModel: ObservableObject {
    struct Battery: Equatable {
        let percent: Int
        let charging: Bool
    }

    @Published private(set) var adb: String? = PhoneADB.findAdb()
    @Published private(set) var devices: [PhoneDevice] = []
    @Published var selected: String?
    @Published private(set) var screen: NSImage?
    /// The phone screen's size in pixels (the picture's).
    @Published private(set) var pixels = CGSize(width: 1080, height: 2340)
    @Published private(set) var battery: Battery?
    @Published var textDraft = ""

    private let queue = DispatchQueue(label: "dev.muna.phone")
    private var timer: Timer?
    private var capturing = false
    private var ticks = 0

    var device: PhoneDevice? { devices.first { $0.serial == selected } ?? devices.first { $0.ready } ?? devices.first }

    /// The page is shown: look for phones, and show the screen every second.
    func watch() {
        adb = adb ?? PhoneADB.findAdb()
        refreshDevices()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func unwatch() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        ticks += 1
        if ticks % 5 == 0 { refreshDevices() }
        capture()
    }

    // --- adb --------------------------------------------------------------------------------------

    /// Runs adb (on the phone's queue) and returns what it printed.
    private func run(_ arguments: [String]) -> Data {
        guard let adb else { return Data() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return Data() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    func refreshDevices() {
        guard adb != nil else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let devices = PhoneADB.parseDevices(String(decoding: self.run(["devices", "-l"]), as: UTF8.self))
            let chosen = devices.first { $0.serial == self.selected && $0.ready } ?? devices.first { $0.ready }
            var battery: Battery?
            if let chosen, let parsed = PhoneADB.parseBattery(String(decoding: self.run(["-s", chosen.serial, "shell", "dumpsys", "battery"]), as: UTF8.self)) {
                battery = Battery(percent: parsed.percent, charging: parsed.charging)
            }
            DispatchQueue.main.async {
                self.devices = devices
                if self.selected == nil || !devices.contains(where: { $0.serial == self.selected }) {
                    self.selected = chosen?.serial
                }
                self.battery = battery
            }
        }
    }

    private func capture() {
        guard !capturing, let serial = device?.serial, device?.ready == true else { return }
        capturing = true
        queue.async { [weak self] in
            guard let self else { return }
            let data = self.run(["-s", serial, "exec-out", "screencap", "-p"])
            let image = NSImage(data: data)
            DispatchQueue.main.async {
                self.capturing = false
                guard let image, let rep = image.representations.first, rep.pixelsWide > 0 else { return }
                self.screen = image
                self.pixels = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            }
        }
    }

    private func shell(_ arguments: [String]) {
        guard let serial = device?.serial else { return }
        queue.async { [weak self] in
            _ = self?.run(["-s", serial, "shell"] + arguments)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.capture() }
        }
    }

    // --- control ---------------------------------------------------------------------------------

    /// A point of the picture shown `size` big → the phone's pixels.
    private func phonePoint(_ point: CGPoint, in size: CGSize) -> (Int, Int) {
        let x = Int(min(max(point.x / max(size.width, 1), 0), 1) * pixels.width)
        let y = Int(min(max(point.y / max(size.height, 1), 0), 1) * pixels.height)
        return (x, y)
    }

    func tap(_ point: CGPoint, in size: CGSize) {
        let (x, y) = phonePoint(point, in: size)
        shell(["input", "tap", "\(x)", "\(y)"])
    }

    func swipe(from start: CGPoint, to end: CGPoint, in size: CGSize, seconds: Double) {
        let (x1, y1) = phonePoint(start, in: size)
        let (x2, y2) = phonePoint(end, in: size)
        let ms = Int(min(max(seconds * 1000, 80), 1000))
        shell(["input", "swipe", "\(x1)", "\(y1)", "\(x2)", "\(y2)", "\(ms)"])
    }

    func key(_ code: Int) {
        shell(["input", "keyevent", "\(code)"])
    }

    func sendText() {
        let text = textDraft
        guard !text.isEmpty else { return }
        textDraft = ""
        shell(["input", "text", PhoneADB.escapeInputText(text)])
    }
}

struct PhonePage: View {
    @EnvironmentObject var phone: PhoneModel

    var body: some View {
        VStack(spacing: 10) {
            if phone.adb == nil {
                QuickBlock {
                    Text("adb is not installed").font(.system(size: 13, weight: .semibold))
                    Text("Muna talks to an Android phone with adb. Install it once in the Terminal:")
                        .font(.system(size: 11))
                        .foregroundColor(MunaColor.secondary)
                    Text("brew install android-platform-tools").font(.system(size: 11, design: .monospaced))
                    Pill(label: "Look again") { phone.watch() }
                }
            } else if let device = phone.device {
                header(device)
                if device.ready {
                    screen
                    HStack(spacing: 6) {
                        ToolTile(symbol: "chevron.backward", label: "Back") { phone.key(PhoneADB.back) }
                        ToolTile(symbol: "circle", label: "Home") { phone.key(PhoneADB.home) }
                        ToolTile(symbol: "square.on.square", label: "Recent") { phone.key(PhoneADB.recents) }
                        ToolTile(symbol: "sun.max", label: "Wake") { phone.key(PhoneADB.wake) }
                    }
                    HStack(spacing: 6) {
                        TextField("Type on the phone", text: $phone.textDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { phone.sendText() }
                        Pill(label: "Send") { phone.sendText() }
                    }
                } else {
                    QuickBlock {
                        Text(device.state == "unauthorized" ? "Allow USB debugging on the phone (a question is on its screen)."
                             : "The phone is \(device.state).")
                            .font(.system(size: 12))
                    }
                }
            } else {
                QuickBlock {
                    Text("No phone").font(.system(size: 13, weight: .semibold))
                    Text("Connect an Android phone with a USB cable and switch on USB debugging (Settings → Developer options).")
                        .font(.system(size: 11))
                        .foregroundColor(MunaColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { phone.watch() }
        .onDisappear { phone.unwatch() }
    }

    private func header(_ device: PhoneDevice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone").font(.system(size: 16))
            Text(device.model).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer()
            if let battery = phone.battery {
                Image(systemName: battery.charging ? "battery.100.bolt" : "battery.75")
                Text("\(battery.percent)%").font(.system(size: 12).monospacedDigit())
            }
            if phone.devices.count > 1 {
                Menu("Phone") {
                    ForEach(phone.devices) { other in
                        Button(other.model) { phone.selected = other.serial }
                    }
                }
                .frame(width: 70)
            }
        }
    }

    /// The phone's screen: a click taps, a drag swipes.
    private var screen: some View {
        let ratio = phone.pixels.width / max(phone.pixels.height, 1)
        let height: CGFloat = 400
        let width = height * ratio
        return ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.06))
            if let image = phone.screen {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onEnded { drag in
            let size = CGSize(width: width, height: height)
            let distance = hypot(drag.translation.width, drag.translation.height)
            if distance < 8 {
                phone.tap(drag.location, in: size)
            } else {
                phone.swipe(from: drag.startLocation, to: drag.location, in: size, seconds: 0.3)
            }
        })
    }
}
