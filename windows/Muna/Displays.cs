using System;
using System.Collections.Generic;
using System.Linq;
using System.Management;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Forms = System.Windows.Forms;

namespace Muna;

/// <summary>Displays: each monitor's brightness (the laptop screen through Windows, other monitors
/// through DDC/CI when they speak it, else dimmed by Muna with a dark layer), and their arrangement.</summary>
public sealed class DisplaysModel : Model
{
    public enum Kind { Builtin, Ddc, Dimmed }
    public sealed record Display(string Id, string Name, System.Drawing.Rectangle Bounds, bool Primary, Kind How, double Brightness);

    public List<Display> Displays { get; private set; } = new();
    readonly Dictionary<string, Window> _dimmers = new();
    readonly Dictionary<string, double> _dimmed = new();

    /// <summary>Reads the monitors again (in the background: DDC/CI and WMI take a moment).</summary>
    public void Refresh()
    {
        var dimmed = new Dictionary<string, double>(_dimmed);
        Task.Run(() => Read(dimmed)).ContinueWith(t =>
        {
            if (t.IsFaulted) return;
            Ui(() => { Displays = t.Result; Notify(); });
        });
    }

    static List<Display> Read(Dictionary<string, double> dimmedValues)
    {
        var builtin = BuiltinBrightness();
        var list = new List<Display>();
        var first = true;
        foreach (var screen in Forms.Screen.AllScreens.OrderByDescending(s => s.Primary))
        {
            var ddc = DdcBrightness(screen);
            Kind how;
            double value;
            if (first && builtin is { } b && ddc is null) { how = Kind.Builtin; value = b; }
            else if (ddc is { } d) { how = Kind.Ddc; value = d; }
            else { how = Kind.Dimmed; value = dimmedValues.GetValueOrDefault(screen.DeviceName, 1); }
            if (how == Kind.Builtin) first = false;
            list.Add(new Display(screen.DeviceName, Name(screen, list.Count), screen.Bounds, screen.Primary, how, value));
        }
        return list;
    }

    static string Name(Forms.Screen screen, int index) =>
        $"{(screen.Primary ? "Main screen" : $"Screen {index + 1}")} · {screen.Bounds.Width}×{screen.Bounds.Height}";

    public void Set(Display display, double value)
    {
        value = Math.Clamp(value, 0, 1);
        switch (display.How)
        {
            case Kind.Builtin:
                Task.Run(() => SetBuiltin((int)Math.Round(value * 100)));
                break;
            case Kind.Ddc:
                var screen = Forms.Screen.AllScreens.FirstOrDefault(s => s.DeviceName == display.Id);
                if (screen is not null) Task.Run(() => SetDdc(screen, value));
                break;
            default:
                _dimmed[display.Id] = value;
                Dim(display, value);
                break;
        }
        Displays = Displays.Select(d => d.Id == display.Id ? d with { Brightness = value } : d).ToList();
        Notify();
    }

    /// <summary>Muna quits: the dark layers go away.</summary>
    public void Restore()
    {
        foreach (var window in _dimmers.Values) window.Close();
        _dimmers.Clear();
        _dimmed.Clear();
    }

