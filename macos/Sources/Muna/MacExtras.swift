import AppKit
import Carbon
import Combine
import IOKit
import IOKit.ps
import MunaCore

/// Night Shift on or off (macOS's own CoreBrightness, what Control Centre's switch uses).
enum NightShift {
    private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let type = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        return type.init()
    }()

    static var available: Bool { client != nil }

    /// The status record is { active, enabled, sunSchedulePermitted, mode, schedule, disableFlags } (first byte: active).
    static var isOn: Bool {
        guard let client, client.responds(to: NSSelectorFromString("getBlueLightStatus:")) else { return false }
        let status = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { status.deallocate() }
        status.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        typealias Get = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let selector = NSSelectorFromString("getBlueLightStatus:")
        guard let method = class_getMethodImplementation(type(of: client), selector) else { return false }
        _ = unsafeBitCast(method, to: Get.self)(client, selector, status)
        return status.load(as: Bool.self)
    }

    static func set(_ on: Bool) {
        guard let client else { return }
        let selector = NSSelectorFromString("setEnabled:")
        guard client.responds(to: selector), let method = class_getMethodImplementation(type(of: client), selector) else { return }
        typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Bool
        _ = unsafeBitCast(method, to: Set.self)(client, selector, on)
    }
}

/// Readings macOS does not give through Foundation, read from IOKit without any permission: the
/// graphics card's use, the disks' activity, the power the battery gives, and the temperatures (the
/// HID sensors of Apple silicon).
final class Sensors {
    static let shared = Sensors()
    private(set) var gpu: Double?
    private(set) var diskBytesPerSecond: Double?
    private(set) var watts: Double?
    private(set) var temperature: Double?
    private var lastDisk: (bytes: UInt64, at: Date)?

    func sample() {
        gpu = Self.gpuUse()
        watts = Self.batteryWatts()
        temperature = Thermal.cpu()
        if let bytes = Self.diskBytes() {
            if let last = lastDisk {
                let seconds = max(0.1, Date().timeIntervalSince(last.at))
                diskBytesPerSecond = Double(bytes >= last.bytes ? bytes - last.bytes : 0) / seconds
            }
            lastDisk = (bytes, Date())
        }
    }

    private static func services(_ name: String, _ each: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            each(entry)
            IOObjectRelease(entry)
        }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func gpuUse() -> Double? {
        var best: Double?
        services("IOAccelerator") { entry in
            if let stats = property(entry, "PerformanceStatistics") as? [String: Any], let use = stats["Device Utilization %"] as? NSNumber {
                best = max(best ?? 0, use.doubleValue / 100)
            }
        }
        return best
    }

    static func diskBytes() -> UInt64? {
        var total: UInt64 = 0
        var any = false
        services("IOBlockStorageDriver") { entry in
            guard let stats = property(entry, "Statistics") as? [String: Any] else { return }
            any = true
            total += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            total += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return any ? total : nil
    }

    static func batteryWatts() -> Double? {
        var watts: Double?
        services("AppleSmartBattery") { entry in
            guard let amperage = property(entry, "InstantAmperage") as? NSNumber ?? property(entry, "Amperage") as? NSNumber,
                  let voltage = property(entry, "Voltage") as? NSNumber else { return }
            let w = abs(Double(Int64(truncatingIfNeeded: amperage.int64Value)) * voltage.doubleValue) / 1_000_000
            if w > 0 { watts = w }
        }
        return watts
    }
}

/// The temperature sensors Apple silicon gives through IOKit's HID event system (what the "Stats"
/// app reads); none on most Intel Macs.
enum Thermal {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?

    private static let functions: (Create, SetMatching, CopyServices, CopyEvent, GetFloat, CopyProperty)? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let a = dlsym(handle, "IOHIDEventSystemClientCreate"), let b = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let c = dlsym(handle, "IOHIDEventSystemClientCopyServices"), let d = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let e = dlsym(handle, "IOHIDEventGetFloatValue"), let f = dlsym(handle, "IOHIDServiceClientCopyProperty") else { return nil }
        return (unsafeBitCast(a, to: Create.self), unsafeBitCast(b, to: SetMatching.self), unsafeBitCast(c, to: CopyServices.self),
                unsafeBitCast(d, to: CopyEvent.self), unsafeBitCast(e, to: GetFloat.self), unsafeBitCast(f, to: CopyProperty.self))
    }()

