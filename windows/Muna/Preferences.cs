using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using Muna.Core;

namespace Muna;

/// <summary>One widget of the capsule's Muna page, as Muna on Linux has it (linux/src/utils/widgetInfo.js).</summary>
public sealed record WidgetInfo(string Id, string Title, string Subtitle, string Glyph, int Cells, int MinCells);

public static class WidgetCatalog
{
    public static readonly WidgetInfo[] All =
    {
        new("media", "Media Player", "The music or video playing in any app", Muna.Glyph.Music, 5, 3),
        new("calendar", "Calendar", "The days around today and the events", Muna.Glyph.Calendar, 4, 3),
        new("mirror", "Mirror", "A camera preview, only while open", Muna.Glyph.Camera, 3, 2),
        new("timer", "Timer", "A countdown that shows in the capsule", Muna.Glyph.Clock, 3, 3),
        new("todo", "To-do", "A simple local task list", Muna.Glyph.Checklist, 4, 3),
        new("notes", "Notes", "Quick notes you can copy later", Muna.Glyph.Note, 4, 3),
        new("shortcuts", "Shortcuts", "Launch your favourite apps", Muna.Glyph.Apps, 4, 2),
        new("phonecard", "Phone", "Your Android phone in the capsule: its screen, with control; a QR code connects it", Muna.Glyph.Phone, 3, 2),
        new("companion", "Companion", "A small friend: its eyes follow the pointer, it sways to the music, falls asleep", Muna.Glyph.Emoji, 2, 2),
    };

    public static WidgetInfo? Info(string id) => All.FirstOrDefault(w => w.Id == id);

    /// <summary>Linux's default Muna page, without the widgets of the top-bar window.</summary>
    public static readonly string[] DefaultEnabled = { "media", "calendar", "mirror", "timer" };
}

/// <summary>Muna's settings, with the names and defaults of Muna on Linux (its GSettings schema),
/// kept in %APPDATA%\Muna\settings.json. <see cref="Changed"/> tells which one changed.</summary>
public sealed class Preferences
{
    public static readonly Preferences Shared = new();
    readonly JsonStore _store = new("settings.json");
    readonly JsonObject _values;
    public event Action<string>? Changed;

    Preferences()
    {
        _values = _store.Load() ?? new JsonObject();
    }

    T Get<T>(string key, T fallback)
    {
        try
        {
            if (_values[key] is JsonNode node) return node.GetValue<T>();
        }
        catch { /* another type: the default */ }
        return fallback;
    }

    void Set(string key, JsonNode? value)
    {
        _values[key] = value;
        _store.Save(_values);
        Changed?.Invoke(key);
    }

    // --- every other setting of Linux, by its key, with Linux's defaults --------------------------

    public static readonly Dictionary<string, JsonNode?> LinuxDefaults = new()
    {
        ["collapsed-width-adjust"] = 0.0, ["butterfly-flap"] = true, ["butterfly-flap-every"] = 30.0,
        ["gestures-swipe-open"] = true, ["gestures-swipe-close"] = true, ["gestures-invert"] = false, ["gestures-media-swipe"] = true,
        ["gestures-middle-click"] = "none", ["fingerprint-agents"] = true, ["fingerprint-private"] = true,
        ["activity-media"] = true, ["activity-timer"] = true, ["activity-calendar"] = true, ["activity-files"] = true, ["activity-downloads"] = true,
        ["peek-media-seconds"] = 2.5, ["peek-files-seconds"] = 1.5, ["peek-calendar-seconds"] = 6.0,
        ["album-corner-radius"] = 8.0, ["media-effect"] = "spectrum", ["colored-effects"] = true,
        ["show-caps-lock"] = true, ["show-input-source"] = true, ["clipboard-click-pastes"] = false,
        ["monitor-interval"] = 2.0, ["graph-scale"] = true, ["cleaning-visible"] = false, ["awake-color"] = "#ff9500", ["reminders"] = "[]", ["color-scheme"] = "dark",
    };

