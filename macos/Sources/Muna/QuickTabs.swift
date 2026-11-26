import AppKit
import Combine
import IOKit
import IOKit.ps
import SwiftUI

// The tabs of Linux's top-bar window that the Mac's quick panel had not yet: Disks, Power, Input,
// Desktops, Utilities, Controls and Quick toggles (linux/src/widgets/*), with what macOS gives.

// --- Disks ------------------------------------------------------------------------------------------

final class DisksModel: ObservableObject {
    static let shared = DisksModel()

    struct Volume: Identifiable, Equatable {
        let url: URL
        let name: String
        let free: Int64
        let total: Int64
        let removable: Bool
        var id: String { url.path }
    }

    @Published private(set) var volumes: [Volume] = []
    @Published var selected: String = "/"
    @Published private(set) var readHistory: [Double] = []
    @Published private(set) var writeHistory: [Double] = []
    @Published private(set) var reading: Double = 0
    @Published private(set) var writing: Double = 0
    @Published private(set) var readSinceStart: UInt64 = 0
    @Published private(set) var writtenSinceStart: UInt64 = 0
    @Published private(set) var temperature: Double?
    private var first: (read: UInt64, write: UInt64)?
    private var last: (read: UInt64, write: UInt64, at: Date)?
    private var timer: Timer?
    private var watchers = 0

    func watch() {
        watchers += 1
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: max(1, Preferences.shared.double("monitor-interval")), repeats: true) { [weak self] _ in self?.sample() }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { timer?.invalidate(); timer = nil }
    }

    func sample() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let removable = url.path != "/" && (values.volumeIsRemovable == true || values.volumeIsEjectable == true || values.volumeIsInternal == false)
            return Volume(url: url, name: values.volumeName ?? url.lastPathComponent, free: values.volumeAvailableCapacityForImportantUsage ?? 0,
                          total: Int64(total), removable: removable)
        }
        temperature = Thermal.disk()
        let (read, write) = Self.bytes()
        if first == nil { first = (read, write) }
        if let last {
            let seconds = max(0.1, Date().timeIntervalSince(last.at))
            reading = Double(read >= last.read ? read - last.read : 0) / seconds
            writing = Double(write >= last.write ? write - last.write : 0) / seconds
            Self.push(&readHistory, reading)
            Self.push(&writeHistory, writing)
        }
        last = (read, write, Date())
        if let first {
            readSinceStart = read >= first.read ? read - first.read : 0
            writtenSinceStart = write >= first.write ? write - first.write : 0
        }
    }

    private static func push(_ list: inout [Double], _ value: Double) {
        list.append(value)
        if list.count > SystemMonitor.historyLength { list.removeFirst(list.count - SystemMonitor.historyLength) }
    }

    /// Bytes read and written by every disk since the Mac started (IOBlockStorageDriver's statistics).
    static func bytes() -> (UInt64, UInt64) {
        var read: UInt64 = 0, write: UInt64 = 0
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(entry)
        }
        return (read, write)
    }
}

struct DisksPage: View {
    @EnvironmentObject var disks: DisksModel

