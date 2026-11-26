import AppKit
import Combine
import LocalAuthentication
import MunaCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// The settings window of Muna on Linux (linux/prefsWindow.js), page for page: a search on top of the
// list, the sections Essentials, Features, Utilities, Sound, Dynamic Island, Tabs and Muna, back and
// forward, and the "Try it" button of the pages that have one. Every setting keeps Linux's key.

/// One page of the list on the left.
struct SettingsPageInfo: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let intro: String
}

enum SettingsPages {
    static let sections: [(String, [SettingsPageInfo])] = [
        ("Essentials", [
            .init(id: "general", title: "General", symbol: "gearshape", intro: "Size, shortcuts and where Muna is shown."),
            .init(id: "tools", title: "Menu bar", symbol: "menubar.rectangle", intro: "Click the Muna icon in the menu bar to open the window. Its tabs appear in this order."),
            .init(id: "touchpad", title: "Touchpad gestures", symbol: "hand.draw", intro: "Three and four fingers on the trackpad do what you choose here, anywhere: switch apps, desktops, windows, sound, tabs, Muna, or any keys."),
            .init(id: "fingerprint", title: "Touch ID", symbol: "touchid", intro: "The fingerprint reader of the Mac: allow Claude's questions, open private notes and clipboard items."),
            .init(id: "monitor", title: "Monitor", symbol: "desktopcomputer", intro: "What the menu bar and the panel show about this computer, and when to warn you."),
        ]),
        ("Features", [
            .init(id: "features", title: "Overview", symbol: "square.grid.3x3", intro: "Everything Muna can do, by topic. Each line says where it appears: in the window of the menu-bar icon, or in the capsule (the island)."),
            .init(id: "feat-media", title: "Music and media", symbol: "music.note", intro: "The player, the lyrics, the colours of the album art, the sound and the mirror."),
            .init(id: "feat-system", title: "System", symbol: "desktopcomputer", intro: "The processor, the network, the disks, the battery, the monitors, staying awake, and the warnings about them."),
            .init(id: "feat-windows", title: "Windows and desktops", symbol: "macwindow.on.rectangle", intro: "Windows, desktops, the mouse and the keyboard, and the trackpad."),
            .init(id: "feat-work", title: "Work", symbol: "checkmark.square", intro: "Focus, timer, to-do, notes, reminders, shortcuts, the calendar and the AI agents."),
            .init(id: "feat-files", title: "Files and sharing", symbol: "person.2.circle", intro: "The tray, downloads, the clipboard, LocalSend and the phone."),
            .init(id: "feat-capsule", title: "Capsule", symbol: "sparkles", intro: "What the capsule shows on its own (Live Activities, cards), how it opens and closes, and the companion."),
        ]),
        ("Utilities", [
            .init(id: "command", title: "Command Bar", symbol: "magnifyingglass", intro: ""),
            .init(id: "quickpanel", title: "Quick panel", symbol: "star", intro: ""),
            .init(id: "toggles", title: "Quick toggles", symbol: "switch.2", intro: ""),
            .init(id: "cleaning", title: "Cleaning Mode", symbol: "keyboard", intro: ""),
            .init(id: "screenshot", title: "Screenshot", symbol: "camera.viewfinder", intro: ""),
            .init(id: "phone", title: "Phone", symbol: "iphone", intro: ""),
            .init(id: "camera", title: "Camera preview", symbol: "camera", intro: ""),
            .init(id: "scratchpad", title: "Scratchpad", symbol: "note.text", intro: ""),
            .init(id: "color", title: "Color picker", symbol: "eyedropper", intro: ""),
            .init(id: "radial", title: "Radial menu", symbol: "circle.grid.cross", intro: ""),
        ]),
        ("Sound", [
            .init(id: "sound", title: "Volume mixer", symbol: "speaker.wave.2", intro: ""),
            .init(id: "output", title: "Output switcher", symbol: "hifispeaker", intro: ""),
            .init(id: "mic", title: "Mute microphone", symbol: "mic.slash", intro: ""),
        ]),
        ("Dynamic Island", [
            .init(id: "muna", title: "Widgets", symbol: "square.grid.3x1.below.line.grid.1x2", intro: "Choose the widgets of the capsule (the island), their order and their width."),
            .init(id: "appearance", title: "Appearance", symbol: "paintpalette", intro: "The look of the capsule."),
            .init(id: "gestures", title: "Gestures", symbol: "hand.point.up.left", intro: "How the capsule opens, closes and reacts to the pointer and the trackpad."),
            .init(id: "activities", title: "Live Activities", symbol: "play.circle", intro: "What the capsule shows while something is going on, and for how long."),
        ]),
        ("Tabs", [
            .init(id: "tray", title: "Tray", symbol: "tray.and.arrow.down", intro: "The file shelf: drag files to the top of the screen to keep them there."),
            .init(id: "clipboard", title: "Clipboard", symbol: "doc.on.clipboard", intro: "The history of what you copy, and how it behaves."),
            .init(id: "localsend", title: "LocalSend", symbol: "wifi", intro: "Sending files to other computers and phones, and receiving them."),
            .init(id: "snippets", title: "Snippets", symbol: "text.insert", intro: "Texts you use often: type ;trigger in the Command Bar (⌥Space), Enter copies the text."),
        ]),
        ("Muna", [
            .init(id: "about", title: "About", symbol: "info.circle", intro: ""),
        ]),
    ]

    static var all: [SettingsPageInfo] { sections.flatMap { $0.1 } }
    static func info(_ id: String) -> SettingsPageInfo? { all.first { $0.id == id } }

    /// What the blue "Try it" button of a page does (as on Linux).
    static let tryIt: [String: String] = [
        "command": "command", "quickpanel": "quickpanel", "toggles": "dark", "cleaning": "cleaning", "screenshot": "screenshot",
        "color": "color", "mic": "mic", "radial": "radial", "output": "output", "sound": "quickpanel:sound", "tools": "quickpanel",
    ]
}

/// What the settings window remembers (no @State: see PanelState).
final class SettingsState: ObservableObject {
    @Published var page = "general"
    @Published var search = ""
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
    @Published var reminderText = ""
    @Published var reminderTime = Date().addingTimeInterval(3600)
    @Published var note: String?
    private var back: [String] = []
    private var forward: [String] = []
    /// Runs an action of the app ("quickpanel", "command", "radial", "cleaning", "scratchpad", "screenshot",
    /// "record", "color", "dark", "output", "mic", "capsule:<tab>", "quickpanel:<page>"); set by the app.
    var run: (String) -> Void = { _ in }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func go(_ id: String) {
        guard id != page else { return }
        back.append(page)
        forward.removeAll()
        page = id
    }

