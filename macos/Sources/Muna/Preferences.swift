import AppKit
import Combine

/// One widget of the capsule's Muna page, as Muna on Linux has it (linux/src/utils/widgetInfo.js).
struct WidgetInfo: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let cells: Int
    let minCells: Int
}

enum WidgetCatalog {
    static let all: [WidgetInfo] = [
        WidgetInfo(id: "media", title: "Media Player", subtitle: "The music playing in Music or Spotify", symbol: "music.note", cells: 5, minCells: 3),
        WidgetInfo(id: "calendar", title: "Calendar", subtitle: "The days around today and the events", symbol: "calendar", cells: 4, minCells: 3),
        WidgetInfo(id: "mirror", title: "Mirror", subtitle: "A camera preview, only while open", symbol: "camera", cells: 3, minCells: 2),
        WidgetInfo(id: "timer", title: "Timer", subtitle: "A countdown that shows in the capsule", symbol: "timer", cells: 3, minCells: 3),
        WidgetInfo(id: "todo", title: "To-do", subtitle: "A simple local task list", symbol: "checklist", cells: 4, minCells: 3),
        WidgetInfo(id: "notes", title: "Notes", subtitle: "Quick notes you can copy later", symbol: "note.text", cells: 4, minCells: 3),
        WidgetInfo(id: "shortcuts", title: "Shortcuts", subtitle: "Launch your favourite apps", symbol: "square.grid.2x2", cells: 4, minCells: 2),
        WidgetInfo(id: "companion", title: "Companion", subtitle: "A small friend: its eyes follow the pointer, it sways to the music, falls asleep", symbol: "face.smiling", cells: 2, minCells: 2),
    ]

    static func info(_ id: String) -> WidgetInfo? { all.first { $0.id == id } }

    /// Linux's default Muna page, without the widgets of the top-bar window.
    static let defaultEnabled = ["media", "calendar", "mirror", "timer"]
}