    var body: some View {
        let shown = disks.volumes.first { $0.id == disks.selected } ?? disks.volumes.first
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(disks.volumes) { volume in
                        Pill(label: volume.name, active: volume.id == shown?.id) { disks.selected = volume.id }
                    }
                }
            }
            if let volume = shown {
                QuickBlock {
                    MeterRow(label: volume.name, share: 1 - Double(volume.free) / Double(max(volume.total, 1)),
                             value: "\(sizeText(volume.free)) free of \(sizeText(volume.total))")
                    HStack(spacing: 6) {
                        Pill(label: "Open") { NSWorkspace.shared.open(volume.url) }
                        if volume.removable { Pill(label: "Eject") { QuickTools.eject(volume.url); disks.sample() } }
                        Spacer()
                        Pill(label: "Disk Utility") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app")) }
                    }
                }
            }
            QuickBlock {
                HStack {
                    Label(Readings.rate(disks.reading) + "/s", systemImage: "arrow.down.doc").foregroundColor(MunaColor.accent)
                    Spacer()
                    Label(Readings.rate(disks.writing) + "/s", systemImage: "arrow.up.doc").foregroundColor(MunaColor.muna)
                }
                .font(.system(size: 12).monospacedDigit())
                Graph(values: disks.readHistory)
                Text("Since Muna started: \(sizeText(Int64(disks.readSinceStart))) read, \(sizeText(Int64(disks.writtenSinceStart))) written")
                    .font(.system(size: 11)).foregroundColor(MunaColor.secondary)
                if let temperature = disks.temperature {
                    Text("Temperature \(Readings.temperature(temperature))").font(.system(size: 11)).foregroundColor(MunaColor.secondary)
                }
            }
        }
        .onAppear { disks.watch() }
        .onDisappear { disks.unwatch() }
    }
}

// --- Power ------------------------------------------------------------------------------------------

final class PowerModel: ObservableObject {
    static let shared = PowerModel()

    struct Health: Equatable { let percent: Int?; let cycles: Int?; let temperature: Double? }
    struct Device: Identifiable, Equatable { let name: String; let percent: Int; var id: String { name } }
    struct Busy: Identifiable, Equatable { let name: String; let cpu: Double; var id: String { name } }

    @Published private(set) var percent: Int?
    @Published private(set) var charging = false
    @Published private(set) var onPower = false
    @Published private(set) var minutesLeft: Int?
    @Published private(set) var history: [Double] = []
    @Published private(set) var watts: Double?
    @Published private(set) var adapterWatts: Int?
    @Published private(set) var health: Health?
    @Published private(set) var devices: [Device] = []
    @Published private(set) var busy: [Busy] = []
    @Published private(set) var temperature: Double?
    private var timer: Timer?
    private var watchers = 0

    func watch() {
        watchers += 1
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.sample() }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { timer?.invalidate(); timer = nil }
    }

    func sample() {
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
                let maximum = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
                percent = current * 100 / maximum
                charging = description[kIOPSIsChargingKey] as? Bool ?? false
                onPower = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
                let minutes = (charging ? description[kIOPSTimeToFullChargeKey] : description[kIOPSTimeToEmptyKey]) as? Int ?? -1
                minutesLeft = minutes > 0 ? minutes : nil
            }
        }
        if let percent {
            history.append(Double(percent) / 100)
            if history.count > 120 { history.removeFirst(history.count - 120) }
        }
        watts = Sensors.batteryWatts()
        adapterWatts = (IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any])?[kIOPSPowerAdapterWattsKey] as? Int
        health = Self.batteryHealth()
        temperature = Thermal.cpu()
        devices = Self.deviceBatteries()
        busy = Self.busyPrograms()
    }

    private static func batteryHealth() -> Health? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        func number(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        let design = number("DesignCapacity")
        let full = number("AppleRawMaxCapacity") ?? number("NominalChargeCapacity")
        let percent = design.flatMap { d in full.map { min(100, $0 * 100 / max(d, 1)) } }
        return Health(percent: percent, cycles: number("CycleCount"), temperature: number("Temperature").map { Double($0) / 100 })
    }

    /// Keyboards, mice and headphones that report their battery (their IOKit services).
    private static func deviceBatteries() -> [Device] {
        var found: [Device] = []
        for name in ["AppleDeviceManagementHIDEventService", "IOBluetoothDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { continue }
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                let percent = (IORegistryEntryCreateCFProperty(entry, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
                let product = IORegistryEntryCreateCFProperty(entry, "Product" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                if let percent, let product, !found.contains(where: { $0.name == product }) { found.append(Device(name: product, percent: percent)) }
                IOObjectRelease(entry)
            }
            IOObjectRelease(iterator)
        }
        return found
    }

    /// The programs that keep the processor busy now (and so use the energy).
    private static func busyPrograms() -> [Busy] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pcpu,comm", "-r"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst()
        return lines.prefix(5).compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let cpu = Double(parts[0]), cpu >= 1 else { return nil }
            return Busy(name: String(parts[1]), cpu: cpu)
        }
    }
}

