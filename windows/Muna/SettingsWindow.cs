using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Muna.Core;

namespace Muna;

/// <summary>Muna's settings, in the pages of the Linux settings (grouped as there, with a search over
/// the pages).</summary>
public sealed class SettingsWindow : DarkWindow
{
    // The pages of Linux's settings window (linux/prefsWindow.js), section for section.
    static readonly (string Id, string Title, string Glyph, string About, string Group)[] Pages =
    {
        ("general", "General", Glyph.Settings, "Size, shortcuts and where Muna is shown.", "Essentials"),
        ("tools", "Menu bar", Glyph.Window, "Click Muna's icon in the notification area to open the window. Its tabs appear in this order.", "Essentials"),
        ("touchpad", "Touchpad gestures", Glyph.Gesture, "Three and four fingers on the touchpad do what you choose here, anywhere: switch apps, desktops, windows, sound, tabs, Muna, or any keys.", "Essentials"),
        ("fingerprint", "Fingerprint", Glyph.Fingerprint, "Windows Hello (face, finger or PIN): allow Claude's questions, open private notes and clipboard items.", "Essentials"),
        ("monitor", "Monitor", Glyph.Cpu, "What the notification area, the Muna bar and the panel show about this computer, and when to warn you.", "Essentials"),
        ("features", "Overview", Glyph.Apps, "Everything Muna can do, by topic. Each line says where it appears: in the window of Muna's icon, or in the capsule (the island).", "Features"),
        ("feat-media", "Music and media", Glyph.Music, "The player, the lyrics, the colours of the album art, the sound and the mirror.", "Features"),
        ("feat-system", "System", Glyph.Monitor, "The processor, the network, the disks, the battery, the monitors, staying awake, and the warnings about them.", "Features"),
        ("feat-windows", "Windows and desktops", Glyph.Window, "Windows, desktops, the switches for them, the mouse and the keyboard, and the touchpad.", "Features"),
        ("feat-work", "Work", Glyph.Checklist, "Focus, timer, to-do, notes, reminders, shortcuts, the calendar and the AI agents.", "Features"),
        ("feat-files", "Files and sharing", Glyph.Folder, "The tray, downloads, the clipboard, LocalSend and the phone.", "Features"),
        ("feat-capsule", "Capsule", Glyph.Sparkle, "What the capsule shows on its own (Live Activities, cards), how it opens and closes, and the companion.", "Features"),
        ("command", "Command Bar", Glyph.Search, "", "Utilities"),
        ("quickpanel", "Quick panel", Glyph.Sparkle, "", "Utilities"),
        ("toggles", "Quick toggles", Glyph.Sliders, "", "Utilities"),
        ("cleaning", "Cleaning Mode", Glyph.Keyboard, "", "Utilities"),
        ("screenshot", "Screenshot", Glyph.Screenshot, "", "Utilities"),
        ("phone", "Phone", Glyph.Phone, "", "Utilities"),
        ("camera", "Camera preview", Glyph.Camera, "", "Utilities"),
        ("scratchpad", "Scratchpad", Glyph.Note, "", "Utilities"),
        ("color", "Color picker", Glyph.Eyedropper, "", "Utilities"),
        ("radial", "Radial menu", Glyph.Apps, "", "Utilities"),
        ("sound", "Volume mixer", Glyph.Volume, "", "Sound"),
        ("output", "Output switcher", Glyph.Volume, "", "Sound"),
        ("mic", "Mute microphone", Glyph.Microphone, "", "Sound"),
        ("muna", "Widgets", Glyph.Apps, "Choose the widgets of the capsule (the island), their order and their width.", "Dynamic Island"),
        ("appearance", "Appearance", Glyph.Brightness, "The look of the capsule and the Muna bar.", "Dynamic Island"),
        ("gestures", "Gestures", Glyph.Gesture, "How the capsule opens, closes and reacts to the pointer and the touchpad.", "Dynamic Island"),
        ("activities", "Live Activities", Glyph.Play, "What the capsule shows while something is going on, and for how long.", "Dynamic Island"),
        ("tray", "Tray", Glyph.Tray, "The file shelf: drag files to the top of the screen to keep them there.", "Tabs"),
        ("clipboard", "Clipboard", Glyph.Clipboard, "The history of what you copy, and how it behaves.", "Tabs"),
        ("localsend", "LocalSend", Glyph.Wifi, "Sending files to other computers and phones, and receiving them.", "Tabs"),
        ("snippets", "Snippets", Glyph.Edit, "Texts you use often: type ;trigger in the Command Bar (Alt+Space), Enter copies the text.", "Tabs"),
        ("about", "About", Glyph.Info, "", "Muna"),
    };

    /// What the blue "Try it" button of a page does (as on Linux).
    static readonly Dictionary<string, string> TryIt = new()
    {
        ["command"] = "command", ["quickpanel"] = "quickpanel", ["toggles"] = "dark", ["cleaning"] = "cleaning", ["screenshot"] = "screenshot",
        ["color"] = "color", ["mic"] = "mic", ["radial"] = "radial", ["output"] = "output", ["sound"] = "quickpanel:sound", ["tools"] = "quickpanel",
    };

    readonly List<string> _back = new(), _forward = new();

    void Go(string page)
    {
        if (page == _page) return;
        _back.Add(_page);
        _forward.Clear();
        _page = page;
        Render();
    }

    readonly TextBox _search = Input();
    readonly Grid _searchHolder = new();
    readonly TextBox _reminderText = Input();
    readonly TextBox _reminderTime = Input();
    string _reminderRepeat = "once";

    void SaveReminders(IEnumerable<ButterflyReminders.Reminder> list) => _p.SetValue("reminders", ButterflyReminders.ToJson(list));

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
        PreviewKeyDown += (_, e) => RecordKey(e);
        // Linux's search entry: a magnifier and "Search" while it is empty
        _search.Padding = new Thickness(28, 6, 8, 6);
        var magnifier = Ui.Icon(Glyph.Search, 12, C.WinSecondary);
        magnifier.IsHitTestVisible = false;
        magnifier.Margin = new Thickness(10, 0, 0, 0);
        magnifier.VerticalAlignment = VerticalAlignment.Center;
        magnifier.HorizontalAlignment = HorizontalAlignment.Left;
        var hint = Ui.Text("Search", 13, color: C.WinSecondary);
        hint.IsHitTestVisible = false;
        hint.Margin = new Thickness(30, 0, 0, 0);
        hint.VerticalAlignment = VerticalAlignment.Center;
        hint.HorizontalAlignment = HorizontalAlignment.Left;
        _searchHolder.Children.Add(_search);
        _searchHolder.Children.Add(magnifier);
        _searchHolder.Children.Add(hint);
        _search.TextChanged += (_, _) => hint.Visibility = _search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        _search.TextChanged += (_, _) =>
        {
            Render();
            Dispatcher.BeginInvoke(() => { _search.Focus(); _search.CaretIndex = _search.Text.Length; });
        };
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
        var side = Ui.Column(2, Ui.Row(10, Ui.Butterfly(20), Ui.Bold("Muna", 15, C.WinText)).Margin(8, 0, 0, 10));
        _search.ToolTip = "Search the settings";
        // the entry follows light and dark too (it is made once)
        _search.Background = C.WinControl;
        _search.Foreground = C.WinText;
        _search.CaretBrush = C.WinText;
        _search.BorderBrush = C.WinBorder;
        side.Children.Add(Ui.Detach(_searchHolder).Margin(0, 0, 0, 8));
        var query = _search.Text.Trim();
        string? group = null;
        foreach (var (id, title, glyph, about, heading) in Pages)
        {
            if (query.Length > 0 && !title.Contains(query, StringComparison.OrdinalIgnoreCase) && !about.Contains(query, StringComparison.OrdinalIgnoreCase)) continue;
            if (heading != group)
            {
                group = heading;
                side.Children.Add(Ui.Text(heading.ToUpperInvariant(), 10, FontWeights.Bold, C.WinSecondary).Margin(10, 8, 0, 2));
            }
            var on = id == _page;
            var page = id;
            side.Children.Add(Ui.Box(Ui.Row(10, Ui.Icon(glyph, 13, on ? Brushes.White : C.WinSecondary), Ui.Text(title, 13, color: on ? Brushes.White : C.WinText)),
                                     on ? C.WinAccent : C.Clear, 8, 10, 6).OnClick(() => { _search.Text = ""; Go(page); }, on ? null : C.White(0.06)));
        }
        var info = Pages.First(p => p.Id == _page);
        var searching = query.Length > 0;
        var head = Ui.Row(10,
            Ui.Box(Ui.Icon(Glyph.Back, 11, _back.Count > 0 ? C.WinText : C.WinSecondary), C.White(0.07), 13).Size(30, 26).OnClick(() =>
            {
                if (_back.Count == 0) return;
                _forward.Add(_page); _page = _back[^1]; _back.RemoveAt(_back.Count - 1); Render();
            }),
            Ui.Box(Ui.Icon(Glyph.Forward, 11, _forward.Count > 0 ? C.WinText : C.WinSecondary), C.White(0.07), 13).Size(30, 26).OnClick(() =>
            {
                if (_forward.Count == 0) return;
                _back.Add(_page); _page = _forward[^1]; _forward.RemoveAt(_forward.Count - 1); Render();
            }),
            Ui.Bold(searching ? "Search" : info.Title, 20, C.WinText).Grow());
        if (!searching && TryIt.TryGetValue(_page, out var action)) head.Children.Add(Button("▶  Try it", () => _app.Perform(action), accent: true));
        var content = Ui.Column(18, head);
        if (!searching && info.About.Length > 0) content.Children.Add(Ui.Text(info.About, 12, color: C.WinSecondary, wrap: true));
        foreach (var block in searching ? FeatureList(Features.All(_app)) : _page switch
        {
            "general" => General(),
            "tools" => MenuBarPage(),
            "touchpad" => Gestures(),
            "fingerprint" => PrivacyPage(),
            "monitor" => Monitor(),
            "features" => FeaturesOverview(),
            "command" => CommandPage(),
            "quickpanel" => QuickPanelPage(),
            "toggles" => TogglesPage(),
            "cleaning" => CleaningPage(),
            "screenshot" => ScreenshotPage(),
            "phone" => PhonePage(),
            "camera" => CameraPage(),
            "scratchpad" => ScratchpadPage(),
            "color" => ColorPage(),
            "radial" => RadialPage(),
            "sound" => MixerPage(),
            "output" => OutputPage(),
            "mic" => MicPage(),
            "muna" => Widgets().Concat(Calendar()),
            "appearance" => Appearance(),
            "gestures" => CapsuleGestures(),
            "activities" => Activities(),
            "tray" => TrayPage(),
            "clipboard" => ClipboardPage(),
            "localsend" => LocalSendPage(),
            "snippets" => Snippets(),
            "about" => About(),
            var topic when topic.StartsWith("feat-") => FeatureList(Features.All(_app).Where(f => f.Topic == topic)),
            _ => General(),
        }) content.Children.Add(block);
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(230) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        var sideScroll = Ui.Scroll(side);
        sideScroll.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        grid.Children.Add(new Border { Child = sideScroll, Background = C.WinSurface, Padding = new Thickness(12, 20, 12, 12) });
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

