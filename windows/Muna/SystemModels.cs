using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Muna.Core;
using Forms = System.Windows.Forms;

namespace Muna;

/// <summary>The processor, memory, disk, battery, network and uptime, read every second while the
/// quick panel shows them (with a minute of history for the graphs).</summary>
public sealed class SystemMonitor : Model
{
    public double Cpu { get; private set; }
    public ulong MemoryUsed { get; private set; }
    public ulong MemoryTotal { get; private set; }
    public int MemoryPercent => MemoryTotal > 0 ? (int)(100.0 * MemoryUsed / MemoryTotal) : 0;
    public List<double> CpuHistory { get; } = new();
    public List<double> MemoryHistory { get; } = new();
    public double DownPerSecond { get; private set; }
    public double UpPerSecond { get; private set; }
    public List<double> DownHistory { get; } = new();
    public string NetworkName { get; private set; } = "";
    /// <summary>The temperature of the hottest ACPI thermal zone in °C (Windows' performance counters,
    /// no administrator rights), null when the computer reports none.</summary>
    public double? Temperature { get; private set; }
    /// <summary>The graphics card's 3D engines in use (0–1), null when unknown.</summary>
    public double? Gpu { get; private set; }
    /// <summary>Bytes read and written per second on all disks.</summary>
    public double? DiskBytesPerSecond { get; private set; }
    /// <summary>Watts the battery gives (discharging) or takes, null when unknown.</summary>
    public double? PowerWatts { get; private set; }
    public List<double> TemperatureHistory { get; } = new();
    DateTime _extrasAt;
    bool _extrasBusy;
    public string Address { get; private set; } = "";
    long _idle, _kernel, _user, _received, _sent;
    DateTime _netAt;
    int _watchers;
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };

    public SystemMonitor() => _timer.Tick += (_, _) => { Sample(); Notify(); };

    public bool Watched => _watchers > 0;

    public void Watch()
    {
        if (_watchers++ == 0) { Sample(); _timer.Start(); }
    }

    public void Unwatch()
    {
        if (--_watchers <= 0) { _watchers = 0; _timer.Stop(); }
    }

    public void Sample()
    {
        if (Native.GetSystemTimes(out var idle, out var kernel, out var user))
        {
            long di = idle - _idle, dk = kernel - _kernel, du = user - _user;
            if (_kernel != 0 && dk + du > 0) Cpu = Math.Clamp(1 - (double)di / (dk + du), 0, 1);
            (_idle, _kernel, _user) = (idle, kernel, user);
        }
        var memory = new Native.MEMORYSTATUSEX { Length = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.MEMORYSTATUSEX>() };
        if (Native.GlobalMemoryStatusEx(ref memory))
        {
            MemoryTotal = memory.TotalPhys;
            MemoryUsed = memory.TotalPhys - memory.AvailPhys;
        }
        Push(CpuHistory, Cpu);
        Push(MemoryHistory, MemoryTotal > 0 ? (double)MemoryUsed / MemoryTotal : 0);
        SampleNetwork();
        SampleExtras();
    }

    /// <summary>Temperature, graphics, disk activity and power come from WMI, which takes a moment:
    /// read in the background every 3 seconds.</summary>
    void SampleExtras()
    {
        if (_extrasBusy || (DateTime.Now - _extrasAt).TotalSeconds < 3) return;
        _extrasBusy = true;
        _extrasAt = DateTime.Now;
        Task.Run(() => (Wmi.Temperature(), Wmi.Gpu(), Wmi.DiskBytes(), Wmi.PowerWatts())).ContinueWith(t => Ui(() =>
        {
            _extrasBusy = false;
            if (t.IsFaulted) return;
            (Temperature, Gpu, DiskBytesPerSecond, PowerWatts) = t.Result;
            if (Temperature is { } c) Push(TemperatureHistory, c);
        }));
    }

    /// <summary>"42 °C" or "108 °F" (Settings → System: the unit, as Linux's temp-unit).</summary>
    public static string TemperatureText(double celsius) =>
        Preferences.Shared.TemperatureUnit == "F" ? $"{celsius * 9 / 5 + 32:0} °F" : $"{celsius:0} °C";

    void SampleNetwork()
    {
        try
        {
            var nic = NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType is not (NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel))
                .OrderByDescending(n => n.GetIPProperties().GatewayAddresses.Count)
                .FirstOrDefault();
            if (nic is null) { NetworkName = "Offline"; Address = ""; return; }
            NetworkName = nic.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 ? $"Wi-Fi · {nic.Name}" : nic.Name;
            Address = nic.GetIPProperties().UnicastAddresses.FirstOrDefault(a => a.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)?.Address.ToString() ?? "";
            var stats = nic.GetIPStatistics();
            var now = DateTime.Now;
            if (_netAt != default)
            {
                var seconds = Math.Max(0.1, (now - _netAt).TotalSeconds);
                DownPerSecond = Math.Max(0, (stats.BytesReceived - _received) / seconds);
                UpPerSecond = Math.Max(0, (stats.BytesSent - _sent) / seconds);
            }
            (_received, _sent, _netAt) = (stats.BytesReceived, stats.BytesSent, now);
            Push(DownHistory, DownPerSecond);
        }
        catch { /* the network changed under us */ }
    }

    static void Push(List<double> list, double value)
    {
        list.Add(value);
        if (list.Count > 60) list.RemoveAt(0);
    }

    public static (int Percent, bool Charging, bool HasBattery, int MinutesLeft) Battery()
    {
        if (!Native.GetSystemPowerStatus(out var s)) return (0, false, false, -1);
        var has = s.BatteryFlag != 128 && s.BatteryLifePercent != 255;
        return (s.BatteryLifePercent == 255 ? 0 : s.BatteryLifePercent, s.ACLineStatus == 1, has, s.BatteryLifeTime > 0 ? s.BatteryLifeTime / 60 : -1);
    }

    public static TimeSpan Uptime => TimeSpan.FromMilliseconds(Native.GetTickCount64());

    public static (long Free, long Total) SystemDisk()
    {
        try
        {
            var drive = new DriveInfo(Path.GetPathRoot(Environment.SystemDirectory) ?? "C:\\");
            return (drive.AvailableFreeSpace, drive.TotalSize);
        }
        catch { return (0, 0); }
    }
}