    /// The hottest processor sensor in °C (any sensor when none is named for the processor).
    static func cpu() -> Double? {
        guard let f = functions, let client = f.0(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        let (setMatching, copyServices, copyEvent, getFloat, copyProperty) = (f.1, f.2, f.3, f.4, f.5)
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return nil }
        var processor: Double?
        var any: Double?
        for service in services {
            guard let event = copyEvent(service, 15, 0, 0)?.takeRetainedValue() else { continue }   // kIOHIDEventTypeTemperature
            let value = getFloat(event, 15 << 16)
            guard value > 0, value < 130 else { continue }
            let name = (copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? "").lowercased()
            any = max(any ?? 0, value)
            if name.contains("tdie") || name.contains("cpu") || name.contains("pmu") { processor = max(processor ?? 0, value) }
        }
        return processor ?? any
    }
}

/// Linux's top-bar readings: what each is called and its short value for the menu bar.
struct Reading {
    let id: String
    let label: String
    let title: String
    let value: (SystemMonitor) -> String?

    var available: Bool {
        switch id {
        case "cputemp": return Sensors.shared.temperature != nil || Thermal.cpu() != nil
        case "gpu": return Sensors.gpuUse() != nil
        case "power": return Sensors.batteryWatts() != nil
        default: return true
        }
    }
}

enum Readings {
    static func temperature(_ celsius: Double) -> String {
        Preferences.shared.string("temp-unit") == "F" ? "\(Int((celsius * 9 / 5 + 32).rounded()))°F" : "\(Int(celsius.rounded()))°"
    }

    static func rate(_ bytes: Double) -> String {
        bytes < 1000 ? "\(Int(bytes))B" : bytes < 1_000_000 ? "\(Int(bytes / 1000))K" : String(format: "%.1fM", bytes / 1_000_000)
    }

    static let all: [Reading] = [
        Reading(id: "cpu", label: "CPU", title: "CPU") { "\(Int($0.cpu * 100))%" },
        Reading(id: "cputemp", label: "TMP", title: "CPU temperature") { _ in Sensors.shared.temperature.map(Readings.temperature) },
        Reading(id: "gpu", label: "GPU", title: "GPU") { _ in Sensors.shared.gpu.map { "\(Int($0 * 100))%" } },
        Reading(id: "mem", label: "RAM", title: "Memory") { m in m.memoryTotal > 0 ? "\(Int(Double(m.memoryUsed) / Double(m.memoryTotal) * 100))%" : nil },
        Reading(id: "battery", label: "BAT", title: "Battery") { m in m.battery.map { "\($0.percent)%" } },
        Reading(id: "net", label: "NET", title: "Network") { m in "↓\(Readings.rate(m.download))" },
        Reading(id: "disk", label: "DSK", title: "Disk usage") { m in m.diskTotal > 0 ? "\(Int(100 - Double(m.diskFree) / Double(m.diskTotal) * 100))%" : nil },
        Reading(id: "diskio", label: "I/O", title: "Disk activity") { _ in Sensors.shared.diskBytesPerSecond.map(Readings.rate) },
        Reading(id: "power", label: "PWR", title: "Power draw") { _ in Sensors.shared.watts.map { String(format: "%.1fW", $0) } },
    ]
}

/// The actions the radial menu can have (Linux's radial-actions ids).
enum RadialCatalog {
    struct Info {
        let id: String, title: String, kind: String, symbol: String
    }

    static let all: [Info] = [
        Info(id: "play-pause", title: "Play or pause", kind: "Media control", symbol: "playpause"),
        Info(id: "next", title: "Next track", kind: "Media control", symbol: "forward"),
        Info(id: "prev", title: "Previous track", kind: "Media control", symbol: "backward"),
        Info(id: "screenshot", title: "Screenshot", kind: "Tool", symbol: "camera.viewfinder"),
        Info(id: "recording", title: "Screen recording", kind: "Tool", symbol: "record.circle"),
        Info(id: "color", title: "Color picker", kind: "Tool", symbol: "eyedropper"),
        Info(id: "downloads", title: "Downloads", kind: "Open a file or folder", symbol: "arrow.down.circle"),
        Info(id: "command", title: "Search", kind: "Command bar", symbol: "magnifyingglass"),
        Info(id: "clipboard", title: "Clipboard", kind: "Clipboard history", symbol: "doc.on.clipboard"),
        Info(id: "dark", title: "Dark mode", kind: "Quick toggles", symbol: "circle.lefthalf.filled"),
        Info(id: "night", title: "Night Shift", kind: "Quick toggles", symbol: "moon"),
        Info(id: "mic", title: "Mute microphone", kind: "Quick toggles", symbol: "mic.slash"),
        Info(id: "awake", title: "Keep awake", kind: "Tool", symbol: "cup.and.saucer"),
        Info(id: "cleaning", title: "Cleaning mode", kind: "Tool", symbol: "keyboard"),
        Info(id: "lock", title: "Lock the screen", kind: "Quick toggles", symbol: "lock"),
    ]

