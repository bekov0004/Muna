import AppKit
import Combine
import IOKit.ps
import IOKit.pwr_mgt
import SwiftUI

// The top-bar window of Muna on Linux (linux/src/ui/toolsMenu.js): on a Mac it opens from Muna's
// item in the menu bar. System, network, keep awake and quick tools.

// --- what the computer is doing ------------------------------------------------------------------

/// Readings of the computer, every two seconds while someone looks (the quick panel, or the readings
/// in the menu bar).
final class SystemMonitor: ObservableObject {
    struct Battery: Equatable {
        var percent: Int
        var charging: Bool
        var onPower: Bool
    }

    @Published private(set) var cpu: Double = 0                 // 0…1
    var cpuPublisher: Published<Double>.Publisher { $cpu }
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryUsed: UInt64 = 0
    @Published private(set) var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var diskFree: Int64 = 0
    @Published private(set) var diskTotal: Int64 = 0
    @Published private(set) var battery: Battery?
    @Published private(set) var download: Double = 0            // bytes per second
    @Published private(set) var upload: Double = 0
    @Published private(set) var downloadHistory: [Double] = []
    @Published private(set) var received: UInt64 = 0            // since Muna started
    @Published private(set) var sent: UInt64 = 0

    private var timer: Timer?
    private var watchers = 0
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastNet: (inBytes: UInt64, outBytes: UInt64, at: Date)?
    private var netStart: (inBytes: UInt64, outBytes: UInt64)?

    static let historyLength = 60

    /// Someone looks (counted: the panel and the menu-bar readings each call it).
    func watch() {
        watchers += 1
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: max(1, Preferences.shared.double("monitor-interval")), repeats: true) { [weak self] _ in self?.sample() }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    private func sample() {
        if let ticks = Self.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                cpu = Double(ticks.busy - last.busy) / Double(ticks.total - last.total)
                push(&cpuHistory, cpu)
            }
            lastTicks = ticks
        }
        memoryUsed = Self.memoryUsed()
        push(&memoryHistory, memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0)
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            diskFree = values.volumeAvailableCapacityForImportantUsage ?? 0
            diskTotal = Int64(values.volumeTotalCapacity ?? 0)
        }
        battery = Self.battery()
        let now = Date()
        let net = Self.networkBytes()
        if let last = lastNet, now > last.at {
            let seconds = now.timeIntervalSince(last.at)
            // the counters are 32 bits on some interfaces: a smaller value means they went round
            download = net.inBytes >= last.inBytes ? Double(net.inBytes - last.inBytes) / seconds : download
            upload = net.outBytes >= last.outBytes ? Double(net.outBytes - last.outBytes) / seconds : upload
            push(&downloadHistory, download)
        }
        if netStart == nil { netStart = (net.inBytes, net.outBytes) }
        if let start = netStart {
            received = net.inBytes >= start.inBytes ? net.inBytes - start.inBytes : received
            sent = net.outBytes >= start.outBytes ? net.outBytes - start.outBytes : sent
        }
        lastNet = (net.inBytes, net.outBytes, now)
    }

    private func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(load.cpu_ticks.0)
        let system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2)
        let nice = UInt64(load.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    private static func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        // what Activity Monitor calls "memory used": apps, wired and compressed
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let pages = (anonymous > purgeable ? anonymous - purgeable : 0) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * page
    }

    private static func battery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String
            return Battery(percent: current * 100 / maximum,
                           charging: description[kIOPSIsChargingKey] as? Bool ?? false,
                           onPower: state == kIOPSACPowerValue)
        }
        return nil
    }

    /// Bytes received and sent by the network interfaces (not the loopback).
    private static func networkBytes() -> (inBytes: UInt64, outBytes: UInt64) {
        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let head = first else { return (0, 0) }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard !name.hasPrefix("lo") else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            inBytes += UInt64(counters.ifi_ibytes)
            outBytes += UInt64(counters.ifi_obytes)
        }
        return (inBytes, outBytes)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file))/s"
    }
}

// --- keep awake ------------------------------------------------------------------------------------