/// <summary>WMI readings an ordinary user may make.</summary>
static class Wmi
{
    static IEnumerable<System.Management.ManagementBaseObject> Query(string scope, string query)
    {
        using var searcher = new System.Management.ManagementObjectSearcher(scope, query);
        foreach (var o in searcher.Get()) yield return o;
    }

    public static double? Temperature()
    {
        try
        {
            // tenths of kelvin in MSAcpi (admin only); kelvin in the performance counter (anyone)
            double? best = null;
            foreach (var o in Query(@"root\cimv2", "SELECT Temperature FROM Win32_PerfFormattedData_Counters_ThermalZoneInformation"))
            {
                var kelvin = Convert.ToDouble(o["Temperature"]);
                if (kelvin < 200 || kelvin > 400) continue;
                best = Math.Max(best ?? double.MinValue, kelvin - 273.15);
            }
            return best;
        }
        catch { return null; }
    }

    public static double? Gpu()
    {
        try
        {
            double sum = 0;
            var any = false;
            foreach (var o in Query(@"root\cimv2", "SELECT Name, UtilizationPercentage FROM Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine"))
            {
                if (o["Name"] is not string name || !name.Contains("engtype_3D", StringComparison.OrdinalIgnoreCase)) continue;
                sum += Convert.ToDouble(o["UtilizationPercentage"]);
                any = true;
            }
            return any ? Math.Clamp(sum / 100, 0, 1) : null;
        }
        catch { return null; }
    }

    public static double? DiskBytes()
    {
        try
        {
            foreach (var o in Query(@"root\cimv2", "SELECT DiskBytesPersec FROM Win32_PerfFormattedData_PerfDisk_PhysicalDisk WHERE Name='_Total'"))
                return Convert.ToDouble(o["DiskBytesPersec"]);
        }
        catch { /* no counters */ }
        return null;
    }

