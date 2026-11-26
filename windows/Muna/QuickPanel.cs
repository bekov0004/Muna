using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Muna.Core;
using Forms = System.Windows.Forms;

namespace Muna;

/// <summary>The top-bar window of Muna on Linux (linux/src/ui/toolsMenu.js): on Windows it opens from
/// Muna's icon in the notification area. System, network, sound, displays, the phone, keep awake,
/// focus, reminders, downloads, windows, agents and quick tools.</summary>
public sealed class QuickPanel : Window
{
    /// Linux's tabs of the top-bar window, in Linux's order (linux/prefsWindow.js MENU_ORDER).
    static readonly (string Id, string Title, string Glyph, string About)[] AllPages =
    {
        ("awake", "Keep awake", Glyph.Coffee, "Keeps your computer awake for as long as you want."),
        ("reminders", "Reminders", Glyph.Bell, "The butterfly tells you something at a time you choose."),
        ("phone", "Phone", Glyph.Phone, "Phone screen on the computer, with control."),
        ("displays", "Displays", Glyph.Brightness, "Brightness of every monitor, night light, and where the monitors stand."),
        ("sound", "Sound", Glyph.Volume, "Volume of each app, one slider each."),
        ("system", "System", Glyph.Cpu, "Processor, graphics and memory at a glance."),
        ("network", "Network", Glyph.Network, "Internet speed and its graph."),
        ("disks", "Disks", Glyph.Disk, "Free space and disk activity."),
        ("power", "Power", Glyph.Battery, "Battery, charging and power use."),
        ("utilities", "Utilities", Glyph.Settings, "Screenshots, colour picker and other tools."),
        ("controls", "Controls", Glyph.Sliders, "Switches for mouse, keyboard and windows."),
        ("toggles", "Quick toggles", Glyph.Wifi, "Wi-Fi, Bluetooth, dark mode, microphone, bin and more."),
        ("windows", "Windows", Glyph.Window, "A picture of each screen: drag windows, split them into columns or rows."),
        ("workspaces", "Desktops", Glyph.Desktop, "Create, switch and remove desktops."),
        ("focus", "Focus", Glyph.Flag, "A focus timer and a stopwatch."),
        ("input", "Input", Glyph.Keyboard, "Mouse and keyboard switches."),
        ("downloads", "Downloads", Glyph.Download, "Files arriving in Downloads."),
        ("agents", "AI agents", Glyph.Sparkle, "Claude Code and Codex at work."),
    };

    /// The tabs in the order chosen in Settings → Menu bar (new ones at the end).
    public static List<(string Id, string Title, string Glyph, string About)> Ordered(List<string> order)
    {
        var chosen = order.Select(id => AllPages.FirstOrDefault(p => p.Id == id)).Where(p => p.Id is not null).ToList();
        return chosen.Concat(AllPages.Where(p => !order.Contains(p.Id))).ToList();
    }

    /// The tabs shown: in their order, without the ones switched off.
    static List<(string Id, string Title, string Glyph, string About)> Pages
    {
        get
        {
            var p = Preferences.Shared;
            var shown = Ordered(p.Strings("menu-order")).Where(t => !p.Has("menu-hidden", t.Id)).ToList();
            return shown.Count > 0 ? shown : AllPages.Where(t => t.Id == "system").ToList();
        }
    }

    readonly AppState _app;
    string _page = "system";
    string? _message;
    bool _queued;
    DateTime _hiddenAt;
    readonly Field _reminderText = new("Remind me to…");
    readonly Field _reminderTime = new("HH:MM");
    readonly Field _phoneText = new("Type on the phone, Enter sends");
    readonly Border _root = new() { Background = Brushes.Black, CornerRadius = new CornerRadius(14), BorderBrush = C.White(0.1), BorderThickness = new Thickness(1), Padding = new Thickness(14) };

    public QuickPanel(AppState app)
    {
        _app = app;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.NoResize;
        Width = 360;
        SizeToContent = SizeToContent.Height;
        FontFamily = Ui.Font;
        Title = "Muna";
        Content = _root;
        Deactivated += (_, _) => HidePanel();
        KeyDown += (_, e) => { if (e.Key == Key.Escape) HidePanel(); };
        SizeChanged += (_, _) => Place();
        foreach (var model in new Model[] { app.Monitor, app.Awake, app.Focus, app.Reminders, app.Downloads, app.Sound, app.Agents, app.Windows, app.Displays, app.Phone, app.Desktops, app.Power })
            model.Changed += Queue;
        _reminderText.Submitted += AddReminder;
        _reminderTime.Submitted += AddReminder;
        _phoneText.Box.TextChanged += (_, _) => app.Phone.Draft = _phoneText.Text;
        _phoneText.Submitted += () => { app.Phone.SendText(); _phoneText.Text = ""; };
        foreach (var field in new[] { _reminderText, _reminderTime, _phoneText })
            field.Box.PreviewMouseLeftButtonDown += (_, _) => { Activate(); field.Box.Focus(); };
    }

    public void Toggle()
    {
        // a click on the icon while open closes it (the click itself deactivated it a moment ago)
        if (IsVisible || (DateTime.Now - _hiddenAt).TotalMilliseconds < 300) { HidePanel(); return; }
        _app.Windows.Remember();
        _message = null;
        _app.Monitor.Watch();
        _app.Sound.Watch();
        _app.Displays.Refresh();
        _app.Downloads.Refresh();
        if (_page == "phone") _app.Phone.Watch();
        if (_page == "agents") _app.Agents.WatchSessions();
        if (_page == "toggles") RefreshRadios();
        if (_page == "windows") StartPictures();
        Render();
        Show();
        Place();
        Activate();
    }

    /// <summary>Opens on a page (or as it was); when open on that page already, it closes.</summary>
    public void ShowPage(string? page)
    {
        if (page == "tools") page = "toggles";
        if (page is not null && AllPages.Any(p => p.Id == page))
        {
            if (IsVisible && _page == page) { HidePanel(); return; }
            if (IsVisible) { SetPage(page); return; }
            _page = page;
        }
        _hiddenAt = default;
        if (IsVisible) { HidePanel(); return; }
        Toggle();
    }

    void HidePanel()
    {
        if (!IsVisible) return;
        _hiddenAt = DateTime.Now;
        Hide();
        _app.Monitor.Unwatch();
        _app.Sound.Unwatch();
        _pictureTimer.Stop();
        if (_page == "phone") _app.Phone.Unwatch();
        if (_page == "agents") _app.Agents.UnwatchSessions();
    }