    /// <summary>A dark, click-through layer over a monitor (at most 85% dark, so it never goes black).</summary>
    void Dim(Display display, double value)
    {
        if (value >= 0.999)
        {
            if (_dimmers.Remove(display.Id, out var old)) old.Close();
            return;
        }
        if (!_dimmers.TryGetValue(display.Id, out var window))
        {
            window = new Window
            {
                WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Black, Topmost = true, ShowInTaskbar = false,
                ShowActivated = false, Left = 0, Top = 0, Width = 10, Height = 10, Title = "Muna dimming",
            };
            var bounds = display.Bounds;
            window.SourceInitialized += (_, _) =>
            {
                var hwnd = new WindowInteropHelper(window).Handle;
                Native.AddExStyle(hwnd, Native.WS_EX_TRANSPARENT | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE | Native.WS_EX_LAYERED);
                Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, bounds.Left, bounds.Top, bounds.Width, bounds.Height, Native.SWP_NOACTIVATE);
            };
            window.Show();
            _dimmers[display.Id] = window;
        }
        window.Opacity = (1 - value) * 0.85;
    }

    // --- the laptop screen: WMI -----------------------------------------------------------------

    static double? BuiltinBrightness()
    {
        try
        {
            using var searcher = new ManagementObjectSearcher(@"root\WMI", "SELECT CurrentBrightness FROM WmiMonitorBrightness");
            foreach (ManagementObject o in searcher.Get())
                return Convert.ToDouble(o["CurrentBrightness"]) / 100;
        }
        catch { /* no built-in screen */ }
        return null;
    }

    static void SetBuiltin(int percent)
    {
        try
        {
            using var searcher = new ManagementObjectSearcher(@"root\WMI", "SELECT * FROM WmiMonitorBrightnessMethods");
            foreach (ManagementObject o in searcher.Get())
            {
                o.InvokeMethod("WmiSetBrightness", new object[] { (uint)1, (byte)Math.Clamp(percent, 0, 100) });
                break;
            }
        }
        catch { /* not allowed */ }
    }

    // --- other monitors: DDC/CI ------------------------------------------------------------------

    static IntPtr Monitor(Forms.Screen screen) => Native.MonitorAt(screen.Bounds.Left + screen.Bounds.Width / 2, screen.Bounds.Top + screen.Bounds.Height / 2);

    static double? DdcBrightness(Forms.Screen screen)
    {
        try
        {
            var monitor = Monitor(screen);
            if (!Native.GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, out var count) || count == 0) return null;
            var physical = new Native.PHYSICAL_MONITOR[count];
            if (!Native.GetPhysicalMonitorsFromHMONITOR(monitor, count, physical)) return null;
            try
            {
                if (Native.GetMonitorBrightness(physical[0].Handle, out var min, out var current, out var max) && max > min)
                    return (double)(current - min) / (max - min);
            }
            finally { Native.DestroyPhysicalMonitors(count, physical); }
        }
        catch { /* no DDC/CI */ }
        return null;
    }

    static void SetDdc(Forms.Screen screen, double value)
    {
        try
        {
            var monitor = Monitor(screen);
            if (!Native.GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, out var count) || count == 0) return;
            var physical = new Native.PHYSICAL_MONITOR[count];
            if (!Native.GetPhysicalMonitorsFromHMONITOR(monitor, count, physical)) return;
            try
            {
                if (Native.GetMonitorBrightness(physical[0].Handle, out var min, out _, out var max))
                    Native.SetMonitorBrightness(physical[0].Handle, (uint)(min + value * (max - min)));
            }
            finally { Native.DestroyPhysicalMonitors(count, physical); }
        }
        catch { }
    }
}

