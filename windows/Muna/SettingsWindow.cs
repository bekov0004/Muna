using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Muna.Core;

namespace Muna;

/// <summary>Muna's settings, in the pages of the Mac and Linux settings: General, Muna page, LocalSend,
/// Clipboard and Tray, Snippets, About.</summary>
public sealed class SettingsWindow : DarkWindow
{
    static readonly (string Id, string Title, string Glyph, string About)[] Pages =
    {
        ("general", "General", Glyph.Settings, "How the capsule opens and closes, and what it shows when closed."),
        ("appearance", "Appearance", Glyph.Brightness, "The capsule's size, shape, colour and shadow."),
        ("widgets", "Muna page", Glyph.Apps, "The widgets of the Muna section: which, in what order, how wide."),
        ("calendar", "Calendar", Glyph.Calendar, "The calendar the Calendar widget shows."),
        ("localsend", "LocalSend", Glyph.Wifi, "Sending files to other computers and phones, and receiving them."),
        ("clipboard", "Clipboard and Tray", Glyph.Clipboard, "What is kept of what you copy, and of the Tray."),
        ("snippets", "Snippets", Glyph.Edit, "Texts you use often: type ;trigger in the Command Bar (Alt+Space), Enter copies the text."),
        ("about", "About", Glyph.Info, "Muna for Windows."),
    };

    readonly AppState _app;
    readonly Preferences _p = Preferences.Shared;
    string _page = "general";
    readonly TextBox _calendarUrl = Input();
    readonly TextBox _alias = Input();
    readonly TextBox _trigger = Input();
    readonly TextBox _snippet = Input(multiline: true);
    string _snippetError = "";

    public SettingsWindow(AppState app)
    {
        _app = app;
        Title = "Muna Settings";
        Width = 860;
        Height = 640;
        MinWidth = 680;
        MinHeight = 460;
        _calendarUrl.Text = _p.CalendarUrl;
        _alias.Text = _p.LocalSendAlias;
        _p.Changed += _ => Dispatcher.BeginInvoke(() => { if (IsVisible) Render(); });
        Render();
    }

    public string Page
    {
        get => _page;
        set { _page = Pages.Any(p => p.Id == value) ? value : "general"; Render(); }
    }

    protected override void OnShown() => Render();

    void Render()
    {
        var side = Ui.Column(2, Ui.Row(10, Ui.Butterfly(20), Ui.Bold("Muna", 15, C.WinText)).Margin(8, 0, 0, 14));
        foreach (var (id, title, glyph, _) in Pages)
        {
            var on = id == _page;
            var page = id;
            side.Children.Add(Ui.Box(Ui.Row(10, Ui.Icon(glyph, 13, on ? Brushes.White : C.WinSecondary), Ui.Text(title, 13, color: on ? Brushes.White : C.WinText)),
                                     on ? C.WinAccent : C.Clear, 8, 10, 7).OnClick(() => { _page = page; Render(); }, on ? null : C.White(0.06)));
        }
        var info = Pages.First(p => p.Id == _page);
        var content = Ui.Column(18, Ui.Column(4, Ui.Bold(info.Title, 22, C.WinText), Ui.Text(info.About, 12, color: C.WinSecondary, wrap: true)));
        foreach (var block in _page switch
        {
            "general" => General(),
            "appearance" => Appearance(),
            "widgets" => Widgets(),
            "calendar" => Calendar(),
            "localsend" => LocalSendPage(),
            "clipboard" => ClipboardPage(),
            "snippets" => Snippets(),
            _ => About(),
        }) content.Children.Add(block);
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.Children.Add(new Border { Child = side, Background = C.WinSurface, Padding = new Thickness(12, 20, 12, 12) });
        var scroller = Ui.Scroll(content.Margin(28, 24, 28, 28));
        scroller.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        Grid.SetColumn(scroller, 1);
        grid.Children.Add(scroller);
        Content = grid;
    }

    static UIElement Switch(string title, string? detail, bool on, Action<bool> set) => Setting(title, detail, Toggle(on, set));

    UIElement SliderRow(string title, string value, double min, double max, double current, Action<double> set, double step = 0)
    {
        var slider = Slider(min, max, current, v => { }, step);
        slider.PreviewMouseLeftButtonUp += (_, _) => set(slider.Value);
        slider.LostKeyboardFocus += (_, _) => set(slider.Value);
        return Setting(title, value, slider);
    }