struct PowerPage: View {
    @EnvironmentObject var power: PowerModel

    var body: some View {
        VStack(spacing: 10) {
            QuickBlock {
                if let percent = power.percent {
                    MeterRow(label: power.charging ? "Battery · charging" : power.onPower ? "Battery · on power" : "Battery",
                             share: Double(percent) / 100, value: "\(percent)%" + (power.minutesLeft.map { " · \($0 / 60) h \($0 % 60) min" } ?? ""))
                    Graph(values: power.history, top: 1)
                } else {
                    Text("This Mac has no battery.").font(.system(size: 12)).foregroundColor(MunaColor.secondary)
                }
                HStack {
                    if let watts = power.watts { Text(String(format: "Drawing %.1f W", watts)) }
                    Spacer()
                    if let adapter = power.adapterWatts { Text("Adapter \(adapter) W") }
                }
                .font(.system(size: 11)).foregroundColor(MunaColor.secondary)
            }
            if let health = power.health {
                QuickBlock {
                    if let percent = health.percent { MeterRow(label: "Battery health", share: Double(percent) / 100, value: "\(percent)%") }
                    HStack {
                        if let cycles = health.cycles { Text("\(cycles) cycles") }
                        Spacer()
                        if let t = health.temperature { Text("Battery \(Readings.temperature(t))") }
                        if let t = power.temperature { Text("· Processor \(Readings.temperature(t))") }
                    }
                    .font(.system(size: 11)).foregroundColor(MunaColor.secondary)
                }
            }
            if !power.busy.isEmpty {
                QuickBlock {
                    Text("USING THE PROCESSOR").font(.system(size: 10, weight: .heavy)).foregroundColor(MunaColor.caption)
                    ForEach(power.busy) { program in
                        HStack { Text(program.name).font(.system(size: 12)).lineLimit(1); Spacer(); Text(String(format: "%.0f%%", program.cpu)).font(.system(size: 11).monospacedDigit()).foregroundColor(MunaColor.secondary) }
                    }
                }
            }
            if !power.devices.isEmpty {
                QuickBlock {
                    Text("DEVICES").font(.system(size: 10, weight: .heavy)).foregroundColor(MunaColor.caption)
                    ForEach(power.devices) { device in
                        MeterRow(label: device.name, share: Double(device.percent) / 100, value: "\(device.percent)%")
                    }
                }
            }
        }
        .onAppear { power.watch() }
        .onDisappear { power.unwatch() }
    }
}

// --- Input, Controls, Quick toggles -----------------------------------------------------------------

/// macOS's own settings, flipped from Muna: each switch reads the live value and writes the same
/// preference System Settings writes (some take effect at the next login: said under them).
enum MacSwitches {
    struct Switch: Identifiable {
        let id: String, group: String, symbol: String, title: String, detail: String
        let get: () -> Bool
        let set: (Bool) -> Void
    }

    private static func read(_ domain: String, _ key: String, _ fallback: Bool) -> Bool {
        let values = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        return (values[key] as? NSNumber)?.boolValue ?? fallback
    }

    private static func write(_ domain: String, _ key: String, _ value: Bool, then restart: String? = nil) {
        run("/usr/bin/defaults", ["write", domain, key, "-bool", value ? "true" : "false"])
        if let restart { run("/usr/bin/killall", [restart]) }
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }

    private static func dock(_ property: String, _ value: Bool) {
        var error: NSDictionary?
        _ = NSAppleScript(source: "tell application \"System Events\" to set \(property) of dock preferences to \(value)")?.executeAndReturnError(&error)
    }