/// Keeps the Mac from sleeping (and the screen on, if chosen) for a while or until switched off.
final class KeepAwake: ObservableObject {
    @Published private(set) var isOn = false
    /// nil: until switched off.
    @Published private(set) var until: Date?
    @Published var keepScreenOn = true

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    struct Choice: Hashable {
        let label: String
        let minutes: Int?
    }

    static let choices = [Choice(label: "30 min", minutes: 30), Choice(label: "1 h", minutes: 60), Choice(label: "2 h", minutes: 120),
                          Choice(label: "5 h", minutes: 300), Choice(label: "Until off", minutes: nil)]

    func start(minutes: Int?) {
        stop()
        let type = (keepScreenOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Muna: keep awake" as CFString, &assertion)
        guard result == kIOReturnSuccess else { return }
        isOn = true
        if let minutes {
            let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
            until = end
            timer = Timer.scheduledTimer(withTimeInterval: end.timeIntervalSinceNow, repeats: false) { [weak self] _ in self?.stop() }
        } else {
            until = nil
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if isOn {
            IOPMAssertionRelease(assertion)
        }
        assertion = 0
        isOn = false
        until = nil
    }
}

// --- quick tools ---------------------------------------------------------------------------------------

enum QuickTools {
    /// Dark or light for the whole Mac (System Events; macOS asks once).
    static func toggleDarkMode() {
        run("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
    }

    static func emptyTrash() {
        run("tell application \"Finder\" to empty trash")
    }

    /// The screenshot tool of macOS (Cmd+Shift+5).
    static func screenshot() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-iUc"]
        try? process.run()
    }

    /// Turns the screen off now (it locks if the Mac asks for the password at once).
    static func displaySleep() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    /// Picks a colour anywhere on the screen and copies it as #RRGGBB.
    static func pickColor(_ done: @escaping (String) -> Void) {
        NSColorSampler().show { color in
            guard let color = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                             Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            done(hex)
        }
    }

    /// The disks that can be ejected (not the system's).
    static var removableVolumes: [URL] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return url.path != "/" && (values?.volumeIsEjectable == true || values?.volumeIsRemovable == true || values?.volumeIsInternal == false)
        }
    }

    static func eject(_ volume: URL) {
        try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
    }

    private static func run(_ source: String) {
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}

// --- the window -----------------------------------------------------------------------------------

enum QuickPage: String, CaseIterable, Identifiable {
    // Linux's order of the tabs (linux/prefsWindow.js MENU_ORDER)
    case awake, reminders, phone, displays, sound, system, network, disks, power, utilities, controls, toggles, windows, workspaces, focus, input, downloads, agents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .network: return "Network"
        case .sound: return "Sound"
        case .displays: return "Displays"
        case .phone: return "Phone"
        case .awake: return "Keep awake"
        case .focus: return "Focus"
        case .reminders: return "Reminders"
        case .downloads: return "Downloads"
        case .windows: return "Windows"
        case .agents: return "AI agents"
        case .disks: return "Disks"
        case .power: return "Power"
        case .utilities: return "Utilities"
        case .controls: return "Controls"
        case .toggles: return "Quick toggles"
        case .workspaces: return "Desktops"
        case .input: return "Input"
        }
    }

    /// What the tab is for (Settings → Menu bar, as Linux's descriptions).
    var about: String {
        switch self {
        case .system: return "Processor, graphics and memory at a glance."
        case .network: return "Internet speed and its graph."
        case .sound: return "Volume, output and microphone."
        case .displays: return "Brightness of every screen, and where the screens stand."
        case .phone: return "Phone screen on the computer, with control."
        case .awake: return "Keeps your computer awake for as long as you want."
        case .focus: return "A focus timer and a stopwatch."
        case .reminders: return "The butterfly tells you something at a time you choose."
        case .downloads: return "Files arriving in Downloads."
        case .windows: return "Snap the window in front: halves, quarters, thirds, another screen."
        case .agents: return "Claude Code and Codex at work."
        case .disks: return "Free space and disk activity."
        case .power: return "Battery, charging and power use."
        case .utilities: return "Screenshots, colour picker and other tools."
        case .controls: return "Switches for mouse, keyboard and windows."
        case .toggles: return "Dark mode, microphone, trash and more."
        case .workspaces: return "Create, switch and remove desktops."
        case .input: return "Mouse and keyboard switches."
        }
    }

    /// The tabs in the order chosen in Settings → Menu bar (new ones at the end).
    static func ordered(_ order: [String]) -> [QuickPage] {
        let chosen = order.compactMap(QuickPage.init(rawValue:))
        return chosen + allCases.filter { !chosen.contains($0) }
    }

    /// The tabs shown: in their order, without the ones switched off.
    static var visible: [QuickPage] {
        let hidden = Preferences.shared.strings("menu-hidden")
        let pages = ordered(Preferences.shared.strings("menu-order")).filter { !hidden.contains($0.rawValue) }
        return pages.isEmpty ? [.system] : pages
    }

    var symbol: String {
        switch self {
        case .system: return "waveform.path.ecg"
        case .network: return "network"
        case .sound: return "speaker.wave.2"
        case .displays: return "sun.max"
        case .phone: return "iphone"
        case .awake: return "cup.and.saucer"
        case .focus: return "target"
        case .reminders: return "bell.badge"
        case .downloads: return "arrow.down.circle"
        case .windows: return "rectangle.split.2x1"
        case .agents: return "sparkles"
        case .disks: return "internaldrive"
        case .power: return "battery.75"
        case .utilities: return "wrench.and.screwdriver"
        case .controls: return "switch.2"
        case .toggles: return "circle.grid.2x2"
        case .workspaces: return "rectangle.3.group"
        case .input: return "keyboard"
        }
    }
}