    public JsonNode? Value(string key) => _values[key] ?? (LinuxDefaults.TryGetValue(key, out var d) ? d : null);
    public bool Bool(string key) { try { return Value(key)?.GetValue<bool>() ?? false; } catch { return false; } }
    public double Number(string key) { try { return Value(key)?.GetValue<double>() ?? 0; } catch { return 0; } }
    public string Text(string key) { try { return Value(key)?.GetValue<string>() ?? ""; } catch { return ""; } }

    /// A list setting ("menu-hidden", "system-blocks" …); fallback when it was never set.
    public List<string> Strings(string key, params string[] fallback) =>
        (_values[key] as JsonArray)?.Select(n => n?.GetValue<string>()).OfType<string>().ToList() ?? fallback.ToList();

    public void SetValue(string key, JsonNode? value)
    {
        if (value is null) { _values.Remove(key); _store.Save(_values); Changed?.Invoke(key); return; }
        Set(key, value);
    }

    public void SetStrings(string key, IEnumerable<string> values) => Set(key, new JsonArray(values.Select(v => (JsonNode?)v).ToArray()));

    /// A switch on one item of a list setting.
    public bool Has(string key, string item) => Strings(key).Contains(item);
    public void Toggle(string key, string item, bool inList)
    {
        var list = Strings(key).Where(x => x != item).ToList();
        if (inList) list.Add(item);
        SetStrings(key, list);
    }

    /// Settings → General → Reset all settings.
    public void ResetAll()
    {
        _values.Clear();
        _store.Save(_values);
        Changed?.Invoke("*");
    }

    // the capsule
    public bool OpenOnHover { get => Get("open-on-hover", true); set => Set("open-on-hover", value); }
    public bool AutoCollapse { get => Get("auto-collapse", true); set => Set("auto-collapse", value); }
    /// <summary>Seconds the pointer rests on the capsule before it opens / after it left before it closes.</summary>
    public double OpenDelay { get => Get("open-delay", 0.15); set => Set("open-delay", value); }
    public double CloseDelay { get => Get("close-delay", 0.3); set => Set("close-delay", value); }
    public bool CapsuleButterfly { get => Get("capsule-butterfly", true); set => Set("capsule-butterfly", value); }
    public bool ActivitiesInCollapsed { get => Get("activities-in-collapsed", true); set => Set("activities-in-collapsed", value); }
    /// <summary>Which monitors have a capsule: "all", "main".</summary>
    public string CapsuleScreens { get => Get("capsule-screens", "all"); set => Set("capsule-screens", value); }
    /// <summary>The capsule hides while an app fills the whole screen (a game, a video).</summary>
    public bool HideInFullscreen { get => Get("hide-in-fullscreen", true); set => Set("hide-in-fullscreen", value); }
    public double CornerRadius { get => Math.Clamp(Get("corner-radius", 32.0), 8, 44); set => Set("corner-radius", value); }
    public double BackgroundOpacity { get => Math.Clamp(Get("background-opacity", 0.96), 0.5, 1); set => Set("background-opacity", value); }
    /// <summary>Settings → Appearance: the widgets' size (cells of 44 × this), height, padding, spacing,
    /// dividers, width, shadow and colour, with Linux's keys.</summary>
    public double SizeScale { get => Math.Clamp(Get("size-scale", 1.0), 0.85, 1.25); set => Set("size-scale", value); }
    public double RowHeight { get => Math.Clamp(Get("row-height", 112.0), 90, 220); set => Set("row-height", value); }
    public double ContentPadding { get => Math.Clamp(Get("content-padding", 16.0), 6, 32); set => Set("content-padding", value); }
    public double WidgetSpacing { get => Math.Clamp(Get("widget-spacing", 16.0), 0, 40); set => Set("widget-spacing", value); }
    public bool ShowDividers { get => Get("show-dividers", true); set => Set("show-dividers", value); }
    /// <summary>"auto": as wide as the widgets need; "fixed": <see cref="FixedWidth"/> of the screen.</summary>
    public string WidthMode { get => Get("width-mode", "auto"); set => Set("width-mode", value); }
    public double FixedWidth { get => Math.Clamp(Get("fixed-width", 0.4), 0.25, 0.9); set => Set("fixed-width", value); }
    public double ShadowStrength { get => Math.Clamp(Get("shadow-strength", 0.6), 0, 1); set => Set("shadow-strength", value); }
    /// <summary>The capsule's colour ("#rrggbb"; black as on Linux).</summary>
    public string CapsuleColorHex { get => Get("capsule-color", "#000000"); set => Set("capsule-color", value); }
    public System.Windows.Media.Color CapsuleColor => ParseColor(CapsuleColorHex, System.Windows.Media.Colors.Black);
    public LayoutLook Look => new(SizeScale, WidgetSpacing, ContentPadding, RowHeight, ShowDividers, WidthMode == "fixed" ? FixedWidth : null);