    static let all: [Switch] = [
        Switch(id: "dock-hide", group: "Windows", symbol: "dock.rectangle", title: "Hide the Dock", detail: "The Dock comes out when the pointer reaches it.",
               get: { read("com.apple.dock", "autohide", false) }, set: { dock("autohide", $0) }),
        Switch(id: "spaces-order", group: "Windows", symbol: "rectangle.3.group", title: "Rearrange desktops by use", detail: "Desktops change their order by the most recent use.",
               get: { read("com.apple.dock", "mru-spaces", true) }, set: { write("com.apple.dock", "mru-spaces", $0, then: "Dock") }),
        Switch(id: "spaces-span", group: "Windows", symbol: "display.2", title: "Separate desktops for every monitor", detail: "Each screen switches its own desktops (after the next login).",
               get: { !read("com.apple.spaces", "spans-displays", false) }, set: { write("com.apple.spaces", "spans-displays", !$0) }),
        Switch(id: "minimize-app", group: "Windows", symbol: "arrow.down.right.and.arrow.up.left", title: "Minimize into the app's icon", detail: "Minimized windows go into their app in the Dock.",
               get: { read("com.apple.dock", "minimize-to-application", false) }, set: { write("com.apple.dock", "minimize-to-application", $0, then: "Dock") }),
        Switch(id: "natural", group: "Mouse and keyboard", symbol: "scroll", title: "Natural scrolling", detail: "The content follows the fingers (after the next login).",
               get: { read(UserDefaults.globalDomain, "com.apple.swipescrolldirection", true) }, set: { write("-g", "com.apple.swipescrolldirection", $0) }),
        Switch(id: "tap", group: "Mouse and keyboard", symbol: "hand.tap", title: "Tap to click", detail: "Tap the trackpad to click (after the next login).",
               get: { read("com.apple.AppleMultitouchTrackpad", "Clicking", false) },
               set: { write("com.apple.AppleMultitouchTrackpad", "Clicking", $0); write("com.apple.driver.AppleBluetoothMultitouch.trackpad", "Clicking", $0) }),
        Switch(id: "hold", group: "Mouse and keyboard", symbol: "keyboard", title: "Key repeat", detail: "Hold a key to repeat it (off: the accents menu).",
               get: { !read(UserDefaults.globalDomain, "ApplePressAndHoldEnabled", true) }, set: { write("-g", "ApplePressAndHoldEnabled", !$0) }),
        Switch(id: "hidden", group: "Files", symbol: "eye", title: "Show hidden files", detail: "Finder shows hidden files and folders.",
               get: { read("com.apple.finder", "AppleShowAllFiles", false) }, set: { write("com.apple.finder", "AppleShowAllFiles", $0, then: "Finder") }),
        Switch(id: "extensions", group: "Files", symbol: "doc.text", title: "Show file extensions", detail: "Finder shows .txt, .app and the like.",
               get: { read(UserDefaults.globalDomain, "AppleShowAllExtensions", false) }, set: { write("-g", "AppleShowAllExtensions", $0, then: "Finder") }),
        Switch(id: "history", group: "Files", symbol: "doc.on.clipboard", title: "Keep the clipboard history", detail: "Saved on this computer and restored after a restart.",
               get: { Preferences.shared.clipboardKeepHistory }, set: { Preferences.shared.clipboardKeepHistory = $0 }),
        Switch(id: "cleanurl", group: "Files", symbol: "link", title: "Clean URLs when copied", detail: "Removes tracking parameters from a link the moment it is copied.",
               get: { Preferences.shared.clipboardCleanUrls }, set: { Preferences.shared.clipboardCleanUrls = $0 }),
    ]
}

/// A row with a switch, refreshed when switched (the value lives in macOS's settings).
struct SwitchRow: View {
    @EnvironmentObject var state: QuickPanelState
    let item: MacSwitches.Switch

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).frame(width: 20).foregroundColor(MunaColor.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12, weight: .semibold))
                Text(item.detail).font(.system(size: 10)).foregroundColor(MunaColor.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { item.get() }, set: { item.set($0); state.objectWillChange.send() })).labelsHidden().toggleStyle(.switch)
        }
    }
}