/// Windows' adaptive brightness (the light sensor), through powercfg on the current power plan.
public static class AutoBrightness
{
    static string Run(params string[] arguments)
    {
        try
        {
            var info = new System.Diagnostics.ProcessStartInfo("powercfg") { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
            foreach (var a in arguments) info.ArgumentList.Add(a);
            using var process = System.Diagnostics.Process.Start(info)!;
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(4000);
            return output;
        }
        catch { return ""; }
    }

    static (DateTime At, bool? Value) _cache;

    /// On when plugged in (null: the computer has no light sensor setting); read at most every 10 seconds.
    public static bool? IsOn
    {
        get
        {
            if ((DateTime.Now - _cache.At).TotalSeconds < 10) return _cache.Value;
            _cache = (DateTime.Now, Read());
            return _cache.Value;
        }
    }

    static bool? Read()
    {
        {
            var text = Run("/QUERY", "SCHEME_CURRENT", "SUB_VIDEO", "ADAPTBRIGHT");
            var match = System.Text.RegularExpressions.Regex.Match(text, @"0x0000000([01])\s*$", System.Text.RegularExpressions.RegexOptions.Multiline);
            return match.Success ? match.Groups[1].Value == "1" : null;
        }
    }

    public static void Set(bool on)
    {
        var value = on ? "1" : "0";
        Run("/SETACVALUEINDEX", "SCHEME_CURRENT", "SUB_VIDEO", "ADAPTBRIGHT", value);
        Run("/SETDCVALUEINDEX", "SCHEME_CURRENT", "SUB_VIDEO", "ADAPTBRIGHT", value);
        Run("/SETACTIVE", "SCHEME_CURRENT");
        _cache = (DateTime.Now, on);
    }
}

/// Linux's arrangement of the monitors (displays tab): which one is the main one, on which side of it
/// each other one stands, and joined, mirrored or only one (Windows' own display settings).
public static class DisplayArrangement
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        public short SpecVersion, DriverVersion, Size, DriverExtra;
        public int Fields;
        public int PositionX, PositionY, DisplayOrientation, DisplayFixedOutput;
        public short Color, Duplex, YResolution, TTOption, Collate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FormName;
        public short LogPixels;
        public int BitsPerPel, PelsWidth, PelsHeight, DisplayFlags, DisplayFrequency, ICMMethod, ICMIntent, MediaType, DitherType, Reserved1, Reserved2, PanningWidth, PanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE devMode);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string? device, ref DEVMODE mode, IntPtr hwnd, uint flags, IntPtr param);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string? device, IntPtr mode, IntPtr hwnd, uint flags, IntPtr param);
    const int CurrentSettings = -1, DmPosition = 0x20;
    const uint UpdateRegistry = 0x1, NoReset = 0x10000000, SetPrimary = 0x10;

    static bool Place(string device, int x, int y, bool primary)
    {
        var mode = new DEVMODE { Size = (short)Marshal.SizeOf<DEVMODE>() };
        if (!EnumDisplaySettings(device, CurrentSettings, ref mode)) return false;
        mode.PositionX = x;
        mode.PositionY = y;
        mode.Fields = DmPosition;
        return ChangeDisplaySettingsEx(device, ref mode, IntPtr.Zero, UpdateRegistry | NoReset | (primary ? SetPrimary : 0), IntPtr.Zero) == 0;
    }

    static void Apply() => ChangeDisplaySettingsEx(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);

    /// Makes a monitor the main one (it moves to 0,0; the others keep their places around it).
    public static void MakeMain(string device)
    {
        var screens = Forms.Screen.AllScreens;
        var chosen = screens.FirstOrDefault(s => s.DeviceName == device);
        if (chosen is null || chosen.Primary) return;
        var (dx, dy) = (chosen.Bounds.Left, chosen.Bounds.Top);
        foreach (var screen in screens.OrderBy(s => s.DeviceName == device ? 0 : 1))
            Place(screen.DeviceName, screen.Bounds.Left - dx, screen.Bounds.Top - dy, screen.DeviceName == device);
        Apply();
    }

    /// Puts a monitor on a side of the main one: "left", "right", "above", "below".
    public static void PutBeside(string device, string side)
    {
        var screens = Forms.Screen.AllScreens;
        var main = screens.FirstOrDefault(s => s.Primary);
        var screen = screens.FirstOrDefault(s => s.DeviceName == device);
        if (main is null || screen is null || screen.Primary) return;
        var m = main.Bounds;
        var (w, h) = (screen.Bounds.Width, screen.Bounds.Height);
        var (x, y) = side switch
        {
            "left" => (m.Left - w, m.Top),
            "above" => (m.Left, m.Top - h),
            "below" => (m.Left, m.Bottom),
            _ => (m.Right, m.Top),
        };
        if (Place(device, x, y, false)) Apply();
    }

    /// The side a monitor stands on, as seen from the main one.
    public static string SideOf(System.Drawing.Rectangle bounds, System.Drawing.Rectangle main)
    {
        var dx = bounds.Left + bounds.Width / 2 - (main.Left + main.Width / 2);
        var dy = bounds.Top + bounds.Height / 2 - (main.Top + main.Height / 2);
        return Math.Abs(dx) * main.Height >= Math.Abs(dy) * main.Width ? (dx < 0 ? "left" : "right") : (dy < 0 ? "above" : "below");
    }

    /// Joined (one desktop over all), mirrored, or only one screen: Windows' own projection switch.
    public static void Project(string how) => CapsuleViews.Launch(System.IO.Path.Combine(Environment.SystemDirectory, "DisplaySwitch.exe"), how switch
    {
        "mirror" => "/clone",
        "internal" => "/internal",
        "external" => "/external",
        _ => "/extend",
    });
}
