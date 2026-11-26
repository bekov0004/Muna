using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace Muna;

/// <summary>The colour under the pointer: a click anywhere copies it as #RRGGBB (Esc leaves).</summary>
public static class ColorPicker
{
    public static void Pick(Action<string> picked)
    {
        var area = Forms.SystemInformation.VirtualScreen;
        var label = Ui.Box(Ui.Row(8, new Rectangle { Width = 18, Height = 18, RadiusX = 4, RadiusY = 4, Stroke = C.White(0.4) }, Ui.Digits("#000000", 13, FontWeights.SemiBold)), C.Rgb(0, 0, 0, 0.85), 10, 10, 6);
        var canvas = new Canvas();
        canvas.Children.Add(label);
        // nearly transparent: it catches the click, and the pixel under it is read from the screen behind
        var window = new Window
        {
            WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = C.Rgb(0, 0, 0, 1 / 255.0), Topmost = true, ShowInTaskbar = false,
            Cursor = Cursors.Cross, Content = canvas, Title = "Muna colour",
        };
        window.SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(window).Handle;
            Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, area.Left, area.Top, area.Width, area.Height, 0);
        };
        string Hex(Color c) => $"#{c.R:X2}{c.G:X2}{c.B:X2}";
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(40) };
        timer.Tick += (_, _) =>
        {
            var p = Native.Cursor();
            var color = Native.PixelAt((int)p.X, (int)p.Y);
            var row = (Flex)label.Child;
            ((Rectangle)row.Children[0]).Fill = new SolidColorBrush(color);
            ((TextBlock)row.Children[1]).Text = Hex(color);
            var local = canvas.PointFromScreen(p);
            Canvas.SetLeft(label, local.X + 18);
            Canvas.SetTop(label, local.Y + 18);
        };
        window.MouseLeftButtonDown += (_, _) =>
        {
            timer.Stop();
            var p = Native.Cursor();
            window.Hide();
            var hex = Hex(Native.PixelAt((int)p.X, (int)p.Y));
            window.Close();
            ClipboardModel.SetText(hex);
            picked(hex);
        };
        window.KeyDown += (_, e) => { if (e.Key == Key.Escape) { timer.Stop(); window.Close(); } };
        window.Show();
        window.Activate();
        timer.Start();
    }
}

/// <summary>A ring of actions around the pointer (Ctrl+Alt+Space): point at one and click, or press
/// its number; Esc or a click in the middle leaves.</summary>
public sealed class RadialMenu
{
    readonly AppState _app;
    Window? _window;

    public RadialMenu(AppState app) => _app = app;

    /// <summary>What can go around the wheel (Linux's radial-actions ids).</summary>
    public static readonly (string Id, string Title, string Glyph)[] Catalog =
    {
        ("play-pause", "Play or pause", Glyph.Play), ("next", "Next track", Glyph.Next), ("prev", "Previous track", Glyph.Previous),
        ("screenshot", "Screenshot", Glyph.Screenshot), ("recording", "Screen recording", Glyph.Video), ("color", "Colour picker", Glyph.Eyedropper),
        ("downloads", "Downloads", Glyph.Download), ("command", "Search", Glyph.Search), ("clipboard", "Clipboard", Glyph.Clipboard),
        ("dark", "Dark mode", Glyph.Moon), ("night", "Night light", Glyph.Sun), ("mic", "Mute microphone", Glyph.Microphone),
        ("awake", "Keep awake", Glyph.Coffee), ("cleaning", "Cleaning mode", Glyph.Broom), ("lock", "Lock the screen", Glyph.Lock),
        ("scratchpad", "Scratchpad", Glyph.Note), ("screen-off", "Screen off", Glyph.Monitor),
    };

    Action Run(string id) => id switch
    {
        "play-pause" => () => Native.TapKey(Native.VK_MEDIA_PLAY_PAUSE),
        "next" => () => Native.TapKey(Native.VK_MEDIA_NEXT),
        "prev" => () => Native.TapKey(Native.VK_MEDIA_PREV),
        "screenshot" => QuickTools.Screenshot,
        "recording" => () => Keys.Chord(0x5B, 0x10, 0x52),          // Win+Shift+R: the Snipping Tool's recording
        "color" => () => ColorPicker.Pick(hex => _app.Capsules.Tell("Colour copied", hex, Glyph.Eyedropper, true)),
        "downloads" => DownloadsModel.OpenFolder,
        "command" => _app.Capsules.OpenCommand,
        "clipboard" => () => _app.Capsules.Open(PanelTab.Clipboard),
        "dark" => () => QuickTools.ToggleDarkMode(),
        "night" => () => SystemSwitches.SetNightLight(!(SystemSwitches.NightLight ?? false)),
        "mic" => _app.Sound.ToggleMicrophone,
        "awake" => () => { if (_app.Awake.IsOn) _app.Awake.Stop(); else _app.Awake.Start(60); },
        "cleaning" => CleaningMode.Start,
        "lock" => () => Native.LockWorkStation(),
        "scratchpad" => _app.ShowScratchpad,
        _ => QuickTools.ScreenOff,
    };

