using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace Muna;

/// <summary>The Muna bar (linux/src/ui/munaBar.js): a top bar of Muna's for monitors (Windows has no
/// top bar at all). Left: the desktops (Muna's own for this monitor when it keeps separate desktops,
/// else Windows'); a dot switches, the free space opens task view. Middle: the capsule of this monitor,
/// or the date and time when it has none. Right: the chosen readings, the network, the sound, the
/// battery and Muna's button. It hides as Linux's bars do (never, when a window touches it, always).</summary>
public sealed class MunaBar : Window
{
    public const double BarHeight = 28;
    public Forms.Screen Screen { get; private set; }
    readonly AppState _app;
    readonly Border _root = new();
    readonly Grid _layout = new();
    readonly StackPanel _left = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) };
    readonly TextBlock _clock = Ui.Text("", 12, FontWeights.SemiBold);
    readonly StackPanel _right = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 0, 10, 0) };
    readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromSeconds(2) };
    readonly DispatcherTimer _watch = new() { Interval = TimeSpan.FromMilliseconds(150) };
    IntPtr _hwnd;
    bool _appBar, _shown = true;
    DateTime _leftAt = DateTime.MaxValue;
    int _callback;
    double _scale = 1;

    public MunaBar(AppState app, Forms.Screen screen)
    {
        _app = app;
        Screen = screen;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Title = "Muna bar";
        FontFamily = Ui.Font;
        _layout.ColumnDefinitions.Add(new ColumnDefinition());
        _layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _layout.ColumnDefinitions.Add(new ColumnDefinition());
        _layout.Children.Add(_left);
        _clock.VerticalAlignment = VerticalAlignment.Center;
        _clock.Foreground = C.Text;
        Grid.SetColumn(_clock, 1);
        _layout.Children.Add(_clock);
        Grid.SetColumn(_right, 2);
        _layout.Children.Add(_right);
        _root.Child = _layout;
        // the free space opens task view (as the free space of Linux's bar opens the overview)
        _root.MouseLeftButtonUp += (_, e) => { if (e.OriginalSource == _root || e.OriginalSource == _layout) VirtualDesktops.TaskView(); };
        Content = _root;
        SourceInitialized += (_, _) =>
        {
            _hwnd = new WindowInteropHelper(this).Handle;
            Native.AddExStyle(_hwnd, Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE);
            HwndSource.FromHwnd(_hwnd)?.AddHook(OnMessage);
            Place();
        };
        _tick.Tick += (_, _) => Draw();
        _watch.Tick += (_, _) => Watch();
        app.Desktops.Changed += Draw;
        Loaded += (_, _) => { Draw(); _tick.Start(); _watch.Start(); };
        Closed += (_, _) => { _tick.Stop(); _watch.Stop(); app.Desktops.Changed -= Draw; RemoveAppBar(); };
    }

    static string Mode => Preferences.Shared.MunaBarHide;
    int HeightPx => (int)Math.Round(BarHeight * _scale);

    /// <summary>Across the top of its monitor; with "never hide" it is an app bar, so maximised windows stay under it.</summary>
    public void Place()
    {
        if (_hwnd == IntPtr.Zero) return;
        var b = Screen.Bounds;
        _scale = Native.Scale(Native.MonitorAt(b.Left + b.Width / 2, b.Top + 1));
        var color = Preferences.ParseColor(Preferences.Shared.PanelColorHex, Colors.Black);
        _root.Background = new SolidColorBrush(Color.FromArgb((byte)Math.Round(Math.Max(0.02, Preferences.Shared.PanelOpacity) * 255), color.R, color.G, color.B));
        if (Mode == "never") AddAppBar(); else RemoveAppBar();
        Move(_shown || Mode == "never");
    }

    public void Update(Forms.Screen screen)
    {
        Screen = screen;
        Place();
        Draw();
    }

    void Move(bool shown)
    {
        _shown = shown;
        var b = Screen.Bounds;
        Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, b.Left, shown ? b.Top : b.Top - HeightPx + 1, b.Width, HeightPx, Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        // the capsule stays above the bar
        _app.Capsules.Raise();
    }

    // --- app bar --------------------------------------------------------------------------------

    [StructLayout(LayoutKind.Sequential)]
    struct APPBARDATA
    {
        public int Size;
        public IntPtr Hwnd;
        public int Callback;
        public int Edge;
        public Native.RECT Rect;
        public IntPtr Param;
    }

    [DllImport("shell32.dll")] static extern IntPtr SHAppBarMessage(int message, ref APPBARDATA data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int RegisterWindowMessage(string name);

    void AddAppBar()
    {
        var data = new APPBARDATA { Size = Marshal.SizeOf<APPBARDATA>(), Hwnd = _hwnd };
        if (!_appBar)
        {
            _callback = RegisterWindowMessage("MunaBarMessage");
            data.Callback = _callback;
            SHAppBarMessage(0, ref data);           // ABM_NEW
            _appBar = true;
        }
        var b = Screen.Bounds;
        data.Edge = 1;                              // ABE_TOP
        data.Rect = new Native.RECT { Left = b.Left, Top = b.Top, Right = b.Right, Bottom = b.Top + HeightPx };
        SHAppBarMessage(2, ref data);               // ABM_QUERYPOS
        data.Rect.Bottom = data.Rect.Top + HeightPx;
        SHAppBarMessage(3, ref data);               // ABM_SETPOS
        MunaBars.Reserved.Add(Screen.DeviceName);
    }

    void RemoveAppBar()
    {
        if (!_appBar) return;
        var data = new APPBARDATA { Size = Marshal.SizeOf<APPBARDATA>(), Hwnd = _hwnd };
        SHAppBarMessage(1, ref data);               // ABM_REMOVE
        _appBar = false;
        MunaBars.Reserved.Remove(Screen.DeviceName);
    }

    IntPtr OnMessage(IntPtr hwnd, int message, IntPtr w, IntPtr l, ref bool handled)
    {
        if (_appBar && message == _callback)
        {
            switch (w.ToInt32())
            {
                case 1: Dispatcher.BeginInvoke(Place); break;                                         // ABN_POSCHANGED
                case 2: Visibility = l != IntPtr.Zero ? Visibility.Hidden : Visibility.Visible; break;   // ABN_FULLSCREENAPP
            }
        }
        return IntPtr.Zero;
    }

    // --- hiding ------------------------------------------------------------------------------------

    /// <summary>Intellihide and always: out when the pointer pushes against the top edge, away again
    /// 0.7 s after it left; intellihide also shows it while no window touches it. Full-screen apps hide it.</summary>
    void Watch()
    {
        var b = Screen.Bounds;
        var full = Native.ForegroundIsFullScreen(b);
        var visibility = full && !_shown ? Visibility.Hidden : Visibility.Visible;
        if (Mode == "never")
        {
            if (Visibility != visibility && !_appBar) Visibility = visibility;
            return;
        }
        var p = Native.Cursor();
        var onMonitor = p.X >= b.Left && p.X < b.Right && p.Y >= b.Top && p.Y < b.Bottom;
        var atEdge = onMonitor && p.Y <= b.Top + 1;
        var onBar = onMonitor && p.Y < b.Top + HeightPx + 2 && _shown;
        var wanted = atEdge || onBar;
        if (!wanted && !full && Mode == "intellihide") wanted = !WindowTouches(b);
        if (onBar || atEdge) _leftAt = DateTime.MaxValue;
        else if (_shown && _leftAt == DateTime.MaxValue) _leftAt = DateTime.Now;
        if (wanted && !_shown) Move(true);
        else if (!wanted && _shown && (DateTime.Now - _leftAt).TotalMilliseconds > 700) Move(false);
        if (Visibility != Visibility.Visible) Visibility = Visibility.Visible;
    }

    bool WindowTouches(System.Drawing.Rectangle b)
    {
        foreach (var hwnd in Native.AppWindows())
        {
            if (Native.IsIconic(hwnd)) continue;
            Native.GetWindowThreadProcessId(hwnd, out var process);
            if (process == Environment.ProcessId) continue;
            var r = Native.VisibleFrame(hwnd);
            if (r.Left < b.Right && r.Right > b.Left && r.Top < b.Top + HeightPx && r.Bottom > b.Top) return true;
        }
        return false;
    }

    // --- what it shows --------------------------------------------------------------------------------

    void Draw()
    {
        _left.Children.Clear();
        var desktops = _app.Desktops;
        if (desktops.On)
        {
            var monitor = desktops.For(Screen.DeviceName);
            for (var i = 0; i < monitor.Count; i++)
            {
                var index = i;
                var current = i == monitor.Current;
                _left.Children.Add(Dot(current, desktops.Windows(Screen.DeviceName, i) > 0, () => desktops.Switch(Screen.DeviceName, index)));
            }
            _left.Children.Add(Ui.Box(Ui.Icon(Glyph.Add, 8, C.Secondary)).Size(18, 18).OnClick(() => desktops.Add(Screen.DeviceName), C.White(0.1)).Tip("Another desktop"));
        }
        else
        {
            var (count, current) = VirtualDesktops.State();
            for (var i = 0; i < count; i++)
            {
                var index = i;
                _left.Children.Add(Dot(i == current, true, () => VirtualDesktops.SwitchTo(index)));
            }
        }
        // the date and time where no capsule shows them
        var hasCapsule = _app.Capsules.HasCapsule(Screen.DeviceName);
        _clock.Text = hasCapsule ? "" : DateTime.Now.ToString("ddd d MMM  HH:mm", CultureInfo.CurrentCulture);
        _right.Children.Clear();
        var monitorReadings = _app.Monitor;
        foreach (var (reading, value) in Reading.Chosen(monitorReadings))
        {
            var page = reading.Page;
            var item = Ui.Box(Ui.Row(4, Ui.Text(reading.Label, 9, FontWeights.Bold, C.Secondary), Ui.Digits(value, 11, FontWeights.SemiBold)), C.Clear, 8, 6, 2)
                .OnClick(() => _app.ShowQuickPanel(page), C.White(0.1));
            item.ToolTip = reading.Long(monitorReadings);
            _right.Children.Add(item);
        }
        _right.Children.Add(BarIcon(Glyph.Network, () => _app.ShowQuickPanel("network")));
        _right.Children.Add(BarIcon(_app.Sound.Muted ? Glyph.Mute : Glyph.Volume, () => _app.ShowQuickPanel("sound")));
        if (SystemMonitor.Battery() is { HasBattery: true } battery)
            _right.Children.Add(Ui.Box(Ui.Row(3, Ui.Icon(Glyph.Battery, 11), Ui.Digits($"{battery.Percent}%", 11)), C.Clear, 8, 6, 2).OnClick(() => _app.ShowQuickPanel("system"), C.White(0.1)));
        if (hasCapsule) _right.Children.Add(Ui.Box(Ui.Digits(DateTime.Now.ToString("HH:mm", CultureInfo.CurrentCulture), 11, FontWeights.SemiBold), C.Clear, 8, 6, 2));
        _right.Children.Add(Ui.Box(Ui.Butterfly(14), C.Clear, 8, 6, 3).OnClick(() => _app.ShowQuickPanel(null), C.White(0.1)).Tip("Muna"));
    }

    static UIElement Dot(bool current, bool used, Action action)
    {
        var dot = current
            ? new Rectangle { Width = 18, Height = 7, RadiusX = 3.5, RadiusY = 3.5, Fill = Brushes.White }
            : new Rectangle { Width = 7, Height = 7, RadiusX = 3.5, RadiusY = 3.5, Fill = C.White(used ? 0.55 : 0.25) };
        return Ui.Box(dot).Size(current ? 26 : 15, 22).OnClick(action);
    }

    static UIElement BarIcon(string glyph, Action action) => Ui.Box(Ui.Icon(glyph, 12), C.Clear, 8, 7, 3).OnClick(action, C.White(0.1));
}