    /// <summary>Above the notification area (the corner of the main screen where the taskbar is).</summary>
    void Place()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        var screen = Forms.Screen.PrimaryScreen ?? Forms.Screen.AllScreens[0];
        var area = screen.WorkingArea;
        var bounds = screen.Bounds;
        var scale = Native.Scale(Native.MonitorAt(area.Right - 1, area.Bottom - 1));
        int w = (int)(ActualWidth * scale), h = (int)(ActualHeight * scale), gap = (int)(12 * scale);
        var x = area.Right - w - gap;
        var y = area.Bottom - h - gap;
        if (area.Top > bounds.Top) y = area.Top + gap;           // the taskbar is on top
        if (area.Left > bounds.Left) x = area.Left + gap;        // on the left
        Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, x, Math.Max(area.Top, y), 0, 0, Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
    }

    void Queue()
    {
        if (_queued || !IsVisible) return;
        _queued = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            _queued = false;
            if (Mouse.LeftButton == MouseButtonState.Pressed && IsMouseOver) { Queue(); return; }
            Render();
        });
    }

    void SetPage(string page)
    {
        if (_page == "phone") _app.Phone.Unwatch();
        if (_page == "agents") _app.Agents.UnwatchSessions();
        _page = page;
        if (page == "phone") { _app.Phone.Watch(); _app.Phone.ReadSize(); }
        if (page == "agents") _app.Agents.WatchSessions();
        if (page == "toggles") RefreshRadios();
        if (page == "windows") StartPictures(); else _pictureTimer.Stop();
        _message = null;
        Render();
    }

    void Say(string message)
    {
        _message = message;
        Render();
    }

    void Render()
    {
        var pages = Pages;
        if (pages.All(t => t.Id != _page)) _page = pages[0].Id;
        var tabs = new UniformGrid { Columns = Math.Min(9, pages.Count) };
        foreach (var (id, title, glyph, _) in pages)
        {
            var selected = id == _page;
            var page = id;
            tabs.Children.Add(Ui.Box(Ui.Icon(glyph, 13, selected ? C.Accent : C.White(0.75)), selected ? C.White(0.1) : C.Clear, 10).Size(height: 30).Tip(title)
                .OnClick(() => SetPage(page), C.White(0.06)));
        }
        var column = Ui.Column(12,
            Ui.Butterfly(22).Align(HorizontalAlignment.Center),
            Ui.Box(tabs, C.White(0.05), 14, 4, 4),
            Ui.Text(AllPages.First(p => p.Id == _page).Title.ToUpperInvariant(), 10, FontWeights.Black, C.Caption));
        UIElement body = _page switch
        {
            "system" => SystemPage(),
            "network" => NetworkPage(),
            "sound" => SoundPage(),
            "displays" => DisplaysPage(),
            "phone" => PhonePage(),
            "awake" => AwakePage(),
            "focus" => FocusPage(),
            "reminders" => RemindersPage(),
            "downloads" => DownloadsPage(),
            "windows" => WindowsPage(),
            "agents" => AgentsPage(),
            "controls" => ControlsPage(),
            "disks" => DisksPage(),
            "power" => PowerPage(),
            "input" => InputPage(),
            "workspaces" => DesktopsPage(),
            "utilities" => UtilitiesPage(),
            _ => ToolsPage(),
        };
        column.Children.Add(body);
        if (_message is not null) column.Children.Add(Ui.Text(_message, 11, color: C.Ok, wrap: true));
        column.Children.Add(Ui.Row(8,
            Footer(Glyph.Settings, "Settings", () => { HidePanel(); _app.ShowSettings(); }).Grow(),
            Footer(Glyph.Search, "Command Bar", () => { HidePanel(); _app.Capsules.OpenCommand(); }).Grow(),
            Footer(Glyph.Power, "Quit", () => Application.Current.Dispatcher.BeginInvoke(() => { HidePanel(); QuitApp(); })).Grow()));
        TextElement.SetForeground(column, C.Text);
        _root.Child = column;
    }

    static void QuitApp()
    {
        App.State.Shutdown();
        Application.Current.Shutdown();
    }

    static Border Footer(string glyph, string label, Action action) =>
        Ui.Box(Ui.Row(6, Ui.Icon(glyph, 11), Ui.Semi(label, 12)).Align(HorizontalAlignment.Center), C.White(0.08), 10).Size(height: 30).OnClick(action, C.White(0.14));

    /// <summary>A block of the quick panel.</summary>
    static Border Block(params UIElement?[] rows) => Ui.Box(Ui.Column(8, rows), C.White(0.06), 12, 12, 12);

    /// <summary>A row: a name, a bar, a value.</summary>
    static UIElement Meter(string label, double share, string value) => Ui.Column(4,
        Ui.Row(4, Ui.Semi(label, 12), Ui.Spacer(), Ui.Digits(value, 12, color: C.Secondary)),
        AgentsWindow.Meter(share));

    /// <summary>A small line graph of the last minute.</summary>
    static UIElement Graph(List<double> values, double? top = null)
    {
        var canvas = new Grid { Height = 44 };
        canvas.SizeChanged += (_, _) =>
        {
            canvas.Children.Clear();
            if (values.Count < 2) return;
            var maximum = Math.Max(top ?? values.Max(), 0.0001);
            var step = canvas.ActualWidth / 59;
            var start = canvas.ActualWidth - step * (values.Count - 1);
            var line = new Polyline { Stroke = C.Accent, StrokeThickness = 1.5 };
            for (var i = 0; i < values.Count; i++)
                line.Points.Add(new Point(start + step * i, canvas.ActualHeight * (1 - Math.Min(values[i] / maximum, 1))));
            canvas.Children.Add(line);
        };
        return canvas;
    }

    static string Speed(double bytes) => bytes < 1000 ? $"{bytes:0} B/s" : $"{Ui.SizeText((long)bytes)}/s";

    // --- pages -------------------------------------------------------------------------------------

    UIElement SystemPage()
    {
        var m = _app.Monitor;
        var (free, total) = SystemMonitor.SystemDisk();
        var battery = SystemMonitor.Battery();
        var up = SystemMonitor.Uptime;
        return Ui.Column(10,
            Block(Meter("Processor", m.Cpu, $"{(int)(m.Cpu * 100)}%"), Graph(m.CpuHistory, 1)),
            Block(Meter("Memory", m.MemoryTotal > 0 ? (double)m.MemoryUsed / m.MemoryTotal : 0, $"{Ui.SizeText((long)m.MemoryUsed)} of {Ui.SizeText((long)m.MemoryTotal)}"), Graph(m.MemoryHistory, 1)),
            Block(total > 0 ? Meter("Disk", 1 - (double)free / total, $"{Ui.SizeText(free)} free") : null,
                  battery.HasBattery ? Meter("Battery", battery.Percent / 100.0, $"{battery.Percent}%{(battery.Charging ? " · charging" : battery.MinutesLeft > 0 ? $" · {battery.MinutesLeft / 60} h {battery.MinutesLeft % 60} min" : "")}") : null,
                  Ui.Text($"Up for {(up.Days > 0 ? $"{up.Days} d " : "")}{up.Hours} h {up.Minutes} min", 11, color: C.Secondary)));
    }

    UIElement NetworkPage()
    {
        var m = _app.Monitor;
        return Block(
            Ui.Row(6, Ui.Semi(m.NetworkName, 12).Grow(), Ui.Digits(m.Address, 12, color: C.Secondary)),
            Ui.Row(6, Ui.Icon(Glyph.Down, 11, C.Accent), Ui.Digits(Speed(m.DownPerSecond), 12), Ui.Spacer(), Ui.Icon(Glyph.Up, 11, C.Muna), Ui.Digits(Speed(m.UpPerSecond), 12)),
            Graph(m.DownHistory),
            Ui.Text($"This session: {Ui.SizeText(m.ReceivedSinceStart)} down · {Ui.SizeText(m.SentSinceStart)} up", 11, color: C.Secondary),
            Ui.Row(6, Ui.Pill("Speed test", () => CapsuleViews.Launch("https://fast.com")), Ui.Pill("Network settings", () => CapsuleViews.Launch("ms-settings:network"))));
    }

    UIElement SoundPage()
    {
        var s = _app.Sound;
        var volume = DarkWindow.Slider(0, 1, s.Volume, v => s.SetVolume(v));
        volume.Width = double.NaN;
        var rows = new List<UIElement?>
        {
            Ui.Row(8, Ui.ControlButton(s.Muted ? Glyph.Mute : Glyph.Volume, s.ToggleMute, 14, 30, 30), volume.Grow(), Ui.Digits($"{(int)Math.Round(s.Volume * 100)}%", 12, color: C.Secondary)),
            s.HasMicrophone ? Ui.Row(8, Ui.ControlButton(Glyph.Microphone, s.ToggleMicrophone, 14, 30, 30, s.MicrophoneMuted ? C.Warning : null),
                                     Ui.Text(s.MicrophoneMuted ? "Microphone muted" : "Microphone on", 12)) : null,
        };
        var outputs = Ui.Column(2, Ui.Text("OUTPUT", 10, FontWeights.Black, C.Caption));
        foreach (var output in s.Outputs)
        {
            var o = output;
            var on = output.Id == s.DefaultOutput;
            outputs.Children.Add(Ui.Box(Ui.Row(8, Ui.Icon(on ? Glyph.Check : Glyph.Volume, 11, on ? C.Accent : C.Secondary), Ui.Text(output.Name, 12).Grow()), on ? C.White(0.06) : C.Clear, 8, 8, 5)
                .OnClick(() => s.SelectOutput(o.Id), C.White(0.08)));
        }
        rows.Add(outputs);
        return Block(rows.ToArray());
    }

    UIElement DisplaysPage()
    {
        var displays = _app.Displays.Displays;
        var column = Ui.Column(10);
        // the arrangement
        if (displays.Count > 0)
        {
            int left = displays.Min(d => d.Bounds.Left), top = displays.Min(d => d.Bounds.Top);
            int right = displays.Max(d => d.Bounds.Right), bottom = displays.Max(d => d.Bounds.Bottom);
            var scale = Math.Min(300.0 / Math.Max(1, right - left), 80.0 / Math.Max(1, bottom - top));
            var canvas = new Canvas { Height = (bottom - top) * scale, Width = (right - left) * scale, HorizontalAlignment = HorizontalAlignment.Center };
            for (var i = 0; i < displays.Count; i++)
            {
                var d = displays[i];
                var box = Ui.Box(Ui.Bold($"{i + 1}", 11, d.Primary ? Brushes.White : C.Secondary).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
                                 d.Primary ? C.Rgb(77, 141, 255, 0.35) : C.White(0.08), 4).Size(Math.Max(10, d.Bounds.Width * scale - 3), Math.Max(10, d.Bounds.Height * scale - 3));
                box.BorderBrush = C.White(0.2);
                box.BorderThickness = new Thickness(1);
                Canvas.SetLeft(box, (d.Bounds.Left - left) * scale);
                Canvas.SetTop(box, (d.Bounds.Top - top) * scale);
                canvas.Children.Add(box);
            }
            column.Children.Add(Block(canvas));
        }
        foreach (var display in displays)
        {
            var d = display;
            var slider = DarkWindow.Slider(0.05, 1, display.Brightness, v => _app.Displays.Set(d, v));
            slider.Width = double.NaN;
            var how = display.How switch { DisplaysModel.Kind.Builtin => "The screen's own brightness", DisplaysModel.Kind.Ddc => "The monitor's own brightness (DDC/CI)", _ => "Dimmed by Muna" };
            column.Children.Add(Block(Ui.Row(6, Ui.Semi(display.Name, 12).Grow(), Ui.Digits($"{(int)Math.Round(display.Brightness * 100)}%", 12, color: C.Secondary)),
                                      Ui.Row(8, Ui.Icon(Glyph.Brightness, 12, C.Secondary), slider.Grow()), Ui.Text(how, 10, color: C.Secondary)));
        }
        var night = SystemSwitches.NightLight;
        column.Children.Add(Block(Ui.Row(8, Ui.Icon(Glyph.Moon, 13, C.Amber), Ui.Column(1, Ui.Semi("Night light", 12), Ui.Text("Warmer colours at night", 10, color: C.Secondary)).Grow(),
            DarkWindow.Toggle(night ?? false, on =>
            {
                if (!SystemSwitches.SetNightLight(on)) { Say("Turn night light on once in Windows' settings, then Muna can switch it"); CapsuleViews.Launch("ms-settings:nightlight"); }
                else Render();
            }))));
        column.Children.Add(Ui.Row(6, Ui.Pill("Night light settings", () => CapsuleViews.Launch("ms-settings:nightlight")), Ui.Pill("Display settings", () => CapsuleViews.Launch("ms-settings:display"))));
        return column;
    }

    UIElement PhonePage()
    {
        var phone = _app.Phone;
        if (phone.Adb is null)
            return Block(Ui.Text("adb was not found. Install Android's platform-tools (winget install Google.PlatformTools) and turn on USB debugging on the phone.", 12, color: C.Secondary, wrap: true));
        if (phone.Pairing is { } pairing) return PairingBlock(phone, pairing);
        if (phone.Current is not { } device)
        {
            var waiting = phone.Devices.FirstOrDefault();
            return Block(Ui.Text(waiting is not null && !waiting.Ready
                ? $"{waiting.Model}: allow USB debugging on the phone ({waiting.State})"
                : "No phone. Connect one with USB debugging on, or pair it over Wi-Fi.", 12, color: C.Secondary, wrap: true),
                Ui.Pill("Pair over Wi-Fi…", phone.StartPairing, accent: true));
        }
        var head = Ui.Row(8, Ui.Icon(Glyph.Phone, 13, C.Accent), Ui.Semi(device.Model, 12).Grow());
        if (phone.Battery is { } battery) head.Children.Add(Ui.Digits($"{battery.Percent}%{(battery.Charging ? " ⚡" : "")}", 12, color: C.Secondary));
        var picture = new Image { Source = phone.Screen, Height = 300, Stretch = Stretch.Uniform, Cursor = Cursors.Hand };
        Point? start = null;
        DateTime startAt = DateTime.Now;
        picture.MouseLeftButtonDown += (_, e) => { start = e.GetPosition(picture); startAt = DateTime.Now; picture.CaptureMouse(); e.Handled = true; };
        picture.MouseLeftButtonUp += (_, e) =>
        {
            picture.ReleaseMouseCapture();
            if (start is not { } s) return;
            start = null;
            var end = e.GetPosition(picture);
            var size = new Size(picture.ActualWidth, picture.ActualHeight);
            if ((end - s).Length < 8) phone.Tap(s, size);
            else phone.Swipe(s, end, size, (DateTime.Now - startAt).TotalSeconds);
        };
        var keys = Ui.Row(6, Ui.Pill("Back", () => phone.Key(PhoneAdb.Back)), Ui.Pill("Home", () => phone.Key(PhoneAdb.Home)),
                          Ui.Pill("Apps", () => phone.Key(PhoneAdb.Recents)), Ui.Pill("Wake", () => phone.Key(PhoneAdb.Wake)),
                          Ui.Pill(phone.Live ? "Live" : "Still", () => { if (phone.Live) phone.StopLive(); else phone.StartLive(); }, active: phone.Live));
        if (phone.LinkActive)
        {
            keys.Children.Add(Ui.Pill("Dark", () => phone.SetDark(!phone.Dark), active: phone.Dark));
            head.Children.Add(Ui.Text("Muna Phone", 10, FontWeights.Bold, C.Ok));
        }
        head.Children.Add(Ui.IconButton(Glyph.Wifi, phone.StartPairing, tip: "Pair another phone over Wi-Fi"));
        keys.HorizontalAlignment = HorizontalAlignment.Center;
        return Block(head, phone.Screen is null ? Ui.Text("Getting the screen…", 11, color: C.Secondary) : picture, keys,
                     phone.LiveError.Length > 0 && phone.Live ? Ui.Text(phone.LiveError, 10, color: C.Warning, wrap: true) : null, Ui.Detach(_phoneText));
    }

    /// <summary>The QR code of a pairing, and what the phone must do.</summary>
    static UIElement PairingBlock(PhoneModel phone, PhoneModel.PairingState pairing)
    {
        var rows = new List<UIElement?> { Ui.Semi("Pair a phone over Wi-Fi", 13) };
        if (pairing.Status == "failed")
        {
            rows.Add(Ui.Text(pairing.Message, 12, color: C.Warning, wrap: true));
            rows.Add(Ui.Row(6, Ui.Pill("Try again", phone.StartPairing, accent: true), Ui.Pill("Cancel", phone.CancelPairing)));
            return Block(rows.ToArray());
        }
        rows.Add(QrImage(pairing.Text, 180).Align(HorizontalAlignment.Center));
        rows.Add(Ui.Text(pairing.Status == "waiting"
            ? "On the phone: Settings → Developer options → Wireless debugging → Pair device with QR code, and scan this. The phone and this computer must be on the same Wi-Fi."
            : pairing.Message, 11, color: C.Secondary, wrap: true));
        rows.Add(Ui.Pill("Cancel", phone.CancelPairing));
        return Block(rows.ToArray());
    }

    /// <summary>A QR code drawn as squares, with its quiet zone.</summary>
    public static FrameworkElement QrImage(string text, double side)
    {
        var modules = Qr.Encode(text);
        var n = modules.GetLength(0);
        var group = new GeometryGroup();
        for (var y = 0; y < n; y++)
            for (var x = 0; x < n; x++)
                if (modules[y, x]) group.Children.Add(new RectangleGeometry(new Rect(x + 4, y + 4, 1, 1)));
        group.Freeze();
        var drawing = new DrawingGroup();
        drawing.Children.Add(new GeometryDrawing(Brushes.White, null, new RectangleGeometry(new Rect(0, 0, n + 8, n + 8))));
        drawing.Children.Add(new GeometryDrawing(Brushes.Black, null, group));
        drawing.Freeze();
        var image = new Image { Source = new DrawingImage(drawing), Width = side, Height = side };
        RenderOptions.SetEdgeMode(image, EdgeMode.Aliased);
        return image;
    }

    UIElement AwakePage()
    {
        var awake = _app.Awake;
        var status = awake.IsOn
            ? Ui.Row(8, Ui.Icon(Glyph.Coffee, 14, C.Amber), Ui.Semi(awake.Until is { } until ? $"Awake until {until.ToString("t", CultureInfo.CurrentCulture)}" : "Awake until you turn it off", 12).Grow(), Ui.Pill("Off", awake.Stop))
            : Ui.Row(8, Ui.Icon(Glyph.Moon, 14, C.Secondary), Ui.Text("The computer sleeps as usual", 12).Grow());
        var choices = new WrapPanel();
        foreach (var (label, minutes) in new (string, int?)[] { ("30 min", 30), ("1 h", 60), ("2 h", 120), ("5 h", 300), ("Until off", null) })
        {
            var m = minutes;
            var pill = Ui.Pill(label, () => awake.Start(m, awake.KeepScreen));
            pill.Margin = new Thickness(0, 0, 6, 6);
            choices.Children.Add(pill);
        }
        var screen = Ui.Row(8, Ui.Text("Keep the screen on too", 12).Grow(), DarkWindow.Toggle(awake.KeepScreen, on => { if (awake.IsOn) awake.Start(awake.Until is { } u ? Math.Max(1, (int)(u - DateTime.Now).TotalMinutes) : null, on); else { awake.Start(null, on); awake.Stop(); } }));
        return Block(status, choices, screen);
    }

    UIElement FocusPage()
    {
        var focus = _app.Focus;
        var pomo = focus.Pomo;
        var remaining = Ui.Digits(FocusModel.Clock(focus.PomoRemainingMs), 30, FontWeights.Light, Brushes.White);
        var buttons = Ui.Row(6);
        if (pomo.State == "running") buttons.Children.Add(Ui.Pill("Pause", focus.PomoPause, accent: true));
        else buttons.Children.Add(Ui.Pill(pomo.State == "paused" ? "Resume" : "Start", focus.PomoStart, accent: true));
        if (pomo.State != "idle") { buttons.Children.Add(Ui.Pill("Skip", focus.PomoSkip)); buttons.Children.Add(Ui.Pill("Reset", focus.PomoReset)); }
        var pomoBlock = Block(
            Ui.Row(6, Ui.Semi(FocusModel.PhaseName(pomo.Phase), 12).Grow(), Ui.Text($"Round {pomo.Round} · {pomo.Done} done", 11, color: C.Secondary)),
            remaining, AgentsWindow.Meter(focus.PomoProgress, pomo.Phase == "work" ? C.Accent : C.Ok), buttons,
            pomo.State == "idle" ? FocusSettings(focus) : null);
        var sw = focus.Stopwatch;
        var swButtons = Ui.Row(6);
        if (sw.State == "running") { swButtons.Children.Add(Ui.Pill("Pause", focus.StopwatchPause, accent: true)); swButtons.Children.Add(Ui.Pill("Lap", focus.StopwatchLap)); }
        else swButtons.Children.Add(Ui.Pill(sw.State == "paused" ? "Resume" : "Start", focus.StopwatchStart, accent: true));
        if (sw.State != "idle") swButtons.Children.Add(Ui.Pill("Reset", focus.StopwatchReset));
        var laps = Ui.Column(1);
        for (var i = sw.Laps.Count - 1; i >= Math.Max(0, sw.Laps.Count - 4); i--)
            laps.Children.Add(Ui.Row(6, Ui.Text($"Lap {i + 1}", 11, color: C.Secondary).Grow(), Ui.Digits(FocusModel.Clock(sw.Laps[i], true), 11)));
        var swBlock = Block(Ui.Semi("Stopwatch", 12), Ui.Digits(FocusModel.Clock(focus.StopwatchMs, true), 24, FontWeights.Light, Brushes.White), swButtons, laps);
        return Ui.Column(10, pomoBlock, swBlock);
    }

    UIElement FocusSettings(FocusModel focus)
    {
        var e = focus.Editing;
        UIElement Stepper(string label, int value, Action<int> set) => Ui.Row(4, Ui.Text(label, 11, color: C.Secondary).Grow(),
            Ui.IconButton(Glyph.Remove, () => { set(value - 1); focus.ApplySettings(); }), Ui.Digits($"{value}", 12).Size(26), Ui.IconButton(Glyph.Add, () => { set(value + 1); focus.ApplySettings(); }));
        return Ui.Column(4,
            Stepper("Focus, minutes", e.Work, v => e.Work = v),
            Stepper("Short break", e.Short, v => e.Short = v),
            Stepper("Long break", e.Long, v => e.Long = v),
            Stepper("Long break every", e.Every, v => e.Every = v));
    }

    void AddReminder()
    {
        var text = _reminderText.Text;
        var time = _reminderTime.Text.Trim();
        string? error;
        if (time.Length == 0) { _app.Reminders.AddIn(text, 10); error = text.Trim().Length == 0 ? "A reminder needs a text" : null; }
        else if (TimeSpan.TryParse(time, CultureInfo.InvariantCulture, out var at) && at.TotalHours < 24) error = _app.Reminders.Add(text, at.Hours, at.Minutes);
        else error = "Write the time as 14:30";
        if (error is null) { _reminderText.Text = ""; _reminderTime.Text = ""; Say("Saved: Muna tells you then"); }
        else Say(error);
    }

    UIElement RemindersPage()
    {
        var list = Ui.Column(4);
        foreach (var reminder in _app.Reminders.Reminders)
        {
            var r = reminder;
            var at = DateTimeOffset.FromUnixTimeMilliseconds(reminder.At).LocalDateTime;
            var when = at.Date == DateTime.Today ? at.ToString("t", CultureInfo.CurrentCulture) : $"Tomorrow {at.ToString("t", CultureInfo.CurrentCulture)}";
            if (at.Date > DateTime.Today.AddDays(1)) when = at.ToString("g", CultureInfo.CurrentCulture);
            list.Children.Add(Ui.Row(8, Ui.Icon(Glyph.Bell, 11, C.Accent), Ui.Text(reminder.Text, 12).Grow(), Ui.Digits(when, 11, color: C.Secondary), Ui.IconButton(Glyph.Close, () => _app.Reminders.Remove(r))));
        }
        if (_app.Reminders.Reminders.Count == 0) list.Children.Add(Ui.Text("No reminders", 12, color: C.Secondary));
        _reminderTime.Width = 70;
        return Ui.Column(10, Block(list), Block(Ui.Detach(_reminderText), Ui.Row(8, Ui.Detach(_reminderTime), Ui.Text("empty: in 10 minutes", 11, color: C.Secondary).Grow(), Ui.Pill("Add", AddReminder, accent: true))));
    }

    UIElement DownloadsPage()
    {
        var downloads = _app.Downloads;
        var rows = new List<UIElement?>();
        foreach (var item in downloads.Active)
            rows.Add(Ui.Row(8, Ui.Icon(Glyph.Download, 12, C.Accent), Ui.Text(System.IO.Path.GetFileNameWithoutExtension(item.Path), 12).Grow(), Ui.Digits(Ui.SizeText(item.Size), 11, color: C.Secondary)));
        foreach (var item in downloads.Recent)
        {
            var path = item.Path;
            var row = Ui.Row(8, Ui.FileIconView(path, 18), Ui.Text(System.IO.Path.GetFileName(path), 12).Grow(), Ui.Digits(Ui.SizeText(item.Size), 11, color: C.Secondary),
                             Ui.IconButton(Glyph.Folder, () => DownloadsModel.Reveal(path), tip: "Show in Explorer"));
            var box = Ui.Box(row, C.Clear, 8, 4, 3);
            DragOut.Attach(box, () => new[] { path }, () => CapsuleViews.Launch(path));
            rows.Add(box);
        }
        if (rows.Count == 0) rows.Add(Ui.Text("Nothing downloaded lately", 12, color: C.Secondary));
        rows.Add(Ui.Pill("Open Downloads", DownloadsModel.OpenFolder));
        return Block(rows.ToArray());
    }

    readonly System.Windows.Threading.DispatcherTimer _pictureTimer = new() { Interval = TimeSpan.FromSeconds(1.5) };
    Dictionary<IntPtr, System.Windows.Media.Imaging.BitmapSource?> _pictures = new();
    string? _mapScreen;
    bool _picturing;

    Forms.Screen MapScreen => Forms.Screen.AllScreens.FirstOrDefault(s => s.DeviceName == _mapScreen)
                              ?? (_app.Windows.Target != IntPtr.Zero ? Forms.Screen.FromHandle(_app.Windows.Target) : Forms.Screen.PrimaryScreen ?? Forms.Screen.AllScreens[0]);

    /// <summary>The windows' pictures of the map, renewed while the page is open.</summary>
    void StartPictures()
    {
        if (_pictureTimer.IsEnabled) return;
        _pictureTimer.Tick -= TakePictures;
        _pictureTimer.Tick += TakePictures;
        _pictureTimer.Start();
        TakePictures(null, EventArgs.Empty);
    }

    void TakePictures(object? sender, EventArgs e)
    {
        if (_picturing || !IsVisible || _page != "windows") return;
        _picturing = true;
        var windows = Tiling.On(MapScreen).Take(12).ToList();
        System.Threading.Tasks.Task.Run(() => windows.ToDictionary(h => h, h => Tiling.Picture(h, 220))).ContinueWith(t => Dispatcher.BeginInvoke(() =>
        {
            _picturing = false;
            if (t.IsFaulted) return;
            _pictures = t.Result;
            Queue();
        }));
    }

    UIElement WindowsPage()
    {
        var windows = _app.Windows;
        var screen = MapScreen;
        var column = Ui.Column(8);
        // which monitor
        if (Forms.Screen.AllScreens.Length > 1)
        {
            var screens = Ui.Row(6);
            var index = 1;
            foreach (var s in Forms.Screen.AllScreens.OrderByDescending(s => s.Primary))
            {
                var id = s.DeviceName;
                screens.Children.Add(Ui.Pill(s.Primary ? "Main screen" : $"Screen {index}", () => { _mapScreen = id; _pictures.Clear(); TakePictures(null, EventArgs.Empty); Render(); }, active: id == screen.DeviceName));
                index++;
            }
            column.Children.Add(screens);
        }
        // the desktops of that monitor
        var tabs = Ui.Row(4);
        var desktops = _app.Desktops;
        if (desktops.On)
        {
            var monitor = desktops.For(screen.DeviceName);
            for (var i = 0; i < monitor.Count; i++)
            {
                var desk = i;
                tabs.Children.Add(Ui.Pill($"Desktop {i + 1}", () => desktops.Switch(screen.DeviceName, desk), active: i == monitor.Current));
            }
            tabs.Children.Add(Ui.IconButton(Glyph.Add, () => desktops.Add(screen.DeviceName), tip: "Another desktop"));
            if (monitor.Count > 1) tabs.Children.Add(Ui.IconButton(Glyph.Remove, () => desktops.RemoveLast(screen.DeviceName), tip: "Remove the last desktop"));
        }
        else
        {
            var (count, current) = VirtualDesktops.State();
            for (var i = 0; i < count; i++)
            {
                var desk = i;
                tabs.Children.Add(Ui.Pill($"Desktop {i + 1}", () => { VirtualDesktops.SwitchTo(desk); Queue(); }, active: i == current));
            }
            tabs.Children.Add(Ui.IconButton(Glyph.Add, () => { VirtualDesktops.New(); Queue(); }, tip: "New desktop"));
        }
        column.Children.Add(tabs);
        // the map and the arrangements
        var map = new WindowMap(screen, _pictures, () => Dispatcher.BeginInvoke(Queue, System.Windows.Threading.DispatcherPriority.Background));
        var arrange = new UniformGrid { Columns = 3 };
        foreach (var (id, label) in Tiling.Modes)
        {
            var mode = id;
            arrange.Children.Add(Ui.Box(Ui.Row(6, TileIcon(id), Ui.Text(label, 10, color: C.Secondary)), C.White(0.06), 8, 6, 5).Margin(2, 2, 2, 2)
                .OnClick(() => { var n = Tiling.Tile(mode, windows.Target, screen); Say(n == 0 ? "No windows on this screen" : $"{n} windows arranged"); }, C.White(0.12)));
        }
        arrange.Children.Add(Ui.Box(Ui.Row(6, Ui.Icon(Glyph.Back, 11, C.Secondary).Size(22), Ui.Text("Undo", 10, color: C.Secondary)), C.White(0.06), 8, 6, 5).Margin(2, 2, 2, 2)
            .OnClick(() => Say(Tiling.Undo() ? "The windows are back" : "Nothing to undo"), C.White(0.12)));
        column.Children.Add(Block(map.Align(HorizontalAlignment.Center), Ui.Text("Drag a window (an edge: half or a quarter, the top: all of it), click it to bring it forward, ✕ closes it.", 10, color: C.Secondary, wrap: true)));
        column.Children.Add(Block(Ui.Text("ALL WINDOWS OF THIS SCREEN", 10, FontWeights.Black, C.Caption), arrange));
        // one window
        var grid = new UniformGrid { Columns = 4 };
        foreach (var (id, label) in WindowsModel.Layouts)
        {
            var layout = id;
            var tile = Ui.Box(Ui.Column(4, LayoutIcon(id), Ui.Text(label, 9, color: C.Secondary).Align(HorizontalAlignment.Center)), C.White(0.06), 10, 4, 8).Margin(2, 2, 2, 2);
            ((Flex)tile.Child).Center = true;
            grid.Children.Add(tile.OnClick(() => windows.Apply(layout), C.White(0.12)));
        }
        var title = windows.TargetTitle;
        column.Children.Add(Block(Ui.Text(title.Length == 0 ? "Click a window, then open this panel" : $"For: {title}", 12, color: C.Secondary), grid));
        if (windows.Message is { } message) column.Children.Add(Ui.Text(message, 11, color: C.Warning));
        column.Children.Add(Ui.Row(6, Ui.Pill("Task view", VirtualDesktops.TaskView), Ui.Pill("Snap layouts", () => Keys.Chord(0x5B, 0x5A))));
        return column;
    }

    /// <summary>A small drawing of an arrangement: its cells.</summary>
    static UIElement TileIcon(string mode)
    {
        const double w = 22, h = 15;
        var canvas = new Canvas { Width = w, Height = h };
        canvas.Children.Add(new Rectangle { Width = w, Height = h, RadiusX = 2, RadiusY = 2, Stroke = C.White(0.35), StrokeThickness = 1 });
        foreach (var s in Tiling.Slots(mode, 3))
        {
            var cell = new Rectangle { Width = Math.Max(1, s.Width * w - 3), Height = Math.Max(1, s.Height * h - 3), RadiusX = 1, RadiusY = 1, Fill = C.Accent };
            Canvas.SetLeft(cell, s.X * w + 1.5);
            Canvas.SetTop(cell, s.Y * h + 1.5);
            canvas.Children.Add(cell);
        }
        return canvas;
    }

    /// <summary>A small screen with the part the window takes.</summary>
    static UIElement LayoutIcon(string id)
    {
        const double w = 30, h = 20;
        var (x, y, rw, rh) = id switch
        {
            "left" => (0.0, 0.0, 0.5, 1.0), "right" => (0.5, 0, 0.5, 1), "top" => (0, 0, 1, 0.5), "bottom" => (0, 0.5, 1, 0.5),
            "tl" => (0, 0, 0.5, 0.5), "tr" => (0.5, 0, 0.5, 0.5), "bl" => (0, 0.5, 0.5, 0.5), "br" => (0.5, 0.5, 0.5, 0.5),
            "third1" => (0, 0, 1 / 3.0, 1), "third2" => (1 / 3.0, 0, 1 / 3.0, 1), "third3" => (2 / 3.0, 0, 1 / 3.0, 1), "twothirds" => (0, 0, 2 / 3.0, 1),
            "max" => (0, 0, 1, 1), "center" => (0.2, 0.2, 0.6, 0.6), "next" => (0.55, 0.15, 0.4, 0.7), _ => (0.3, 0.8, 0.4, 0.2),
        };
        var canvas = new Canvas { Width = w, Height = h, HorizontalAlignment = HorizontalAlignment.Center };
        canvas.Children.Add(new Rectangle { Width = w, Height = h, RadiusX = 3, RadiusY = 3, Stroke = C.White(0.35), StrokeThickness = 1 });
        var part = new Rectangle { Width = Math.Max(2, w * rw - 4), Height = Math.Max(2, h * rh - 4), RadiusX = 1.5, RadiusY = 1.5, Fill = C.Accent };
        Canvas.SetLeft(part, w * x + 2);
        Canvas.SetTop(part, h * y + 2);
        canvas.Children.Add(part);
        return canvas;
    }

    UIElement AgentsPage()
    {
        var agents = _app.Agents;
        var rows = new List<UIElement?>();
        if (agents.ClaudePath is null) rows.Add(Ui.Text("Claude Code is not installed (the claude command was not found).", 12, color: C.Secondary, wrap: true));
        else if (agents.Tasks.Count == 0) rows.Add(Ui.Text("No tasks yet. Start one: Claude Code works in a folder and asks before it changes anything.", 12, color: C.Secondary, wrap: true));
        foreach (var task in agents.Tasks.Take(5))
        {
            var (glyph, tint) = AgentsModel.StatusGlyph(task);
            var t = task;
            rows.Add(Ui.Row(8, Ui.Icon(glyph, 12, tint), Ui.Column(1, Ui.Semi(task.Project, 12), Ui.Text(AgentsModel.StatusText(task), 11, color: C.Secondary)).Grow())
                .OnClick(() => { agents.SelectedId = t.Id; HidePanel(); _app.ShowAgents(); }));
        }
        if (agents.CodexPath is not null)
            rows.Add(Ui.Pill("New Codex task…", () => { agents.NewAgent = "codex"; agents.Creating = true; HidePanel(); _app.ShowAgents(); }));
        rows.Add(Ui.Pill(agents.Tasks.Count == 0 ? "New task…" : "Open the agents window", () =>
        {
            if (agents.Tasks.Count == 0) agents.Creating = true;
            HidePanel();
            _app.ShowAgents();
        }, accent: true));
        var column = Ui.Column(10, Block(rows.ToArray()));
        var recent = agents.Sessions.Where(s => s.Working).Take(4).Concat(agents.Sessions.Where(s => !s.Working).Take(2)).ToList();
        if (recent.Count > 0)
        {
            var list = new List<UIElement?> { Ui.Text("IN TERMINALS", 10, FontWeights.Black, C.Caption) };
            foreach (var session in recent)
                list.Add(Ui.Row(8, new Ellipse { Width = 7, Height = 7, Fill = session.Working ? C.Ok : C.White(0.25) },
                    Ui.Column(1, Ui.Semi($"{session.Project} · {session.Agent}", 12),
                              Ui.Text(session.Working ? "Working now" : $"Last active {session.Modified.ToLocalTime().ToString("t", CultureInfo.CurrentCulture)}", 11, color: C.Secondary)).Grow()));
            column.Children.Add(Block(list.ToArray()));
        }
        if (agents.Usage.Count > 0)
        {
            var usage = new List<UIElement?> { Ui.Text("TOKENS", 10, FontWeights.Black, C.Caption) };
            foreach (var u in agents.Usage)
                usage.Add(Ui.Row(8, Ui.Semi(u.Agent, 12).Grow(), Ui.Text($"{TokenUsage.Short(u.Tokens5h)} in 5 h · {TokenUsage.Short(u.Tokens7d)} week", 11, color: C.Secondary)));
            column.Children.Add(Block(usage.ToArray()));
        }
        if (agents.FiveHour is not null || agents.SevenDay is not null)
            column.Children.Add(Block(
                agents.FiveHour is { } five ? Meter("5 hours", five.Percent / 100, $"{(int)five.Percent}% · {AgentsModel.ResetText(five.ResetsAt)}") : null,
                agents.SevenDay is { } week ? Meter("Week", week.Percent / 100, $"{(int)week.Percent}% · {AgentsModel.ResetText(week.ResetsAt)}") : null));
        return column;
    }

    bool? _wifi, _bluetooth;

    /// <summary>Reads the radios (Windows answers asynchronously), then draws again.</summary>
    async void RefreshRadios()
    {
        _wifi = await SystemSwitches.RadioOn(global::Windows.Devices.Radios.RadioKind.WiFi);
        _bluetooth = await SystemSwitches.RadioOn(global::Windows.Devices.Radios.RadioKind.Bluetooth);
        Queue();
    }

    async void SwitchRadio(global::Windows.Devices.Radios.RadioKind kind, bool on)
    {
        var error = await SystemSwitches.SetRadio(kind, on);
        if (error is not null) Say(error);
        RefreshRadios();
    }

    async void Airplane()
    {
        var on = _wifi == true || _bluetooth == true;
        var error = await SystemSwitches.SetAllRadios(!on);
        Say(error ?? (on ? "Airplane mode: every radio is off" : "Radios are on again"));
        RefreshRadios();
    }

    /// <summary>The quick toggles of Linux's top-bar window: a wide tile with a state.</summary>
    static Border Toggle(string glyph, string title, bool? on, Action action)
    {
        var state = on is null ? "Not here" : on.Value ? "On" : "Off";
        var tint = on == true ? C.Accent : C.White(0.08);
        var tile = Ui.Box(Ui.Row(8, Ui.Box(Ui.Icon(glyph, 13, on == true ? Brushes.White : C.White(0.8)), tint, 13).Size(26, 26),
            Ui.Column(0, Ui.Semi(title, 12), Ui.Text(state, 10, color: C.Secondary)).Grow()), C.White(0.06), 12, 10, 8).Margin(3, 3, 3, 3);
        if (on is null) tile.Opacity = 0.5;
        return tile.OnClick(action, C.White(0.12));
    }

    UIElement ToolsPage()
    {
        var toggles = new UniformGrid { Columns = 2 };
        toggles.Children.Add(Toggle(Glyph.Wifi, "Wi-Fi", _wifi, () => { if (_wifi is { } on) SwitchRadio(global::Windows.Devices.Radios.RadioKind.WiFi, !on); }));
        toggles.Children.Add(Toggle(Glyph.Bluetooth, "Bluetooth", _bluetooth, () => { if (_bluetooth is { } on) SwitchRadio(global::Windows.Devices.Radios.RadioKind.Bluetooth, !on); }));
        var night = SystemSwitches.NightLight;
        toggles.Children.Add(Toggle(Glyph.Moon, "Night light", night ?? false, () =>
        {
            if (!SystemSwitches.SetNightLight(!(night ?? false)))
            {
                Say("Turn night light on once in Windows' settings, then Muna can switch it");
                CapsuleViews.Launch("ms-settings:nightlight");
            }
            else Render();
        }));
        toggles.Children.Add(Toggle(Glyph.Airplane, "Airplane mode", _wifi is null && _bluetooth is null ? null : _wifi != true && _bluetooth != true, Airplane));
        toggles.Children.Add(Toggle(Glyph.Microphone, "Microphone", _app.Sound.HasMicrophone ? !_app.Sound.MicrophoneMuted : null, () => { _app.Sound.ToggleMicrophone(); Render(); }));
        toggles.Children.Add(Toggle(Glyph.Coffee, "Keep awake", _app.Awake.IsOn, () => { if (_app.Awake.IsOn) _app.Awake.Stop(); else _app.Awake.Start(null, true); }));
        var grid = new UniformGrid { Columns = 3 };
        void Tile(string glyph, string label, Action action)
        {
            var tile = Ui.Box(Ui.Column(6, Ui.Icon(glyph, 18), Ui.Text(label, 11, color: C.Secondary).Align(HorizontalAlignment.Center)), C.White(0.06), 12, 6, 12).Margin(3, 3, 3, 3);
            ((Flex)tile.Child).Center = true;
            grid.Children.Add(tile.OnClick(action, C.White(0.12)));
        }
        Tile(Glyph.Moon, "Dark mode", () => Say(QuickTools.ToggleDarkMode() ? "Dark mode on" : "Light mode on"));
        Tile(Glyph.Delete, "Empty bin", () => Say(QuickTools.EmptyRecycleBin() ? "The recycle bin is empty" : "The recycle bin was empty"));
        Tile(Glyph.Up, "Eject disks", () => Say(QuickTools.EjectDisks() is var n and > 0 ? $"{n} disk{(n == 1 ? "" : "s")} ejected" : "No disk to eject"));
        var hidden = SystemSwitches.All.First(x => x.Id == "hidden");
        Tile(Glyph.Eye, SystemSwitches.Read(hidden) ? "Hide hidden files" : "Show hidden files", () => { SystemSwitches.Write(hidden, !SystemSwitches.Read(hidden)); Render(); });
        Tile(Glyph.Monitor, "Screen off", () => { HidePanel(); QuickTools.ScreenOff(); });
        Tile(Glyph.Lock, "Lock", () => { HidePanel(); Native.LockWorkStation(); });
        return Ui.Column(8, toggles, grid);
    }

    // --- the other tabs of Linux's top-bar window -------------------------------------------------------

    /// Linux's Utilities: every tool in one list, each a click away.
    UIElement UtilitiesPage()
    {
        var rows = new List<UIElement?>();
        void Row(string glyph, string title, string about, Action action) =>
            rows.Add(Ui.Box(Ui.Row(10, Ui.Icon(glyph, 14, C.Accent).Size(22), Ui.Column(1, Ui.Semi(title, 12), Ui.Text(about, 10, color: C.Secondary)).Grow(), Ui.Icon(Glyph.Right, 9, C.Secondary)),
                            C.Clear, 8, 6, 5).OnClick(action, C.White(0.08)));
        Row(Glyph.Screenshot, "Screenshot", "A part of the screen or a window, copied", () => { HidePanel(); QuickTools.Screenshot(); });
        Row(Glyph.Video, "Screen recording", "The Snipping Tool, recording", () => { HidePanel(); _app.Perform("recording"); });
        Row(Glyph.Eyedropper, "Colour picker", "Copies the colour as a hex code", () => { HidePanel(); _app.Perform("color"); });
        Row(Glyph.Clipboard, "Clipboard", "What you copied", () => { HidePanel(); _app.Capsules.Open(PanelTab.Clipboard); });
        Row(Glyph.Window, "Window layout", "The window map, columns, rows, a grid", () => SetPage("windows"));
        Row(Glyph.Broom, "Cleaning mode", "Keyboard and pointer locked while you clean", () => { HidePanel(); CleaningMode.Start(); });
        Row(Glyph.Camera, "Camera preview", "See yourself before a call", () => { HidePanel(); _app.Capsules.Open(PanelTab.Mirror); });
        Row(Glyph.Search, "Command Bar", "Apps, calculator, units, snippets", () => { HidePanel(); _app.Capsules.OpenCommand(); });
        Row(Glyph.Note, "Scratchpad", "One long note in its own window", () => { HidePanel(); _app.ShowScratchpad(); });
        Row(Glyph.Apps, "Radial menu", "Your actions around the pointer", () => { HidePanel(); _app.ToggleRadial(); });
        return Block(rows.ToArray());
    }

    string? _disk;

    /// Linux's Disks: each disk, how full, eject, live reading and writing, since Muna started.
    UIElement DisksPage()
    {
        var drives = System.IO.DriveInfo.GetDrives().Where(d => d.IsReady).ToList();
        var shown = drives.FirstOrDefault(d => d.Name == _disk) ?? drives.FirstOrDefault();
        var pills = Ui.Row(6);
        foreach (var d in drives)
        {
            var name = d.Name;
            pills.Children.Add(Ui.Pill(d.Name.TrimEnd('\\'), () => { _disk = name; Render(); }, active: d.Name == shown?.Name));
        }
        var column = Ui.Column(10, pills);
        if (shown is not null)
        {
            var removable = shown.DriveType is System.IO.DriveType.Removable or System.IO.DriveType.CDRom;
            var actions = Ui.Row(6, Ui.Pill("Open", () => CapsuleViews.Launch(shown.RootDirectory.FullName)));
            if (removable) actions.Children.Add(Ui.Pill("Eject", () => { QuickTools.EjectDisks(shown.Name); Render(); }));
            actions.Children.Add(Ui.Spacer());
            actions.Children.Add(Ui.Pill("Disk Management", () => CapsuleViews.Launch("diskmgmt.msc")));
            var label = string.IsNullOrEmpty(shown.VolumeLabel) ? shown.Name : $"{shown.VolumeLabel} ({shown.Name.TrimEnd('\\')})";
            column.Children.Add(Block(Meter(label, 1 - (double)shown.AvailableFreeSpace / Math.Max(1, shown.TotalSize), $"{Ui.SizeText(shown.AvailableFreeSpace)} free of {Ui.SizeText(shown.TotalSize)}"), actions));
        }
        var m = _app.Monitor;
        column.Children.Add(Block(
            Ui.Row(6, Ui.Icon(Glyph.Down, 11, C.Accent), Ui.Digits($"read {Speed(m.DiskReadPerSecond)}", 12), Ui.Spacer(), Ui.Icon(Glyph.Up, 11, C.Muna), Ui.Digits($"write {Speed(m.DiskWritePerSecond)}", 12)),
            Graph(m.DiskHistory),
            Ui.Text($"Since Muna started: {Ui.SizeText((long)m.DiskReadSinceStart)} read, {Ui.SizeText((long)m.DiskWrittenSinceStart)} written", 11, color: C.Secondary)));
        return column;
    }

    /// Linux's Power: the charge and its history, the power drawn, the battery's health, busy programs.
    UIElement PowerPage()
    {
        var battery = SystemMonitor.Battery();
        var m = _app.Monitor;
        var power = _app.Power;
        power.Touch();
        var column = Ui.Column(10);
        if (battery.HasBattery)
            column.Children.Add(Block(
                Meter(battery.Charging ? "Battery · charging" : "Battery", battery.Percent / 100.0,
                      $"{battery.Percent}%{(battery.MinutesLeft > 0 && !battery.Charging ? $" · {battery.MinutesLeft / 60} h {battery.MinutesLeft % 60} min" : "")}"),
                Graph(power.History, 1),
                Ui.Row(6, Ui.Text(m.PowerWatts is { } w ? $"Drawing {w:0.0} W" : "", 11, color: C.Secondary).Grow(), Ui.Text(battery.Charging ? "On the adapter" : "", 11, color: C.Secondary))));
        else column.Children.Add(Block(Ui.Text("This computer has no battery.", 12, color: C.Secondary)));
        if (power.HealthPercent is { } health)
            column.Children.Add(Block(Meter("Battery health", health / 100.0, $"{health}%"),
                Ui.Text($"{(power.Cycles is { } c ? $"{c} cycles · " : "")}designed for {power.DesignWh:0} Wh, holds {power.FullWh:0} Wh{(m.Temperature is { } t ? $" · {SystemMonitor.TemperatureText(t)}" : "")}", 11, color: C.Secondary)));
        if (power.Busy.Count > 0)
        {
            var rows = new List<UIElement?> { Ui.Text("USING THE PROCESSOR", 10, FontWeights.Black, C.Caption) };
            foreach (var (name, share) in power.Busy)
                rows.Add(Ui.Row(6, Ui.Text(name, 12).Grow(), Ui.Digits($"{share * 100:0}%", 11, color: C.Secondary)));
            column.Children.Add(Block(rows.ToArray()));
        }
        column.Children.Add(Ui.Row(6, Ui.Pill("Power settings", () => CapsuleViews.Launch("ms-settings:powersleep")), Ui.Pill("Battery use", () => CapsuleViews.Launch("ms-settings:batterysaver-usagedetails"))));
        return column;
    }

    /// Linux's Input: the mouse and keyboard switches.
    UIElement InputPage()
    {
        var rows = new List<UIElement?>();
        foreach (var item in SystemSwitches.All.Where(x => x.Group == "Mouse and keyboard"))
        {
            var s = item;
            rows.Add(Ui.Row(10, Ui.Icon(item.Glyph, 13, C.Secondary), Ui.Column(1, Ui.Semi(item.Title, 12), Ui.Text(item.Description, 10, color: C.Secondary, wrap: true)).Grow(),
                DarkWindow.Toggle(SystemSwitches.Read(item), value => { SystemSwitches.Write(s, value); Render(); })));
        }
        rows.Add(Ui.Row(6, Ui.Pill("Mouse settings", () => CapsuleViews.Launch("ms-settings:mousetouchpad")), Ui.Pill("Touchpad", () => CapsuleViews.Launch("ms-settings:devices-touchpad")),
                        Ui.Pill("Keyboard", () => CapsuleViews.Launch("ms-settings:typing"))));
        return Block(rows.ToArray());
    }

    /// Linux's Desktops: the list with a click to switch, a new one, separate desktops for every monitor.
    UIElement DesktopsPage()
    {
        var desktops = _app.Desktops;
        var column = Ui.Column(10);
        if (desktops.On)
        {
            foreach (var screen in Forms.Screen.AllScreens.OrderByDescending(x => x.Primary))
            {
                var id = screen.DeviceName;
                var monitor = desktops.For(id);
                var row = Ui.Row(4);
                for (var i = 0; i < monitor.Count; i++)
                {
                    var desk = i;
                    row.Children.Add(Ui.Pill($"Desktop {i + 1}", () => desktops.Switch(id, desk), active: i == monitor.Current));
                }
                row.Children.Add(Ui.IconButton(Glyph.Add, () => desktops.Add(id), tip: "Another desktop"));
                if (monitor.Count > 1) row.Children.Add(Ui.IconButton(Glyph.Remove, () => desktops.RemoveLast(id), tip: "Remove the last desktop"));
                column.Children.Add(Block(Ui.Text(screen.Primary ? "MAIN SCREEN" : "SCREEN", 10, FontWeights.Black, C.Caption), row));
            }
            column.Children.Add(Block(Ui.Pill("Send the window in front to the next desktop", () => { HidePanel(); desktops.MoveFront(1); })));
        }
        else
        {
            var (count, current) = VirtualDesktops.State();
            var row = Ui.Row(4);
            for (var i = 0; i < count; i++)
            {
                var desk = i;
                row.Children.Add(Ui.Pill($"Desktop {i + 1}", () => { VirtualDesktops.SwitchTo(desk); Queue(); }, active: i == current));
            }
            row.Children.Add(Ui.IconButton(Glyph.Add, () => { VirtualDesktops.New(); Queue(); }, tip: "New desktop"));
            column.Children.Add(Block(row, Ui.Row(6, Ui.Pill("Task view", VirtualDesktops.TaskView), Ui.Pill("Close this desktop", () => { Keys.Chord(0x11, 0x5B, 0x73); Queue(); }))));
        }
        var perMonitor = SystemSwitches.All.First(x => x.Id == "permonitor");
        column.Children.Add(Block(Ui.Row(10, Ui.Column(1, Ui.Semi(perMonitor.Title, 12), Ui.Text(perMonitor.Description, 10, color: C.Secondary, wrap: true)).Grow(),
            DarkWindow.Toggle(SystemSwitches.Read(perMonitor), value => { SystemSwitches.Write(perMonitor, value); Render(); }))));
        return column;
    }

    readonly HashSet<string> _folded = new();

    /// <summary>Linux's Controls widget: switches in groups that fold, each group with how many are on.</summary>
    UIElement ControlsPage()
    {
        var column = Ui.Column(8);
        foreach (var group in SystemSwitches.All.GroupBy(s => s.Group))
        {
            var name = group.Key;
            var folded = _folded.Contains(name);
            var on = group.Count(SystemSwitches.Read);
            column.Children.Add(Ui.Row(6, Ui.Icon(folded ? Glyph.Right : Glyph.Down, 9, C.Secondary), Ui.Text(name.ToUpperInvariant(), 10, FontWeights.Black, C.Caption).Grow(),
                                       Ui.Digits($"{on}/{group.Count()}", 10, FontWeights.Bold, C.Accent))
                .OnClick(() => { if (!_folded.Remove(name)) _folded.Add(name); Render(); }));
            if (folded) continue;
            var rows = new List<UIElement?>();
            foreach (var item in group)
            {
                var s = item;
                rows.Add(Ui.Row(10, Ui.Icon(item.Glyph, 13, C.Secondary),
                    Ui.Column(1, Ui.Semi(item.Title, 12), Ui.Text(item.Description, 10, color: C.Secondary, wrap: true)).Grow(),
                    DarkWindow.Toggle(SystemSwitches.Read(item), value => { SystemSwitches.Write(s, value); Render(); })));
            }
            column.Children.Add(Block(rows.ToArray()));
        }
        column.Children.Add(Ui.Row(6, Ui.Pill("Mouse settings", () => CapsuleViews.Launch("ms-settings:mousetouchpad")),
                                      Ui.Pill("Touchpad", () => CapsuleViews.Launch("ms-settings:devices-touchpad")),
                                      Ui.Pill("Window layout", () => SetPage("windows"))));
        return column;
    }
}