final class QuickPanelState: ObservableObject {
    @Published var page = QuickPage.system
    @Published var message: String?
    /// The tools that open something else (set by the app).
    var onScratchpad: () -> Void = {}
    var onCleaning: () -> Void = {}
    var onCommand: () -> Void = {}
    var onMic: () -> Void = {}
    /// Any action by its name (the Utilities tab; set by the app).
    var onRun: (String) -> Void = { _ in }
}

struct QuickPanelView: View {
    @EnvironmentObject var state: QuickPanelState
    @EnvironmentObject var preferences: Preferences
    let onSettings: () -> Void
    let onCommand: () -> Void
    let onAgents: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ButterflyImage(height: 22).padding(.top, 4)
            // the tabs in rows of nine (Linux has eighteen)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: min(9, QuickPage.visible.count)), spacing: 2) {
                ForEach(QuickPage.visible) { page in
                    Button { state.page = page } label: {
                        Image(systemName: page.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(state.page == page ? MunaColor.accent : Color.white.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(state.page == page ? 0.1 : 0)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(page.title)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
            Text(state.page.title.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .foregroundColor(MunaColor.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                switch QuickPage.visible.contains(state.page) ? state.page : QuickPage.visible[0] {
                case .system: SystemPage()
                case .network: NetworkPage()
                case .sound: SoundPage()
                case .displays: DisplaysPage()
                case .phone: PhonePage()
                case .awake: AwakePage()
                case .focus: FocusPage()
                case .reminders: RemindersPage()
                case .downloads: DownloadsPage()
                case .windows: WindowsPage()
                case .agents: AgentsPage(openWindow: onAgents)
                case .utilities: UtilitiesPage()
                case .controls: ControlsPage()
                case .toggles: TogglesPage()
                case .disks: DisksPage()
                case .power: PowerPage()
                case .workspaces: DesktopsPage()
                case .input: InputPage()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            if let message = state.message {
                Text(message).font(.system(size: 11)).foregroundColor(MunaColor.ok)
            }
            HStack(spacing: 8) {
                QuickFooterButton(symbol: "gearshape", label: "Settings", action: onSettings)
                QuickFooterButton(symbol: "magnifyingglass", label: "Command Bar", action: onCommand)
                QuickFooterButton(symbol: "power", label: "Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
        .foregroundColor(MunaColor.text)
        .background(Color.black)
    }
}

struct QuickFooterButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(label)
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A block of the quick panel.
struct QuickBlock<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }
}

/// A row: a name, a bar, a value.
struct MeterRow: View {
    let label: String
    let share: Double
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(value).font(.system(size: 12).monospacedDigit()).foregroundColor(MunaColor.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(MunaColor.accent).frame(width: proxy.size.width * CGFloat(min(max(share, 0), 1)))
                }
            }
            .frame(height: 5)
        }
    }
}

/// A small line graph of the last minutes.
struct Graph: View {
    let values: [Double]
    var top: Double? = nil

    var body: some View {
        GeometryReader { proxy in
            let maximum = max(top ?? (values.max() ?? 1), 0.0001)
            let step = proxy.size.width / CGFloat(max(SystemMonitor.historyLength - 1, 1))
            let start = proxy.size.width - step * CGFloat(max(values.count - 1, 0))
            ZStack {
                Path { path in
                    for (index, value) in values.enumerated() {
                        let point = CGPoint(x: start + step * CGFloat(index),
                                            y: proxy.size.height * (1 - CGFloat(min(value / maximum, 1))))
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(MunaColor.accent, lineWidth: 1.5)
            }
        }
        .frame(height: 44)
    }
}

struct SystemPage: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        // Settings → Monitor → In the panel: which blocks are shown
        let blocks = preferences.strings("system-blocks")
        let sensors = Sensors.shared
        VStack(spacing: 10) {
            if blocks.contains("temps"), let temperature = sensors.temperature {
                QuickBlock {
                    MeterRow(label: "Processor temperature", share: min(temperature / 100, 1), value: Readings.temperature(temperature))
                }
            }
            if blocks.contains("cpu") {
                QuickBlock {
                    MeterRow(label: "Processor", share: monitor.cpu, value: "\(Int(monitor.cpu * 100))%")
                    Graph(values: monitor.cpuHistory, top: 1)
                    if preferences.bool("graph-scale") { Text("100%").font(.system(size: 9)).foregroundColor(MunaColor.secondary) }
                }
            }
            if blocks.contains("gpu"), let gpu = sensors.gpu {
                QuickBlock {
                    MeterRow(label: "Graphics", share: gpu, value: "\(Int(gpu * 100))%")
                }
            }
            if blocks.contains("memory") {
                QuickBlock {
                    MeterRow(label: "Memory", share: Double(monitor.memoryUsed) / Double(max(monitor.memoryTotal, 1)),
                             value: "\(ByteCountFormatter.string(fromByteCount: Int64(monitor.memoryUsed), countStyle: .memory)) / \(ByteCountFormatter.string(fromByteCount: Int64(monitor.memoryTotal), countStyle: .memory))")
                    Graph(values: monitor.memoryHistory, top: 1)
                    if preferences.bool("graph-scale") { Text("100%").font(.system(size: 9)).foregroundColor(MunaColor.secondary) }
                }
            }
            QuickBlock {
                if monitor.diskTotal > 0 {
                    MeterRow(label: "Disk", share: 1 - Double(monitor.diskFree) / Double(monitor.diskTotal),
                             value: "\(sizeText(monitor.diskFree)) free")
                }
                if let battery = monitor.battery {
                    MeterRow(label: battery.charging ? "Battery · charging" : battery.onPower ? "Battery · on power" : "Battery",
                             share: Double(battery.percent) / 100, value: "\(battery.percent)%")
                }
                if let watts = sensors.watts {
                    MeterRow(label: "Power draw", share: min(watts / 60, 1), value: String(format: "%.1f W", watts))
                }
                if blocks.contains("uptime") {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                        Text("Up for \(Self.uptime(ProcessInfo.processInfo.systemUptime))")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(MunaColor.secondary)
                }
            }
        }
        .onAppear { Sensors.shared.sample() }
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let (d, h, m) = (minutes / 1440, minutes / 60 % 24, minutes % 60)
        return d > 0 ? "\(d)d \(h)h \(m)m" : "\(h)h \(m)m"
    }
}

struct NetworkPage: View {
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        QuickBlock {
            HStack {
                Label(SystemMonitor.rate(monitor.download), systemImage: "arrow.down")
                Spacer()
                Label(SystemMonitor.rate(monitor.upload), systemImage: "arrow.up")
            }
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            Graph(values: monitor.downloadHistory)
            Text("This session: \(sizeText(Int64(monitor.received))) down · \(sizeText(Int64(monitor.sent))) up")
                .font(.system(size: 11))
                .foregroundColor(MunaColor.secondary)
            HStack {
                Pill(label: "Speed test") { NSWorkspace.shared.open(URL(string: "https://fast.com")!) }
                Pill(label: "Network settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!) }
            }
        }
    }
}

struct AwakePage: View {
    @EnvironmentObject var awake: KeepAwake

    var body: some View {
        QuickBlock {
            HStack(spacing: 10) {
                Image(systemName: awake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 20))
                    .foregroundColor(awake.isOn ? MunaColor.amber : MunaColor.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(awake.isOn ? "Staying awake" : "Sleeps as usual").font(.system(size: 13, weight: .semibold))
                    Text(awake.isOn ? (awake.until.map { "until \($0.formatted(date: .omitted, time: .shortened))" } ?? "until you switch it off") : "Choose for how long")
                        .font(.system(size: 11))
                        .foregroundColor(MunaColor.secondary)
                }
                Spacer()
                if awake.isOn {
                    Pill(label: "Off") { awake.stop() }
                }
            }
            HStack(spacing: 6) {
                ForEach(KeepAwake.choices, id: \.self) { choice in
                    Pill(label: choice.label) { awake.start(minutes: choice.minutes) }
                }
            }
            Toggle("Keep the screen on too", isOn: $awake.keepScreenOn)
                .toggleStyle(.switch)
                .font(.system(size: 12))
        }
    }
}

struct ToolsPage: View {
    @EnvironmentObject var state: QuickPanelState

    var body: some View {
        let volumes = QuickTools.removableVolumes
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ToolTile(symbol: "circle.lefthalf.filled", label: "Dark mode") { QuickTools.toggleDarkMode() }
                ToolTile(symbol: "camera.viewfinder", label: "Screenshot") { QuickTools.screenshot() }
                ToolTile(symbol: "eyedropper", label: "Colour") {
                    QuickTools.pickColor { hex in state.message = "Copied \(hex)" }
                }
                ToolTile(symbol: "trash", label: "Empty trash") { QuickTools.emptyTrash() }
                ToolTile(symbol: "display", label: "Screen off") { QuickTools.displaySleep() }
                ToolTile(symbol: "eject", label: volumes.isEmpty ? "No disks" : "Eject all") {
                    // the drives excluded in Settings → Quick toggles stay
                    let excluded = Preferences.shared.strings("eject-excluded")
                    volumes.filter { !excluded.contains($0.path) }.forEach(QuickTools.eject)
                }
                ToolTile(symbol: "moon", label: NightShift.isOn ? "Night Shift on" : "Night Shift") { NightShift.set(!NightShift.isOn) }
                ToolTile(symbol: "mic.slash", label: "Microphone") { state.onMic() }
                ToolTile(symbol: "lock", label: "Lock") { Keyboard.press("<Super><Control>q") }
                ToolTile(symbol: "note.text", label: "Scratchpad") { state.onScratchpad() }
                ToolTile(symbol: "sparkles.rectangle.stack", label: "Cleaning") { state.onCleaning() }
                ToolTile(symbol: "magnifyingglass", label: "Command Bar") { state.onCommand() }
            }
            if !volumes.isEmpty {
                QuickBlock {
                    ForEach(volumes, id: \.self) { volume in
                        HStack {
                            Image(systemName: "externaldrive")
                            Text(volume.lastPathComponent).font(.system(size: 12))
                            Spacer()
                            Pill(label: "Eject") { QuickTools.eject(volume) }
                        }
                    }
                }
            }
        }
    }
}

struct ToolTile: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 16))
                Text(label).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