    public static System.Windows.Media.Color ParseColor(string hex, System.Windows.Media.Color fallback)
    {
        try { return (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(hex); }
        catch { return fallback; }
    }

    /// <summary>Puts the appearance back as it was.</summary>
    public void ResetAppearance()
    {
        foreach (var key in new[] { "size-scale", "row-height", "content-padding", "widget-spacing", "show-dividers", "width-mode", "fixed-width",
                                    "shadow-strength", "capsule-color", "corner-radius", "background-opacity", "animation-speed" })
            _values.Remove(key);
        _store.Save(_values);
        Changed?.Invoke("appearance");
    }

    public double AnimationSpeed { get => Math.Clamp(Get("animation-speed", 1.0), 0.25, 4); set => Set("animation-speed", value); }
    /// <summary>The words of the song, from lrclib.net (artist, title, album and length are sent there).</summary>
    public bool ShowLyrics { get => Get("show-lyrics", false); set => Set("show-lyrics", value); }
    /// <summary>Ctrl+Alt+Space opens the radial menu.</summary>
    public bool RadialHotKey { get => Get("radial-hotkey", true); set => Set("radial-hotkey", value); }
    /// <summary>Ctrl+Alt+1 … 5 open the sections.</summary>
    public bool SectionHotKeys { get => Get("section-hotkeys", true); set => Set("section-hotkeys", value); }
    /// <summary>Alt+Space opens the Command Bar.</summary>
    public bool CommandHotKey { get => Get("command-hotkey", true); set => Set("command-hotkey", value); }
    /// <summary>The processor and the memory in the tooltip of Muna's tray icon.</summary>
    public bool MenuBarReadings { get => Get("menu-bar-readings", false); set => Set("menu-bar-readings", value); }
    /// <summary>Linux's top-bar readings: each one chosen gets a small icon with its value in the
    /// notification area (and a place in the Muna bar). Ids: cpu, cputemp, gpu, mem, battery, net, disk, diskio, power.</summary>
    public List<string> BarMetrics
    {
        get => (_values["bar-metrics"] as JsonArray)?.Select(n => n?.GetValue<string>()).OfType<string>().ToList() ?? new();
        set => Set("bar-metrics", new JsonArray(value.Select(v => (JsonNode?)v).ToArray()));
    }
    /// <summary>"C" or "F".</summary>
    public string TemperatureUnit { get => Get("temp-unit", "C"); set => Set("temp-unit", value); }

    /// <summary>The Muna bar: a bar of Muna's across the top of monitors ("off", "others": every monitor
    /// but the main one, "all").</summary>
    public string MunaBarScreens { get => Get("muna-bar-screens", "off"); set => Set("muna-bar-screens", value); }
    /// <summary>How the Muna bar hides: "never" (windows stay below it), "intellihide" (when a window
    /// touches it), "always" (until the pointer pushes against the top edge).</summary>
    public string MunaBarHide { get => Get("muna-bar-hide", "intellihide"); set => Set("muna-bar-hide", value); }
    public string PanelColorHex { get => Get("panel-color", "#000000"); set => Set("panel-color", value); }
    public double PanelOpacity { get => Math.Clamp(Get("panel-opacity", 0.5), 0, 1); set => Set("panel-opacity", value); }

    /// <summary>Each monitor switches its own desktops (Muna hides and shows the windows of the others).</summary>
    public bool DesktopsPerMonitor { get => Get("desktops-per-monitor", false); set => Set("desktops-per-monitor", value); }

    /// <summary>Other apps' notifications in the Alerts section (read from Windows' notification list).</summary>
    public bool AppNotifications { get => Get("app-notifications", true); set => Set("app-notifications", value); }
    /// <summary>Cards for a busy processor, heat, a full disk or memory and a low battery (Linux's system-alerts).</summary>
    public bool SystemAlerts { get => Get("system-alerts", true); set => Set("system-alerts", value); }

    /// <summary>Linux's alert thresholds: processor %, temperature °C, free disk %, battery %, free memory %.</summary>
    public int AlertCpu { get => Get("alert-cpu", 90); set => Set("alert-cpu", value); }
    public int AlertTemp { get => Get("alert-temp", 85); set => Set("alert-temp", value); }
    public int AlertDisk { get => Get("alert-disk", 5); set => Set("alert-disk", value); }
    public int AlertBattery { get => Get("alert-battery", 20); set => Set("alert-battery", value); }
    public int AlertMemory { get => Get("alert-memory", 8); set => Set("alert-memory", value); }
    public bool ReminderSound { get => Get("reminder-sound", true); set => Set("reminder-sound", value); }
    public bool AwakeOnStart { get => Get("awake-on-start", false); set => Set("awake-on-start", value); }
    public bool AgentsAlerts { get => Get("agents-alerts", true); set => Set("agents-alerts", value); }
    /// <summary>The phone's screen goes dark while it is used from the computer (Muna Phone).</summary>
    public bool PhoneDarkScreen { get => Get("phone-dark-screen", true); set => Set("phone-dark-screen", value); }
    /// <summary>Seconds a card stays in the closed capsule.</summary>
    public double CardSeconds { get => Math.Clamp(Get("card-seconds", 4.0), 1, 15); set => Set("card-seconds", value); }
    /// <summary>The actions around the radial menu, in order (Linux's ids).</summary>
    public List<string> RadialActions
    {
        get
        {
            var list = (_values["radial-actions"] as JsonArray)?.Select(n => n?.GetValue<string>()).OfType<string>().ToList();
            return list is { Count: > 0 } ? list : new List<string> { "play-pause", "next", "screenshot", "downloads", "color", "prev" };
        }
        set => Set("radial-actions", new JsonArray(value.Select(v => (JsonNode?)v).ToArray()));
    }

    // touchpad gestures (Linux's keys)
    /// <summary>Three- and four-finger swipes, pinches and holds (Windows' own must be set to "Nothing" first).</summary>
    public bool TouchpadGestures { get => Get("touchpad-gestures", false); set => Set("touchpad-gestures", value); }
    /// <summary>One finger along the touchpad's edges, double taps and holds at them.</summary>
    public bool EdgeGestures { get => Get("edge-gestures", true); set => Set("edge-gestures", value); }
    public double GestureSensitivity { get => Math.Clamp(Get("gesture-sensitivity", 100.0), 25, 400); set => Set("gesture-sensitivity", value); }

    public string GestureAction(string gesture) =>
        (_values["gesture-actions"] as JsonObject)?[gesture]?.GetValue<string>() ?? GestureCatalog.Defaults.GetValueOrDefault(gesture, "none");

    public void SetGestureAction(string gesture, string action)
    {
        var all = (_values["gesture-actions"] as JsonObject)?.DeepClone() as JsonObject ?? new JsonObject();
        all[gesture] = action;
        Set("gesture-actions", all);
    }

    public void ResetGestures()
    {
        _values.Remove("gesture-actions");
        foreach (var key in GestureCatalog.EdgeDefaults.Keys) _values.Remove(key);
        _store.Save(_values);
        Changed?.Invoke("gesture-actions");
    }

    public string EdgeAction(string key) => Get(key, GestureCatalog.EdgeDefaults.GetValueOrDefault(key, "none"));
    public void SetEdgeAction(string key, string action) => Set(key, action);

    // the Muna page
    public List<string> EnabledWidgets
    {
        get
        {
            var known = WidgetCatalog.All.Select(w => w.Id).ToHashSet();
            var list = (_values["enabled-widgets"] as JsonArray)?.Select(n => n?.GetValue<string>()).OfType<string>().ToList();
            return (list ?? WidgetCatalog.DefaultEnabled.ToList()).Where(known.Contains).ToList();
        }
        set => Set("enabled-widgets", new JsonArray(value.Select(v => (JsonNode?)v).ToArray()));
    }

    public Dictionary<string, int> WidgetCells
    {
        get => (_values["widget-cells"] as JsonObject)?.ToDictionary(p => p.Key, p => p.Value?.GetValue<int>() ?? 0) ?? new();
        set
        {
            var o = new JsonObject();
            foreach (var (k, v) in value) o[k] = v;
            Set("widget-cells", o);
        }
    }

    public List<string> ShortcutApps
    {
        get => (_values["shortcut-apps"] as JsonArray)?.Select(n => n?.GetValue<string>()).OfType<string>().ToList() ?? new();
        set => Set("shortcut-apps", new JsonArray(value.Select(v => (JsonNode?)v).ToArray()));
    }

    // LocalSend, clipboard, tray
    public bool LocalSendReceive { get => Get("localsend-receive", false); set => Set("localsend-receive", value); }
    public string LocalSendAlias { get => Get("localsend-alias", ""); set => Set("localsend-alias", value); }
    /// <summary>Where received files go ("": the Downloads folder).</summary>
    public string LocalSendFolder { get => Get("localsend-folder", ""); set => Set("localsend-folder", value); }
    public bool ClipboardKeepHistory { get => Get("clipboard-keep-history", true); set => Set("clipboard-keep-history", value); }
    public int ClipboardMaxItems { get => Get("clipboard-max-items", 50); set => Set("clipboard-max-items", value); }
    public bool ClipboardCleanUrls { get => Get("clipboard-clean-urls", false); set => Set("clipboard-clean-urls", value); }
    public bool TrayKeepFiles { get => Get("tray-keep-files", true); set => Set("tray-keep-files", value); }

    /// <summary>An iCalendar (.ics) link whose events the Calendar widget shows (Outlook, Google: "secret address").</summary>
    public string CalendarUrl { get => Get("calendar-url", ""); set => Set("calendar-url", value); }
    /// <summary>Every calendar link (the first one is <see cref="CalendarUrl"/>, kept for older settings).</summary>
    public List<string> CalendarUrls
    {
        get
        {
            var more = (_values["calendar-urls"] as JsonArray)?.Select(n => n?.GetValue<string>()).OfType<string>() ?? Enumerable.Empty<string>();
            return new[] { CalendarUrl }.Concat(more).Select(u => u.Trim()).Where(u => u.Length > 0).Distinct().ToList();
        }
        set
        {
            var list = value.Select(u => u.Trim()).Where(u => u.Length > 0).Distinct().ToList();
            _values["calendar-url"] = list.FirstOrDefault() ?? "";
            Set("calendar-urls", new JsonArray(list.Skip(1).Select(v => (JsonNode?)v).ToArray()));
        }
    }
    /// <summary>Outlook's own calendar (when Outlook for Windows is installed).</summary>
    public bool CalendarOutlook { get => Get("calendar-outlook", true); set => Set("calendar-outlook", value); }

    public int Cells(string id)
    {
        var info = WidgetCatalog.Info(id);
        return Math.Max(WidgetCells.TryGetValue(id, out var c) ? c : info?.Cells ?? 4, info?.MinCells ?? 1);
    }

    public static string Downloads => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");

    /// <summary>The folder received files go to.</summary>
    public string ReceiveFolder
    {
        get
        {
            if (LocalSendFolder.Length > 0)
            {
                try
                {
                    Directory.CreateDirectory(LocalSendFolder);
                    return LocalSendFolder;
                }
                catch { /* not writable: the Downloads folder */ }
            }
            return Downloads;
        }
    }
}