/// <summary>The Muna bars of the chosen monitors (Settings → System → Muna bar).</summary>
public sealed class MunaBars
{
    /// <summary>Monitors whose top a Muna bar takes (the capsule hangs over it, not below it).</summary>
    public static readonly HashSet<string> Reserved = new();
    readonly AppState _app;
    readonly List<MunaBar> _bars = new();

    public MunaBars(AppState app)
    {
        _app = app;
        Preferences.Shared.Changed += key =>
        {
            if (key is "muna-bar-screens" or "muna-bar-hide" or "panel-color" or "panel-opacity" or "capsule-screens")
                Application.Current.Dispatcher.BeginInvoke(Rebuild);
        };
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged += (_, _) => Application.Current.Dispatcher.BeginInvoke(Rebuild);
    }

    IEnumerable<Forms.Screen> Screens => Preferences.Shared.MunaBarScreens switch
    {
        "all" => Forms.Screen.AllScreens,
        "others" => Forms.Screen.AllScreens.Where(s => !s.Primary),
        _ => Enumerable.Empty<Forms.Screen>(),
    };

    public void Rebuild()
    {
        var wanted = Screens.ToList();
        foreach (var bar in _bars.Where(b => wanted.All(s => s.DeviceName != b.Screen.DeviceName)).ToList())
        {
            bar.Close();
            _bars.Remove(bar);
        }
        foreach (var screen in wanted)
        {
            var existing = _bars.FirstOrDefault(b => b.Screen.DeviceName == screen.DeviceName);
            if (existing is not null) { existing.Update(screen); continue; }
            var bar = new MunaBar(_app, screen);
            bar.Show();
            _bars.Add(bar);
        }
        _app.Capsules.Rebuild();
    }