    IEnumerable<UIElement> General()
    {
        yield return Card("The capsule",
            Switch("Open on hover", "Off: the capsule opens on a click only.", _p.OpenOnHover, v => _p.OpenOnHover = v),
            Switch("Collapse when the pointer leaves", "Off: it stays open until you click somewhere else.", _p.AutoCollapse, v => _p.AutoCollapse = v),
            SliderRow("Open after", $"{_p.OpenDelay:0.00} s", 0, 1, _p.OpenDelay, v => _p.OpenDelay = Math.Round(v, 2)),
            SliderRow("Close after", $"{_p.CloseDelay:0.00} s", 0, 2, _p.CloseDelay, v => _p.CloseDelay = Math.Round(v, 2)),
            Switch("Butterfly in the capsule", "Off: a small dark circle, like a camera.", _p.CapsuleButterfly, v => _p.CapsuleButterfly = v),
            Switch("Activities in the closed capsule", "Music, the timer and sendings take the sides of the closed capsule.", _p.ActivitiesInCollapsed, v => _p.ActivitiesInCollapsed = v),
            Switch("Step aside for full-screen apps", "Games, videos and presentations hide the capsule.", _p.HideInFullscreen, v => _p.HideInFullscreen = v),
            Setting("Screens", "Which monitors have a capsule.", Choice(new[] { "Every screen", "The main screen" }, _p.CapsuleScreens == "main" ? 1 : 0, i => _p.CapsuleScreens = i == 1 ? "main" : "all")));
        yield return Card("Media",
            Switch("Show the lyrics", "The words of the song from lrclib.net (artist, title, album and length are sent there).", _p.ShowLyrics, v => _p.ShowLyrics = v));
        yield return Card("Keys",
            Switch("Command Bar: Alt+Space", null, _p.CommandHotKey, v => _p.CommandHotKey = v),
            Switch("Radial menu: Ctrl+Alt+Space", null, _p.RadialHotKey, v => _p.RadialHotKey = v),
            Switch("Sections: Ctrl+Alt+1 to Ctrl+Alt+5", "Muna, Tray, LocalSend, Clipboard, Alerts.", _p.SectionHotKeys, v => _p.SectionHotKeys = v));
        yield return Card("System",
            Switch("Readings on Muna's icon", "The processor and the memory in the tray icon's tooltip.", _p.MenuBarReadings, v => _p.MenuBarReadings = v),
            Switch("Open at login", "Muna starts when you sign in.", AutoStart.Enabled, v => { try { AutoStart.Enabled = v; } catch { } Render(); }));
    }

    static readonly (string Name, string Hex)[] Colors =
    {
        ("Black", "#000000"), ("Graphite", "#1c1c1e"), ("Night blue", "#0b1a33"), ("Plum", "#24112e"), ("Forest", "#0d2318"), ("Wine", "#2a0d14"),
    };

    readonly TextBox _colorHex = Input();

