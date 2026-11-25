import AppKit
import MunaCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// The pages of the settings window (a list on the left, as on Linux).
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, widgets, localSend, clipboard, snippets, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .widgets: return "Muna page"
        case .localSend: return "LocalSend"
        case .clipboard: return "Clipboard and Tray"
        case .snippets: return "Snippets"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .widgets: return "square.grid.3x1.below.line.grid.1x2"
        case .localSend: return "wifi"
        case .clipboard: return "doc.on.clipboard"
        case .snippets: return "text.insert"
        case .about: return "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "How the capsule opens and closes, and what it shows when closed."
        case .widgets: return "The widgets of the Muna section: which, in what order, how wide."
        case .localSend: return "Sending files to other computers and phones, and receiving them."
        case .clipboard: return "What is kept of what you copy, and of the Tray."
        case .snippets: return "Texts you use often: type ;trigger in the Command Bar (⌥Space), Enter copies the text."
        case .about: return "Muna for macOS."
        }
    }
}

/// What the settings window remembers (no @State: see PanelState).
final class SettingsState: ObservableObject {
    @Published var page = SettingsPage.general
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
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
    private let state = SettingsState()
    private let app: AppState

    init(app: AppState) {
        self.app = app
    }

    func show(page: SettingsPage? = nil) {
        if let page { state.page = page }
        if window == nil {
            let root = SettingsView()
                .environmentObject(state)
                .environmentObject(Preferences.shared)
                .environmentObject(app.localSend)
                .environmentObject(app.snippets)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Muna"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.setContentSize(NSSize(width: 780, height: 560))
            window.minSize = NSSize(width: 640, height: 420)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        state.openAtLogin = SMAppService.mainApp.status == .enabled
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: SettingsState

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    ButterflyImage(height: 18)
                    Text("Muna").font(.system(size: 15, weight: .bold))
                }
                .padding(.horizontal, 10)
                .padding(.top, 34)
                .padding(.bottom, 14)
                ForEach(SettingsPage.allCases) { page in
                    Button { state.page = page } label: {
                        HStack(spacing: 10) {
                            Image(systemName: page.symbol).frame(width: 18)
                            Text(page.title)
                            Spacer()
                        }
                        .font(.system(size: 13, weight: state.page == page ? .semibold : .regular))
                        .foregroundColor(state.page == page ? .white : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(state.page == page ? Color.accentColor : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 220)
            .background(Color.primary.opacity(0.04))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.page.title).font(.system(size: 22, weight: .bold))
                        Text(state.page.subtitle).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    switch state.page {
                    case .general: GeneralSettings()
                    case .widgets: WidgetSettings()
                    case .localSend: LocalSendSettings()
                    case .clipboard: ClipboardSettings()
                    case .snippets: SnippetSettings()
                    case .about: AboutSettings()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 40)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

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
                Text(title).font(.system(size: 13, weight: .semibold))
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

/// A switch with a title and an explanation under it.
struct SettingsToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var state: SettingsState

    var body: some View {
        SettingsCard("The capsule") {
            SettingsToggle(title: "Open on hover", detail: "Off: the capsule opens on a click only.", isOn: $preferences.openOnHover)
            SettingsToggle(title: "Collapse when the pointer leaves", detail: "Off: it stays open until you click somewhere else.",
                           isOn: $preferences.autoCollapse)
            VStack(alignment: .leading, spacing: 4) {
                Text("Open after: \(String(format: "%.2f", preferences.openDelay)) s").font(.system(size: 13))
                Slider(value: $preferences.openDelay, in: 0...1, step: 0.05)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Close after: \(String(format: "%.2f", preferences.closeDelay)) s").font(.system(size: 13))
                Slider(value: $preferences.closeDelay, in: 0...2, step: 0.05)
            }
        }
        SettingsCard("Appearance") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Corner radius: \(Int(preferences.cornerRadius))").font(.system(size: 13))
                Slider(value: $preferences.cornerRadius, in: 8...44, step: 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Opacity: \(Int(preferences.backgroundOpacity * 100))%").font(.system(size: 13))
                Slider(value: $preferences.backgroundOpacity, in: 0.5...1, step: 0.01)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Animation speed: \(String(format: "%.2f", preferences.animationSpeed))×").font(.system(size: 13))
                Slider(value: $preferences.animationSpeed, in: 0.25...4, step: 0.25)
            }
        }
        SettingsCard("Screens") {
            Picker("A capsule on", selection: $preferences.capsuleScreens) {
                Text("Every screen").tag("all")
                Text("The main screen (with the menu bar)").tag("main")
                Text("The built-in screen (with the notch)").tag("notch")
            }
            .pickerStyle(.radioGroup)
            .font(.system(size: 13))
        }
        SettingsCard("Closed") {
            SettingsToggle(title: "Butterfly in the capsule",
                           detail: "On a screen without a notch: the butterfly between the date and the time (off: a small camera circle).",
                           isOn: $preferences.capsuleButterfly)
            SettingsToggle(title: "Activities in the closed capsule",
                           detail: "The music, the timer and sendings take the sides of the closed capsule while they run.",
                           isOn: $preferences.activitiesInCollapsed)
        }
        SettingsCard("Menu bar") {
            SettingsToggle(title: "Readings next to Muna's item",
                           detail: "The processor and the memory, written in the menu bar (Muna's item opens the quick panel; a right click, its menu).",
                           isOn: $preferences.menuBarReadings)
        }
        SettingsCard("Shortcuts") {
            SettingsToggle(title: "Command Bar: ⌥Space",
                           detail: "Option and Space open the Command Bar from any app: start apps, calculate, convert units, find what you copied, search the web.",
                           isOn: $preferences.commandHotKey)
            SettingsToggle(title: "Sections: ⌃⌥1 to ⌃⌥5",
                           detail: "Control, Option and a number open Muna, Tray, LocalSend, Clipboard and Alerts.",
                           isOn: $preferences.sectionHotKeys)
        }
        SettingsCard("Start") {
            SettingsToggle(title: "Open at login", detail: "Muna starts when you log in.",
                           isOn: Binding(get: { state.openAtLogin }, set: { state.setOpenAtLogin($0) }))
            if let error = state.loginError {
                Text(error).font(.system(size: 11)).foregroundColor(.orange)
            }
        }
    }
}

struct WidgetSettings: View {
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        SettingsCard("Widgets, in their order") {
            ForEach(WidgetCatalog.all) { info in
                let enabled = preferences.enabledWidgets.contains(info.id)
                HStack(spacing: 12) {
                    Image(systemName: info.symbol).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.title).font(.system(size: 13))
                        Text(info.subtitle).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if enabled {
                        Stepper("\(preferences.cells(info.id)) wide", value: Binding(
                            get: { preferences.cells(info.id) },
                            set: { preferences.widgetCells[info.id] = max(info.minCells, min($0, 8)) }
                        ), in: info.minCells...8)
                        .font(.system(size: 11))
                        .fixedSize()
                        Button { move(info.id, -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                        Button { move(info.id, 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                    }
                    Toggle("", isOn: Binding(get: { enabled }, set: { on in
                        if on {
                            if !preferences.enabledWidgets.contains(info.id) { preferences.enabledWidgets.append(info.id) }
                        } else {
                            preferences.enabledWidgets.removeAll { $0 == info.id }
                        }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
        }
        Text("The panel is as wide as the widgets need (a widget is cells of 44 points); what does not fit goes on a second page.")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        SettingsCard("Shortcuts: the apps") {
            if preferences.shortcutApps.isEmpty {
                Text("No apps yet.").font(.system(size: 12)).foregroundColor(.secondary)
            }
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
            for url in panel.urls where !preferences.shortcutApps.contains(url.path) {
                preferences.shortcutApps.append(url.path)
            }
        }
    }
}

struct LocalSendSettings: View {
    @EnvironmentObject var preferences: Preferences
    @EnvironmentObject var localSend: LocalSendController

    var body: some View {
        SettingsCard("Receiving") {
            SettingsToggle(title: "Receive files",
                           detail: "Other computers and phones on this network can send you files (Muna and the LocalSend apps). You accept every sending.",
                           isOn: $preferences.localSendReceive)
            if let problem = localSend.receiveProblem {
                Text(problem).font(.system(size: 11)).foregroundColor(.orange)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save received files in").font(.system(size: 13))
                    Text(preferences.receiveFolder.path).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                if !preferences.localSendFolder.isEmpty {
                    Button("Downloads") { preferences.localSendFolder = "" }
                }
                Button("Choose…") { chooseFolder() }
            }
        }
        SettingsCard("This Mac") {
            HStack {
                Text("Name others see").font(.system(size: 13))
                Spacer()
                Text(LocalSendController.alias).foregroundColor(.secondary)
            }
            Text("The name is the computer's name (System Settings → General → Sharing). Other Munas see this Mac marked “Muna”; groups find it again even after its address changed.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.receiveFolder
        if panel.runModal() == .OK, let url = panel.url {
            preferences.localSendFolder = url.path
        }
    }
}

struct ClipboardSettings: View {
    @EnvironmentObject var preferences: Preferences

    var body: some View {
        SettingsCard("Clipboard") {
            SettingsToggle(title: "Keep the history",
                           detail: "What you copied stays after Muna restarts. Pinned items always stay. Copies that password managers mark as secret are never kept.",
                           isOn: $preferences.clipboardKeepHistory)
            Stepper("Keep the last \(preferences.clipboardMaxItems) items", value: $preferences.clipboardMaxItems, in: 10...200, step: 10)
                .font(.system(size: 13))
            SettingsToggle(title: "Clean copied links",
                           detail: "Tracking parameters (utm_…, fbclid, gclid …) are taken out of a link as you copy it.",
                           isOn: $preferences.clipboardCleanUrls)
        }
        SettingsCard("Tray") {
            SettingsToggle(title: "Keep the files after a restart",
                           detail: "The Tray holds references to your files, not copies.",
                           isOn: $preferences.trayKeepFiles)
        }
    }
}

struct SnippetSettings: View {
    @EnvironmentObject var snippets: SnippetsModel

    var body: some View {
        SettingsCard("New snippet") {
            TextField("Trigger, for example: addr", text: $snippets.draftTrigger)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $snippets.draftText)
                .font(.system(size: 13))
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Text("{date}, {time} and {datetime} are filled in.").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Button("Add") { snippets.addDraft() }
            }
            if !snippets.error.isEmpty {
                Text(snippets.error).font(.system(size: 11)).foregroundColor(.orange)
            }
        }
        SettingsCard("Snippets") {
            if snippets.snippets.isEmpty {
                Text("None yet.").font(.system(size: 12)).foregroundColor(.secondary)
            }
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
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                        .foregroundColor(.secondary)
                    Text("A Dynamic Island for your Mac, from the same project as Muna for GNOME.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            HStack {
                Button("Open the data folder") { NSWorkspace.shared.open(DataDirectory.url) }
                Button("Muna on GitHub") {
                    if let url = URL(string: "https://github.com/bekov0004/Muna") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}