    (string Glyph, string Label, Action Run)[] Actions() => Preferences.Shared.RadialActions
        .Select(id => Catalog.FirstOrDefault(c => c.Id == id)).Where(c => c.Id is not null)
        .Select(c => (c.Glyph, c.Id == "awake" && _app.Awake.IsOn ? "Sleep" : c.Title, Run(c.Id))).ToArray();

    public void Toggle()
    {
        if (_window is not null) { Close(); return; }
        var actions = Actions();
        const double size = 300, radius = 105, button = 64;
        var canvas = new Canvas { Width = size, Height = size };
        canvas.Children.Add(new Ellipse { Width = size, Height = size, Fill = C.Rgb(0, 0, 0, 0.82), Stroke = C.White(0.12), StrokeThickness = 1 });
        var centre = Ui.Box(Ui.Butterfly(22), C.White(0.08), 28).Size(56, 56);
        Canvas.SetLeft(centre, size / 2 - 28);
        Canvas.SetTop(centre, size / 2 - 28);
        canvas.Children.Add(centre.OnClick(Close));
        for (var i = 0; i < actions.Length; i++)
        {
            var (glyph, label, run) = actions[i];
            var angle = -Math.PI / 2 + i * 2 * Math.PI / actions.Length;
            var column = Ui.Column(3, Ui.Icon(glyph, 18), Ui.Text(label, 10, color: C.Secondary).Align(HorizontalAlignment.Center));
            column.Center = true;
            var tile = Ui.Box(column.Align(HorizontalAlignment.Center, VerticalAlignment.Center), C.White(0.06), button / 2).Size(button, button);
            Canvas.SetLeft(tile, size / 2 + Math.Cos(angle) * radius - button / 2);
            Canvas.SetTop(tile, size / 2 + Math.Sin(angle) * radius - button / 2);
            var action = run;
            canvas.Children.Add(tile.OnClick(() => { Close(); action(); }, C.Rgb(77, 141, 255, 0.45)));
        }
        TextElement.SetForeground(canvas, C.Text);
        var window = new Window
        {
            WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent, Topmost = true, ShowInTaskbar = false,
            Width = size, Height = size, Content = canvas, Title = "Muna radial menu", FontFamily = Ui.Font,
        };
        var pointer = Native.Cursor();
        window.SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(window).Handle;
            var scale = Native.Scale(Native.MonitorAt((int)pointer.X, (int)pointer.Y));
            Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, (int)(pointer.X - size * scale / 2), (int)(pointer.Y - size * scale / 2), 0, 0, Native.SWP_NOSIZE);
        };
        window.Deactivated += (_, _) => Close();
        window.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) Close();
            var index = e.Key - Key.D1;
            if (index >= 0 && index < actions.Length) { Close(); actions[index].Run(); }
        };
        _window = window;
        window.Show();
        window.Activate();
    }

    void Close()
    {
        var window = _window;
        _window = null;
        window?.Close();
    }
}

/// <summary>Cleaning mode, as on Linux: every screen goes black and the keyboard and mouse do nothing,
/// so they can be wiped. Hold Esc for 1.5 s to leave; it ends by itself after 60 s.</summary>
public static class CleaningMode
{
    static readonly List<Window> Windows = new();
    static IntPtr _keyboardHook, _mouseHook;
    static Native.HookProc? _keyboardProc, _mouseProc;
    static DispatcherTimer? _tick;
    static DateTime _endsAt, _escapeSince;
    static bool _escapeDown;
    public static bool IsOn { get; private set; }