    public static double? PowerWatts()
    {
        try
        {
            foreach (var o in Query(@"root\WMI", "SELECT DischargeRate, ChargeRate FROM BatteryStatus"))
            {
                var discharge = Convert.ToDouble(o["DischargeRate"]);
                var charge = Convert.ToDouble(o["ChargeRate"]);
                var mw = discharge > 0 ? discharge : charge;
                if (mw > 0) return mw / 1000;
            }
        }
        catch { /* not allowed or no battery */ }
        return null;
    }
}

/// <summary>Keep awake: the computer (and, when chosen, the screen) does not sleep, for a while or until off.</summary>
public sealed class KeepAwake : Model
{
    public bool IsOn { get; private set; }
    public bool KeepScreen { get; private set; } = true;
    public DateTime? Until { get; private set; }
    readonly DispatcherTimer _end = new();

    public KeepAwake() => _end.Tick += (_, _) => Stop();

    public void Start(int? minutes, bool screen = true)
    {
        KeepScreen = screen;
        Native.SetThreadExecutionState(Native.ES_CONTINUOUS | Native.ES_SYSTEM_REQUIRED | (screen ? Native.ES_DISPLAY_REQUIRED : 0));
        IsOn = true;
        _end.Stop();
        Until = minutes is int m ? DateTime.Now.AddMinutes(m) : null;
        if (minutes is int n) { _end.Interval = TimeSpan.FromMinutes(n); _end.Start(); }
        Notify();
    }

    public void Stop()
    {
        _end.Stop();
        Native.SetThreadExecutionState(Native.ES_CONTINUOUS);
        IsOn = false;
        Until = null;
        Notify();
    }
}

/// <summary>Focus: the stopwatch and the focus timer (focus.json, as on Linux and the Mac).</summary>
public sealed class FocusModel : Model
{
    readonly FocusFile _file = new();
    readonly DispatcherTimer _ticker = new() { Interval = TimeSpan.FromMilliseconds(500) };
    readonly DispatcherTimer _phase = new();
    public FocusConfig Editing { get; set; }
    public event Action<string, string>? PhaseEnded;

    public FocusModel()
    {
        Editing = new FocusConfig { Work = _file.Pomo.Config.Work, Short = _file.Pomo.Config.Short, Long = _file.Pomo.Config.Long, Every = _file.Pomo.Config.Every };
        _ticker.Tick += (_, _) => Notify();
        _phase.Tick += (_, _) => { _phase.Stop(); Advance(true); };
        if (_file.Pomo.State == "running") Arm();
        UpdateTicker();
    }

    static double Now => Json.NowMs();
    public FocusStopwatch Stopwatch => _file.Stopwatch;
    public Pomodoro Pomo => _file.Pomo;

    void Save()
    {
        _file.Save();
        UpdateTicker();
        Notify();
    }

    void UpdateTicker()
    {
        if (Stopwatch.State == "running" || Pomo.State == "running") _ticker.Start(); else _ticker.Stop();
    }

    public double StopwatchMs => Stopwatch.Elapsed + (Stopwatch.State == "running" ? Now - Stopwatch.Since : 0);

    public void StopwatchStart()
    {
        if (Stopwatch.State == "running") return;
        Stopwatch.State = "running";
        Stopwatch.Since = Now;
        Save();
    }

    public void StopwatchPause()
    {
        if (Stopwatch.State != "running") return;
        Stopwatch.Elapsed += Now - Stopwatch.Since;
        Stopwatch.State = "paused";
        Save();
    }

    public void StopwatchLap()
    {
        if (Stopwatch.State != "running") return;
        Stopwatch.Laps.Add(StopwatchMs);
        if (Stopwatch.Laps.Count > 50) Stopwatch.Laps.RemoveAt(0);
        Save();
    }

    public void StopwatchReset()
    {
        Stopwatch.State = "idle";
        Stopwatch.Elapsed = 0;
        Stopwatch.Since = 0;
        Stopwatch.Laps.Clear();
        Save();
    }

    public double PomoRemainingMs => Pomo.State == "running" ? Math.Max(0, Pomo.EndAt - Now) : Pomo.Remaining;