    IEnumerable<UIElement> Appearance()
    {
        yield return Card("Shape",
            SliderRow("Corner radius", $"{(int)_p.CornerRadius} px", 8, 44, _p.CornerRadius, v => _p.CornerRadius = Math.Round(v), 1),
            SliderRow("Transparency", $"{_p.BackgroundOpacity:0.00} (1.00 is fully opaque)", 0.5, 1, _p.BackgroundOpacity, v => _p.BackgroundOpacity = Math.Round(v, 2), 0.02),
            SliderRow("Shadow", _p.ShadowStrength <= 0.01 ? "Off" : $"{_p.ShadowStrength:0.0}", 0, 1, _p.ShadowStrength, v => _p.ShadowStrength = Math.Round(v, 1), 0.1),
            SliderRow("Animation speed", $"{_p.AnimationSpeed:0.00}×", 0.25, 4, _p.AnimationSpeed, v => _p.AnimationSpeed = Math.Round(v, 2)));
        var swatches = Ui.Row(8);
        foreach (var (name, hex) in Colors)
        {
            var h = hex;
            var on = string.Equals(_p.CapsuleColorHex, hex, StringComparison.OrdinalIgnoreCase);
            var dot = new Border
            {
                Width = 26, Height = 26, CornerRadius = new CornerRadius(13), Background = new SolidColorBrush(Preferences.ParseColor(hex, System.Windows.Media.Colors.Black)),
                BorderBrush = on ? C.WinAccent : C.White(0.25), BorderThickness = new Thickness(on ? 3 : 1), ToolTip = name,
            };
            swatches.Children.Add(dot.OnClick(() => _p.CapsuleColorHex = h));
        }
        _colorHex.Width = 90;
        if (!_colorHex.IsKeyboardFocused) _colorHex.Text = _p.CapsuleColorHex;
        swatches.Children.Add(Ui.Detach(_colorHex));
        swatches.Children.Add(Button("Use", () =>
        {
            var text = _colorHex.Text.Trim();
            if (!text.StartsWith('#')) text = "#" + text;
            if (System.Text.RegularExpressions.Regex.IsMatch(text, "^#[0-9a-fA-F]{6}$")) _p.CapsuleColorHex = text.ToLowerInvariant();
        }));
        yield return Card("Colour", Setting("Capsule colour", "The closed capsule and the open panel.", swatches));
        yield return Card("Widgets",
            SliderRow("Widget size", $"{_p.SizeScale:0.00}× (scales the width of every cell)", 0.85, 1.25, _p.SizeScale, v => _p.SizeScale = Math.Round(v, 2), 0.05),
            SliderRow("Height", $"{(int)_p.RowHeight} px of widgets", 90, 220, _p.RowHeight, v => _p.RowHeight = Math.Round(v), 2),
            SliderRow("Padding", $"{(int)_p.ContentPadding} px around the widgets", 6, 32, _p.ContentPadding, v => _p.ContentPadding = Math.Round(v), 1),
            SliderRow("Spacing", $"{(int)_p.WidgetSpacing} px between widgets", 0, 40, _p.WidgetSpacing, v => _p.WidgetSpacing = Math.Round(v), 1),
            Switch("Dividers", "Thin lines between widgets.", _p.ShowDividers, v => _p.ShowDividers = v),
            Setting("Width", "Auto follows the widgets; fixed is a share of the screen.", Choice(new[] { "Auto", "Fixed" }, _p.WidthMode == "fixed" ? 1 : 0, i => _p.WidthMode = i == 1 ? "fixed" : "auto")),
            _p.WidthMode == "fixed" ? SliderRow("Fixed width", $"{(int)(_p.FixedWidth * 100)}% of the screen", 0.25, 0.9, _p.FixedWidth, v => _p.FixedWidth = Math.Round(v, 2), 0.05) : null);
        yield return Button("Reset the appearance", _p.ResetAppearance).Align(HorizontalAlignment.Left);
    }