    static func info(_ id: String) -> Info? { all.first { $0.id == id } }
}

/// Linux's system alerts: a card when the processor stays busy, the Mac gets hot, the disk or the
/// memory is nearly full, or the battery runs low (each once until it is fine again).
final class SystemAlerts {
    private let monitor: SystemMonitor
    private let tell: (String, String, String) -> Void
    private var told: Set<String> = []
    private var busySince: Date?
    private var timer: Timer?

    init(monitor: SystemMonitor, tell: @escaping (String, String, String) -> Void) {
        self.monitor = monitor
        self.tell = tell
    }

    func start() {
        monitor.watch()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.check() }
    }

    private func check() {
        let p = Preferences.shared
        guard p.bool("system-alerts") else { return }
        Sensors.shared.sample()
        let cpuLimit = p.double("alert-cpu")
        if cpuLimit > 0, monitor.cpu * 100 >= cpuLimit { busySince = busySince ?? Date() } else { busySince = nil }
        report("cpu", busySince.map { Date().timeIntervalSince($0) >= 30 } ?? false, "The processor is busy", "Over \(Int(cpuLimit))% for 30 seconds", "cpu")
        let tempLimit = p.double("alert-temp")
        if let t = Sensors.shared.temperature { report("temp", tempLimit > 0 && t >= tempLimit, "The Mac is hot", Readings.temperature(t), "thermometer") }
        let diskLimit = p.double("alert-disk")
        if monitor.diskTotal > 0 {
            report("disk", diskLimit > 0 && Double(monitor.diskFree) * 100 / Double(monitor.diskTotal) < diskLimit, "The disk is nearly full",
                   ByteCountFormatter.string(fromByteCount: monitor.diskFree, countStyle: .file) + " free", "internaldrive")
        }
        let memoryLimit = p.double("alert-memory")
        if monitor.memoryTotal > 0 {
            let free = 100 - Double(monitor.memoryUsed) * 100 / Double(monitor.memoryTotal)
            report("memory", memoryLimit > 0 && free < memoryLimit, "Memory is nearly full", "\(Int(free))% free", "memorychip")
        }
        if let battery = monitor.battery {
            let limit = p.double("alert-battery")
            report("battery", limit > 0 && !battery.charging && Double(battery.percent) <= limit, "The battery is low", "\(battery.percent)% left", "battery.25")
        }
    }

    private func report(_ id: String, _ bad: Bool, _ title: String, _ details: String, _ symbol: String) {
        guard bad else { told.remove(id); return }
        guard !told.contains(id) else { return }
        told.insert(id)
        tell(title, details, symbol)
    }
}

/// Linux's cards for the keyboard: the layout when it changes, Caps Lock on or off.
final class KeyboardCards {
    private let tell: (String, String) -> Void
    private var capsLock = NSEvent.modifierFlags.contains(.capsLock)
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init(tell: @escaping (String, String) -> Void) { self.tell = tell }

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
                                                                       object: nil, queue: .main) { [weak self] _ in
            guard Preferences.shared.bool("show-input-source") else { return }
            self?.tell(Self.layoutName(), "keyboard")
        }
        // Caps Lock: macOS tells no app, so its state is looked at often (no permission is needed)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let on = NSEvent.modifierFlags.contains(.capsLock)
            guard on != self.capsLock else { return }
            self.capsLock = on
            if Preferences.shared.bool("show-caps-lock") { self.tell(on ? "Caps Lock on" : "Caps Lock off", on ? "capslock.fill" : "capslock") }
        }
    }

    static func layoutName() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let name = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return "Keyboard" }
        return Unmanaged<CFString>.fromOpaque(name).takeUnretainedValue() as String
    }
}