    public double PomoProgress
    {
        get
        {
            var total = Pomo.Config.Minutes(Pomo.Phase) * 60_000;
            return total > 0 ? Math.Clamp(1 - PomoRemainingMs / total, 0, 1) : 0;
        }
    }

    public void PomoStart()
    {
        if (Pomo.State == "running") return;
        if (Pomo.State == "paused")
        {
            Pomo.EndAt = Now + Pomo.Remaining;
        }
        else
        {
            Pomo.Config = Editing.Clean();
            Pomo.Phase = "work";
            Pomo.Round = 1;
            Pomo.Done = 0;
            Pomo.Remaining = Pomo.Config.Minutes("work") * 60_000;
            Pomo.EndAt = Now + Pomo.Remaining;
        }
        Pomo.State = "running";
        Arm();
        Save();
    }

    public void PomoPause()
    {
        if (Pomo.State != "running") return;
        Pomo.Remaining = Math.Max(0, Pomo.EndAt - Now);
        Pomo.State = "paused";
        _phase.Stop();
        Save();
    }

    public void PomoSkip()
    {
        if (Pomo.State == "idle") return;
        Advance(false);
    }

    public void PomoReset()
    {
        _phase.Stop();
        _file.ResetPomo();
        Save();
    }

    public void ApplySettings()
    {
        if (Pomo.State != "idle") return;
        Editing = Editing.Clean();
        Pomo.Config = Editing;
        Pomo.Remaining = Pomo.Config.Minutes("work") * 60_000;
        Save();
    }

    void Arm()
    {
        _phase.Stop();
        _phase.Interval = TimeSpan.FromMilliseconds(Math.Max(50, Pomo.EndAt - Now));
        _phase.Start();
    }

    void Advance(bool announce)
    {
        var next = _file.Advance(Now);
        Arm();
        Save();
        if (!announce) return;
        var minutes = (int)Pomo.Config.Minutes(next);
        var title = next == "work" ? "Back to work" : next == "long" ? "Long break" : "Short break";
        var details = next == "work" ? $"Round {Pomo.Round} · {minutes} min" : $"Work done · {minutes} min break";
        PhaseEnded?.Invoke(title, details);
    }

    public static string PhaseName(string phase) => phase == "work" ? "Focus" : phase == "long" ? "Long break" : "Short break";

    public static string Clock(double ms, bool tenths = false)
    {
        var total = (long)(ms / 1000);
        var text = total >= 3600 ? $"{total / 3600}:{total / 60 % 60:00}:{total % 60:00}" : $"{total / 60:00}:{total % 60:00}";
        return tenths ? $"{text}.{(long)(ms / 100) % 10}" : text;
    }
}

/// <summary>Reminders: a text at a time today (or tomorrow); a card and a sound when it comes.</summary>
public sealed class RemindersModel : Model
{
    readonly RemindersStore _store = new();
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(10) };
    public List<Reminder> Reminders => _store.Reminders;
    public event Action<string>? Due;

    public void Start()
    {
        _timer.Tick += (_, _) => Check();
        _timer.Start();
        Check();
    }

    void Check()
    {
        var due = _store.TakeDue(DateTime.Now);
        foreach (var reminder in due) Due?.Invoke(reminder.Text);
        if (due.Count > 0) Notify();
    }

    public string? Add(string text, int hour, int minute)
    {
        try
        {
            _store.Add(text, RemindersStore.NextAt(hour, minute, DateTime.Now));
            Notify();
            return null;
        }
        catch (ArgumentException e)
        {
            return e.Message;
        }
    }

    public void AddIn(string text, int minutes)
    {
        try { _store.Add(text, DateTime.Now.AddMinutes(minutes)); } catch { return; }
        Notify();
    }

    public void Remove(Reminder reminder) { _store.Remove(reminder.Id); Notify(); }
}

/// <summary>The Downloads folder: the files coming in (still growing), the last ones done.</summary>
public sealed class DownloadsModel : Model
{
    public sealed record Item(string Path, long Size, bool Partial, DateTime Modified);