    /// <summary>Linux's appearance chooser: three small windows, System (half light, half dark), Light
    /// and Dark; the chosen one has a blue frame.</summary>
    static UIElement SchemeCards(int chosen, Action<int> choose)
    {
        static Border Window(Brush body, Brush bar) => new()
        {
            CornerRadius = new CornerRadius(6), Background = body, ClipToBounds = true, Height = 74,
            Child = new Border { Height = 10, Background = bar, VerticalAlignment = VerticalAlignment.Top },
        };
        var light = C.Rgb(0xf2, 0xf2, 0xf5);
        var lightBar = C.Rgb(0xd6, 0xd6, 0xdc);
        var dark = C.Rgb(0x2c, 0x2c, 0x30);
        var darkBar = C.Rgb(0x3a, 0x3a, 0x3f);
        var grid = new Grid { Margin = new Thickness(12) };
        var names = new[] { "System", "Light", "Dark" };
        for (var i = 0; i < 3; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            UIElement picture;
            if (i == 0)
            {
                // half light, half dark, cut on the diagonal
                var half = Window(dark, darkBar);
                var top = Window(light, lightBar);
                top.Clip = new PathGeometry(new[] { new PathFigure(new Point(0, 0), new PathSegment[] { new LineSegment(new Point(200, 0), false), new LineSegment(new Point(0, 74), false) }, true) });
                var both = new Grid();
                both.Children.Add(half);
                both.Children.Add(top);
                both.SizeChanged += (_, e) => top.Clip = new PathGeometry(new[] { new PathFigure(new Point(0, 0), new PathSegment[] { new LineSegment(new Point(e.NewSize.Width * 0.75, 0), false), new LineSegment(new Point(e.NewSize.Width * 0.35, 74), false), new LineSegment(new Point(0, 74), false) }, true) });
                picture = both;
            }
            else picture = i == 1 ? Window(light, lightBar) : Window(dark, darkBar);
            var on = i == chosen;
            var index = i;
            var tile = new Border
            {
                Child = Ui.Column(6, picture, Ui.Semi(names[i], 12, on ? C.WinAccent : C.WinText).Align(h: HorizontalAlignment.Center)),
                Padding = new Thickness(8), Margin = new Thickness(6, 0, 6, 0), CornerRadius = new CornerRadius(10),
                BorderThickness = new Thickness(2), BorderBrush = on ? C.WinAccent : C.Clear,
                Background = on ? C.Rgb(0x12, 0x83, 0xff, 0.10) : C.Clear, Cursor = System.Windows.Input.Cursors.Hand,
            };
            tile.MouseLeftButtonUp += (_, _) => choose(index);
            Grid.SetColumn(tile, i);
            grid.Children.Add(tile);
        }
        return grid;
    }

    IEnumerable<UIElement> General()
    {
        var schemes = new[] { "default", "light", "dark" };
        var chosen = Math.Max(0, Array.IndexOf(schemes, _p.Text("color-scheme")));
        yield return Ui.Column(8, Card("Appearance", SchemeCards(chosen, i => _p.SetValue("color-scheme", schemes[i]))),
            Ui.Text("Applies to the settings window of Muna (and the agents and scratchpad windows), not to the whole desktop.", 11, color: C.WinSecondary, wrap: true).Margin(4, 0, 0, 0));
        foreach (var card in TopBar()) yield return card;
        yield return Card("Muna",
            Switch("Open on hover", "Off: the capsule opens on click only.", _p.OpenOnHover, v => _p.OpenOnHover = v),
            Switch("Collapse when the pointer leaves", "Off: it stays open until you close it.", _p.AutoCollapse, v => _p.AutoCollapse = v),
            SliderRow("Collapsed width", $"{(int)_p.Number("collapsed-width-adjust")} px · fine tune the width of the collapsed capsule", -60, 120, _p.Number("collapsed-width-adjust"),
                      v => _p.SetValue("collapsed-width-adjust", Math.Round(v / 2) * 2), 2),
            SliderRow("Animation speed", $"{_p.AnimationSpeed:0.00}× · how fast the capsule grows and shrinks", 0.25, 4, _p.AnimationSpeed, v => _p.AnimationSpeed = Math.Round(v, 2), 0.25),
            SliderRow("Open after", $"{(int)(_p.OpenDelay * 1000)} ms the pointer rests on the capsule before it opens", 0, 1000, _p.OpenDelay * 1000, v => _p.OpenDelay = Math.Round(v / 25) * 25 / 1000, 25),
            SliderRow("Close after", $"{(int)(_p.CloseDelay * 1000)} ms it stays open after the pointer left it", 0, 2000, _p.CloseDelay * 1000, v => _p.CloseDelay = Math.Round(v / 50) * 50 / 1000, 50),
            Switch("Step aside for full-screen apps", "Games, videos and presentations hide the capsule.", _p.HideInFullscreen, v => _p.HideInFullscreen = v));
        yield return Card("Show on",
            Setting("Screens", "Which monitors have a capsule.", Choice(new[] { "Every screen", "The main screen" }, _p.CapsuleScreens == "main" ? 1 : 0, i => _p.CapsuleScreens = i == 1 ? "main" : "all")));
        yield return Card("Shortcuts",
            Switch("Command Bar: Alt+Space", null, _p.CommandHotKey, v => _p.CommandHotKey = v),
            Switch("Radial menu: Ctrl+Alt+Space", null, _p.RadialHotKey, v => _p.RadialHotKey = v),
            Switch("Muna, Tray, LocalSend, Clipboard, Alerts: Ctrl+Alt+1 … 5", "Each opens the capsule on its own tab, from anywhere.", _p.SectionHotKeys, v => _p.SectionHotKeys = v));
        yield return Card("Your shortcuts", App.Shortcuts.Select(s => ShortcutRow(s.Key, s.Title)).ToArray());
        yield return Ui.Text("Works in any app, no extra permissions. Press keys…, then the keys you want (Escape: none).", 11, color: C.WinSecondary, wrap: true);
        yield return Card("LocalSend",
            Switch("Receive files", _app.LocalSend.ReceiveProblem ?? "Other computers and phones on this network can send you files; you accept every sending.", _p.LocalSendReceive, v => _p.LocalSendReceive = v),
            Setting("Save received files in", _p.ReceiveFolder, Button("Choose…", () =>
            {
                var dialog = new Microsoft.Win32.OpenFolderDialog { InitialDirectory = _p.ReceiveFolder };
                if (dialog.ShowDialog(this) == true) _p.LocalSendFolder = dialog.FolderName;
            })));
        yield return Card("Alerts",
            Switch("Other apps' notifications", _app.Notifications.Problem ?? "What apps tell you shows in the Alerts section too; a click opens the app. Muna reads Windows' notification list on this computer, nothing is sent anywhere.", _p.AppNotifications, v => _p.AppNotifications = v),
            Setting("Do not disturb", "Windows' own setting: which apps may show notifications.", Button("Open", () => CapsuleViews.Launch("ms-settings:notifications"))));
        yield return Card("Start",
            Switch("Open at login", "Muna starts when you sign in.", AutoStart.Enabled, v => { try { AutoStart.Enabled = v; } catch { } Render(); }));
        yield return Card("Feedback",
            Setting("Send feedback", "Send a bug report or a feature idea directly to the person who maintains Muna.", Button("Send feedback", () => CapsuleViews.Launch("https://github.com/bekov0004/Muna/issues/new"))));
        yield return Card(null,
            Setting("Reset all settings", "Every setting goes back to Muna's default. Your notes, to-dos and files stay.", Button("Reset all settings", _p.ResetAll)));
    }