/// Muna's settings, with the names and defaults of Muna on Linux (its GSettings schema), kept in
/// the user defaults. Changing one is seen at once by the capsule and the settings window.
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    // the capsule
    @Published var openOnHover: Bool { didSet { defaults.set(openOnHover, forKey: "open-on-hover") } }
    @Published var autoCollapse: Bool { didSet { defaults.set(autoCollapse, forKey: "auto-collapse") } }
    /// Seconds the pointer rests on the capsule before it opens / after it left before it closes.
    @Published var openDelay: Double { didSet { defaults.set(openDelay, forKey: "open-delay") } }
    @Published var closeDelay: Double { didSet { defaults.set(closeDelay, forKey: "close-delay") } }
    /// The butterfly in the middle of the closed capsule (on a screen without a notch).
    @Published var capsuleButterfly: Bool { didSet { defaults.set(capsuleButterfly, forKey: "capsule-butterfly") } }
    /// Music, a timer ... take the sides of the closed capsule while they run.
    @Published var activitiesInCollapsed: Bool { didSet { defaults.set(activitiesInCollapsed, forKey: "activities-in-collapsed") } }

    /// Which screens have a capsule: "all", "main" (the one with the menu bar), "notch" (the built-in one).
    @Published var capsuleScreens: String { didSet { defaults.set(capsuleScreens, forKey: "capsule-screens") } }
    /// The look of the capsule, as on Linux: the open capsule's corner radius, how opaque it is, how
    /// fast it moves.
    @Published var cornerRadius: Double { didSet { defaults.set(cornerRadius, forKey: "corner-radius") } }
    @Published var backgroundOpacity: Double { didSet { defaults.set(backgroundOpacity, forKey: "background-opacity") } }
    @Published var animationSpeed: Double { didSet { defaults.set(animationSpeed, forKey: "animation-speed") } }
    /// The words of the song, from lrclib.net (artist, title, album and length are sent there).
    @Published var showLyrics: Bool { didSet { defaults.set(showLyrics, forKey: "show-lyrics") } }
    /// ⌃⌥Space opens the radial menu.
    @Published var radialHotKey: Bool { didSet { defaults.set(radialHotKey, forKey: "radial-hotkey") } }
    /// ⌃⌥1 … ⌃⌥5 open the sections.
    @Published var sectionHotKeys: Bool { didSet { defaults.set(sectionHotKeys, forKey: "section-hotkeys") } }
    /// ⌥Space opens the Command Bar.
    @Published var commandHotKey: Bool { didSet { defaults.set(commandHotKey, forKey: "command-hotkey") } }

    /// The processor and the memory written next to Muna's item in the menu bar.
    @Published var menuBarReadings: Bool { didSet { defaults.set(menuBarReadings, forKey: "menu-bar-readings") } }

    // the Muna page
    @Published var enabledWidgets: [String] { didSet { defaults.set(enabledWidgets, forKey: "enabled-widgets") } }
    @Published var widgetCells: [String: Int] { didSet { defaults.set(widgetCells, forKey: "widget-cells") } }
    @Published var shortcutApps: [String] { didSet { defaults.set(shortcutApps, forKey: "shortcut-apps") } }

    // LocalSend, clipboard, tray
    @Published var localSendReceive: Bool { didSet { defaults.set(localSendReceive, forKey: "localsend-receive") } }
    /// Where received files go ("": the Downloads folder).
    @Published var localSendFolder: String { didSet { defaults.set(localSendFolder, forKey: "localsend-folder") } }
    @Published var clipboardKeepHistory: Bool { didSet { defaults.set(clipboardKeepHistory, forKey: "clipboard-keep-history") } }
    @Published var clipboardMaxItems: Int { didSet { defaults.set(clipboardMaxItems, forKey: "clipboard-max-items") } }
    /// Tracking parameters (utm_…, fbclid …) are taken out of copied links.
    @Published var clipboardCleanUrls: Bool { didSet { defaults.set(clipboardCleanUrls, forKey: "clipboard-clean-urls") } }
    @Published var trayKeepFiles: Bool { didSet { defaults.set(trayKeepFiles, forKey: "tray-keep-files") } }

    private init() {
        // (a local name: the stored property may not be used before every property has its value)
        let defaults = UserDefaults.standard
        func bool(_ key: String, _ value: Bool) -> Bool { defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key) }
        func double(_ key: String, _ value: Double) -> Double { defaults.object(forKey: key) == nil ? value : defaults.double(forKey: key) }
        func int(_ key: String, _ value: Int) -> Int { defaults.object(forKey: key) == nil ? value : defaults.integer(forKey: key) }
        openOnHover = bool("open-on-hover", true)
        autoCollapse = bool("auto-collapse", true)
        openDelay = double("open-delay", 0.15)
        closeDelay = double("close-delay", 0.3)
        capsuleButterfly = bool("capsule-butterfly", true)
        activitiesInCollapsed = bool("activities-in-collapsed", true)
        commandHotKey = bool("command-hotkey", true)
        cornerRadius = min(max(double("corner-radius", 32), 8), 44)
        backgroundOpacity = min(max(double("background-opacity", 0.96), 0.5), 1)
        animationSpeed = min(max(double("animation-speed", 1), 0.25), 4)
        sectionHotKeys = bool("section-hotkeys", true)
        showLyrics = bool("show-lyrics", false)
        radialHotKey = bool("radial-hotkey", true)
        capsuleScreens = defaults.string(forKey: "capsule-screens") ?? "all"
        menuBarReadings = bool("menu-bar-readings", false)
        let known = Set(WidgetCatalog.all.map(\.id))
        enabledWidgets = (defaults.stringArray(forKey: "enabled-widgets") ?? WidgetCatalog.defaultEnabled).filter { known.contains($0) }
        widgetCells = (defaults.dictionary(forKey: "widget-cells") as? [String: Int]) ?? [:]
        shortcutApps = defaults.stringArray(forKey: "shortcut-apps") ?? []
        localSendReceive = bool("localsend-receive", false)
        localSendFolder = defaults.string(forKey: "localsend-folder") ?? ""
        clipboardKeepHistory = bool("clipboard-keep-history", true)
        clipboardMaxItems = int("clipboard-max-items", 50)
        clipboardCleanUrls = bool("clipboard-clean-urls", false)
        // an earlier build of the Mac version called it "tray-keep"
        trayKeepFiles = defaults.object(forKey: "tray-keep-files") == nil ? bool("tray-keep", true) : defaults.bool(forKey: "tray-keep-files")
    }

    /// How many cells wide a widget is (its own choice, else Linux's default).
    func cells(_ id: String) -> Int {
        let info = WidgetCatalog.info(id)
        return max(widgetCells[id] ?? info?.cells ?? 4, info?.minCells ?? 1)
    }

    /// The folder received files go to.
    var receiveFolder: URL {
        if !localSendFolder.isEmpty {
            let url = URL(fileURLWithPath: localSendFolder, isDirectory: true)
            if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil {
                return url
            }
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}