    public List<Item> Recent { get; private set; } = new();
    public List<Item> Active { get; private set; } = new();
    public event Action<string>? Finished;
    FileSystemWatcher? _watcher;
    readonly DispatcherTimer _scan = new() { Interval = TimeSpan.FromSeconds(1) };
    readonly HashSet<string> _known = new(StringComparer.OrdinalIgnoreCase);
    Dictionary<string, long> _lastSizes = new(StringComparer.OrdinalIgnoreCase);
    bool _started;

    public static string Folder => Preferences.Downloads;

    public static bool IsPartial(string path)
    {
        var ext = System.IO.Path.GetExtension(path).ToLowerInvariant();
        return ext is ".crdownload" or ".part" or ".partial" or ".download" or ".tmp" or ".opdownload" or ".!ut";
    }

    public void Start()
    {
        if (!Directory.Exists(Folder)) return;
        foreach (var file in Directory.EnumerateFiles(Folder)) _known.Add(file);
        _watcher = new FileSystemWatcher(Folder) { EnableRaisingEvents = true, IncludeSubdirectories = false };
        _watcher.Created += (_, _) => Ui(Kick);
        _watcher.Renamed += (_, _) => Ui(Kick);
        _watcher.Changed += (_, _) => Ui(Kick);
        _scan.Tick += (_, _) => Scan();
        _started = true;
        Scan();
    }

    void Kick()
    {
        if (!_scan.IsEnabled) _scan.Start();
    }

    void Scan()
    {
        if (!_started) return;
        List<FileInfo> files;
        try { files = new DirectoryInfo(Folder).EnumerateFiles().Where(f => (f.Attributes & FileAttributes.Hidden) == 0).ToList(); }
        catch { return; }
        var sizes = files.ToDictionary(f => f.FullName, f => f.Length, StringComparer.OrdinalIgnoreCase);
        Active = files.Where(f => IsPartial(f.FullName)).Select(f => new Item(f.FullName, f.Length, true, f.LastWriteTime)).ToList();
        Recent = files.Where(f => !IsPartial(f.FullName)).OrderByDescending(f => f.LastWriteTime).Take(8)
            .Select(f => new Item(f.FullName, f.Length, false, f.LastWriteTime)).ToList();
        foreach (var f in files.Where(f => !IsPartial(f.FullName) && !_known.Contains(f.FullName)))
        {
            // a new file whose size stopped changing is done
            if (_lastSizes.TryGetValue(f.FullName, out var before) && before == f.Length && f.Length > 0)
            {
                _known.Add(f.FullName);
                Finished?.Invoke(f.FullName);
            }
        }
        _lastSizes = sizes;
        if (Active.Count == 0 && files.All(f => IsPartial(f.FullName) || _known.Contains(f.FullName))) _scan.Stop();
        Notify();
    }

    public void Refresh() => Scan();
    public static void Reveal(string path) { try { Process.Start("explorer.exe", $"/select,\"{path}\""); } catch { } }
    public static void OpenFolder() => CapsuleViews.Launch(Folder);
}

/// <summary>The scratchpad: one long note in its own window, saved half a second after typing stops.</summary>
public sealed class ScratchpadModel
{
    readonly ScratchpadStore _store = new();
    readonly DispatcherTimer _save = new() { Interval = TimeSpan.FromMilliseconds(500) };
    string _text;

    public ScratchpadModel()
    {
        _text = _store.Text;
        _save.Tick += (_, _) => Save();
    }

    public string Text
    {
        get => _text;
        set
        {
            _text = value;
            _save.Stop();
            _save.Start();
        }
    }

    public void Save()
    {
        _save.Stop();
        if (_text != _store.Text) _store.SetText(_text);
    }
}

/// <summary>Window snapping: halves, quarters, thirds, maximise, centre, next monitor, for the window
/// that was in front when the quick panel opened.</summary>
public sealed class WindowsModel : Model
{
    public IntPtr Target { get; set; }
    public string TargetTitle => Target == IntPtr.Zero ? "" : Native.WindowTitle(Target);
    public string? Message { get; private set; }