    public void CloseAll()
    {
        foreach (var bar in _bars) bar.Close();
        _bars.Clear();
    }
}

/// <summary>Windows' taskbar hides by itself or not (Linux's "hide the top bar", for the bar Windows has).</summary>
public static class Taskbar
{
    [StructLayout(LayoutKind.Sequential)]
    struct APPBARDATA
    {
        public int Size;
        public IntPtr Hwnd;
        public int Callback;
        public int Edge;
        public Native.RECT Rect;
        public IntPtr Param;
    }

    [DllImport("shell32.dll")] static extern IntPtr SHAppBarMessage(int message, ref APPBARDATA data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string name, string? title);

    public static bool AutoHide
    {
        get
        {
            var data = new APPBARDATA { Size = Marshal.SizeOf<APPBARDATA>(), Hwnd = FindWindow("Shell_TrayWnd", null) };
            return (SHAppBarMessage(4, ref data).ToInt64() & 1) != 0;   // ABM_GETSTATE, ABS_AUTOHIDE
        }
        set
        {
            var data = new APPBARDATA { Size = Marshal.SizeOf<APPBARDATA>(), Hwnd = FindWindow("Shell_TrayWnd", null), Param = new IntPtr(value ? 1 : 2) };
            SHAppBarMessage(10, ref data);                                 // ABM_SETSTATE (ABS_ALWAYSONTOP = 2)
        }
    }
}