/// <summary>Small system actions of the tools page and the radial menu.</summary>
public static class QuickTools
{
    const string Personalize = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    /// <summary>Switches apps and Windows between light and dark; true when now dark.</summary>
    public static bool ToggleDarkMode()
    {
        using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(Personalize);
        var dark = (key.GetValue("AppsUseLightTheme") as int? ?? 1) == 1;
        key.SetValue("AppsUseLightTheme", dark ? 0 : 1, Microsoft.Win32.RegistryValueKind.DWord);
        key.SetValue("SystemUsesLightTheme", dark ? 0 : 1, Microsoft.Win32.RegistryValueKind.DWord);
        // tell the open windows (the taskbar and Explorer follow at once)
        Native.SendMessage(new IntPtr(0xffff), 0x001A, IntPtr.Zero, System.Runtime.InteropServices.Marshal.StringToHGlobalUni("ImmersiveColorSet"));
        return dark;
    }

    public static void Screenshot() => CapsuleViews.Launch("ms-screenclip:");

    /// <summary>Ejects the removable drives and discs (Explorer's own "Eject"); how many.</summary>
    public static int EjectDisks(string? only = null)
    {
        // the drives excluded in Settings → Quick toggles stay (unless one is asked for by name)
        var excluded = Preferences.Shared.Strings("eject-excluded");
        var drives = System.IO.DriveInfo.GetDrives().Where(d => d.DriveType is System.IO.DriveType.Removable or System.IO.DriveType.CDRom && d.IsReady)
            .Where(d => only is null ? !excluded.Contains(d.Name) : d.Name == only).ToList();
        if (drives.Count == 0 || Type.GetTypeFromProgID("Shell.Application") is not { } type) return 0;
        var count = 0;
        try
        {
            dynamic shell = Activator.CreateInstance(type)!;
            dynamic computer = shell.Namespace(17);   // This PC
            foreach (var drive in drives)
            {
                try
                {
                    dynamic? item = computer.ParseName(drive.Name);
                    if (item is null) continue;
                    item.InvokeVerb("Eject");
                    count++;
                }
                catch { /* in use */ }
            }
        }
        catch { /* no shell */ }
        return count;
    }

    public static bool EmptyRecycleBin() => Native.SHEmptyRecycleBin(IntPtr.Zero, null, 0x7) == 0;

    public static void ScreenOff()
    {
        // after the click is over, or the mouse wakes it at once
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        timer.Tick += (_, _) => { timer.Stop(); Native.ScreenOff(); };
        timer.Start();
    }
}