    public static readonly (string Id, string Label)[] Layouts =
    {
        ("left", "Left half"), ("right", "Right half"), ("top", "Top half"), ("bottom", "Bottom half"),
        ("tl", "Top left"), ("tr", "Top right"), ("bl", "Bottom left"), ("br", "Bottom right"),
        ("third1", "First third"), ("third2", "Middle third"), ("third3", "Last third"), ("twothirds", "Two thirds"),
        ("max", "Maximise"), ("center", "Centre"), ("next", "Next screen"), ("min", "Minimise"),
    };

    /// <summary>Remembers the window in front (not Muna's own).</summary>
    public void Remember()
    {
        var hwnd = Native.GetForegroundWindow();
        Native.GetWindowThreadProcessId(hwnd, out var process);
        if (hwnd != IntPtr.Zero && process != Environment.ProcessId) Target = hwnd;
    }

    public void Apply(string layout)
    {
        var hwnd = Target;
        if (hwnd == IntPtr.Zero || !Native.IsWindowVisible(hwnd))
        {
            Message = "Click the window first, then open the quick panel";
            Notify();
            return;
        }
        var frame = Native.VisibleFrame(hwnd);
        var screen = Forms.Screen.FromHandle(hwnd);
        var a = screen.WorkingArea;
        if (layout == "max") { Native.ShowWindow(hwnd, 3); Done(hwnd); return; }
        if (layout == "min") { Native.ShowWindow(hwnd, 6); Message = null; Notify(); return; }
        if (layout == "next")
        {
            var screens = Forms.Screen.AllScreens;
            var next = screens[(Array.IndexOf(screens, screens.First(s => s.DeviceName == screen.DeviceName)) + 1) % screens.Length].WorkingArea;
            double sx = (double)(frame.Left - a.Left) / a.Width, sy = (double)(frame.Top - a.Top) / a.Height;
            int w = Math.Min(frame.Width, next.Width), h = Math.Min(frame.Height, next.Height);
            Native.PlaceWindow(hwnd, next.Left + (int)(sx * next.Width), next.Top + (int)(sy * next.Height), w, h);
            Done(hwnd);
            return;
        }
        int hw = a.Width / 2, hh = a.Height / 2, third = a.Width / 3;
        var rect = layout switch
        {
            "left" => (a.Left, a.Top, hw, a.Height),
            "right" => (a.Left + hw, a.Top, a.Width - hw, a.Height),
            "top" => (a.Left, a.Top, a.Width, hh),
            "bottom" => (a.Left, a.Top + hh, a.Width, a.Height - hh),
            "tl" => (a.Left, a.Top, hw, hh),
            "tr" => (a.Left + hw, a.Top, a.Width - hw, hh),
            "bl" => (a.Left, a.Top + hh, hw, a.Height - hh),
            "br" => (a.Left + hw, a.Top + hh, a.Width - hw, a.Height - hh),
            "third1" => (a.Left, a.Top, third, a.Height),
            "third2" => (a.Left + third, a.Top, third, a.Height),
            "third3" => (a.Left + 2 * third, a.Top, a.Width - 2 * third, a.Height),
            "twothirds" => (a.Left, a.Top, 2 * third, a.Height),
            _ => (a.Left + (a.Width - Math.Min(frame.Width, a.Width)) / 2, a.Top + (a.Height - Math.Min(frame.Height, a.Height)) / 2,
                  Math.Min(frame.Width, a.Width), Math.Min(frame.Height, a.Height)),
        };
        Native.PlaceWindow(hwnd, rect.Item1, rect.Item2, rect.Item3, rect.Item4);
        Done(hwnd);
    }

    void Done(IntPtr hwnd)
    {
        Native.SetForegroundWindow(hwnd);
        Message = null;
        Notify();
    }
}

/// <summary>An Android phone over adb (Linux's phone card without its helper): the phones, the
/// battery, the screen as a picture every second, taps, swipes, keys and typing.</summary>
public sealed class PhoneModel : Model
{
    public string? Adb { get; } = PhoneAdb.FindAdb();
    public List<PhoneDevice> Devices { get; private set; } = new();
    public string? Serial { get; set; }
    public (int Percent, bool Charging)? Battery { get; private set; }
    public BitmapSource? Screen { get; private set; }
    public string Draft { get; set; } = "";
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    int _watchers, _ticks;
    bool _busy;

