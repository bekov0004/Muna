using System;
using System.Collections.Generic;
using System.Linq;
using System.Management;
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