    func goBack() {
        guard let last = back.popLast() else { return }
        forward.append(page)
        page = last
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(page)
        page = next
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// The settings window: made once, shown again when asked.
final class SettingsWindowController {
    private var window: NSWindow?
    let state = SettingsState()
    private let app: AppState
    private var observers: [AnyCancellable] = []

    init(app: AppState) {
        self.app = app
        // Settings → General → Appearance: the window follows the system, or is light or dark
        Preferences.shared.changed.sink { [weak self] key in
            if key == "color-scheme" || key == "*" { DispatchQueue.main.async { self?.applyScheme() } }
        }.store(in: &observers)
    }

    func show(page: String? = nil) {
        if let page { state.page = page }
        if window == nil {
            let root = SettingsView()
                .environmentObject(state)
                .environmentObject(Preferences.shared)
                .environmentObject(app.localSend)
                .environmentObject(app.snippets)
                .environmentObject(app.sound)
                .environmentObject(app.reminders)
                .environmentObject(app.privacy)
                .environmentObject(app.phone)
                .environmentObject(app.monitor)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Muna"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.setContentSize(NSSize(width: 960, height: 680))
            window.minSize = NSSize(width: 760, height: 480)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
            applyScheme()
        }
        state.openAtLogin = SMAppService.mainApp.status == .enabled
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func applyScheme() {
        switch Preferences.shared.string("color-scheme") {
        case "light": window?.appearance = NSAppearance(named: .aqua)
        case "dark": window?.appearance = NSAppearance(named: .darkAqua)
        default: window?.appearance = nil
        }
    }
}

// --- the frame -----------------------------------------------------------------------------------

struct SettingsView: View {
    @EnvironmentObject var state: SettingsState

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar().frame(width: 236)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                SettingsHeader()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let intro = SettingsPages.info(state.page)?.intro, !intro.isEmpty, state.search.isEmpty {
                            Text(intro).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        SettingsPageContent(page: state.search.isEmpty ? state.page : "feat-search")
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

struct SettingsSidebar: View {
    @EnvironmentObject var state: SettingsState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search", text: $state.search).textFieldStyle(.plain)
                if !state.search.isEmpty {
                    Button { state.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .padding(.horizontal, 12)
            .padding(.top, 40)
            .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsPages.sections, id: \.0) { section in
                        let pages = section.1.filter(matches)
                        if !pages.isEmpty {
                            Text(section.0).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                                .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
                            ForEach(pages) { page in
                                SidebarRow(page: page, selected: state.search.isEmpty && state.page == page.id) {
                                    state.search = ""
                                    state.go(page.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .background(Color.primary.opacity(0.04))
    }

    private func matches(_ page: SettingsPageInfo) -> Bool {
        let q = state.search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || page.title.lowercased().contains(q) || page.intro.lowercased().contains(q)
    }
}

struct SidebarRow: View {
    let page: SettingsPageInfo
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol).frame(width: 20).foregroundColor(selected ? .white : .accentColor)
                Text(page.title)
                Spacer()
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundColor(selected ? .white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsHeader: View {
    @EnvironmentObject var state: SettingsState

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                Button { state.goBack() } label: { Image(systemName: "chevron.left").frame(width: 28, height: 26) }
                    .disabled(!state.canGoBack)
                Button { state.goForward() } label: { Image(systemName: "chevron.right").frame(width: 28, height: 26) }
                    .disabled(!state.canGoForward)
            }
            .buttonStyle(.plain)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            Text(state.search.isEmpty ? (SettingsPages.info(state.page)?.title ?? "") : "Search")
                .font(.system(size: 18, weight: .semibold))
            Spacer()
            if state.search.isEmpty, let action = SettingsPages.tryIt[state.page] {
                Button { state.run(action) } label: {
                    Label("Try it", systemImage: "play.fill").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 10)
    }
}

// --- the pieces of a page ------------------------------------------------------------------------

/// A rounded block of rows, like the cards of the Linux settings.
struct SettingsCard<Content: View>: View {
    let title: String?
    let content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        }
    }
}

/// A title with an explanation under it, and a control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String
    let control: () -> Control

    init(_ title: String, _ detail: String = "", @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
    }
}

/// A switch with a title and an explanation under it.
struct SettingsToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title, detail) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

/// A slider row: the value written beside the title.
struct SettingsSlider: View {
    let title: String
    let detail: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Text(format(value)).font(.system(size: 12).monospacedDigit()).foregroundColor(.secondary)
            }
            Slider(value: $value, in: range, step: step)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A choice from a few values (a pop-up menu, as Linux's drop-downs).
struct SettingsChoice: View {
    let title: String
    let detail: String
    @Binding var selection: String
    let options: [(String, String)]

    var body: some View {
        SettingsRow(title, detail) {
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { option in Text(option.1).tag(option.0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

extension Preferences {
    func boolBinding(_ key: String) -> Binding<Bool> { Binding(get: { self.bool(key) }, set: { self.set(key, $0) }) }
    func doubleBinding(_ key: String) -> Binding<Double> { Binding(get: { self.double(key) }, set: { self.set(key, $0) }) }
    func stringBinding(_ key: String) -> Binding<String> { Binding(get: { self.string(key) }, set: { self.set(key, $0) }) }

    /// A switch on one item of a list setting (menu-hidden, bar-metrics …).
    func listBinding(_ key: String, _ item: String, onMeansIn: Bool = true) -> Binding<Bool> {
        Binding(get: { self.strings(key).contains(item) == onMeansIn }, set: { on in
            var list = self.strings(key).filter { $0 != item }
            if on == onMeansIn { list.append(item) }
            self.set(key, list)
        })
    }
}

/// The page shown on the right.
struct SettingsPageContent: View {
    let page: String

    var body: some View {
        switch page {
        case "general": GeneralSettings()
        case "tools": MenuBarSettings()
        case "touchpad": TouchpadSettings()
        case "fingerprint": TouchIDSettings()
        case "monitor": MonitorSettings()
        case "features": FeaturesOverview()
        case "feat-search": FeatureList(features: Features.all)
        case "command": CommandSettings()
        case "quickpanel": QuickPanelSettings()
        case "toggles": TogglesSettings()
        case "cleaning": CleaningSettings()
        case "screenshot": ScreenshotSettings()
        case "phone": PhoneSettings()
        case "camera": CameraSettings()
        case "scratchpad": ScratchpadSettings()
        case "color": ColorSettings()
        case "radial": RadialSettings()
        case "sound": MixerSettings()
        case "output": OutputSettings()
        case "mic": MicSettings()
        case "muna": WidgetSettings()
        case "appearance": AppearanceSettings()
        case "gestures": CapsuleGestureSettings()
        case "activities": ActivitiesSettings()
        case "tray": TraySettings()
        case "clipboard": ClipboardSettings()
        case "localsend": LocalSendSettings()
        case "snippets": SnippetSettings()
        case "about": AboutSettings()
        default:
            if page.hasPrefix("feat-") { FeatureList(features: Features.all.filter { $0.topic == page }) } else { EmptyView() }
        }
    }
}

// --- Essentials ------------------------------------------------------------------------------------

struct GeneralSettings: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var state: SettingsState
    @EnvironmentObject var localSend: LocalSendController

    var body: some View {
        SettingsCard("Appearance") {
            HStack(spacing: 14) {
                ForEach([("default", "System"), ("light", "Light"), ("dark", "Dark")], id: \.0) { scheme in
                    let on = preferences.string("color-scheme") == scheme.0
                    Button { preferences.set("color-scheme", scheme.0) } label: {
                        VStack(spacing: 6) {
                            SchemePicture(kind: scheme.0).frame(height: 70)
                            Text(scheme.1).font(.system(size: 12, weight: on ? .semibold : .regular)).foregroundColor(on ? .accentColor : .primary)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 12).stroke(on ? Color.accentColor : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            SettingsNote("Applies to the settings window of Muna, not to the whole Mac.")
        }
        SettingsCard("Menu bar") {
            SettingsChoice(title: "Hide the menu bar", detail: "Hidden, it comes out when you push the pointer against the top edge of the screen (macOS's own setting).",
                           selection: Binding(get: { MenuBarHiding.current }, set: { MenuBarHiding.set($0); preferences.set("topbar-hide", $0) }),
                           options: [("never", "Never"), ("always", "Always"), ("fullscreen", "Only in full screen")])
            SettingsNote("macOS gives every screen its own menu bar (System Settings → Desktop & Dock → Displays have separate Spaces); Muna's capsule sits on each of them.")
        }
        SettingsCard("Muna") {
            SettingsToggle(title: "Open on hover", detail: "Off: the capsule opens on click only.", isOn: $preferences.openOnHover)
            SettingsToggle(title: "Collapse when the pointer leaves", detail: "Off: it stays open until you close it.", isOn: $preferences.autoCollapse)
            SettingsSlider(title: "Collapsed width", detail: "Fine tune the width of the collapsed capsule, in points (beside a notch the notch decides).",
                           value: preferences.doubleBinding("collapsed-width-adjust"), range: -60...120, step: 2, format: { "\(Int($0)) pt" })
            SettingsSlider(title: "Animation speed", detail: "How fast the capsule grows and shrinks. 2 is twice as fast.",
                           value: $preferences.animationSpeed, range: 0.25...4, step: 0.25, format: { String(format: "%.2f×", $0) })
            SettingsSlider(title: "Open after", detail: "Milliseconds the pointer rests on the capsule before it opens. 0: at once.",
                           value: Binding(get: { preferences.openDelay * 1000 }, set: { preferences.openDelay = $0 / 1000 }),
                           range: 0...1000, step: 25, format: { "\(Int($0)) ms" })
            SettingsSlider(title: "Close after", detail: "Milliseconds it stays open after the pointer left it.",
                           value: Binding(get: { preferences.closeDelay * 1000 }, set: { preferences.closeDelay = $0 / 1000 }),
                           range: 0...2000, step: 50, format: { "\(Int($0)) ms" })
        }
        SettingsCard("Show on") {
            Picker("", selection: $preferences.capsuleScreens) {
                Text("Every screen").tag("all")
                Text("The main screen (with the menu bar)").tag("main")
                Text("The built-in screen (with the notch)").tag("notch")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        SettingsCard("Shortcuts") {
            SettingsToggle(title: "Command Bar: ⌥Space", detail: "Start apps, calculate, convert units, find what you copied, search the web.", isOn: $preferences.commandHotKey)
            SettingsToggle(title: "Radial menu: ⌃⌥Space", detail: "A wheel of your favourite actions around the pointer.", isOn: $preferences.radialHotKey)
            SettingsToggle(title: "Muna, Tray, LocalSend, Clipboard, Alerts: ⌃⌥1 … ⌃⌥5", detail: "Each opens the capsule on its own tab, from anywhere.", isOn: $preferences.sectionHotKeys)
            SettingsNote("Works in any app, no extra permissions.")
        }
        SettingsCard("LocalSend") {
            SettingsToggle(title: "Receive files", detail: localSend.receiveProblem ?? "Other computers and phones on this network can send you files; you accept every sending.",
                           isOn: $preferences.localSendReceive)
            SettingsRow("Save received files in", preferences.receiveFolder.path) {
                Button("Choose…") { chooseReceiveFolder(preferences) }
            }
        }
        SettingsCard("Start") {
            SettingsToggle(title: "Open at login", detail: "Muna starts when you log in.",
                           isOn: Binding(get: { state.openAtLogin }, set: { state.setOpenAtLogin($0) }))
            if let error = state.loginError { Text(error).font(.system(size: 11)).foregroundColor(.orange) }
        }
        SettingsCard("Feedback") {
            SettingsRow("Send feedback", "Send a bug report or a feature idea directly to the person who maintains Muna.") {
                Button("Send feedback") { openLink("https://github.com/bekov0004/Muna/issues/new") }
            }
        }
        SettingsCard {
            SettingsRow("Reset all settings", "Every setting goes back to Muna's default; Muna starts again. Your notes, to-dos and files stay.") {
                Button("Reset all settings") {
                    preferences.resetAll()
                    relaunch()
                }
            }
        }
    }
}

/// A small picture of the light, dark or "as the system" window.
struct SchemePicture: View {
    let kind: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(kind == "dark" ? Color(white: 0.17) : Color(white: 0.95))
            if kind == "default" {
                GeometryReader { geometry in
                    Path { path in
                        path.move(to: CGPoint(x: geometry.size.width * 0.75, y: 0))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                        path.addLine(to: CGPoint(x: geometry.size.width * 0.25, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(Color(white: 0.17))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack {
                Rectangle().fill(Color.gray.opacity(0.35)).frame(height: 10)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(width: 150)
    }
}

/// macOS's own "Automatically hide and show the menu bar" (System Events' dock preferences).
enum MenuBarHiding {
    static var current: String {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        let hidden = global["_HIHideMenuBar"] as? Bool ?? false
        let inFullScreen = global["AppleMenuBarVisibleInFullscreen"] as? Bool == false
        return hidden ? "always" : inFullScreen ? "fullscreen" : "never"
    }

    static func set(_ mode: String) {
        // "Only in full screen": the bar stays, but full-screen apps hide it (Desktop & Dock's own choice)
        let defaults = Process()
        defaults.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        defaults.arguments = ["write", "-g", "AppleMenuBarVisibleInFullscreen", "-bool", mode == "fullscreen" ? "false" : "true"]
        try? defaults.run()
        defaults.waitUntilExit()
        let script = "tell application \"System Events\" to tell dock preferences to set autohide menu bar to \(mode == "always")"
        var error: NSDictionary?
        _ = NSAppleScript(source: script)?.executeAndReturnError(&error)
        DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, userInfo: nil, deliverImmediately: true)
    }
}

struct MenuBarSettings: View {
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        SettingsCard("Tabs of the window") {
            let pages = QuickPage.ordered(preferences.strings("menu-order"))
            ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                HStack(spacing: 12) {
                    Image(systemName: page.symbol).frame(width: 22).foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.title).font(.system(size: 13))
                        Text(page.about).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button { move(pages, index, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(index == 0)
                    Button { move(pages, index, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(index == pages.count - 1)
                    Toggle("", isOn: preferences.listBinding("menu-hidden", page.rawValue, onMeansIn: false)).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsNote("Switch off anything you do not need; the arrows change the order.")
        }
        SettingsCard("Menu bar icon") {
            SettingsRow("The icon of the Muna item in the menu bar") {
                Picker("", selection: preferences.stringBinding("bar-icon")) {
                    Text("Butterfly").tag("butterfly")
                    ForEach(MenuBarIcon.symbols, id: \.self) { symbol in Label(symbol, systemImage: symbol).tag(symbol) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private func move(_ pages: [QuickPage], _ index: Int, _ step: Int) {
        var list = pages.map(\.rawValue)
        let target = index + step
        guard list.indices.contains(target) else { return }
        list.swapAt(index, target)
        preferences.set("menu-order", list)
    }
}

enum MenuBarIcon {
    static let symbols = ["sparkles", "circle.grid.2x2", "square.grid.2x2", "star", "moon.stars", "leaf", "bolt", "cup.and.saucer"]
}

struct TouchpadSettings: View {
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        SettingsCard("Trackpad") {
            SettingsToggle(title: "Gestures everywhere", detail: "Three and four fingers do what you choose below, in any app.", isOn: preferences.boolBinding("touchpad-gestures"))
            SettingsToggle(title: "One finger along the edges", detail: "Slide along an edge of the trackpad for brightness or volume, double tap or rest a finger at an edge.",
                           isOn: preferences.boolBinding("edge-gestures"))
            SettingsSlider(title: "Sensitivity", detail: "More: a shorter move of the fingers is enough.",
                           value: preferences.doubleBinding("gesture-sensitivity"), range: 25...400, step: 5, format: { "\(Int($0)) %" })
            SettingsChoice(title: "Desktops", detail: "Which way the desktops go with a swipe.", selection: preferences.stringBinding("gesture-desktops"),
                           options: [("fingers", "Move with the fingers"), ("swipe", "Go the way of the swipe")])
            SettingsNote("macOS does its own three- and four-finger gestures too: turn the ones you give to Muna off in System Settings → Trackpad → More Gestures.")
        }
        ForEach(GestureGroups.groups, id: \.0) { group in
            SettingsCard(group.0) {
                ForEach(group.1, id: \.self) { gesture in
                    GestureActionRow(title: GestureGroups.name(gesture), key: gesture, isEdge: false)
                }
            }
        }
        SettingsCard("Edges (one finger)") {
            ForEach(GestureGroups.edges, id: \.0) { edge in
                GestureActionRow(title: edge.1, key: edge.0, isEdge: true)
            }
        }
        Button("Back to the defaults") { GestureSettings.reset() }
    }
}

struct GestureActionRow: View {
    @EnvironmentObject var preferences: Preferences
    let title: String
    let key: String
    let isEdge: Bool

    var body: some View {
        SettingsRow(title) {
            Picker("", selection: Binding(get: { GestureSettings.action(key, edge: isEdge) }, set: { GestureSettings.set(key, $0, edge: isEdge) })) {
                ForEach(GestureCatalog.actions.filter { !isEdge || !$0.live }, id: \.id) { action in
                    Text(action.group.isEmpty ? action.title : "\(action.title)").tag(action.id)
                }
            }
            .labelsHidden()
            .frame(width: 260)
        }
    }
}

enum GestureGroups {
    static let groups: [(String, [String])] = [
        ("Three fingers", ["swipe3-left", "swipe3-right", "swipe3-up", "swipe3-down"]),
        ("Four fingers", ["swipe4-left", "swipe4-right", "swipe4-up", "swipe4-down"]),
        ("Pinch", ["pinch3-in", "pinch3-out", "pinch4-in", "pinch4-out"]),
        ("Rest the fingers", ["hold3", "hold4"]),
    ]

    static let edges: [(String, String)] = [
        ("edge-left-plus", "Left edge, up"), ("edge-left-minus", "Left edge, down"), ("edge-right-plus", "Right edge, up"), ("edge-right-minus", "Right edge, down"),
        ("edge-top-plus", "Top edge, to the right"), ("edge-top-minus", "Top edge, to the left"), ("edge-bottom-plus", "Bottom edge, to the right"),
        ("edge-bottom-minus", "Bottom edge, to the left"), ("edge-tap-left", "Double tap, left edge"), ("edge-tap-right", "Double tap, right edge"),
        ("edge-tap-top", "Double tap, top middle"), ("edge-tap-bottom", "Double tap, bottom middle"), ("edge-hold-left", "Rest a finger, left edge"),
        ("edge-hold-right", "Rest a finger, right edge"), ("edge-hold-top", "Rest a finger, top middle"), ("edge-hold-bottom", "Rest a finger, bottom middle"),
    ]

    static func name(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        let kind = parts[0].filter(\.isLetter)
        let fingers = parts[0].filter(\.isNumber)
        if kind == "hold" { return "\(fingers) fingers rest and lift" }
        let direction = parts.count > 1 ? parts[1] : ""
        let names = ["left": "Swipe left", "right": "Swipe right", "up": "Swipe up", "down": "Swipe down",
                     "in": "Pinch in (fingers together)", "out": "Pinch out (fingers apart)"]
        let name = names[direction] ?? direction
        return kind == "pinch" ? "\(name) · \(fingers)" : name
    }
}

/// The gestures' choices: "gesture-actions" (a dictionary, as Linux) and the edge keys.
enum GestureSettings {
    static func action(_ key: String, edge: Bool) -> String {
        let p = Preferences.shared
        if edge { return (p.value(key) as? String) ?? GestureCatalog.edgeDefaults[key] ?? "none" }
        return (p.value("gesture-actions") as? [String: String])?[key] ?? GestureCatalog.defaults[key] ?? "none"
    }

    static func set(_ key: String, _ action: String, edge: Bool) {
        let p = Preferences.shared
        if edge { p.set(key, action); return }
        var all = (p.value("gesture-actions") as? [String: String]) ?? [:]
        all[key] = action
        p.set("gesture-actions", all)
    }

    static func reset() {
        let p = Preferences.shared
        p.set("gesture-actions", nil)
        for (key, _) in GestureGroups.edges { p.set(key, nil) }
    }
}

struct TouchIDSettings: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var privacy: PrivacyModel

    var body: some View {
        SettingsCard("Reader") {
            Text(TouchIDSettings.status).font(.system(size: 13))
        }
        SettingsCard("Confirm") {
            SettingsToggle(title: "Claude Code's questions",
                           detail: "While Claude Code asks to edit a file or run a command, Touch ID allows it (Deny stays a button).",
                           isOn: preferences.boolBinding("fingerprint-agents"))
        }
        SettingsCard("Private notes and clipboard items") {
            SettingsToggle(title: "Ask for Touch ID", detail: "Notes and clipboard items you mark private stay hidden until Touch ID (or your password) opens them, for 5 minutes.",
                           isOn: preferences.boolBinding("fingerprint-private"))
            SettingsRow(privacy.unlocked ? "Open now" : "Locked") {
                if privacy.unlocked { Button("Lock") { privacy.lock() } } else { Button("Open") { privacy.unlock() } }
            }
        }
        SettingsNote("macOS lets no app notice a finger on the reader by itself, so touching it cannot start an action; it answers when Muna asks.")
    }

    static var status: String {
        let context = LAContext()
        var error: NSError?
        let can = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        if can { return "Touch ID is ready." }
        if context.biometryType == .touchID { return "Touch ID is here, but no finger is added: System Settings → Touch ID & Password." }
        return "No Touch ID on this Mac: your password opens private items instead."
    }
}

struct MonitorSettings: View {
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        SettingsCard("In the menu bar") {
            ForEach(Readings.all, id: \.id) { reading in
                SettingsToggle(title: reading.title, detail: reading.available ? "" : "macOS gives no app this reading on this Mac.",
                               isOn: preferences.listBinding("bar-metrics", reading.id))
            }
            SettingsNote("Choose what is written next to the Muna icon in the menu bar. Nothing chosen: only the icon.")
        }
        SettingsCard("In the panel") {
            ForEach([("cpu", "Processor"), ("gpu", "Graphics"), ("memory", "Memory"), ("temps", "Temperatures"), ("uptime", "Uptime")], id: \.0) { block in
                SettingsToggle(title: block.1, detail: "", isOn: preferences.listBinding("system-blocks", block.0))
            }
            SettingsToggle(title: "Show graph scale", detail: "Write the highest value on the dotted line of every graph.", isOn: preferences.boolBinding("graph-scale"))
        }
        SettingsCard("Readings and alerts") {
            SettingsChoice(title: "Update every", detail: "How often the numbers are read while a monitor page or a menu-bar value is shown.",
                           selection: Binding(get: { String(Int(preferences.double("monitor-interval"))) }, set: { preferences.set("monitor-interval", Double($0) ?? 2) }),
                           options: [("1", "1 second"), ("2", "2 seconds"), ("5", "5 seconds")])
            SettingsChoice(title: "Temperatures", detail: "", selection: preferences.stringBinding("temp-unit"), options: [("C", "°C"), ("F", "°F")])
        }
        SettingsCard("Alerts") {
            SettingsToggle(title: "Show alerts", detail: "A card in the capsule when one of the limits below is passed. 0 turns a limit off.", isOn: preferences.boolBinding("system-alerts"))
            SettingsSlider(title: "High CPU", detail: "% for 30 seconds", value: preferences.doubleBinding("alert-cpu"), range: 0...100, step: 5, format: { "\(Int($0)) %" })
            SettingsSlider(title: "High CPU temperature", detail: "°C", value: preferences.doubleBinding("alert-temp"), range: 0...110, step: 1, format: { "\(Int($0)) °C" })
            SettingsSlider(title: "Memory nearly full", detail: "% free", value: preferences.doubleBinding("alert-memory"), range: 0...50, step: 1, format: { "\(Int($0)) %" })
            SettingsSlider(title: "Low disk space", detail: "% free", value: preferences.doubleBinding("alert-disk"), range: 0...50, step: 1, format: { "\(Int($0)) %" })
            SettingsSlider(title: "Low battery", detail: "%", value: preferences.doubleBinding("alert-battery"), range: 0...50, step: 1, format: { "\(Int($0)) %" })
        }
    }
}

// --- Features ---------------------------------------------------------------------------------------

/// One line of the feature lists: a widget (in the capsule or the menu-bar window) or a switch.
struct Feature: Identifiable {
    let topic: String
    let group: String
    let title: String
    let subtitle: String
    let symbol: String
    /// A capsule widget (enabled-widgets), a menu-bar page (menu-hidden), or a setting.
    enum Kind { case widget(String), page(String), key(String) }
    let kind: Kind
    var id: String { "\(topic)-\(title)" }
}

enum Features {
    static let tools = "Window of the menu-bar icon"
    static let island = "Island widgets (the capsule)"

    static var all: [Feature] {
        let topicOf: [String: String] = [
            "media": "feat-media", "sound": "feat-media", "mirror": "feat-media",
            "system": "feat-system", "network": "feat-system", "awake": "feat-system", "displays": "feat-system", "tools": "feat-system",
            "windows": "feat-windows",
            "focus": "feat-work", "timer": "feat-work", "todo": "feat-work", "notes": "feat-work", "reminders": "feat-work",
            "shortcuts": "feat-work", "calendar": "feat-work", "agents": "feat-work",
            "downloads": "feat-files", "phone": "feat-files",
        ]
        var list: [Feature] = QuickPage.allCases.map {
            Feature(topic: topicOf[$0.rawValue] ?? "feat-system", group: tools, title: $0.title, subtitle: $0.about, symbol: $0.symbol, kind: .page($0.rawValue))
        }
        list += WidgetCatalog.all.map {
            Feature(topic: topicOf[$0.id] ?? "feat-capsule", group: island, title: $0.title, subtitle: $0.subtitle, symbol: $0.symbol, kind: .widget($0.id))
        }
        func key(_ topic: String, _ group: String, _ title: String, _ subtitle: String, _ symbol: String, _ key: String) -> Feature {
            Feature(topic: topic, group: group, title: title, subtitle: subtitle, symbol: symbol, kind: .key(key))
        }
        list += [
            key("feat-capsule", "Live Activities", "Music", "The playing track in the collapsed capsule", "music.note", "activity-media"),
            key("feat-capsule", "Live Activities", "Timer", "A running countdown or focus session in the capsule", "timer", "activity-timer"),
            key("feat-capsule", "Live Activities", "Calendar", "The next meeting, from 10 minutes before it", "calendar", "activity-calendar"),
            key("feat-capsule", "Live Activities", "Tray", "A card when files are added to the tray", "tray.and.arrow.down", "activity-files"),
            key("feat-capsule", "Live Activities", "Downloads", "Files arriving in the Downloads folder", "arrow.down.circle", "activity-downloads"),
            key("feat-system", "Cards and alerts", "System alerts", "A busy processor, heat, a full disk or memory, a low battery", "exclamationmark.triangle", "system-alerts"),
            key("feat-work", "Cards and alerts", "AI agents finished", "A card when Claude Code or Codex finishes a task", "checkmark.circle", "agents-alerts"),
            key("feat-capsule", "Cards and alerts", "Keyboard layout", "The capsule widens for a moment and shows the layout when you switch it", "keyboard", "show-input-source"),
            key("feat-capsule", "Cards and alerts", "Caps Lock", "The capsule shows whether Caps Lock is on or off", "capslock", "show-caps-lock"),
            key("feat-media", "Music", "Lyrics", "The line being sung under the title (the song is looked up on lrclib.net)", "quote.bubble", "show-lyrics"),
            key("feat-media", "Music", "Colored effects", "The effect takes the color of the album art", "paintpalette", "colored-effects"),
            key("feat-media", "Music", "Swipe to change tracks", "A sideways swipe on the capsule skips songs", "forward", "gestures-media-swipe"),
            key("feat-files", "Clipboard", "Click pastes", "A click on an item pastes it into the app you were in", "doc.on.clipboard", "clipboard-click-pastes"),
            key("feat-files", "Clipboard", "Keep history", "Save everything you copied after a restart (pinned items and notes are always saved)", "tray.full", "clipboard-keep-history"),
            key("feat-files", "Clipboard", "Clean links", "Remove tracking parameters (utm_*, fbclid ...) from copied links", "link", "clipboard-clean-urls"),
            key("feat-files", "Files and sharing", "Keep the tray", "The files on the tray stay after a restart", "tray.and.arrow.down", "tray-keep-files"),
            key("feat-files", "Files and sharing", "Receive files with LocalSend", "This computer becomes visible to LocalSend devices (port 53317); every transfer asks first", "wifi", "localsend-receive"),
            key("feat-windows", "Behaviour", "Touchpad gestures everywhere", "Three and four fingers: switch apps, desktops, windows, sound and more", "hand.draw", "touchpad-gestures"),
            key("feat-capsule", "Behaviour", "Open on hover", "The capsule opens when the pointer rests on it", "cursorarrow", "open-on-hover"),
            key("feat-capsule", "Behaviour", "Collapse when the pointer leaves", "The open panel closes by itself", "arrow.down.right.and.arrow.up.left", "auto-collapse"),
            key("feat-capsule", "Behaviour", "Swipe down to open", "A two-finger swipe down on the capsule opens it", "hand.draw", "gestures-swipe-open"),
            key("feat-capsule", "Behaviour", "Swipe up to close", "A two-finger swipe up closes the panel", "hand.draw", "gestures-swipe-close"),
        ]
        return list
    }

    static let topics: [(String, String, String, String)] = SettingsPages.sections[1].1.dropFirst().map { ($0.id, $0.title, $0.symbol, $0.intro) }

    /// Whether a feature is on; switching it.
    static func isOn(_ feature: Feature) -> Bool {
        let p = Preferences.shared
        switch feature.kind {
        case .widget(let id): return p.enabledWidgets.contains(id)
        case .page(let id): return !p.strings("menu-hidden").contains(id)
        case .key(let key): return typed[key]?.get() ?? p.bool(key)
        }
    }

    static func set(_ feature: Feature, _ on: Bool) {
        let p = Preferences.shared
        switch feature.kind {
        case .widget(let id):
            p.enabledWidgets.removeAll { $0 == id }
            if on { p.enabledWidgets.append(id) }
        case .page(let id):
            p.set("menu-hidden", p.strings("menu-hidden").filter { $0 != id } + (on ? [] : [id]))
        case .key(let key):
            if let typed = typed[key] { typed.set(on) } else { p.set(key, on) }
        }
    }

    /// The settings the Mac version keeps as typed properties (the others are read by key).
    private struct Typed {
        let get: () -> Bool
        let set: (Bool) -> Void
    }

    private static let typed: [String: Typed] = {
        let p = Preferences.shared
        return [
            "show-lyrics": Typed(get: { p.showLyrics }, set: { p.showLyrics = $0 }),
            "clipboard-keep-history": Typed(get: { p.clipboardKeepHistory }, set: { p.clipboardKeepHistory = $0 }),
            "clipboard-clean-urls": Typed(get: { p.clipboardCleanUrls }, set: { p.clipboardCleanUrls = $0 }),
            "tray-keep-files": Typed(get: { p.trayKeepFiles }, set: { p.trayKeepFiles = $0 }),
            "localsend-receive": Typed(get: { p.localSendReceive }, set: { p.localSendReceive = $0 }),
            "open-on-hover": Typed(get: { p.openOnHover }, set: { p.openOnHover = $0 }),
            "auto-collapse": Typed(get: { p.autoCollapse }, set: { p.autoCollapse = $0 }),
        ]
    }()
}

struct FeatureList: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var state: SettingsState
    let features: [Feature]

    var body: some View {
        let q = state.search.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = features.filter { q.isEmpty || "\($0.title) \($0.subtitle) \($0.group)".lowercased().contains(q) }
        let groups = shown.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
        if shown.isEmpty { SettingsNote("Nothing found.") }
        ForEach(groups, id: \.self) { group in
            SettingsCard(group) {
                ForEach(shown.filter { $0.group == group }) { feature in
                    HStack(spacing: 12) {
                        Image(systemName: feature.symbol)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8).fill(tone(group).opacity(0.18)))
                            .foregroundColor(tone(group))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(feature.title).font(.system(size: 13))
                                if let badge = badge(group) {
                                    Text(badge).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Capsule().fill(tone(group).opacity(0.2))).foregroundColor(tone(group))
                                }
                            }
                            Text(feature.subtitle).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { Features.isOn(feature) }, set: { Features.set(feature, $0) })).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
    }

    private func badge(_ group: String) -> String? {
        switch group {
        case Features.tools: return "Menu-bar icon"
        case Features.island, "Live Activities", "Cards and alerts": return "Island"
        default: return nil
        }
    }

    private func tone(_ group: String) -> Color {
        switch group {
        case Features.island, "Music": return .purple
        case "Live Activities", "Files and sharing": return .green
        case "Cards and alerts": return .orange
        default: return .accentColor
        }
    }
}

struct FeaturesOverview: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var state: SettingsState

    static let presets: [(String, String, [String])] = [
        ("Everything", "Every tool and widget.", WidgetCatalog.all.map(\.id)),
        ("Essentials", "Music, calendar and mirror in the capsule, with every tool in the menu-bar window.", ["media", "calendar", "mirror", "timer"]),
        ("Light island", "Only music and calendar.", ["media", "calendar"]),
    ]

    var body: some View {
        let features = Features.all
        let widgets = WidgetCatalog.all.count + QuickPage.allCases.count
        let on = preferences.enabledWidgets.count + QuickPage.allCases.filter { !preferences.strings("menu-hidden").contains($0.rawValue) }.count
        SettingsCard("Start with a bundle") {
            Text("\(on) of \(widgets) tools and widgets are on").font(.system(size: 13, weight: .semibold))
            HStack(alignment: .top, spacing: 10) {
                ForEach(Self.presets, id: \.0) { preset in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(preset.0).font(.system(size: 13, weight: .semibold))
                        Text(preset.1).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Apply") {
                            preferences.enabledWidgets = preset.2
                            preferences.set("menu-hidden", preset.0 == "Light island" ? QuickPage.allCases.map(\.rawValue) : [String]())
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                }
            }
        }
        SettingsCard("By topic") {
            ForEach(Features.topics, id: \.0) { topic in
                let members = features.filter { $0.topic == topic.0 }
                Button { state.go(topic.0) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: topic.2).frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.18))).foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(topic.1).font(.system(size: 13))
                            Text(topic.3).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text("\(members.filter(Features.isOn).count) of \(members.count) on").font(.system(size: 11)).foregroundColor(.secondary)
                        Image(systemName: "chevron.right").foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// --- Utilities --------------------------------------------------------------------------------------

struct CommandSettings: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var state: SettingsState

    var body: some View {
        SettingsCard("Command Bar") {
            SettingsRow("Open the search now", "One shortcut (⌥Space) opens a field over whatever you are doing. Type a few letters, press Return and it happens. Nothing you type is saved.") {
                Button("Try") { state.run("command") }
            }
            SettingsToggle(title: "Shortcut ⌥Space", detail: "", isOn: $preferences.commandHotKey)
        }
        SettingsCard("Other shortcuts") {
            ForEach([("Open the capsule", "⌃⌥1", "muna"), ("File shelf", "⌃⌥2", "tray"), ("LocalSend", "⌃⌥3", "localSend"),
                     ("Clipboard history", "⌃⌥4", "clipboard"), ("Alerts", "⌃⌥5", "alerts")], id: \.0) { item in
                SettingsRow(item.0, item.1) { Button("Open") { state.run("capsule:\(item.2)") } }
            }
            SettingsToggle(title: "These shortcuts", detail: "Each opens the capsule on its own tab, from anywhere.", isOn: $preferences.sectionHotKeys)
        }
        SettingsNote("Snippets (;trigger) are under Tabs → Snippets.")
    }
}

struct QuickPanelSettings: View {
    @EnvironmentObject var state: SettingsState

    var body: some View {
        SettingsCard("Quick panel") {
            SettingsRow("Open quick panel", "The window of the menu-bar icon with your favourite tools.") { Button("Open") { state.run("quickpanel") } }
            SettingsRow("Its tabs", "Choose, hide and order them in Essentials → Menu bar.") { Button("Menu bar") { state.go("tools") } }
        }
    }
}

struct TogglesSettings: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var state: SettingsState

    var body: some View {
        SettingsCard("Quick toggles") {
            SettingsRow("Switch dark mode", "The whole Mac between light and dark.") { Button("Switch") { state.run("dark") } }
            SettingsRow("Night Shift", "Warmer colours at night.") {
                Toggle("", isOn: Binding(get: { NightShift.isOn }, set: { NightShift.set($0); preferences.objectWillChange.send() })).labelsHidden().toggleStyle(.switch)
            }
            SettingsNote("One-click system actions in the menu-bar window (Tools) and in the radial menu.")
        }
        SettingsCard("Excluded drives") {
            let volumes = QuickTools.removableVolumes
            if volumes.isEmpty { SettingsNote("No drives are connected.") }
            ForEach(volumes, id: \.path) { volume in
                SettingsToggle(title: volume.lastPathComponent, detail: volume.path, isOn: preferences.listBinding("eject-excluded", volume.path))
            }
            SettingsNote("Drives in the list are never ejected by Eject all disks.")
        }
    }
}

struct CleaningSettings: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var state: SettingsState

    var body: some View {
        SettingsCard("Cleaning Mode") {
            SettingsRow("Lock keyboard now", "Locks the keyboard and the pointer so you can clean safely. Hold Esc for 3 seconds to finish; it ends by itself after a minute.") {
                Button("Lock") { state.run("cleaning") }
            }
            SettingsToggle(title: "Keep screen visible", detail: "Shows a discreet indicator in the corner of the screen instead of blacking out the content.",
                           isOn: preferences.boolBinding("cleaning-visible"))
        }
    }
}

struct ScreenshotSettings: View {
    @EnvironmentObject var state: SettingsState

    var body: some View {
        SettingsCard("Screenshot") {
            SettingsRow("Take a screenshot", "Choose a part of the screen or a window; it is copied.") { Button("Take") { state.run("screenshot") } }
            SettingsRow("Screen recording", "Opens macOS's screenshot tool in recording mode. Stop it with the button in the menu bar.") { Button("Record") { state.run("record") } }
        }
    }
}

struct PhoneSettings: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var phone: PhoneModel
    @EnvironmentObject var state: SettingsState

    var body: some View {
        SettingsCard("Phone") {
            SettingsRow("Android's platform-tools", phone.adb ?? "Not found: brew install android-platform-tools, then start Muna again.") {
                if phone.adb == nil { Button("Get them") { openLink("https://developer.android.com/tools/releases/platform-tools") } } else { Text("Found").foregroundColor(.green) }
            }
            SettingsRow("The phone in the menu-bar window", "Its screen, touches, keys and typing.") { Button("Open") { state.run("quickpanel:phone") } }
            SettingsToggle(title: "Dark phone screen", detail: "While you use the phone from here, its own screen stays dark (Muna Phone).", isOn: preferences.boolBinding("phone-dark-screen"))
        }
    }
}

struct CameraSettings: View {
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        SettingsCard("Camera preview") {
            SettingsToggle(title: "Show in the capsule", detail: "A mirror: see yourself in the capsule before a call. The camera is on only while the capsule shows it.",
                           isOn: widgetBinding(preferences, "mirror"))
        }
    }
}

struct ScratchpadSettings: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var state: SettingsState

    var body: some View {
        SettingsCard("Scratchpad") {
            SettingsRow("Open the scratchpad", "One long note in its own window, kept on this computer.") { Button("Open") { state.run("scratchpad") } }
            SettingsToggle(title: "Notes in the capsule", detail: "Quick notes you can copy later.", isOn: widgetBinding(preferences, "notes"))
            SettingsToggle(title: "To-do list", detail: "A short list of things to do, next to the notes.", isOn: widgetBinding(preferences, "todo"))
        }
    }
}

struct ColorSettings: View {
    @EnvironmentObject var state: SettingsState

    var body: some View {
        SettingsCard("Color picker") {
            SettingsRow("Pick a color", "Pick any pixel of the screen. The color is copied as a hex code.") { Button("Pick") { state.run("color") } }
        }
    }
}

struct RadialSettings: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var state: SettingsState

    var body: some View {
        SettingsCard("Radial menu") {
            SettingsRow("Open the radial menu", "Opens a wheel of your favorite actions around the pointer.") { Button("Open") { state.run("radial") } }
            SettingsToggle(title: "Shortcut ⌃⌥Space", detail: "", isOn: $preferences.radialHotKey)
        }
        SettingsCard("Actions") {
            let chosen = preferences.strings("radial-actions")
            ForEach(Array(chosen.enumerated()), id: \.offset) { index, id in
                if let info = RadialCatalog.info(id) {
                    HStack(spacing: 12) {
                        Text("\(index + 1)").font(.system(size: 12).monospacedDigit()).foregroundColor(.secondary).frame(width: 16)
                        Image(systemName: info.symbol).frame(width: 22).foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info.title).font(.system(size: 13))
                            Text(info.kind).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button { move(chosen, index, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(index == 0)
                        Button { move(chosen, index, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(index == chosen.count - 1)
                        Button { preferences.set("radial-actions", chosen.enumerated().filter { $0.offset != index }.map(\.element)) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Menu("Add action") {
                    ForEach(RadialCatalog.all.filter { !chosen.contains($0.id) }, id: \.id) { info in
                        Button(info.title) { preferences.set("radial-actions", chosen + [info.id]) }
                    }
                }
                .fixedSize()
                .disabled(chosen.count >= 8)
                Spacer()
                Button("Reset") { preferences.set("radial-actions", nil) }
            }
            SettingsNote("Add up to eight actions. While the wheel is open, the number keys choose them.")
        }
    }

    private func move(_ list: [String], _ index: Int, _ step: Int) {
        var list = list
        let target = index + step
        guard list.indices.contains(target) else { return }
        list.swapAt(index, target)
        preferences.set("radial-actions", list)
    }
}

// --- Sound ------------------------------------------------------------------------------------------

struct MixerSettings: View {
    @EnvironmentObject var sound: SoundModel
    @EnvironmentObject var state: SettingsState

    var body: some View {
        SettingsCard("Volume") {
            SettingsSlider(title: "Volume", detail: "The output's volume.", value: Binding(get: { sound.volume }, set: { sound.setVolume($0) }),
                           range: 0...1, step: 0.01, format: { "\(Int(($0 * 100).rounded())) %" })
            SettingsToggle(title: "Mute", detail: "", isOn: Binding(get: { sound.muted }, set: { sound.setMuted($0) }))
            SettingsRow("Open the volume mixer", "The Sound tab of the menu-bar window.") { Button("Open") { state.run("quickpanel:sound") } }
        }
        SettingsNote("macOS has no volume of its own for each app (that needs an audio driver); Muna sets the volume of the output.")
    }
}

struct OutputSettings: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var sound: SoundModel
    @EnvironmentObject var state: SettingsState

    var body: some View {
        SettingsCard("Output switcher") {
            SettingsRow("Switch output now", "Switches the sound to the next output: speakers, headphones, a Bluetooth device.") { Button("Switch") { state.run("output") } }
        }
        SettingsCard("Outputs in the cycle") {
            if sound.outputs.isEmpty { SettingsNote("No sound outputs found.") }
            ForEach(sound.outputs) { output in
                SettingsToggle(title: output.name, detail: output.id == sound.currentOutput ? "Playing now" : "",
                               isOn: preferences.listBinding("output-skipped", output.name, onMeansIn: false))
            }
            SettingsNote("Turn an output off to skip it when switching.")
        }
        .onAppear { sound.refresh() }
    }
}

struct MicSettings: View {
    @EnvironmentObject var sound: SoundModel
    @EnvironmentObject var state: SettingsState

    var body: some View {
        SettingsCard("Mute microphone") {
            SettingsRow(sound.microphoneMuted ? "The microphone is muted" : "The microphone is on",
                        "Cuts the microphone with a click, across every app.") {
                Button(sound.microphoneMuted ? "Unmute" : "Mute") { state.run("mic") }
            }
        }
        .onAppear { sound.refresh() }
    }
}

// --- Dynamic Island ---------------------------------------------------------------------------------

func widgetBinding(_ preferences: Preferences, _ id: String) -> Binding<Bool> {
    Binding(get: { preferences.enabledWidgets.contains(id) }, set: { on in
        preferences.enabledWidgets.removeAll { $0 == id }
        if on { preferences.enabledWidgets.append(id) }
    })
}

struct WidgetSettings: View {
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        SettingsCard("Capsule width") {
            SettingsChoice(title: "Width mode", detail: "Auto follows the widgets; fixed is a share of the screen.",
                           selection: preferences.stringBinding("width-mode"), options: [("auto", "Auto"), ("fixed", "Fixed")])
            if preferences.string("width-mode") == "fixed" {
                SettingsSlider(title: "Fixed width", detail: "Share of the screen width (fixed mode).", value: preferences.doubleBinding("fixed-width"),
                               range: 0.25...0.9, step: 0.05, format: { "\(Int(($0 * 100).rounded())) %" })
            }
            SettingsSlider(title: "Widget size", detail: "Scales the width of every cell.", value: preferences.doubleBinding("size-scale"),
                           range: 0.85...1.25, step: 0.05, format: { String(format: "%.2f", $0) })
        }
        SettingsCard("Widgets, in their order") {
            ForEach(orderedWidgets, id: \.id) { info in
                let enabled = preferences.enabledWidgets.contains(info.id)
                HStack(spacing: 12) {
                    Image(systemName: info.symbol).frame(width: 20).foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.title).font(.system(size: 13))
                        Text(info.subtitle).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if enabled {
                        Stepper("\(preferences.cells(info.id)) cells", value: Binding(
                            get: { preferences.cells(info.id) },
                            set: { preferences.widgetCells[info.id] = max(info.minCells, min($0, 8)) }
                        ), in: info.minCells...8)
                        .font(.system(size: 11))
                        .fixedSize()
                        Button { move(info.id, -1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless).help("Move left")
                        Button { move(info.id, 1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless).help("Move right")
                    }
                    Toggle("", isOn: widgetBinding(preferences, info.id)).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsNote("The order of the widgets in the capsule; a widget is cells of 44 points; what does not fit goes on a second page.")
        }
        SettingsCard("Shortcuts: the apps") {
            if preferences.shortcutApps.isEmpty { SettingsNote("No apps yet.") }
            ForEach(preferences.shortcutApps, id: \.self) { path in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 22, height: 22)
                    Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent).font(.system(size: 13))
                    Spacer()
                    Button("Remove") { preferences.shortcutApps.removeAll { $0 == path } }
                }
            }
            Button("Add apps…") { addApps() }
        }
    }

    /// The chosen widgets first, in their order, then the others.
    private var orderedWidgets: [WidgetInfo] {
        preferences.enabledWidgets.compactMap(WidgetCatalog.info) + WidgetCatalog.all.filter { !preferences.enabledWidgets.contains($0.id) }
    }

    private func move(_ id: String, _ step: Int) {
        var list = preferences.enabledWidgets
        guard let index = list.firstIndex(of: id) else { return }
        let target = index + step
        guard list.indices.contains(target) else { return }
        list.swapAt(index, target)
        preferences.enabledWidgets = list
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK {
            for url in panel.urls where !preferences.shortcutApps.contains(url.path) { preferences.shortcutApps.append(url.path) }
        }
    }
}

struct AppearanceSettings: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var reminders: RemindersModel
    @EnvironmentObject var state: SettingsState

    var body: some View {
        SettingsCard("Butterfly") {
            SettingsToggle(title: "Butterfly in the capsule", detail: "The little butterfly in the middle of the closed capsule. Off: a small camera circle.", isOn: $preferences.capsuleButterfly)
            SettingsToggle(title: "Flap its wings", detail: "Now and then it beats its wings and blinks.", isOn: preferences.boolBinding("butterfly-flap"))
            SettingsSlider(title: "Every", detail: "Seconds between two flaps.", value: preferences.doubleBinding("butterfly-flap-every"), range: 5...300, step: 5, format: { "\(Int($0)) s" })
        }
        SettingsCard("Reminders") {
            SettingsToggle(title: "A sound with a reminder", detail: "At the time you choose the butterfly flies out of the capsule, grows and shows your text. Also in the menu-bar window (Reminders).",
                           isOn: preferences.boolBinding("reminder-sound"))
            HStack {
                TextField("What should the butterfly tell you?", text: $state.reminderText).textFieldStyle(.roundedBorder)
                DatePicker("", selection: $state.reminderTime, displayedComponents: [.date, .hourAndMinute]).labelsHidden().fixedSize()
                Button("Add") {
                    let text = state.reminderText.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return }
                    reminders.add(text: text, time: state.reminderTime)
                    state.reminderText = ""
                }
            }
            if reminders.reminders.filter({ !$0.done }).isEmpty { SettingsNote("No reminders yet.") }
            ForEach(reminders.reminders.filter { !$0.done }) { reminder in
                HStack {
                    Image(systemName: "bell").foregroundColor(.accentColor)
                    Text(reminder.text).font(.system(size: 13))
                    Spacer()
                    Text(Date(timeIntervalSince1970: TimeInterval(reminder.at) / 1000).formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    Button("Remove") { reminders.remove(id: reminder.id) }
                }
            }
        }
        SettingsCard("Shape") {
            SettingsSlider(title: "Corner radius", detail: "In points.", value: $preferences.cornerRadius, range: 8...44, step: 1, format: { "\(Int($0))" })
            SettingsSlider(title: "Transparency", detail: "Background opacity: 1.00 is fully opaque.", value: $preferences.backgroundOpacity, range: 0.5...1, step: 0.02, format: { String(format: "%.2f", $0) })
            SettingsSlider(title: "Shadow", detail: "0 turns the shadow off.", value: preferences.doubleBinding("shadow-strength"), range: 0...1, step: 0.1, format: { String(format: "%.1f", $0) })
        }
        SettingsCard("Widgets") {
            SettingsSlider(title: "Height", detail: "Height of the widget area, in points.", value: preferences.doubleBinding("row-height"), range: 90...220, step: 2, format: { "\(Int($0))" })
            SettingsSlider(title: "Padding", detail: "Space around the widgets.", value: preferences.doubleBinding("content-padding"), range: 6...32, step: 1, format: { "\(Int($0))" })
            SettingsSlider(title: "Spacing", detail: "Space between widgets.", value: preferences.doubleBinding("widget-spacing"), range: 0...40, step: 1, format: { "\(Int($0))" })
            SettingsToggle(title: "Dividers", detail: "Thin lines between widgets.", isOn: preferences.boolBinding("show-dividers"))
        }
        SettingsCard {
            SettingsToggle(title: "System alerts", detail: "Cards for a busy processor, heat, a full disk or memory and low batteries.", isOn: preferences.boolBinding("system-alerts"))
            SettingsNote("The menu bar's colour is macOS's (it follows the wallpaper); Linux's top-bar colour has no counterpart here.")
        }
        Button("Reset the appearance") {
            for key in ["size-scale", "row-height", "content-padding", "widget-spacing", "show-dividers", "shadow-strength", "butterfly-flap", "butterfly-flap-every"] {
                preferences.set(key, nil)
            }
            preferences.cornerRadius = 32
            preferences.backgroundOpacity = 0.96
        }
    }
}

struct CapsuleGestureSettings: View {
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        SettingsCard("Capsule") {
            SettingsToggle(title: "Swipe down to open", detail: "Two-finger swipe down over the collapsed capsule.", isOn: preferences.boolBinding("gestures-swipe-open"))
            SettingsToggle(title: "Swipe up to close", detail: "Two-finger swipe up over the open capsule (on its first page).", isOn: preferences.boolBinding("gestures-swipe-close"))
            SettingsToggle(title: "Invert direction", detail: "Reverses every swipe: up opens, down closes, and so on.", isOn: preferences.boolBinding("gestures-invert"))
        }
        SettingsCard("Media") {
            SettingsToggle(title: "Swipe sideways to skip tracks", detail: "While music is playing: left is the previous track, right the next one.", isOn: preferences.boolBinding("gestures-media-swipe"))
        }
        SettingsCard("Middle click") {
            SettingsChoice(title: "On the collapsed capsule", detail: "", selection: preferences.stringBinding("gestures-middle-click"),
                           options: [("none", "Nothing"), ("activity", "Next activity"), ("play-pause", "Play / pause")])
        }
    }
}

struct ActivitiesSettings: View {
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        SettingsCard("Live Activities") {
            ForEach([("activity-media", "Music", "Playing track"), ("activity-timer", "Timer", "Countdown"), ("activity-calendar", "Calendar", "Next meeting"),
                     ("activity-files", "Tray", "Added files"), ("activity-downloads", "Downloads", "Files arriving")], id: \.0) { item in
                SettingsToggle(title: item.1, detail: item.2, isOn: preferences.boolBinding(item.0))
            }
            SettingsNote("Choose what gets its own place in the capsule.")
        }
        SettingsCard("Collapsed capsule") {
            SettingsToggle(title: "Show activities when collapsed", detail: "A running timer, music or a meeting instead of the time.", isOn: $preferences.activitiesInCollapsed)
            SettingsSlider(title: "Music card", detail: "Seconds the card with the new track stays on screen.", value: preferences.doubleBinding("peek-media-seconds"), range: 0.5...10, step: 0.5, format: { String(format: "%.1f s", $0) })
            SettingsSlider(title: "Tray card", detail: "Seconds the \"Adding / Added files\" card stays on screen.", value: preferences.doubleBinding("peek-files-seconds"), range: 0.5...10, step: 0.5, format: { String(format: "%.1f s", $0) })
            SettingsSlider(title: "Meeting card", detail: "Seconds the card about an upcoming meeting stays on screen.", value: preferences.doubleBinding("peek-calendar-seconds"), range: 0.5...30, step: 0.5, format: { String(format: "%.1f s", $0) })
        }
        SettingsCard("Music") {
            SettingsSlider(title: "Album corner radius", detail: "", value: preferences.doubleBinding("album-corner-radius"), range: 0...24, step: 1, format: { "\(Int($0))" })
            SettingsChoice(title: "Effect type", detail: "The animation shown while music plays.", selection: preferences.stringBinding("media-effect"),
                           options: [("spectrum", "Audio spectrum"), ("waves", "Waves")])
            SettingsToggle(title: "Show lyrics", detail: "The line being sung, from lrclib.net (artist, title, album and length are sent there).", isOn: $preferences.showLyrics)
            SettingsToggle(title: "Colored effects", detail: "The effect takes the color of the album art; otherwise it is white.", isOn: preferences.boolBinding("colored-effects"))
        }
    }
}

// --- Tabs ---------------------------------------------------------------------------------------------

struct TraySettings: View {
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        SettingsCard("Tray") {
            SettingsToggle(title: "Keep files", detail: "Remember the tray after a restart or logout (references to your files, not copies).", isOn: $preferences.trayKeepFiles)
        }
    }
}

struct ClipboardSettings: View {
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        SettingsCard("Clipboard") {
            SettingsToggle(title: "A click pastes", detail: "Clicking an item puts it in the app you were using (⌘V; macOS asks once for Accessibility). Off: it is only copied.",
                           isOn: preferences.boolBinding("clipboard-click-pastes"))
        }
        SettingsCard("Links") {
            SettingsToggle(title: "Remove tracking from copied links", detail: "utm_*, fbclid, gclid and similar parameters are cut from a link when you copy it.", isOn: $preferences.clipboardCleanUrls)
        }
        SettingsCard("History") {
            SettingsToggle(title: "Keep history after a restart", detail: "Off: only pinned items and your notes are saved on disk, so copied passwords are not.", isOn: $preferences.clipboardKeepHistory)
            SettingsSlider(title: "History size", detail: "How many unpinned items are kept.",
                           value: Binding(get: { Double(preferences.clipboardMaxItems) }, set: { preferences.clipboardMaxItems = Int($0) }),
                           range: 10...200, step: 10, format: { "\(Int($0))" })
            SettingsNote("Items copied from password managers are skipped.")
        }
    }
}

struct LocalSendSettings: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var localSend: LocalSendController

    var body: some View {
        SettingsCard("Receiving") {
            SettingsToggle(title: "Receive files", detail: "Other computers and phones on this network can send you files (Muna and the LocalSend apps). You accept every sending.",
                           isOn: $preferences.localSendReceive)
            if let problem = localSend.receiveProblem { Text(problem).font(.system(size: 11)).foregroundColor(.orange) }
            SettingsRow("Save received files in", preferences.receiveFolder.path) {
                HStack {
                    if !preferences.localSendFolder.isEmpty { Button("Downloads") { preferences.localSendFolder = "" } }
                    Button("Choose…") { chooseReceiveFolder(preferences) }
                }
            }
        }
        SettingsCard("This Mac") {
            SettingsRow("Name others see", "The computer's name (System Settings → General → Sharing). Other Munas see this Mac marked “Muna”; groups find it again even after its address changed.") {
                Text(LocalSendController.alias).foregroundColor(.secondary)
            }
        }
    }
}

struct SnippetSettings: View {
    @EnvironmentObject var snippets: SnippetsModel

    var body: some View {
        SettingsCard("New snippet") {
            TextField("Trigger, for example: addr", text: $snippets.draftTrigger).textFieldStyle(.roundedBorder)
            TextEditor(text: $snippets.draftText)
                .font(.system(size: 13))
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                SettingsNote("{date}, {time} and {datetime} are filled in.")
                Spacer()
                Button("Add") { snippets.addDraft() }
            }
            if !snippets.error.isEmpty { Text(snippets.error).font(.system(size: 11)).foregroundColor(.orange) }
        }
        SettingsCard("Snippets") {
            if snippets.snippets.isEmpty { SettingsNote("None yet.") }
            ForEach(snippets.snippets) { snippet in
                HStack(alignment: .top) {
                    Text(";\(snippet.trigger)").font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text(snippet.text).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(2)
                    Spacer()
                    Button("Remove") { snippets.remove(snippet) }
                }
            }
        }
    }
}

struct AboutSettings: View {
    var body: some View {
        SettingsCard {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Muna").font(.system(size: 18, weight: .bold))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")").foregroundColor(.secondary)
                    Text("A Dynamic Island for your Mac: media, calendar, mirror, shortcuts and a file tray in one capsule at the top of the screen.")
                        .font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Project page") { openLink("https://github.com/bekov0004/Muna") }
                Button("Open the data folder") { NSWorkspace.shared.open(DataDirectory.url) }
            }
        }
    }
}

// --- helpers ----------------------------------------------------------------------------------------

private func openLink(_ link: String) {
    if let url = URL(string: link) { NSWorkspace.shared.open(url) }
}

private func chooseReceiveFolder(_ preferences: Preferences) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.directoryURL = preferences.receiveFolder
    if panel.runModal() == .OK, let url = panel.url { preferences.localSendFolder = url.path }
}

/// Muna starts again (after Reset all settings).
private func relaunch() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "sleep 1; open \"\(Bundle.main.bundlePath)\""]
    try? process.run()
    NSApp.terminate(nil)
}