    public PhoneModel() => _timer.Tick += (_, _) => Tick();

    // --- pairing over Wi-Fi (Android 11+: Wireless debugging → Pair with QR code) -------------------

    /// <summary>A pairing in progress: the QR text, and "waiting", "pairing", "connecting" or "failed".</summary>
    public sealed record PairingState(string Text, string Status, string Message);
    public PairingState? Pairing { get; private set; }
    string _pairName = "", _pairPassword = "", _pairHost = "";
    DateTime _pairSince;
    readonly HashSet<string> _pairTried = new();
    bool _pairBusy;

    static string Random(string alphabet, int length) =>
        new(Enumerable.Range(0, length).Select(_ => alphabet[System.Security.Cryptography.RandomNumberGenerator.GetInt32(alphabet.Length)]).ToArray());

    /// <summary>Shows a QR code for the phone to scan (as Linux): adb finds the phone by its name, pairs with the password, connects.</summary>
    public void StartPairing()
    {
        if (Adb is null) return;
        _pairName = $"muna-{Random("abcdefghjkmnpqrstuvwxyz23456789", 5)}";
        _pairPassword = Random("0123456789", 6);
        _pairSince = DateTime.Now;
        _pairTried.Clear();
        Pairing = new PairingState($"WIFI:T:ADB;S:{_pairName};P:{_pairPassword};;", "waiting", "");
        Notify();
    }

    public void CancelPairing()
    {
        Pairing = null;
        Notify();
    }

    void SetPairing(string status, string message)
    {
        if (Pairing is null) return;
        Pairing = Pairing with { Status = status, Message = message };
        Notify();
    }

    void AdvancePairing()
    {
        if (Pairing is null || _pairBusy || Pairing.Status is not ("waiting" or "connecting")) return;
        if ((DateTime.Now - _pairSince).TotalMinutes > 3) { SetPairing("failed", "Time is up. Try again."); return; }
        _pairBusy = true;
        var status = Pairing.Status;
        Task.Run(() =>
        {
            var services = PhoneAdb.ParseMdns(Text("mdns", "services"));
            if (status == "waiting")
            {
                var entry = services.FirstOrDefault(s => s.Type == "pairing" && s.Name == _pairName);
                if (entry.Address is null || !_pairTried.Add(entry.Address)) return ("", "");
                _pairHost = entry.Address.Split(':')[0];
                Ui(() => SetPairing("pairing", "Pairing…"));
                var result = Text("pair", entry.Address, _pairPassword);
                if (!result.Contains("Successfully paired", StringComparison.OrdinalIgnoreCase))
                    return ("failed", result.Trim().Split('\n')[0] is { Length: > 0 } line ? line : "Pairing failed");
                return ("connecting", "Paired. Connecting…");
            }
            var connect = services.FirstOrDefault(s => s.Type == "connect" && s.Address.StartsWith(_pairHost + ":"));
            if (connect.Address is null) return ("", "");
            var answer = Text("connect", connect.Address);
            if (!answer.Contains("connected to", StringComparison.OrdinalIgnoreCase))
                return ("failed", answer.Trim().Split('\n')[0] is { Length: > 0 } line ? line : "Could not connect");
            Serial = connect.Address;
            return ("done", "");
        }).ContinueWith(t => Ui(() =>
        {
            _pairBusy = false;
            if (t.IsFaulted) return;
            var (next, message) = t.Result;
            if (next == "done") { Pairing = null; _ticks = 0; Notify(); }
            else if (next.Length > 0) SetPairing(next, message);
        }));
    }

    public PhoneDevice? Current => Devices.FirstOrDefault(d => d.Serial == Serial && d.Ready) ?? Devices.FirstOrDefault(d => d.Ready);

    public void Watch()
    {
        if (_watchers++ == 0) { Tick(); _timer.Start(); }
    }

    public void Unwatch()
    {
        if (--_watchers <= 0) { _watchers = 0; _timer.Stop(); }
    }