    IEnumerable<UIElement> Widgets()
    {
        var enabled = _p.EnabledWidgets;
        var rows = new List<UIElement>();
        // the chosen ones first, in their order, then the others
        foreach (var info in enabled.Select(WidgetCatalog.Info).OfType<WidgetInfo>().Concat(WidgetCatalog.All.Where(w => !enabled.Contains(w.Id))))
        {
            var id = info.Id;
            var on = enabled.Contains(id);
            var index = enabled.IndexOf(id);
            var controls = Ui.Row(6);
            if (on)
            {
                var cells = _p.Cells(id);
                controls.Children.Add(Ui.Text("Width", 11, color: C.WinSecondary));
                controls.Children.Add(Ui.IconButton(Glyph.Remove, () => SetCells(id, cells - 1)));
                controls.Children.Add(Ui.Digits($"{cells}", 12, color: C.WinText).Size(18));
                controls.Children.Add(Ui.IconButton(Glyph.Add, () => SetCells(id, cells + 1)));
                controls.Children.Add(Ui.IconButton(Glyph.Up, () => Move(id, -1), index > 0 ? C.WinText : C.WinSecondary, "Earlier"));
                controls.Children.Add(Ui.IconButton(Glyph.Down, () => Move(id, 1), index < enabled.Count - 1 ? C.WinText : C.WinSecondary, "Later"));
            }
            controls.Children.Add(Toggle(on, v =>
            {
                var list = _p.EnabledWidgets;
                if (v && !list.Contains(id)) list.Add(id);
                if (!v) list.Remove(id);
                _p.EnabledWidgets = list;
            }));
            var text = Ui.Column(2, Ui.Text(info.Title, 13, color: C.WinText), Ui.Text(info.Subtitle, 11, color: C.WinSecondary, wrap: true));
            rows.Add(new Border { Child = Ui.Row(12, Ui.Icon(info.Glyph, 16, C.WinAccent).Size(24), text.Grow(), controls), Padding = new Thickness(14, 10, 14, 10) });
        }
        yield return Card("Widgets", rows.ToArray());
        yield return Ui.Text("The panel is as wide as the widgets need (a widget is cells of 44 points); what does not fit goes on a second page.", 11, color: C.WinSecondary, wrap: true);
        var apps = _p.ShortcutApps;
        var appRows = new List<UIElement>();
        foreach (var app in apps)
        {
            var path = app;
            appRows.Add(new Border
            {
                Child = Ui.Row(10, Ui.FileIconView(path, 22), Ui.Text(Path.GetFileNameWithoutExtension(path), 13, color: C.WinText).Grow(),
                               Ui.IconButton(Glyph.Close, () => { var list = _p.ShortcutApps; list.Remove(path); _p.ShortcutApps = list; })),
                Padding = new Thickness(14, 8, 14, 8),
            });
        }
        if (appRows.Count == 0) appRows.Add(new Border { Child = Ui.Text("No apps yet.", 12, color: C.WinSecondary), Padding = new Thickness(14, 10, 14, 10) });
        appRows.Add(new Border
        {
            Child = Button("Add apps…", () =>
            {
                var start = Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu);
                var dialog = new Microsoft.Win32.OpenFileDialog
                {
                    Multiselect = true, Title = "Apps for the Shortcuts widget", Filter = "Programs and shortcuts|*.exe;*.lnk;*.url;*.appref-ms|All files|*.*",
                    InitialDirectory = Path.Combine(start, "Programs"), DereferenceLinks = false,
                };
                if (dialog.ShowDialog(this) != true) return;
                var list = _p.ShortcutApps;
                list.AddRange(dialog.FileNames.Where(f => !list.Contains(f)));
                _p.ShortcutApps = list;
            }).Align(HorizontalAlignment.Left),
            Padding = new Thickness(14, 10, 14, 10),
        });
        yield return Card("Shortcuts widget", appRows.ToArray());
    }

    void SetCells(string id, int cells)
    {
        var info = WidgetCatalog.Info(id);
        var all = _p.WidgetCells;
        all[id] = Math.Clamp(cells, info?.MinCells ?? 1, 12);
        _p.WidgetCells = all;
    }

    void Move(string id, int step)
    {
        var list = _p.EnabledWidgets;
        var index = list.IndexOf(id);
        var target = index + step;
        if (index < 0 || target < 0 || target >= list.Count) return;
        (list[index], list[target]) = (list[target], list[index]);
        _p.EnabledWidgets = list;
    }

    IEnumerable<UIElement> Calendar()
    {
        _calendarUrl.Width = 380;
        var status = _app.Calendar.Loading ? "Reading…" : _app.Calendar.Error.Length > 0 ? _app.Calendar.Error : _app.Calendar.HasSource ? "Read" : "No calendar yet";
        yield return Card("Calendar link",
            Setting("iCalendar (.ics) address", status, Ui.Row(8, Ui.Detach(_calendarUrl), Button("Save", () => { _p.CalendarUrl = _calendarUrl.Text.Trim(); }, accent: true))));
        yield return Ui.Text("Outlook: Settings → Calendar → Shared calendars → Publish a calendar → the ICS link. Google: the calendar's settings → \"Secret address in iCal format\". A .ics file on this computer works too. Muna reads it every 15 minutes; nothing is sent anywhere.", 11, color: C.WinSecondary, wrap: true);
    }

    IEnumerable<UIElement> LocalSendPage()
    {
        var localSend = _app.LocalSend;
        yield return Card("Receiving",
            Switch("Receive files", localSend.ReceiveProblem ?? "Other Munas and LocalSend apps on this network can send you files; you accept each sending.", _p.LocalSendReceive, v => _p.LocalSendReceive = v),
            Setting("Save received files in", _p.ReceiveFolder, Button("Choose…", () =>
            {
                var dialog = new Microsoft.Win32.OpenFolderDialog { InitialDirectory = _p.ReceiveFolder };
                if (dialog.ShowDialog(this) == true) _p.LocalSendFolder = dialog.FolderName;
            })));
        _alias.Width = 240;
        yield return Card("This computer",
            Setting("Name others see", $"Empty: the computer's name ({Environment.MachineName}).",
                    Ui.Row(8, Ui.Detach(_alias), Button("Save", () => _p.LocalSendAlias = _alias.Text.Trim(), accent: true))));
        yield return Ui.Text("Other Munas see this computer marked “Muna”; groups find it again even after its address changes. Windows may ask once to allow Muna on private networks: allow it, or others cannot reach you.", 11, color: C.WinSecondary, wrap: true);
        var groups = localSend.Session.Groups;
        if (groups.Count > 0)
            yield return Card("Groups", groups.Select(g => (UIElement)new Border
            {
                Child = Ui.Row(10, Ui.Column(2, Ui.Text(g.Name, 13, color: C.WinText), Ui.Text(string.Join(", ", g.Members.Select(m => m.Alias)), 11, color: C.WinSecondary)).Grow(),
                               Button("Delete", () => localSend.Session.DeleteGroup(g.Id))),
                Padding = new Thickness(14, 10, 14, 10),
            }).ToArray());
    }

    IEnumerable<UIElement> ClipboardPage()
    {
        yield return Card("Clipboard",
            Switch("Keep the history", "Off: the list is forgotten when Muna quits (pinned items stay).", _p.ClipboardKeepHistory, v => _p.ClipboardKeepHistory = v),
            SliderRow("Items kept", $"{_p.ClipboardMaxItems}", 5, 200, _p.ClipboardMaxItems, v => _p.ClipboardMaxItems = (int)Math.Round(v), 5),
            Switch("Clean copied links", "Tracking parameters (utm_…, fbclid …) are taken out of links you copy.", _p.ClipboardCleanUrls, v => _p.ClipboardCleanUrls = v),
            Setting("Clear the history", "Pinned items stay.", Button("Clear", _app.Clipboard.Clear)));
        yield return Card("Tray",
            Switch("Keep the files after a restart", "The Tray keeps references to files, never copies.", _p.TrayKeepFiles, v => _p.TrayKeepFiles = v));
    }

    IEnumerable<UIElement> Snippets()
    {
        _trigger.Width = 160;
        _snippet.MinHeight = 70;
        var add = Ui.Column(8,
            Ui.Row(8, Ui.Text("Trigger", 12, color: C.WinSecondary).Size(60), Ui.Detach(_trigger)),
            Ui.Row(8, Ui.Text("Text", 12, color: C.WinSecondary).Size(60).Align(v: VerticalAlignment.Top), Ui.Detach(_snippet).Grow()),
            Ui.Row(8, Ui.Text("{date}, {time} and {datetime} are filled in.", 11, color: C.WinSecondary).Grow(), Button("Add", () =>
            {
                _snippetError = _app.Snippets.Add(_trigger.Text, _snippet.Text) ?? "";
                if (_snippetError.Length == 0) { _trigger.Text = ""; _snippet.Text = ""; }
                Render();
            }, accent: true)));
        if (_snippetError.Length > 0) add.Children.Add(Ui.Text(_snippetError, 11, color: C.Warning));
        yield return Card("New snippet", new Border { Child = add, Padding = new Thickness(14) });
        var rows = _app.Snippets.Snippets.Select(s => (UIElement)new Border
        {
            Child = Ui.Row(10, Ui.Text(s.Trigger.StartsWith(';') ? s.Trigger : ";" + s.Trigger, 13, FontWeights.SemiBold, C.WinText).Size(120),
                           Ui.Text(s.Text.Replace("\n", " "), 12, color: C.WinSecondary).Grow(), Ui.IconButton(Glyph.Close, () => { _app.Snippets.Remove(s); Render(); })),
            Padding = new Thickness(14, 8, 14, 8),
        }).ToArray();
        yield return Card("Snippets", rows.Length == 0 ? new UIElement[] { new Border { Child = Ui.Text("None yet.", 12, color: C.WinSecondary), Padding = new Thickness(14, 10, 14, 10) } } : rows);
    }

    IEnumerable<UIElement> About()
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "?";
        yield return Card(null, new Border
        {
            Child = Ui.Row(16, new Image { Source = Ui.LoadResource("Assets/Muna.ico"), Width = 64, Height = 64 },
                Ui.Column(4, Ui.Bold("Muna", 18, C.WinText), Ui.Text($"Version {version}", 12, color: C.WinSecondary),
                          Ui.Text("A Dynamic Island for Windows, from the same project as Muna for GNOME and macOS.", 12, color: C.WinSecondary, wrap: true)).Grow()),
            Padding = new Thickness(18),
        });
        yield return Card("Data", Setting("Notes, to-dos, clipboard, groups …", DataDirectory.Path, Button("Open folder", () => CapsuleViews.Launch(DataDirectory.Path))));
    }
}