    public static void Start()
    {
        if (IsOn) return;
        IsOn = true;
        _endsAt = DateTime.Now.AddSeconds(60);
        // Settings → Cleaning Mode → Keep screen visible: a small sign in a corner instead of black
        var visible = Preferences.Shared.Bool("cleaning-visible");
        foreach (var screen in Forms.Screen.AllScreens)
        {
            var label = Ui.Text("", 16, color: C.White(0.6));
            label.HorizontalAlignment = HorizontalAlignment.Center;
            label.VerticalAlignment = VerticalAlignment.Center;
            label.TextAlignment = TextAlignment.Center;
            var window = new Window
            {
                WindowStyle = WindowStyle.None, Background = Brushes.Black, Topmost = true, ShowInTaskbar = false, ResizeMode = ResizeMode.NoResize,
                Content = new Grid { Children = { Ui.Column(12, Ui.Butterfly(40).Align(HorizontalAlignment.Center), label).Align(HorizontalAlignment.Center, VerticalAlignment.Center) } },
                Cursor = Cursors.None, Title = "Muna cleaning", Tag = label,
            };
            var bounds = screen.Bounds;
            if (visible)
            {
                bounds = new System.Drawing.Rectangle(screen.WorkingArea.Right - 420, screen.WorkingArea.Bottom - 120, 400, 100);
                window.AllowsTransparency = true;
                window.Background = C.Rgb(0, 0, 0, 0.8);
            }
            window.SourceInitialized += (_, _) =>
            {
                var hwnd = new WindowInteropHelper(window).Handle;
                Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, bounds.Left, bounds.Top, bounds.Width, bounds.Height, 0);
            };
            window.Show();
            Windows.Add(window);
        }
        // the keys and the mouse are swallowed (a low-level hook; Ctrl+Alt+Del still works)
        var module = Native.GetModuleHandle(null);
        _keyboardProc = Keyboard;
        _mouseProc = (code, w, l) => code >= 0 ? new IntPtr(1) : Native.CallNextHookEx(_mouseHook, code, w, l);
        _keyboardHook = Native.SetWindowsHookEx(13, _keyboardProc, module, 0);
        _mouseHook = Native.SetWindowsHookEx(14, _mouseProc, module, 0);
        _tick = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        _tick.Tick += (_, _) => Tick();
        _tick.Start();
        Tick();
    }

    static IntPtr Keyboard(int code, IntPtr w, IntPtr l)
    {
        if (code < 0) return Native.CallNextHookEx(_keyboardHook, code, w, l);
        var vk = Marshal.ReadInt32(l);
        var down = w.ToInt32() is 0x100 or 0x104;
        if (vk == 0x1B)
        {
            if (down && !_escapeDown) _escapeSince = DateTime.Now;
            _escapeDown = down;
        }
        return new IntPtr(1);
    }

    static void Tick()
    {
        var left = (int)Math.Ceiling((_endsAt - DateTime.Now).TotalSeconds);
        var held = _escapeDown ? (DateTime.Now - _escapeSince).TotalSeconds : 0;
        if (left <= 0 || held >= 1.5) { Stop(); return; }
        foreach (var window in Windows)
            if (window.Tag is TextBlock label)
                label.Text = $"Cleaning mode: the keyboard and the mouse do nothing\nHold Esc to leave · ends by itself in {left} s";
    }

    public static void Stop()
    {
        if (!IsOn) return;
        IsOn = false;
        _tick?.Stop();
        if (_keyboardHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_keyboardHook);
        if (_mouseHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_mouseHook);
        _keyboardHook = _mouseHook = IntPtr.Zero;
        _escapeDown = false;
        foreach (var window in Windows) window.Close();
        Windows.Clear();
    }
}

/// <summary>The scratchpad window: one long note, saved as you type (scratchpad.json).</summary>
public sealed class ScratchpadWindow : DarkWindow
{
    public ScratchpadWindow(ScratchpadModel model)
    {
        Title = "Scratchpad";
        Width = 560;
        Height = 520;
        MinWidth = 320;
        MinHeight = 240;
        var box = new TextBox
        {
            Text = model.Text, AcceptsReturn = true, AcceptsTab = true, TextWrapping = TextWrapping.Wrap, Background = C.WinBackground, Foreground = C.WinText,
            CaretBrush = C.WinText, BorderThickness = new Thickness(0), FontFamily = Ui.Font, FontSize = 14, Padding = new Thickness(18),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, SelectionBrush = C.WinAccent,
        };
        var count = Ui.Text("", 11, color: C.WinSecondary);
        void Count() => count.Text = $"{box.Text.Length} characters";
        box.TextChanged += (_, _) => { model.Text = box.Text; Count(); };
        Count();
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition());
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.Children.Add(box);
        var footer = Ui.Row(8, count, Ui.Spacer(), DarkWindow.Button("Copy all", () => ClipboardModel.SetText(box.Text)));
        footer.Margin = new Thickness(18, 8, 18, 12);
        Grid.SetRow(footer, 1);
        grid.Children.Add(footer);
        Content = grid;
        Deactivated += (_, _) => model.Save();
        Activated += (_, _) => box.Focus();
    }
}