struct InputPage: View {
    var body: some View {
        QuickBlock {
            ForEach(MacSwitches.all.filter { $0.group == "Mouse and keyboard" }) { SwitchRow(item: $0) }
            HStack {
                Pill(label: "Trackpad settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!) }
                Pill(label: "Keyboard settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!) }
            }
        }
    }
}

struct ControlsPage: View {
    @EnvironmentObject var state: QuickPanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(["Windows", "Mouse and keyboard", "Files"], id: \.self) { group in
                let items = MacSwitches.all.filter { $0.group == group }
                HStack {
                    Text(group.uppercased()).font(.system(size: 10, weight: .heavy)).foregroundColor(MunaColor.caption)
                    Spacer()
                    Text("\(items.filter { $0.get() }.count)/\(items.count)").font(.system(size: 10, weight: .bold)).foregroundColor(MunaColor.accent)
                }
                QuickBlock { ForEach(items) { SwitchRow(item: $0) } }
            }
        }
    }
}

struct TogglesPage: View {
    @EnvironmentObject var state: QuickPanelState
    @EnvironmentObject var sound: SoundModel

    var body: some View {
        let volumes = QuickTools.removableVolumes
        let excluded = Preferences.shared.strings("eject-excluded")
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ToggleTile(symbol: "circle.lefthalf.filled", title: "Dark mode", on: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) {
                QuickTools.toggleDarkMode()
            }
            ToggleTile(symbol: "moon", title: "Night Shift", on: NightShift.isOn) { NightShift.set(!NightShift.isOn); state.objectWillChange.send() }
            ToggleTile(symbol: "mic.slash", title: "Microphone", on: !sound.microphoneMuted) { sound.toggleMicrophone() }
            ToggleTile(symbol: "light.max", title: "Keyboard light", on: KeyboardLight.level > 0.01) { KeyboardLight.set(KeyboardLight.level > 0.01 ? 0 : 0.6); state.objectWillChange.send() }
            ToggleTile(symbol: "eye", title: "Hidden files", on: MacSwitches.all.first { $0.id == "hidden" }?.get() ?? false) {
                if let item = MacSwitches.all.first(where: { $0.id == "hidden" }) { item.set(!item.get()); state.objectWillChange.send() }
            }
            ToggleTile(symbol: "trash", title: "Empty trash", on: nil) { QuickTools.emptyTrash() }
            ToggleTile(symbol: "eject", title: volumes.isEmpty ? "No disks" : "Eject disks", on: nil) {
                volumes.filter { !excluded.contains($0.path) }.forEach(QuickTools.eject)
            }
            ToggleTile(symbol: "lock", title: "Lock", on: nil) { Keyboard.press("<Super><Control>q") }
            ToggleTile(symbol: "display", title: "Screen off", on: nil) { QuickTools.displaySleep() }
        }
    }
}