    byte[] Run(params string[] arguments)
    {
        if (Adb is null) return Array.Empty<byte>();
        try
        {
            var info = new ProcessStartInfo(Adb) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
            foreach (var a in arguments) info.ArgumentList.Add(a);
            using var process = Process.Start(info)!;
            using var memory = new MemoryStream();
            process.StandardOutput.BaseStream.CopyTo(memory);
            process.WaitForExit(8000);
            return memory.ToArray();
        }
        catch { return Array.Empty<byte>(); }
    }

    string Text(params string[] arguments) => System.Text.Encoding.UTF8.GetString(Run(arguments));

    void Tick()
    {
        AdvancePairing();
        if (_busy || Adb is null) return;
        _busy = true;
        var refreshDevices = _ticks++ % 5 == 0 || Devices.Count == 0;
        Task.Run(() =>
        {
            var devices = refreshDevices ? PhoneAdb.ParseDevices(Text("devices", "-l")) : Devices;
            var current = devices.FirstOrDefault(d => d.Serial == Serial && d.Ready) ?? devices.FirstOrDefault(d => d.Ready);
            (int, bool)? battery = Battery;
            BitmapSource? picture = null;
            if (current is not null)
            {
                if (refreshDevices) battery = PhoneAdb.ParseBattery(Text("-s", current.Serial, "shell", "dumpsys", "battery"));
                var png = Run("-s", current.Serial, "exec-out", "screencap", "-p");
                if (png.Length > 100)
                {
                    try
                    {
                        var image = new BitmapImage();
                        image.BeginInit();
                        image.CacheOption = BitmapCacheOption.OnLoad;
                        image.DecodePixelHeight = 640;
                        image.StreamSource = new MemoryStream(png);
                        image.EndInit();
                        image.Freeze();
                        picture = image;
                    }
                    catch { /* half a picture */ }
                }
            }
            return (devices, battery, picture);
        }).ContinueWith(t => Ui(() =>
        {
            _busy = false;
            if (t.IsFaulted) return;
            var (devices, battery, picture) = t.Result;
            Devices = devices;
            Battery = battery;
            if (picture is not null) Screen = picture;
            Notify();
        }));
    }

    void Shell(params string[] arguments)
    {
        if (Current is not { } device) return;
        var all = new[] { "-s", device.Serial, "shell" }.Concat(arguments).ToArray();
        Task.Run(() => Run(all));
    }

    double RealWidth => _realSize.Width;
    double RealHeight => _realSize.Height;
    Size _realSize = new(1080, 2400);

    /// <summary>The phone's real screen size (wm size), for taps on the smaller picture.</summary>
    public void ReadSize()
    {
        if (Current is not { } device) return;
        var serial = device.Serial;
        Task.Run(() => Text("-s", serial, "shell", "wm", "size")).ContinueWith(t => Ui(() =>
        {
            var match = System.Text.RegularExpressions.Regex.Match(t.Result, @"(\d+)x(\d+)\s*$", System.Text.RegularExpressions.RegexOptions.Multiline);
            if (match.Success) _realSize = new Size(double.Parse(match.Groups[1].Value), double.Parse(match.Groups[2].Value));
        }));
    }

    public void Tap(Point point, Size size)
    {
        var (x, y) = ((int)(point.X / size.Width * RealWidth), (int)(point.Y / size.Height * RealHeight));
        Shell("input", "tap", x.ToString(), y.ToString());
    }

    public void Swipe(Point start, Point end, Size size, double seconds)
    {
        int x1 = (int)(start.X / size.Width * RealWidth), y1 = (int)(start.Y / size.Height * RealHeight);
        int x2 = (int)(end.X / size.Width * RealWidth), y2 = (int)(end.Y / size.Height * RealHeight);
        Shell("input", "swipe", x1.ToString(), y1.ToString(), x2.ToString(), y2.ToString(), ((int)Math.Clamp(seconds * 1000, 80, 2000)).ToString());
    }

    public void Key(int code) => Shell("input", "keyevent", code.ToString());

    public void SendText()
    {
        if (Draft.Length == 0) return;
        Shell("input", "text", PhoneAdb.EscapeInputText(Draft));
        Draft = "";
        Notify();
    }
}
