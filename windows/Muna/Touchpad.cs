using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using Muna.Core;

namespace Muna;

/// <summary>Reads the fingers on a precision touchpad (Windows sends its HID reports to any app that
/// asks for them with Raw Input, also in the background), and turns them into Linux's gestures with
/// <see cref="TouchGestures"/>. Windows keeps doing its own three- and four-finger gestures unless they
/// are set to "Nothing" in its touchpad settings; edges, pinches and holds are Muna's alone.</summary>
public sealed class Touchpad : IDisposable
{
    [StructLayout(LayoutKind.Sequential)] struct RAWINPUTDEVICE { public ushort UsagePage, Usage; public uint Flags; public IntPtr Target; }
    [StructLayout(LayoutKind.Sequential)] struct RAWINPUTHEADER { public uint Type, Size; public IntPtr Device, WParam; }

    [StructLayout(LayoutKind.Sequential)]
    struct HIDP_CAPS
    {
        public ushort Usage, UsagePage, InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes, NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices, NumberOutputButtonCaps,
            NumberOutputValueCaps, NumberOutputDataIndices, NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
    }

    /// <summary>HIDP_VALUE_CAPS (72 bytes); Usage is the first field of its union (NotRange.Usage).</summary>
    [StructLayout(LayoutKind.Explicit, Size = 72)]
    struct HIDP_VALUE_CAPS
    {
        [FieldOffset(0)] public ushort UsagePage;
        [FieldOffset(6)] public ushort LinkCollection;
        [FieldOffset(14)] public byte IsRange;
        [FieldOffset(40)] public int LogicalMin;
        [FieldOffset(44)] public int LogicalMax;
        [FieldOffset(48)] public int PhysicalMin;
        [FieldOffset(52)] public int PhysicalMax;
        [FieldOffset(56)] public ushort Usage;
    }

    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] devices, uint count, uint size);
    [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr input, uint command, IntPtr data, ref uint size, uint headerSize);
    [DllImport("user32.dll")] static extern uint GetRawInputDeviceInfo(IntPtr device, uint command, IntPtr data, ref uint size);
    [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr preparsed, out HIDP_CAPS caps);
    [DllImport("hid.dll")] static extern int HidP_GetValueCaps(int type, [Out] HIDP_VALUE_CAPS[] caps, ref ushort length, IntPtr preparsed);
    [DllImport("hid.dll")] static extern int HidP_GetUsageValue(int type, ushort page, ushort link, ushort usage, out uint value, IntPtr preparsed, byte[] report, uint length);
    [DllImport("hid.dll")] static extern int HidP_GetUsages(int type, ushort page, ushort link, [Out] ushort[] usages, ref uint length, IntPtr preparsed, byte[] report, uint length2);
    const int Ok = 0x00110000;

    sealed class Device
    {
        public IntPtr Preparsed;
        public List<(ushort Link, int MinX, int MaxX, int MinY, int MaxY)> Fingers = new();
        public double Aspect = 0.62;
        public int Expected;
        public readonly List<Contact> Collected = new();
    }

    readonly HwndSource _window;
    readonly Dictionary<IntPtr, Device?> _devices = new();
    readonly Stopwatch _clock = Stopwatch.StartNew();
    readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromMilliseconds(100) };
    public TouchGestures Recognizer { get; } = new();
    public event Action<GestureEvent>? Gesture;
    public bool Found { get; private set; }
    bool _touching;

    public Touchpad()
    {
        _window = new HwndSource(new HwndSourceParameters("MunaTouchpad") { Width = 0, Height = 0, WindowStyle = 0 });
        _window.AddHook(OnMessage);
        var device = new RAWINPUTDEVICE { UsagePage = 0x0D, Usage = 0x05, Flags = 0x100, Target = _window.Handle };   // touch pad, RIDEV_INPUTSINK
        RegisterRawInputDevices(new[] { device }, 1, (uint)Marshal.SizeOf<RAWINPUTDEVICE>());
        _tick.Tick += (_, _) => { if (_touching) Send(Recognizer.Tick(Now)); };
        _tick.Start();
    }

    double Now => _clock.Elapsed.TotalSeconds;

    IntPtr OnMessage(IntPtr hwnd, int message, IntPtr w, IntPtr l, ref bool handled)
    {
        if (message != 0x00FF) return IntPtr.Zero;   // WM_INPUT
        try { Read(l); } catch (Exception e) { App.Log(e); }
        return IntPtr.Zero;
    }

    void Read(IntPtr input)
    {
        uint size = 0;
        var header = (uint)Marshal.SizeOf<RAWINPUTHEADER>();
        GetRawInputData(input, 0x10000003, IntPtr.Zero, ref size, header);   // RID_INPUT
        if (size == 0) return;
        var buffer = Marshal.AllocHGlobal((int)size);
        try
        {
            if (GetRawInputData(input, 0x10000003, buffer, ref size, header) != size) return;
            var head = Marshal.PtrToStructure<RAWINPUTHEADER>(buffer);
            if (head.Type != 2) return;   // RIM_TYPEHID
            var device = DeviceFor(head.Device);
            if (device is null) return;
            var sizeHid = Marshal.ReadInt32(buffer, (int)header);
            var count = Marshal.ReadInt32(buffer, (int)header + 4);
            for (var i = 0; i < count; i++)
            {
                var report = new byte[sizeHid];
                Marshal.Copy(buffer + (int)header + 8 + i * sizeHid, report, 0, sizeHid);
                Report(device, report);
            }
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    /// <summary>Where the fingers are in this touchpad's reports (each finger is a link collection with X and Y).</summary>
    Device? DeviceFor(IntPtr handle)
    {
        if (_devices.TryGetValue(handle, out var known)) return known;
        Device? device = null;
        uint size = 0;
        GetRawInputDeviceInfo(handle, 0x20000005, IntPtr.Zero, ref size);   // RIDI_PREPARSEDDATA
        if (size > 0)
        {
            var preparsed = Marshal.AllocHGlobal((int)size);
            if (GetRawInputDeviceInfo(handle, 0x20000005, preparsed, ref size) > 0 && HidP_GetCaps(preparsed, out var caps) == Ok)
            {
                var length = caps.NumberInputValueCaps;
                var values = new HIDP_VALUE_CAPS[length];
                if (HidP_GetValueCaps(0, values, ref length, preparsed) == Ok)
                {
                    device = new Device { Preparsed = preparsed };
                    foreach (var x in values.Take(length).Where(v => v.UsagePage == 0x01 && v.Usage == 0x30))
                    {
                        var y = values.FirstOrDefault(v => v.UsagePage == 0x01 && v.Usage == 0x31 && v.LinkCollection == x.LinkCollection);
                        if (y.LogicalMax <= y.LogicalMin || x.LogicalMax <= x.LogicalMin) continue;
                        device.Fingers.Add((x.LinkCollection, x.LogicalMin, x.LogicalMax, y.LogicalMin, y.LogicalMax));
                        if (x.PhysicalMax > x.PhysicalMin && y.PhysicalMax > y.PhysicalMin)
                            device.Aspect = (double)(y.PhysicalMax - y.PhysicalMin) / (x.PhysicalMax - x.PhysicalMin);
                    }
                    if (device.Fingers.Count == 0) device = null;
                }
            }
            if (device is null) Marshal.FreeHGlobal(preparsed);
        }
        _devices[handle] = device;
        if (device is not null) { Found = true; Recognizer.Aspect = device.Aspect; }
        return device;
    }

    /// <summary>One report: the fingers it carries. A touchpad may spread one moment over several reports
    /// ("hybrid": the count is in the first); the frame goes on when all of them came.</summary>
    void Report(Device d, byte[] report)
    {
        var length = (uint)report.Length;
        if (HidP_GetUsageValue(0, 0x0D, 0, 0x54, out var count, d.Preparsed, report, length) == Ok && count > 0)
        {
            d.Expected = (int)count;
            d.Collected.Clear();
        }
        var usages = new ushort[16];
        foreach (var (link, minX, maxX, minY, maxY) in d.Fingers)
        {
            if (d.Collected.Count >= d.Expected) break;
            if (HidP_GetUsageValue(0, 0x01, link, 0x30, out var x, d.Preparsed, report, length) != Ok) continue;
            HidP_GetUsageValue(0, 0x01, link, 0x31, out var y, d.Preparsed, report, length);
            HidP_GetUsageValue(0, 0x0D, link, 0x51, out var id, d.Preparsed, report, length);
            uint n = (uint)usages.Length;
            var tip = HidP_GetUsages(0, 0x0D, link, usages, ref n, d.Preparsed, report, length) == Ok && usages.Take((int)n).Contains((ushort)0x42);
            // a finger lifting is counted as reported, but it touches no more
            d.Collected.Add(new Contact(tip ? (int)id : -1, (double)((int)x - minX) / (maxX - minX), (double)((int)y - minY) / (maxY - minY)));
        }
        if (d.Collected.Count < d.Expected) return;
        var touching = d.Collected.Where(c => c.Id >= 0).ToList();
        d.Collected.Clear();
        d.Expected = 0;
        _touching = touching.Count > 0;
        Send(Recognizer.Frame(touching, Now));
    }

    void Send(List<GestureEvent> events)
    {
        foreach (var e in events) Gesture?.Invoke(e);
    }

    public void Dispose()
    {
        _tick.Stop();
        var device = new RAWINPUTDEVICE { UsagePage = 0x0D, Usage = 0x05, Flags = 0x1, Target = IntPtr.Zero };   // RIDEV_REMOVE
        RegisterRawInputDevices(new[] { device }, 1, (uint)Marshal.SizeOf<RAWINPUTDEVICE>());
        _window.Dispose();
        foreach (var d in _devices.Values) if (d is not null) Marshal.FreeHGlobal(d.Preparsed);
        _devices.Clear();
    }
}

/// <summary>What a gesture does on Windows (the actions of <see cref="GestureCatalog"/>), and the live
/// app switcher: Windows' own Alt+Tab, held while the fingers move, one app per step.</summary>
public sealed class GestureActions
{
    const double SwitchStep = 0.09;
    readonly AppState _app;
    Touchpad? _touchpad;
    string? _liveGesture;
    double _liveTravel;

    public GestureActions(AppState app)
    {
        _app = app;
        Preferences.Shared.Changed += key =>
        {
            if (key is "touchpad-gestures" or "edge-gestures" or "gesture-sensitivity") Application.Current.Dispatcher.BeginInvoke(Apply);
        };
    }

    public bool TouchpadFound => _touchpad?.Found ?? false;

    public void Start() => Apply();

    void Apply()
    {
        var p = Preferences.Shared;
        var wanted = p.TouchpadGestures || p.EdgeGestures;
        if (wanted && _touchpad is null)
        {
            try
            {
                _touchpad = new Touchpad();
                _touchpad.Gesture += OnGesture;
            }
            catch (Exception e) { App.Log(e); }
        }
        else if (!wanted && _touchpad is not null)
        {
            _touchpad.Dispose();
            _touchpad = null;
        }
        if (_touchpad is not null)
        {
            _touchpad.Recognizer.Edges = p.EdgeGestures;
            _touchpad.Recognizer.Sensitivity = p.GestureSensitivity;
        }
    }

    public void Stop()
    {
        EndLive();
        _touchpad?.Dispose();
        _touchpad = null;
    }

    void OnGesture(GestureEvent e)
    {
        var p = Preferences.Shared;
        switch (e)
        {
            case SwipeLocked locked when p.TouchpadGestures:
                if (GestureCatalog.Find(p.GestureAction(locked.Gesture)).Live) BeginLive(locked.Gesture);
                break;
            case SwipeMoved moved when moved.Gesture == _liveGesture:
                _liveTravel += moved.Delta;
                while (_liveTravel >= SwitchStep) { _liveTravel -= SwitchStep; Keys.Tap(0x09); }
                while (_liveTravel <= -SwitchStep) { _liveTravel += SwitchStep; Keys.Tap(0x09, shift: true); }
                break;
            case SwipeTriggered triggered when p.TouchpadGestures && triggered.Gesture != _liveGesture:
                Run(p.GestureAction(triggered.Gesture));
                break;
            case SwipeEnded ended when ended.Gesture == _liveGesture:
                EndLive();
                break;
            case Pinched pinched when p.TouchpadGestures:
                Run(p.GestureAction(pinched.Gesture));
                break;
            case Held held when p.TouchpadGestures:
                Run(p.GestureAction(held.Gesture));
                break;
            case EdgeStep step:
                Run(p.EdgeAction($"edge-{step.Edge}-{(step.Direction > 0 ? "plus" : "minus")}"));
                break;
            case EdgeDoubleTap tap:
                Run(p.EdgeAction($"edge-tap-{tap.Zone}"));
                break;
            case EdgeHold hold:
                Run(p.EdgeAction($"edge-hold-{hold.Zone}"));
                break;
        }
    }

    /// <summary>Alt goes down and Tab shows the switcher with the next app chosen; each step one more.</summary>
    void BeginLive(string gesture)
    {
        _liveGesture = gesture;
        _liveTravel = 0;
        Native.keybd_event(0x12, 0, 0, Mark);
        Keys.Tap(0x09);
    }

    void EndLive()
    {
        if (_liveGesture is null) return;
        _liveGesture = null;
        Native.keybd_event(0x12, 0, 2, Mark);
    }

    static UIntPtr Mark => (UIntPtr)(ulong)Native.MunaKeyMark.ToInt64();

    /// <summary>Does one action (also the edges' steps and the radial menu could use it).</summary>
    public void Run(string? id)
    {
        if (string.IsNullOrEmpty(id) || id == "none") return;
        try { Do(id); }
        catch (Exception e) { App.Log($"gesture action {id}: {e.Message}"); }
    }

    void Do(string id)
    {
        if (id.StartsWith("keys:")) { Keys.Press(id[5..]); return; }
        var action = GestureCatalog.Find(id);
        if (action.Keys is { } keys) { Keys.Press(keys); return; }
        var front = Native.GetForegroundWindow();
        switch (id)
        {
            case "app-switcher": Keys.Press("<Alt>Tab"); break;
            case "window-maximize": if (front != IntPtr.Zero) Native.ShowWindow(front, Native.IsZoomed(front) ? 9 : 3); break;
            case "window-minimize": if (front != IntPtr.Zero) Native.ShowWindow(front, 6); break;
            case "workspace-left": Desktop(-1); break;
            case "workspace-right": Desktop(1); break;
            case "lock": Native.LockWorkStation(); break;
            case "volume-up": Native.TapKey(0xAF); break;
            case "volume-down": Native.TapKey(0xAE); break;
            case "volume-mute": Native.TapKey(Native.VK_VOLUME_MUTE); break;
            case "play-pause": Native.TapKey(Native.VK_MEDIA_PLAY_PAUSE); break;
            case "next": Native.TapKey(Native.VK_MEDIA_NEXT); break;
            case "prev": Native.TapKey(Native.VK_MEDIA_PREV); break;
            case "brightness-up": Brightness(0.1); break;
            case "brightness-down": Brightness(-0.1); break;
            case "muna:muna": _app.Capsules.Open(PanelTab.Muna); break;
            case "muna:tray": _app.Capsules.Open(PanelTab.Tray); break;
            case "muna:clipboard": _app.Capsules.Open(PanelTab.Clipboard); break;
            case "muna:notifications": _app.Capsules.Open(PanelTab.Alerts); break;
            case "muna:command": _app.Capsules.OpenCommand(); break;
            case "muna:quickpanel": _app.ToggleQuickPanel(); break;
            case "muna:radial": _app.ToggleRadial(); break;
            case "muna:color": ColorPicker.Pick(hex => _app.Capsules.Tell("Colour copied", hex, Glyph.Eyedropper, true)); break;
            case "muna:mic": _app.Sound.ToggleMicrophone(); break;
            case "muna:awake": if (_app.Awake.IsOn) _app.Awake.Stop(); else _app.Awake.Start(null, true); break;
            case "muna:output": _app.Sound.NextOutput(); break;
            case "muna:dark": QuickTools.ToggleDarkMode(); break;
            case "muna:night": SystemSwitches.SetNightLight(!(SystemSwitches.NightLight ?? false)); break;
            case "muna:cleaning": CleaningMode.Start(); break;
        }
    }

    void Desktop(int step)
    {
        if (_app.Desktops.On) _app.Desktops.Step(MonitorDesktops.PointerScreen(), step);
        else Keys.Chord(0x11, 0x5B, (byte)(step > 0 ? 0x27 : 0x25));
    }

    /// <summary>The screen under the pointer, a step brighter or darker.</summary>
    void Brightness(double step)
    {
        var displays = _app.Displays;
        if (displays.Displays.Count == 0) { displays.Refresh(); return; }
        var pointer = Native.Cursor();
        var display = displays.Displays.FirstOrDefault(d => d.Bounds.Contains((int)pointer.X, (int)pointer.Y)) ?? displays.Displays[0];
        displays.Set(display, display.Brightness + step);
        _app.Capsules.Tell("Brightness", $"{(int)Math.Round(Math.Clamp(display.Brightness + step, 0, 1) * 100)}%", Glyph.Brightness, true);
    }
}