/// A quick toggle: a round icon (blue when on), the name and its state.
struct ToggleTile: View {
    let symbol: String
    let title: String
    let on: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(on == true ? MunaColor.accent : Color.white.opacity(0.1)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let on { Text(on ? "On" : "Off").font(.system(size: 10)).foregroundColor(MunaColor.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The keyboard's backlight (CoreBrightness's KeyboardBrightnessClient, as Control Centre).
enum KeyboardLight {
    private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let kind = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return kind.init()
    }()

    static var level: Double {
        guard let client else { return 0 }
        let selector = NSSelectorFromString("brightnessForKeyboard:")
        guard client.responds(to: selector), let method = class_getMethodImplementation(type(of: client), selector) else { return 0 }
        typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
        return Double(unsafeBitCast(method, to: Get.self)(client, selector, 1))
    }

    static func set(_ value: Double) {
        guard let client else { return }
        let selector = NSSelectorFromString("setBrightness:forKeyboard:")
        guard client.responds(to: selector), let method = class_getMethodImplementation(type(of: client), selector) else { return }
        typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        _ = unsafeBitCast(method, to: Set.self)(client, selector, Float(value), 1)
    }
}

// --- Utilities --------------------------------------------------------------------------------------

/// Every tool in one list of rows, each a click away (Linux's Utilities).
struct UtilitiesPage: View {
    @EnvironmentObject var state: QuickPanelState

    static let tools: [(String, String, String, String)] = [
        ("screenshot", "camera.viewfinder", "Screenshot", "A part of the screen or a window, copied"),
        ("record", "record.circle", "Screen recording", "macOS's screenshot tool, recording"),
        ("color", "eyedropper", "Colour picker", "Copies the colour as a hex code"),
        ("clipboard", "doc.on.clipboard", "Clipboard", "What you copied"),
        ("quickpanel:windows", "rectangle.split.2x1", "Window layout", "Halves, quarters, thirds, another screen"),
        ("cleaning", "keyboard", "Cleaning mode", "Keyboard and pointer locked while you clean"),
        ("capsule:mirror", "camera", "Camera preview", "See yourself before a call"),
        ("command", "magnifyingglass", "Command Bar", "Apps, calculator, units, snippets"),
        ("scratchpad", "note.text", "Scratchpad", "One long note in its own window"),
        ("radial", "circle.grid.cross", "Radial menu", "Your actions around the pointer"),
    ]

    @EnvironmentObject var preferences: Preferences

    /// The tools in the chosen order, without the hidden ones (Linux's customize mode of the list).
    private var shown: [(String, String, String, String)] {
        let order = preferences.strings("utilities-order")
        let hidden = preferences.strings("utilities-hidden")
        let ordered = order.compactMap { id in Self.tools.first { $0.0 == id } } + Self.tools.filter { !order.contains($0.0) }
        return state.customizing ? ordered : ordered.filter { !hidden.contains($0.0) }
    }

    private func move(_ id: String, _ step: Int) {
        var ids = shown.map(\.0)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + step) else { return }
        ids.swapAt(index, index + step)
        preferences.set("utilities-order", ids)
    }

    var body: some View {
        QuickBlock {
            HStack {
                Spacer()
                Pill(label: state.customizing ? "Done" : "Customize", active: state.customizing) { state.customizing.toggle() }
            }
            ForEach(shown, id: \.0) { tool in
                if state.customizing {
                    HStack(spacing: 8) {
                        Image(systemName: tool.1).frame(width: 22).foregroundColor(MunaColor.accent)
                        Text(tool.2).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        IconButton(symbol: "chevron.up") { move(tool.0, -1) }
                        IconButton(symbol: "chevron.down") { move(tool.0, 1) }
                        Toggle("", isOn: preferences.listBinding("utilities-hidden", tool.0, onMeansIn: false)).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                } else {
                Button { state.onRun(tool.0) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tool.1).frame(width: 22).foregroundColor(MunaColor.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tool.2).font(.system(size: 12, weight: .semibold))
                            Text(tool.3).font(.system(size: 10)).foregroundColor(MunaColor.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(MunaColor.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                }
            }
        }
    }
}

// --- Desktops ---------------------------------------------------------------------------------------

/// macOS's desktops (Spaces) as far as an app may see them: how many each screen has and which one is
/// shown (SkyLight's CGSCopyManagedDisplaySpaces, read only); switching with Mission Control's keys.
enum Spaces {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Copy = @convention(c) (Int32) -> Unmanaged<CFArray>?

    struct Screen { let id: String; let count: Int; let current: Int }

    static func screens() -> [Screen] {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let main = dlsym(handle, "CGSMainConnectionID") ?? dlsym(handle, "_CGSDefaultConnection"),
              let copy = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return [] }
        let connection = unsafeBitCast(main, to: Connection.self)()
        guard let list = unsafeBitCast(copy, to: Copy.self)(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return list.map { display in
            let spaces = (display["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int ?? 0) == 0 }
            let currentId = ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int) ?? -1
            let index = spaces.firstIndex { ($0["ManagedSpaceID"] as? Int) == currentId } ?? 0
            return Screen(id: display["Display Identifier"] as? String ?? "Main", count: max(spaces.count, 1), current: index)
        }
    }

    /// Goes to desktop `target` of the screen with the pointer (^← and ^→, macOS's own keys).
    static func go(to target: Int, from current: Int) {
        let steps = target - current
        for _ in 0..<abs(steps) { Keyboard.press(steps > 0 ? "<Control>Right" : "<Control>Left") }
    }
}

struct DesktopsPage: View {
    @EnvironmentObject var state: QuickPanelState
    @EnvironmentObject var windows: WindowsModel

    var body: some View {
        let screens = Spaces.screens()
        VStack(spacing: 10) {
            ForEach(Array(screens.enumerated()), id: \.offset) { index, screen in
                QuickBlock {
                    Text(screens.count > 1 ? "SCREEN \(index + 1)" : "DESKTOPS").font(.system(size: 10, weight: .heavy)).foregroundColor(MunaColor.caption)
                    HStack(spacing: 6) {
                        ForEach(0..<screen.count, id: \.self) { desk in
                            Pill(label: "Desktop \(desk + 1)", active: desk == screen.current) {
                                Spaces.go(to: desk, from: screen.current)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { state.objectWillChange.send() }
                            }
                        }
                    }
                }
            }
            QuickBlock {
                HStack {
                    Pill(label: "Mission Control") { MissionControl.run(nil) }
                    Pill(label: "New desktop") { NewDesktop.make { _ in state.objectWillChange.send() } }
                    Pill(label: "Send window there") { windows.sendToNewDesktop() }
                    Pill(label: "Show desktop") { MissionControl.run("1") }
                }
                Text("New desktop presses the + of Mission Control for you; Send window there makes one and carries the window you were in to it (Accessibility, and ^→ on in Keyboard Shortcuts → Mission Control).")
                    .font(.system(size: 10)).foregroundColor(MunaColor.secondary).fixedSize(horizontal: false, vertical: true)
                if let separate = MacSwitches.all.first(where: { $0.id == "spaces-span" }) { SwitchRow(item: separate) }
            }
        }
    }
}

/// A new desktop from Muna (Linux's "new desktop"): macOS has no call for it, so Muna opens Mission
/// Control and presses its + through Accessibility (the Dock draws Mission Control), then closes it.
enum NewDesktop {
    static func make(done: ((Bool) -> Void)? = nil) {
        guard AXIsProcessTrusted() else {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            done?(false)
            return
        }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { done?(false); return }
        MissionControl.run(nil)
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        DispatchQueue.global(qos: .userInitiated).async {
            // Mission Control takes a moment to appear: look for the + for up to two seconds
            var pressed = false
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.1)
                if let button = addButton(in: app, byName: true) ?? addButton(in: app, byName: false) {
                    pressed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.6)
            DispatchQueue.main.async {
                MissionControl.run(nil)   // closes it again
                done?(pressed)
            }
        }
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    /// The + of the Spaces bar: a button that is named "add desktop" (in English), or else the button
    /// beside the list of desktops.
    private static func addButton(in element: AXUIElement, byName: Bool, depth: Int = 0) -> AXUIElement? {
        guard depth < 8 else { return nil }
        let kids = children(element)
        let hasList = kids.contains { string($0, kAXRoleAttribute) == kAXListRole }
        for kid in kids where string(kid, kAXRoleAttribute) == kAXButtonRole {
            let name = (string(kid, kAXDescriptionAttribute) + " " + string(kid, kAXIdentifierAttribute)).lowercased()
            if byName ? name.contains("add desktop") : hasList { return kid }
        }
        for kid in kids { if let found = addButton(in: kid, byName: byName, depth: depth + 1) { return found } }
        return nil
    }
}