    string? _recording;

    /// A shortcut of Linux's list: what it is now, and "Press keys…" to set it.
    UIElement ShortcutRow(string key, string title)
    {
        var current = _p.Strings(key).FirstOrDefault();
        var label = _recording == key ? "Press the keys…" : current is null ? "Not set" : Pretty(current);
        var row = Ui.Row(8, Button(_recording == key ? "Waiting…" : "Press keys…", () => { _recording = key; Render(); Focus(); }, accent: _recording == key));
        if (current is not null) row.Children.Add(Ui.IconButton(Glyph.Close, () => _p.SetValue(key, null), tip: "No shortcut"));
        return Setting(title, label, row);
    }

    static string Pretty(string accel) => GestureCatalog.ParseKeys(accel) is { } k
        ? string.Join("+", k.Modifiers.Select(m => m switch { "control" or "ctrl" or "primary" => "Ctrl", "alt" => "Alt", "shift" => "Shift", "super" => "Win", _ => m }).Append(k.Key.Length == 1 ? k.Key.ToUpperInvariant() : k.Key))
        : accel;

    /// The keys pressed while a shortcut is being set: "<Control><Alt>t", as Linux writes it.
    void RecordKey(KeyEventArgs e)
    {
        if (_recording is null) return;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin) return;
        e.Handled = true;
        var target = _recording;
        _recording = null;
        if (key == Key.Escape) { Render(); return; }
        var name = key switch
        {
            >= Key.A and <= Key.Z => key.ToString().ToLowerInvariant(),
            >= Key.D0 and <= Key.D9 => ((int)(key - Key.D0)).ToString(),
            >= Key.F1 and <= Key.F24 => key.ToString(),
            Key.Space => "space", Key.Left => "Left", Key.Right => "Right", Key.Up => "Up", Key.Down => "Down",
            Key.PageUp => "Page_Up", Key.PageDown => "Page_Down", Key.Home => "Home", Key.End => "End", Key.Tab => "Tab", Key.Enter => "Return",
            Key.Delete => "Delete", Key.Insert => "Insert", Key.OemPlus => "plus", Key.OemMinus => "minus", Key.PrintScreen or Key.Snapshot => "Print",
            _ => null,
        };
        if (name is null) { Render(); return; }
        var m = Keyboard.Modifiers;
        var accel = (m.HasFlag(ModifierKeys.Control) ? "<Control>" : "") + (m.HasFlag(ModifierKeys.Alt) ? "<Alt>" : "") +
                    (m.HasFlag(ModifierKeys.Shift) ? "<Shift>" : "") + (m.HasFlag(ModifierKeys.Windows) ? "<Super>" : "") + name;
        if (App.HotKeyOf(accel) is null) { Render(); return; }
        _p.SetStrings(target, new[] { accel });
    }

    IEnumerable<UIElement> MenuBarPage()
    {
        var order = QuickPanel.Ordered(_p.Strings("menu-order"));
        var rows = new List<UIElement>();
        for (var i = 0; i < order.Count; i++)
        {
            var (id, title, glyph, about) = order[i];
            var index = i;
            rows.Add(new Border
            {
                Child = Ui.Row(10, Ui.Icon(glyph, 14, C.WinAccent).Size(22), Ui.Column(2, Ui.Text(title, 13, color: C.WinText), Ui.Text(about, 11, color: C.WinSecondary, wrap: true)).Grow(),
                    Ui.IconButton(Glyph.Up, () => MoveTab(order, index, -1), tip: "Earlier"), Ui.IconButton(Glyph.Down, () => MoveTab(order, index, 1), tip: "Later"),
                    Toggle(!_p.Has("menu-hidden", id), on => _p.Toggle("menu-hidden", id, !on))),
                Padding = new Thickness(14, 8, 14, 8),
            });
        }
        yield return Card("Tabs of the window", rows.ToArray());
        var colors = new[] { "#ff9500", "#ff3b30", "#34c759", "#0a84ff", "#bf5af2", "#ffffff" };
        var swatches = Ui.Row(8);
        foreach (var hex in colors)
        {
            var h = hex;
            swatches.Children.Add(new Border
            {
                Width = 20, Height = 20, CornerRadius = new CornerRadius(10), Background = new SolidColorBrush(Preferences.ParseColor(hex, System.Windows.Media.Colors.Orange)),
                BorderBrush = _p.Text("awake-color") == hex ? C.WinAccent : C.White(0.2), BorderThickness = new Thickness(_p.Text("awake-color") == hex ? 3 : 1),
            }.OnClick(() => _p.SetValue("awake-color", h)));
        }
        yield return Card("Keep awake", Setting("Its colour", "While the computer is kept awake, Muna's icon in the notification area is a cup in this colour.", swatches));
        yield return Ui.Text("Switch off anything you do not need; the arrows change the order.", 11, color: C.WinSecondary, wrap: true);
    }

    void MoveTab(List<(string Id, string Title, string Glyph, string About)> order, int index, int step)
    {
        var ids = order.Select(o => o.Id).ToList();
        var target = index + step;
        if (target < 0 || target >= ids.Count) return;
        (ids[index], ids[target]) = (ids[target], ids[index]);
        _p.SetStrings("menu-order", ids);
    }

    IEnumerable<UIElement> CommandPage()
    {
        yield return Card("Command Bar",
            Setting("Open the search now", "One shortcut (Alt+Space) opens a field over whatever you are doing. Type a few letters, press Enter and it happens. Nothing you type is saved.",
                    Button("Try", () => _app.Perform("command"))),
            Switch("Shortcut Alt+Space", null, _p.CommandHotKey, v => _p.CommandHotKey = v));
        yield return Card("Other shortcuts",
            Setting("Open the capsule", "Ctrl+Alt+1", Button("Open", () => _app.Perform("capsule:Muna"))),
            Setting("File shelf", "Ctrl+Alt+2", Button("Open", () => _app.Perform("capsule:Tray"))),
            Setting("LocalSend", "Ctrl+Alt+3", Button("Open", () => _app.Perform("capsule:LocalSend"))),
            Setting("Clipboard history", "Ctrl+Alt+4", Button("Open", () => _app.Perform("capsule:Clipboard"))),
            Setting("Alerts", "Ctrl+Alt+5", Button("Open", () => _app.Perform("capsule:Alerts"))),
            Switch("These shortcuts", "Each opens the capsule on its own tab, from anywhere.", _p.SectionHotKeys, v => _p.SectionHotKeys = v));
    }

    IEnumerable<UIElement> QuickPanelPage()
    {
        yield return Card("Quick panel",
            Setting("Open quick panel", "The window of Muna's icon with your favourite tools.", Button("Open", () => _app.Perform("quickpanel"))),
            Setting("Its tabs", "Choose, hide and order them in Essentials → Menu bar.", Button("Menu bar", () => Go("tools"))));
    }

    IEnumerable<UIElement> TogglesPage()
    {
        var night = SystemSwitches.NightLight;
        yield return Card("Quick toggles",
            Setting("Switch dark mode", "Apps and Windows between light and dark.", Button("Switch", () => _app.Perform("dark"))),
            Switch("Night light", "Warmer colours at night.", night ?? false, on => { if (!SystemSwitches.SetNightLight(on)) CapsuleViews.Launch("ms-settings:nightlight"); Render(); }));
        var drives = System.IO.DriveInfo.GetDrives().Where(d => d.DriveType is System.IO.DriveType.Removable or System.IO.DriveType.CDRom && d.IsReady).ToList();
        var rows = drives.Select(d => Switch($"{d.Name} {d.VolumeLabel}", "Never ejected by Eject disks.", _p.Has("eject-excluded", d.Name), on => _p.Toggle("eject-excluded", d.Name, on))).ToList();
        if (rows.Count == 0) rows.Add(Ui.Text("No drives are connected.", 12, color: C.WinSecondary).Margin(14, 10, 14, 10));
        yield return Card("Excluded drives", rows.ToArray());
        yield return Ui.Text("One-click system actions in the quick panel (Quick toggles) and in the radial menu.", 11, color: C.WinSecondary, wrap: true);
    }

    IEnumerable<UIElement> CleaningPage()
    {
        yield return Card("Cleaning Mode",
            Setting("Lock keyboard now", "Locks the keyboard and the pointer so you can clean safely. Hold Esc for 3 seconds to finish; it ends by itself after a minute.", Button("Lock", () => _app.Perform("cleaning"))),
            Switch("Keep screen visible", "Shows a discreet indicator in the corner of the screen instead of blacking out the content.", _p.Bool("cleaning-visible"), v => _p.SetValue("cleaning-visible", v)));
    }

    IEnumerable<UIElement> ScreenshotPage()
    {
        yield return Card("Screenshot",
            Setting("Take a screenshot", "A part of the screen or a window, copied.", Button("Take", () => _app.Perform("screenshot"))),
            Setting("Screen recording", "Opens Windows' Snipping Tool in recording mode.", Button("Record", () => _app.Perform("recording"))));
    }

    IEnumerable<UIElement> CameraPage()
    {
        yield return Card("Camera preview",
            Switch("Show in the capsule", "A mirror: see yourself in the capsule before a call. The camera is on only while the capsule shows it.", _p.EnabledWidgets.Contains("mirror"), on => SetWidget("mirror", on)));
    }

    IEnumerable<UIElement> ScratchpadPage()
    {
        yield return Card("Scratchpad",
            Setting("Open the scratchpad", "One long note in its own window, kept on this computer.", Button("Open", () => _app.Perform("scratchpad"))),
            Switch("Notes in the capsule", "Quick notes you can copy later.", _p.EnabledWidgets.Contains("notes"), on => SetWidget("notes", on)),
            Switch("To-do list", "A short list of things to do, next to the notes.", _p.EnabledWidgets.Contains("todo"), on => SetWidget("todo", on)));
    }

    void SetWidget(string id, bool on)
    {
        var list = _p.EnabledWidgets;
        list.Remove(id);
        if (on) list.Add(id);
        _p.EnabledWidgets = list;
    }

    IEnumerable<UIElement> ColorPage()
    {
        yield return Card("Color picker",
            Setting("Pick a color", "Pick any pixel of the screen. The color is copied as a hex code.", Button("Pick", () => _app.Perform("color"))));
    }

    IEnumerable<UIElement> MixerPage()
    {
        var sound = _app.Sound;
        sound.Refresh();
        yield return Card("Volume",
            SliderRow("Volume", $"{(int)Math.Round(sound.Volume * 100)} %", 0, 1, sound.Volume, sound.SetVolume, 0.01),
            Switch("Mute", null, sound.Muted, _ => sound.ToggleMute()));
        var apps = sound.Apps;
        var rows = apps.Select(a =>
        {
            var app = a;
            return SliderRow(app.Name, $"{(int)Math.Round(app.Volume * 100)} %{(app.Muted ? " · muted" : "")}", 0, 1, app.Volume, v => sound.SetAppVolume(app, v), 0.01);
        }).ToList();
        if (rows.Count == 0) rows.Add(Ui.Text("No app plays sound now.", 12, color: C.WinSecondary).Margin(14, 10, 14, 10));
        yield return Card("Every application on its own", rows.ToArray());
        yield return Setting("Open the volume mixer", "The Sound tab of the quick panel.", Button("Open", () => _app.Perform("quickpanel:sound")));
    }

    IEnumerable<UIElement> OutputPage()
    {
        var sound = _app.Sound;
        sound.Refresh();
        yield return Card("Output switcher",
            Setting("Switch output now", "Switches the sound to the next output: speakers, headphones, a Bluetooth device.", Button("Switch", () => _app.Perform("output"))));
        var rows = sound.Outputs.Select(o => Switch(o.Name, o.Id == sound.DefaultOutput ? "Playing now" : null, !_p.Has("output-skipped", o.Name),
                                                    on => _p.Toggle("output-skipped", o.Name, !on))).ToList();
        if (rows.Count == 0) rows.Add(Ui.Text("No sound outputs found.", 12, color: C.WinSecondary).Margin(14, 10, 14, 10));
        yield return Card("Outputs in the cycle", rows.ToArray());
        yield return Ui.Text("Turn an output off to skip it when switching.", 11, color: C.WinSecondary, wrap: true);
    }

    IEnumerable<UIElement> MicPage()
    {
        var sound = _app.Sound;
        yield return Card("Mute microphone",
            Setting(sound.MicrophoneMuted ? "The microphone is muted" : "The microphone is on", "Cuts the microphone with a click, across every app.",
                    Button(sound.MicrophoneMuted ? "Unmute" : "Mute", () => { _app.Perform("mic"); Render(); })));
    }

    IEnumerable<UIElement> CapsuleGestures()
    {
        yield return Card("Capsule",
            Switch("Swipe down to open", "Two-finger swipe down over the collapsed capsule.", _p.Bool("gestures-swipe-open"), v => _p.SetValue("gestures-swipe-open", v)),
            Switch("Swipe up to close", "Two-finger swipe up over the open capsule (on its first page).", _p.Bool("gestures-swipe-close"), v => _p.SetValue("gestures-swipe-close", v)),
            Switch("Invert direction", "Reverses every swipe: up opens, down closes, and so on.", _p.Bool("gestures-invert"), v => _p.SetValue("gestures-invert", v)));
        yield return Card("Media",
            Switch("Swipe sideways to skip tracks", "While music is playing: left is the previous track, right the next one.", _p.Bool("gestures-media-swipe"), v => _p.SetValue("gestures-media-swipe", v)));
        var modes = new[] { "none", "activity", "play-pause" };
        yield return Card("Middle click",
            Setting("On the collapsed capsule", null, Choice(new[] { "Nothing", "Next activity", "Play / pause" }, Math.Max(0, Array.IndexOf(modes, _p.Text("gestures-middle-click"))),
                                                           i => _p.SetValue("gestures-middle-click", modes[i]))));
    }

    IEnumerable<UIElement> TrayPage()
    {
        yield return Card("Tray",
            Switch("Keep files", "Remember the tray after a restart or logout (references to your files, not copies).", _p.TrayKeepFiles, v => _p.TrayKeepFiles = v));
    }

    // --- Features: the overview and the topics (Linux's _featurePages) ---------------------------------

    IEnumerable<UIElement> FeatureList(IEnumerable<Feature> features)
    {
        var query = _search.Text.Trim();
        var shown = features.Where(f => query.Length == 0 || $"{f.Title} {f.Subtitle} {f.Group}".Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();
        if (shown.Count == 0) yield return Ui.Text("Nothing found.", 12, color: C.WinSecondary);
        foreach (var group in shown.Select(f => f.Group).Distinct())
        {
            var rows = shown.Where(f => f.Group == group).Select(f =>
            {
                var feature = f;
                var title = Ui.Row(8, Ui.Text(feature.Title, 13, color: C.WinText));
                if (Features.Badge(group) is { } badge) title.Children.Add(Ui.Box(Ui.Text(badge, 10, FontWeights.SemiBold, C.WinAccent), C.Rgb(18, 131, 255, 0.18), 8, 6, 1));
                return (UIElement)new Border
                {
                    Child = Ui.Row(12, Ui.Box(Ui.Icon(feature.Glyph, 13, C.WinAccent), C.Rgb(18, 131, 255, 0.16), 8).Size(28, 28),
                        Ui.Column(2, title, Ui.Text(feature.Subtitle, 11, color: C.WinSecondary, wrap: true)).Grow(),
                        Toggle(feature.Get(), on => feature.Set(on))),
                    Padding = new Thickness(14, 8, 14, 8),
                };
            }).ToArray();
            yield return Card(group, rows);
        }
    }

    IEnumerable<UIElement> FeaturesOverview()
    {
        var all = Features.All(_app);
        var presets = new (string Name, string About, string[] Widgets)[]
        {
            ("Everything", "Every tool and widget.", WidgetCatalog.All.Select(w => w.Id).ToArray()),
            ("Essentials", "Music, calendar and mirror in the capsule, with every tool in the window of Muna's icon.", new[] { "media", "calendar", "mirror", "timer" }),
            ("Light island", "Only music and calendar.", new[] { "media", "calendar" }),
        };
        var grid = new System.Windows.Controls.Primitives.UniformGrid { Columns = 3 };
        foreach (var (name, about, widgets) in presets)
        {
            var list = widgets;
            var light = name == "Light island";
            grid.Children.Add(Ui.Box(Ui.Column(6, Ui.Semi(name, 13, C.WinText), Ui.Text(about, 11, color: C.WinSecondary, wrap: true),
                Button("Apply", () =>
                {
                    _p.EnabledWidgets = list.ToList();
                    _p.SetStrings("menu-hidden", light ? QuickPanel.Ordered(new List<string>()).Select(t => t.Id) : Array.Empty<string>());
                })), C.White(0.05), 10, 10, 10).Margin(4, 4, 4, 4));
        }
        var on = _p.EnabledWidgets.Count + QuickPanel.Ordered(new List<string>()).Count(t => !_p.Has("menu-hidden", t.Id));
        var total = WidgetCatalog.All.Length + QuickPanel.Ordered(new List<string>()).Count;
        yield return Card("Start with a bundle", Ui.Column(8, Ui.Semi($"{on} of {total} tools and widgets are on", 13, C.WinText), grid).Margin(14, 10, 14, 10));
        var topics = Pages.Where(p => p.Id.StartsWith("feat-")).Select(p =>
        {
            var id = p.Id;
            var members = all.Where(f => f.Topic == id).ToList();
            return (UIElement)new Border
            {
                Child = Ui.Row(12, Ui.Box(Ui.Icon(p.Glyph, 13, C.WinAccent), C.Rgb(18, 131, 255, 0.16), 8).Size(28, 28),
                    Ui.Column(2, Ui.Text(p.Title, 13, color: C.WinText), Ui.Text(p.About, 11, color: C.WinSecondary, wrap: true)).Grow(),
                    Ui.Text($"{members.Count(f => f.Get())} of {members.Count} on", 11, color: C.WinSecondary), Ui.Icon(Glyph.Right, 10, C.WinSecondary)),
                Padding = new Thickness(14, 10, 14, 10),
            }.OnClick(() => Go(id), C.White(0.04));
        }).ToArray();
        yield return Card("By topic", topics);
    }

    IEnumerable<UIElement> Activities()
    {
        yield return Card("Live Activities",
            Switch("Music", "Playing track", _p.Bool("activity-media"), v => _p.SetValue("activity-media", v)),
            Switch("Timer", "Countdown", _p.Bool("activity-timer"), v => _p.SetValue("activity-timer", v)),
            Switch("Calendar", "Next meeting", _p.Bool("activity-calendar"), v => _p.SetValue("activity-calendar", v)),
            Switch("Tray", "Added files", _p.Bool("activity-files"), v => _p.SetValue("activity-files", v)),
            Switch("Downloads", "Files arriving", _p.Bool("activity-downloads"), v => _p.SetValue("activity-downloads", v)));
        yield return Ui.Text("Choose what gets its own place in the capsule.", 11, color: C.WinSecondary, wrap: true);
        yield return Card("Collapsed capsule",
            Switch("Show activities when collapsed", "A running timer, music or a meeting instead of the time.", _p.ActivitiesInCollapsed, v => _p.ActivitiesInCollapsed = v),
            SliderRow("Music card", $"{_p.Number("peek-media-seconds"):0.0} s the card with the new track stays on screen", 0.5, 10, _p.Number("peek-media-seconds"), v => _p.SetValue("peek-media-seconds", Math.Round(v * 2) / 2), 0.5),
            SliderRow("Tray card", $"{_p.Number("peek-files-seconds"):0.0} s the \"Adding / Added files\" card stays on screen", 0.5, 10, _p.Number("peek-files-seconds"), v => _p.SetValue("peek-files-seconds", Math.Round(v * 2) / 2), 0.5),
            SliderRow("Meeting card", $"{_p.Number("peek-calendar-seconds"):0.0} s the card about an upcoming meeting stays on screen", 0.5, 30, _p.Number("peek-calendar-seconds"), v => _p.SetValue("peek-calendar-seconds", Math.Round(v * 2) / 2), 0.5),
            SliderRow("Other cards", $"{_p.CardSeconds:0.0} s (a sending ended, time is up, a reminder …)", 1, 15, _p.CardSeconds, v => _p.CardSeconds = Math.Round(v * 2) / 2, 0.5));
        var effects = new[] { "spectrum", "waves" };
        yield return Card("Music",
            SliderRow("Album corner radius", $"{(int)_p.Number("album-corner-radius")}", 0, 24, _p.Number("album-corner-radius"), v => _p.SetValue("album-corner-radius", Math.Round(v)), 1),
            Setting("Effect type", "The animation shown while music plays.", Choice(new[] { "Audio spectrum", "Waves" }, Math.Max(0, Array.IndexOf(effects, _p.Text("media-effect"))), i => _p.SetValue("media-effect", effects[i]))),
            Switch("Show lyrics", "The line being sung, from lrclib.net (artist, title, album and length are sent there).", _p.ShowLyrics, v => _p.ShowLyrics = v),
            Switch("Colored effects", "The effect takes the color of the album art; otherwise it is white.", _p.Bool("colored-effects"), v => _p.SetValue("colored-effects", v)));
    }

    IEnumerable<UIElement> RadialPage()
    {
        yield return Card("Radial menu",
            Setting("Open the radial menu", "Opens a wheel of your favorite actions around the pointer.", Button("Open", () => _app.Perform("radial"))),
            Switch("Shortcut Ctrl+Alt+Space", null, _p.RadialHotKey, v => _p.RadialHotKey = v));
        var chosen = _p.RadialActions;
        var rows = new List<UIElement>();
        for (var i = 0; i < chosen.Count; i++)
        {
            var index = i;
            var info = RadialMenu.Catalog.FirstOrDefault(c => c.Id == chosen[i]);
            if (info.Id is null) continue;
            rows.Add(new Border
            {
                Child = Ui.Row(10, Ui.Digits($"{i + 1}", 12, color: C.WinSecondary).Size(16), Ui.Icon(info.Glyph, 14, C.WinAccent), Ui.Text(info.Title, 13, color: C.WinText).Grow(),
                    Ui.IconButton(Glyph.Up, () => MoveRadial(index, -1), tip: "Earlier"), Ui.IconButton(Glyph.Down, () => MoveRadial(index, 1), tip: "Later"),
                    Ui.IconButton(Glyph.Close, () => { var list = _p.RadialActions; list.RemoveAt(index); _p.RadialActions = list; })),
                Padding = new Thickness(14, 8, 14, 8),
            });
        }
        var missing = RadialMenu.Catalog.Where(c => !chosen.Contains(c.Id)).ToList();
        if (missing.Count > 0 && chosen.Count < 9)
            rows.Add(Setting("Add an action", "The number keys 1 … 9 choose them while the wheel is open.",
                Dropdown(missing.Select(m => (m.Title, (string?)null)).Prepend(("Choose…", null)).ToList(), 0, i =>
                {
                    if (i == 0) return;
                    var list = _p.RadialActions;
                    list.Add(missing[i - 1].Id);
                    _p.RadialActions = list;
                })));
        yield return Card("Actions", rows.ToArray());
        yield return Button("Reset the radial menu", () => _p.RadialActions = new List<string> { "play-pause", "next", "screenshot", "downloads", "color", "prev" }).Align(HorizontalAlignment.Left);
    }

    void MoveRadial(int index, int step)
    {
        var list = _p.RadialActions;
        var target = index + step;
        if (target < 0 || target >= list.Count) return;
        (list[index], list[target]) = (list[target], list[index]);
        _p.RadialActions = list;
    }

    IEnumerable<UIElement> PhonePage()
    {
        var phone = _app.Phone;
        yield return Card("adb",
            Setting("Android's platform-tools", phone.Adb ?? "Not found: winget install Google.PlatformTools, then start Muna again.",
                    phone.Adb is null ? Button("Get them", () => CapsuleViews.Launch("https://developer.android.com/tools/releases/platform-tools")) : Ui.Text("Found", 12, color: C.Ok)),
            Setting("Pair a phone over Wi-Fi", "A QR code to scan in the phone's Wireless debugging.", Button("Pair…", () => { _app.ShowQuickPanel("phone"); phone.StartPairing(); })));
        yield return Card("Muna Phone",
            Switch("Dark phone screen", "While you use the phone from here, its own screen stays dark (it still shows on the computer).", _p.PhoneDarkScreen, v => _p.PhoneDarkScreen = v),
            Setting("The app", "With Muna Phone on the phone, the picture and the touches go over the network; without it, through adb.", Ui.Text(phone.LinkActive ? "Connected" : "Used when installed", 12, color: phone.LinkActive ? C.Ok : C.WinSecondary)));
        yield return Ui.Text("The Phone widget shows the phone in the capsule (Widgets); the quick panel's Phone page shows it big.", 11, color: C.WinSecondary, wrap: true);
    }

    IEnumerable<UIElement> PrivacyPage()
    {
        var privacy = _app.Privacy;
        yield return Card("Confirm",
            Switch("Claude Code's questions", "While Claude Code asks to edit a file or run a command, Windows Hello allows it (Deny stays a button).", _p.Bool("fingerprint-agents"), v => _p.SetValue("fingerprint-agents", v)));
        yield return Card("Private notes and clipboard items",
            Switch("Ask for Windows Hello", "Notes and clipboard items you mark private stay hidden until Windows Hello opens them, for 5 minutes.", _p.Bool("fingerprint-private"), v => _p.SetValue("fingerprint-private", v)));
        yield return Card("Private items",
            Setting("Windows Hello", privacy.Problem ?? (privacy.Unlocked ? "Open now (for 5 minutes)" : "Locked"),
                    privacy.Unlocked ? Button("Lock", privacy.Lock) : Button("Open", privacy.Unlock, accent: true)));
        yield return Ui.Text("Notes and clipboard items marked private stay hidden until Windows Hello (face, finger or PIN) opens them; they lock again after 5 minutes.", 11, color: C.WinSecondary, wrap: true);
    }

    static readonly (string Name, string Hex)[] Colors =
    {
        ("Black", "#000000"), ("Graphite", "#1c1c1e"), ("Night blue", "#0b1a33"), ("Plum", "#24112e"), ("Forest", "#0d2318"), ("Wine", "#2a0d14"),
    };

    readonly TextBox _colorHex = Input();

    IEnumerable<UIElement> Appearance()
    {
        yield return Card("Butterfly",
            Switch("Butterfly in the capsule", "The little butterfly in the middle of the closed capsule. Off: a small camera circle.", _p.CapsuleButterfly, v => _p.CapsuleButterfly = v),
            Switch("Flap its wings", "Now and then it beats its wings and blinks.", _p.Bool("butterfly-flap"), v => _p.SetValue("butterfly-flap", v)),
            SliderRow("Every", $"{(int)_p.Number("butterfly-flap-every")} s between two flaps", 5, 300, _p.Number("butterfly-flap-every"), v => _p.SetValue("butterfly-flap-every", Math.Round(v / 5) * 5), 5));
        // the butterfly's reminders (Linux's "reminders" setting): once, every day or on weekdays
        var butterflyList = ButterflyReminders.ParseList(_p.Text("reminders"));
        var now = DateTime.Now;
        var list = butterflyList.Select(r =>
        {
            var item = r;
            return (UIElement)new Border
            {
                Child = Ui.Row(10, Ui.Icon(Glyph.Bell, 12, r.Enabled ? C.WinAccent : C.WinSecondary), Ui.Digits(r.Time, 13, color: C.WinText),
                               Ui.Text(r.Text, 13, color: C.WinText).Grow(), Ui.Text(ButterflyReminders.WhenText(r, now), 11, color: C.WinSecondary),
                               Toggle(r.Enabled, on => SaveReminders(butterflyList.Select(x => x.Id == item.Id ? (on && x.Repeat == "once" ? ButterflyReminders.New(x.Time, x.Text, "once", DateTime.Now) with { Id = x.Id } : x with { Enabled = on }) : x))),
                               Button("Remove", () => SaveReminders(butterflyList.Where(x => x.Id != item.Id)))),
                Padding = new Thickness(14, 8, 14, 8),
            };
        }).ToList();
        if (list.Count == 0) list.Add(Ui.Text("No reminders yet.", 12, color: C.WinSecondary).Margin(14, 10, 14, 10));
        _reminderText.Width = 240;
        _reminderTime.Width = 70;
        var repeats = new[] { "once", "daily", "weekdays" };
        list.Add(new Border
        {
            Child = Ui.Row(8, Ui.Detach(_reminderText), Ui.Detach(_reminderTime),
                Choice(new[] { "Once", "Every day", "Weekdays" }, Array.IndexOf(repeats, _reminderRepeat), i => _reminderRepeat = repeats[i]),
                Button("Add", () =>
                {
                    try
                    {
                        SaveReminders(butterflyList.Append(ButterflyReminders.New(_reminderTime.Text, _reminderText.Text.Trim().Length == 0 ? "Hello! I am your Muna butterfly." : _reminderText.Text, _reminderRepeat, DateTime.Now)));
                        _reminderText.Text = "";
                        _reminderTime.Text = "";
                    }
                    catch (ArgumentException) { _reminderTime.Text = ""; _reminderTime.ToolTip = "Write the time as 18:30"; }
                }, accent: true),
                Button("Show it now", () => _app.Capsules.Tell("Reminder", _reminderText.Text.Trim().Length == 0 ? "Hello! I am your Muna butterfly." : _reminderText.Text, Glyph.Bell, true, 8))),
            Padding = new Thickness(14, 8, 14, 8),
        });
        yield return Card("Reminders",
            Switch("A sound with a reminder", "At the time you choose the butterfly flies out of the capsule, grows and shows your text. Also in the quick panel (Reminders).", _p.ReminderSound, v => _p.ReminderSound = v));
        yield return Card(null, list.ToArray());
        yield return Ui.Text("Write the time as 18:30.", 11, color: C.WinSecondary);
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
        yield return Card(null,
            Switch("System alerts", "Cards for a busy processor, heat, a full disk or memory and low batteries.", _p.SystemAlerts, v => _p.SystemAlerts = v));
        yield return Button("Reset the appearance", _p.ResetAppearance).Align(HorizontalAlignment.Left);
    }

    IEnumerable<UIElement> Monitor()
    {
        var chosen = _p.BarMetrics;
        var rows = new List<UIElement>();
        foreach (var reading in Reading.All)
        {
            var id = reading.Id;
            var value = reading.Long(_app.Monitor) ?? "Not available on this computer";
            rows.Add(Switch($"{reading.Title} ({reading.Label})", value, chosen.Contains(id), on =>
            {
                var list = _p.BarMetrics;
                list.Remove(id);
                if (on) list.Add(id);
                // in the order of the list above, as Linux shows them
                _p.BarMetrics = Reading.All.Select(r => r.Id).Where(list.Contains).ToList();
            }));
        }
        rows.Add(Setting("Temperature unit", null, Choice(new[] { "°C", "°F" }, _p.TemperatureUnit == "F" ? 1 : 0, i => _p.TemperatureUnit = i == 1 ? "F" : "C")));
        rows.Add(Switch("CPU and memory in Muna's tooltip", "Point at Muna's icon in the notification area.", _p.MenuBarReadings, v => _p.MenuBarReadings = v));
        yield return Card("Readings", rows.ToArray());
        yield return Card("Warn me when",
            SliderRow("The processor stays busy", $"over {_p.AlertCpu}% for a minute", 50, 100, _p.AlertCpu, v => _p.AlertCpu = (int)Math.Round(v), 5),
            SliderRow("It gets hot", $"{_p.AlertTemp} °C", 60, 100, _p.AlertTemp, v => _p.AlertTemp = (int)Math.Round(v), 1),
            SliderRow("The disk is nearly full", $"under {_p.AlertDisk}% free", 1, 30, _p.AlertDisk, v => _p.AlertDisk = (int)Math.Round(v), 1),
            SliderRow("Memory is nearly full", $"under {_p.AlertMemory}% free", 2, 30, _p.AlertMemory, v => _p.AlertMemory = (int)Math.Round(v), 1),
            SliderRow("The battery is low", $"{_p.AlertBattery}% or less", 5, 50, _p.AlertBattery, v => _p.AlertBattery = (int)Math.Round(v), 5));
        yield return Ui.Text("Each reading gets a small icon of its own in the notification area with its value (Windows has no top bar), and a place in the Muna bar. A click opens the quick panel on it. The temperature is the hottest of the computer's thermal zones.", 11, color: C.WinSecondary, wrap: true);
        yield return Card("In the panel",
            Switch("Processor", null, _p.Strings("system-blocks", "temps", "cpu", "gpu", "memory", "uptime").Contains("cpu"), v => ToggleBlock("cpu", v)),
            Switch("Graphics", null, _p.Strings("system-blocks", "temps", "cpu", "gpu", "memory", "uptime").Contains("gpu"), v => ToggleBlock("gpu", v)),
            Switch("Memory", null, _p.Strings("system-blocks", "temps", "cpu", "gpu", "memory", "uptime").Contains("memory"), v => ToggleBlock("memory", v)),
            Switch("Temperatures", null, _p.Strings("system-blocks", "temps", "cpu", "gpu", "memory", "uptime").Contains("temps"), v => ToggleBlock("temps", v)),
            Switch("Uptime", null, _p.Strings("system-blocks", "temps", "cpu", "gpu", "memory", "uptime").Contains("uptime"), v => ToggleBlock("uptime", v)),
            Switch("Show graph scale", "Write the highest value on the dotted line of every graph.", _p.Bool("graph-scale"), v => _p.SetValue("graph-scale", v)),
            Setting("Update every", "How often the numbers are read while a monitor page or a value is shown.",
                Choice(new[] { "1 second", "2 seconds", "5 seconds" }, _p.Number("monitor-interval") switch { <= 1 => 0, >= 5 => 2, _ => 1 }, c => _p.SetValue("monitor-interval", c switch { 0 => 1.0, 2 => 5.0, _ => 2.0 }))));
    }

    void ToggleBlock(string id, bool on)
    {
        var list = _p.Strings("system-blocks", "temps", "cpu", "gpu", "memory", "uptime").Where(b => b != id).ToList();
        if (on) list.Add(id);
        _p.SetStrings("system-blocks", list);
    }

    IEnumerable<UIElement> TopBar()
    {
        var swatches = Ui.Row(8);
        foreach (var (name, hex) in Colors)
        {
            var h = hex;
            var on = string.Equals(_p.PanelColorHex, hex, StringComparison.OrdinalIgnoreCase);
            swatches.Children.Add(new Border
            {
                Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Background = new SolidColorBrush(Preferences.ParseColor(hex, System.Windows.Media.Colors.Black)),
                BorderBrush = on ? C.WinAccent : C.White(0.25), BorderThickness = new Thickness(on ? 3 : 1), ToolTip = name,
            }.OnClick(() => _p.PanelColorHex = h));
        }
        yield return Card("Muna bar",
            Setting("Show it on", "A bar across the top of the monitor: desktops on the left, the capsule in the middle, readings, network, sound, battery and Muna on the right.",
                Choice(new[] { "No monitor", "Other monitors", "Every monitor" }, _p.MunaBarScreens switch { "others" => 1, "all" => 2, _ => 0 }, i => _p.MunaBarScreens = i switch { 1 => "others", 2 => "all", _ => "off" })),
            Setting("Hide it", "Never: windows stay under it. When a window touches it. Always: until the pointer pushes against the top edge.",
                Choice(new[] { "Never", "Intellihide", "Always" }, _p.MunaBarHide switch { "never" => 0, "always" => 2, _ => 1 }, i => _p.MunaBarHide = i switch { 0 => "never", 2 => "always", _ => "intellihide" })),
            Setting("Colour", null, swatches),
            SliderRow("Opacity", $"{_p.PanelOpacity:0.00} (0 is fully transparent, 1 is solid)", 0, 1, _p.PanelOpacity, v => _p.PanelOpacity = Math.Round(v, 2), 0.05));
        bool autoHide;
        try { autoHide = Taskbar.AutoHide; } catch { autoHide = false; }
        yield return Card("Taskbar and desktops",
            Switch("Hide the taskbar", "Windows' taskbar slides away and comes back when the pointer reaches it.", autoHide, v => { try { Taskbar.AutoHide = v; } catch { } Render(); }),
            Switch("Separate desktops for every monitor", "Switching desktops on one monitor does not switch the others: Ctrl+Win+← and → switch the monitor under the pointer, with Shift the window in front goes along. Muna keeps these desktops itself (their windows are minimised).",
                _p.DesktopsPerMonitor, v => _p.DesktopsPerMonitor = v));
    }

    static string GestureName(string id)
    {
        var match = System.Text.RegularExpressions.Regex.Match(id, @"^(swipe|pinch|hold)(\d)(?:-(\w+))?$");
        var (kind, fingers, direction) = (match.Groups[1].Value, match.Groups[2].Value, match.Groups[3].Value);
        if (kind == "hold") return $"{fingers} fingers rest and lift";
        var name = direction switch { "left" => "Swipe left", "right" => "Swipe right", "up" => "Swipe up", "down" => "Swipe down", "in" => "Pinch in (fingers together)", _ => "Pinch out (fingers apart)" };
        return kind == "pinch" ? $"{name} · {fingers}" : name;
    }

    UIElement ActionPicker(string current, Action<string> set)
    {
        var actions = GestureCatalog.Actions;
        var items = actions.Select(a => (a.Title, (string?)a.Group)).ToList();
        return Dropdown(items, Math.Max(0, Array.FindIndex(actions, a => a.Id == current)), i => set(actions[i].Id));
    }

    IEnumerable<UIElement> Gestures()
    {
        var found = _app.Gestures.TouchpadFound;
        yield return Card("Touchpad",
            Switch("Gestures with three and four fingers", "Swipes, pinches and resting the fingers do what you choose below.", _p.TouchpadGestures, v => _p.TouchpadGestures = v),
            Switch("One finger along the edges", "Slide along an edge for brightness or volume, double tap or rest a finger at an edge.", _p.EdgeGestures, v => _p.EdgeGestures = v),
            SliderRow("Sensitivity", $"{(int)_p.GestureSensitivity}% (more: a shorter swipe is enough)", 25, 400, _p.GestureSensitivity, v => _p.GestureSensitivity = Math.Round(v / 5) * 5, 5),
            Setting("Windows' own gestures", "Windows does its three- and four-finger gestures too: set them to \"Nothing\" there (Advanced gestures), then Muna's take their place.",
                    Button("Open", () => CapsuleViews.Launch("ms-settings:devices-touchpad"))));
        if ((_p.TouchpadGestures || _p.EdgeGestures) && !found)
            yield return Ui.Text("No precision touchpad has reported yet: touch it once. A touchpad without Windows' precision driver cannot be read.", 11, color: C.Warning, wrap: true);
        foreach (var (title, ids) in new[]
        {
            ("Three fingers", GestureCatalog.Gestures.Where(g => g.StartsWith("swipe3"))),
            ("Four fingers", GestureCatalog.Gestures.Where(g => g.StartsWith("swipe4"))),
            ("Pinch", GestureCatalog.Gestures.Where(g => g.StartsWith("pinch"))),
            ("Rest the fingers", GestureCatalog.Gestures.Where(g => g.StartsWith("hold"))),
        })
        {
            yield return Card(title, ids.Select(id => Setting(GestureName(id), null, ActionPicker(_p.GestureAction(id), a => _p.SetGestureAction(id, a)))).ToArray());
        }
        var edges = new List<UIElement>();
        foreach (var (key, label) in new[]
        {
            ("edge-left-plus", "Left edge, up"), ("edge-left-minus", "Left edge, down"), ("edge-right-plus", "Right edge, up"), ("edge-right-minus", "Right edge, down"),
            ("edge-top-plus", "Top edge, to the right"), ("edge-top-minus", "Top edge, to the left"), ("edge-bottom-plus", "Bottom edge, to the right"), ("edge-bottom-minus", "Bottom edge, to the left"),
            ("edge-tap-left", "Double tap, left edge"), ("edge-tap-right", "Double tap, right edge"), ("edge-tap-top", "Double tap, top middle"), ("edge-tap-bottom", "Double tap, bottom middle"),
            ("edge-hold-left", "Rest a finger, left edge"), ("edge-hold-right", "Rest a finger, right edge"), ("edge-hold-top", "Rest a finger, top middle"), ("edge-hold-bottom", "Rest a finger, bottom middle"),
        })
        {
            var k = key;
            edges.Add(Setting(label, null, ActionPicker(_p.EdgeAction(k), a => _p.SetEdgeAction(k, a))));
        }
        yield return Card("Edges (one finger)", edges.ToArray());
        yield return Button("Reset the gestures", _p.ResetGestures).Align(HorizontalAlignment.Left);
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
        if (_calendarUrl.Text == _p.CalendarUrl) _calendarUrl.Text = "";
        var status = _app.Calendar.Loading ? "Reading…" : _app.Calendar.Error.Length > 0 ? _app.Calendar.Error : _app.Calendar.HasSource ? "Read" : "No calendar yet";
        if (CalendarModel.HasOutlook)
            yield return Card("Outlook",
                Switch("Outlook's calendar", "The events of Outlook on this computer (only their titles and times are read).", _p.CalendarOutlook, v => _p.CalendarOutlook = v));
        var rows = new List<UIElement>();
        foreach (var url in _p.CalendarUrls)
        {
            var u = url;
            rows.Add(new Border
            {
                Child = Ui.Row(10, Ui.Icon(Glyph.Calendar, 13, C.WinAccent), Ui.Text(url, 12, color: C.WinText).Grow(),
                               Ui.IconButton(Glyph.Close, () => { var list = _p.CalendarUrls; list.Remove(u); _p.CalendarUrls = list; })),
                Padding = new Thickness(14, 10, 14, 10),
            });
        }
        rows.Add(Setting("Add an iCalendar (.ics) address", status, Ui.Row(8, Ui.Detach(_calendarUrl), Button("Add", () =>
        {
            var list = _p.CalendarUrls;
            list.Add(_calendarUrl.Text.Trim());
            _calendarUrl.Text = "";
            _p.CalendarUrls = list;
        }, accent: true))));
        yield return Card("Calendar links", rows.ToArray());
        yield return Ui.Text("Outlook on the web: Settings → Calendar → Shared calendars → Publish a calendar → the ICS link. Google: the calendar's settings → \"Secret address in iCal format\". A .ics file on this computer works too. Muna reads them every 15 minutes; nothing is sent anywhere.", 11, color: C.WinSecondary, wrap: true);
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
            Switch("A click pastes", "Clicking an item puts it in the app you were using (Ctrl+V). Off: it is only copied.", _p.Bool("clipboard-click-pastes"), v => _p.SetValue("clipboard-click-pastes", v)),
            Switch("Keep the history", "Off: the list is forgotten when Muna quits (pinned items stay).", _p.ClipboardKeepHistory, v => _p.ClipboardKeepHistory = v),
            SliderRow("Items kept", $"{_p.ClipboardMaxItems}", 5, 200, _p.ClipboardMaxItems, v => _p.ClipboardMaxItems = (int)Math.Round(v), 5),
            Switch("Clean copied links", "Tracking parameters (utm_…, fbclid …) are taken out of links you copy.", _p.ClipboardCleanUrls, v => _p.ClipboardCleanUrls = v),
            Setting("Clear the history", "Pinned items stay.", Button("Clear", _app.Clipboard.Clear)));
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

/// One line of the feature lists of the settings (Linux's _featurePages): a capsule widget, a tab of
/// the quick panel, or a setting.
public sealed record Feature(string Topic, string Group, string Title, string Subtitle, string Glyph, Func<bool> Get, Action<bool> Set);

public static class Features
{
    public const string Tools = "Window of Muna's icon";
    public const string Island = "Island widgets (the capsule)";

    public static string? Badge(string group) => group switch
    {
        Tools => "Muna's icon",
        Island or "Live Activities" or "Cards and alerts" => "Island",
        _ => null,
    };

    static readonly Dictionary<string, string> TopicOf = new()
    {
        ["media"] = "feat-media", ["sound"] = "feat-media", ["mirror"] = "feat-media",
        ["system"] = "feat-system", ["network"] = "feat-system", ["disks"] = "feat-system", ["power"] = "feat-system", ["awake"] = "feat-system",
        ["displays"] = "feat-system", ["toggles"] = "feat-system", ["utilities"] = "feat-system",
        ["windows"] = "feat-windows", ["workspaces"] = "feat-windows", ["controls"] = "feat-windows", ["input"] = "feat-windows",
        ["focus"] = "feat-work", ["timer"] = "feat-work", ["todo"] = "feat-work", ["notes"] = "feat-work", ["reminders"] = "feat-work",
        ["shortcuts"] = "feat-work", ["calendar"] = "feat-work", ["agents"] = "feat-work",
        ["downloads"] = "feat-files", ["phone"] = "feat-files", ["phonecard"] = "feat-files",
    };

    public static List<Feature> All(AppState app)
    {
        var p = Preferences.Shared;
        var list = new List<Feature>();
        foreach (var (id, title, glyph, about) in QuickPanel.Ordered(new List<string>()))
        {
            var tab = id;
            list.Add(new Feature(TopicOf.GetValueOrDefault(id, "feat-system"), Tools, title, about, glyph, () => !p.Has("menu-hidden", tab), on => p.Toggle("menu-hidden", tab, !on)));
        }
        foreach (var widget in WidgetCatalog.All)
        {
            var id = widget.Id;
            list.Add(new Feature(TopicOf.GetValueOrDefault(id, "feat-capsule"), Island, widget.Title, widget.Subtitle, widget.Glyph, () => p.EnabledWidgets.Contains(id), on =>
            {
                var enabled = p.EnabledWidgets;
                enabled.Remove(id);
                if (on) enabled.Add(id);
                p.EnabledWidgets = enabled;
            }));
        }
        Feature Key(string topic, string group, string title, string subtitle, string glyph, string key) =>
            new(topic, group, title, subtitle, glyph, () => p.Bool(key), on => p.SetValue(key, on));
        list.AddRange(new[]
        {
            Key("feat-capsule", "Live Activities", "Music", "The playing track in the collapsed capsule", Glyph.Music, "activity-media"),
            Key("feat-capsule", "Live Activities", "Timer", "A running countdown or focus session in the capsule", Glyph.Clock, "activity-timer"),
            Key("feat-capsule", "Live Activities", "Calendar", "The next meeting, from 10 minutes before it", Glyph.Calendar, "activity-calendar"),
            Key("feat-capsule", "Live Activities", "Tray", "A card when files are added to the tray", Glyph.Tray, "activity-files"),
            Key("feat-capsule", "Live Activities", "Downloads", "Files arriving in the Downloads folder", Glyph.Download, "activity-downloads"),
            new Feature("feat-system", "Cards and alerts", "System alerts", "A busy processor, heat, a full disk or memory, a low battery", Glyph.Warning, () => p.SystemAlerts, on => p.SystemAlerts = on),
            new Feature("feat-work", "Cards and alerts", "AI agents finished", "A card when Claude Code or Codex finishes a task", Glyph.CheckCircle, () => p.AgentsAlerts, on => p.AgentsAlerts = on),
            Key("feat-capsule", "Cards and alerts", "Keyboard layout", "The capsule widens for a moment and shows the layout when you switch it", Glyph.Keyboard, "show-input-source"),
            Key("feat-capsule", "Cards and alerts", "Caps Lock", "The capsule shows whether Caps Lock is on or off", Glyph.Keyboard, "show-caps-lock"),
            new Feature("feat-media", "Music", "Lyrics", "The line being sung under the title (the song is looked up on lrclib.net)", Glyph.Music, () => p.ShowLyrics, on => p.ShowLyrics = on),
            Key("feat-media", "Music", "Colored effects", "The effect takes the color of the album art", Glyph.Brightness, "colored-effects"),
            Key("feat-media", "Music", "Swipe to change tracks", "A sideways swipe on the capsule skips songs", Glyph.Next, "gestures-media-swipe"),
            Key("feat-files", "Clipboard", "Click pastes", "A click on an item pastes it into the app you were in", Glyph.Clipboard, "clipboard-click-pastes"),
            new Feature("feat-files", "Clipboard", "Keep history", "Save everything you copied after a restart (pinned items and notes are always saved)", Glyph.Clipboard, () => p.ClipboardKeepHistory, on => p.ClipboardKeepHistory = on),
            new Feature("feat-files", "Clipboard", "Clean links", "Remove tracking parameters (utm_*, fbclid ...) from copied links", Glyph.Link, () => p.ClipboardCleanUrls, on => p.ClipboardCleanUrls = on),
            new Feature("feat-files", "Files and sharing", "Keep the tray", "The files on the tray stay after a restart", Glyph.Tray, () => p.TrayKeepFiles, on => p.TrayKeepFiles = on),
            new Feature("feat-files", "Files and sharing", "Receive files with LocalSend", "This computer becomes visible to LocalSend devices (port 53317); every transfer asks first", Glyph.Wifi, () => p.LocalSendReceive, on => p.LocalSendReceive = on),
            new Feature("feat-windows", "Behaviour", "Touchpad gestures everywhere", "Three and four fingers: switch apps, desktops, windows, sound and more", Glyph.Gesture, () => p.TouchpadGestures, on => p.TouchpadGestures = on),
            new Feature("feat-capsule", "Behaviour", "Open on hover", "The capsule opens when the pointer rests on it", Glyph.Sparkle, () => p.OpenOnHover, on => p.OpenOnHover = on),
            new Feature("feat-capsule", "Behaviour", "Collapse when the pointer leaves", "The open panel closes by itself", Glyph.Shrink, () => p.AutoCollapse, on => p.AutoCollapse = on),
            Key("feat-capsule", "Behaviour", "Swipe down to open", "A two-finger swipe down on the capsule opens it", Glyph.Gesture, "gestures-swipe-open"),
            Key("feat-capsule", "Behaviour", "Swipe up to close", "A two-finger swipe up closes the panel", Glyph.Gesture, "gestures-swipe-close"),
        });
        return list;
    }
}
