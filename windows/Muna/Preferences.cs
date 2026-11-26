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

    /// <summary>Each monitor switches its own desktops (Muna hides and shows the windows of the others).</summary>
    public bool DesktopsPerMonitor { get => Get("desktops-per-monitor", false); set => Set("desktops-per-monitor", value); }

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
