using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace Muna;

/// <summary>Windows' own virtual desktops, as far as an app may see them: how many there are and which
/// one is shown (Explorer keeps both in the registry), and switching by Windows' own keys.</summary>
public static class VirtualDesktops
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops";

    static byte[]? Read(string name, bool session = false)
    {
        try
        {
            if (!session)
            {
                using var key = Registry.CurrentUser.OpenSubKey(Key);
                if (key?.GetValue(name) is byte[] value) return value;
            }
            // Windows 10 keeps the current one per session
            var sessionId = System.Diagnostics.Process.GetCurrentProcess().SessionId;
            using var old = Registry.CurrentUser.OpenSubKey($@"Software\Microsoft\Windows\CurrentVersion\Explorer\SessionInfo\{sessionId}\VirtualDesktops");
            return old?.GetValue(name) as byte[];
        }
        catch { return null; }
    }

    /// <summary>(how many, which one is shown, 0-based).</summary>
    public static (int Count, int Current) State()
    {
        var ids = Read("VirtualDesktopIDs");
        var count = ids is null ? 1 : Math.Max(1, ids.Length / 16);
        var current = Read("CurrentVirtualDesktop") ?? Read("CurrentVirtualDesktop", true);
        var index = 0;
        if (ids is not null && current is { Length: 16 })
        {
            for (var i = 0; i < count; i++)
                if (ids.AsSpan(i * 16, 16).SequenceEqual(current)) { index = i; break; }
        }
        return (count, index);
    }

    /// <summary>Goes to desktop <paramref name="target"/> with Ctrl+Win+arrows (Windows has no public call).</summary>
    public static void SwitchTo(int target)
    {
        var (count, current) = State();
        target = Math.Clamp(target, 0, count - 1);
        var steps = target - current;
        for (var i = 0; i < Math.Abs(steps); i++) Keys.Chord(0x11, 0x5B, (byte)(steps > 0 ? 0x27 : 0x25));
    }

    public static void New() => Keys.Chord(0x11, 0x5B, 0x44);          // Ctrl+Win+D
    public static void TaskView() => Keys.Chord(0x5B, 0x09);            // Win+Tab
}

/// <summary>Pressing keys for Windows' own shortcuts.</summary>
public static class Keys
{
    public static void Chord(params byte[] keys)
    {
        var mark = (UIntPtr)(ulong)Native.MunaKeyMark.ToInt64();
        foreach (var k in keys) Native.keybd_event(k, 0, Extended(k) ? 1u : 0, mark);
        foreach (var k in keys.Reverse()) Native.keybd_event(k, 0, (Extended(k) ? 1u : 0) | 2, mark);
    }

    static bool Extended(byte k) => k is 0x25 or 0x26 or 0x27 or 0x28 or 0x5B or 0x5C;
}

/// <summary>Linux's "separate desktops for every monitor" (linux/src/windows/monitorDesktops.js):
/// Windows switches all monitors at once, so with this on Muna keeps desktops of its own for each
/// monitor. Switching hides the windows of that monitor's desktop (minimised, as Linux does on the
/// other monitors) and brings back the other desktop's. Ctrl+Win+←/→ then switch the monitor under
/// the pointer only, Ctrl+Win+Shift+←/→ take the window in front along.</summary>
public sealed class MonitorDesktops : Model
{
    public sealed class Monitor
    {
        public string Id = "";
        public int Count = 2;
        public int Current;
        /// <summary>Windows sent away from the shown desktop, with the desktop they are on.</summary>
        public readonly Dictionary<IntPtr, int> Away = new();
    }

    readonly Dictionary<string, Monitor> _monitors = new();
    IntPtr _hook;
    Native.HookProc? _proc;
    bool _swallowUp;

    public bool On => Preferences.Shared.DesktopsPerMonitor;

    public MonitorDesktops()
    {
        Preferences.Shared.Changed += key =>
        {
            if (key != "desktops-per-monitor") return;
            Application.Current.Dispatcher.BeginInvoke(Apply);
        };
    }

    public void Start() => Apply();

    void Apply()
    {
        if (On) Hook();
        else { Unhook(); RestoreAll(); }
        Notify();
    }

    public Monitor For(string screenId)
    {
        if (!_monitors.TryGetValue(screenId, out var monitor)) _monitors[screenId] = monitor = new Monitor { Id = screenId };
        return monitor;
    }

    static string ScreenOf(IntPtr hwnd) => Forms.Screen.FromHandle(hwnd).DeviceName;

    public static string PointerScreen()
    {
        var p = Native.Cursor();
        return Forms.Screen.FromPoint(new System.Drawing.Point((int)p.X, (int)p.Y)).DeviceName;
    }

    static bool IsOwn(IntPtr hwnd)
    {
        Native.GetWindowThreadProcessId(hwnd, out var process);
        return process == Environment.ProcessId;
    }

    /// <summary>Shows desktop <paramref name="target"/> on one monitor.</summary>
    public void Switch(string screenId, int target)
    {
        var monitor = For(screenId);
        if (target < 0) return;
        if (target >= monitor.Count) monitor.Count = Math.Min(9, target + 1);
        if (target == monitor.Current) return;
        // the windows shown there now go with the current desktop
        foreach (var hwnd in Native.AppWindows().Where(h => !IsOwn(h) && !Native.IsIconic(h) && ScreenOf(h) == screenId))
        {
            monitor.Away[hwnd] = monitor.Current;
            Native.ShowWindow(hwnd, 7);   // SW_SHOWMINNOACTIVE
        }
        // the target's windows come back
        IntPtr last = IntPtr.Zero;
        foreach (var (hwnd, desk) in monitor.Away.Where(p => p.Value == target).ToList())
        {
            monitor.Away.Remove(hwnd);
            if (!Native.IsWindowVisible(hwnd)) continue;      // closed meanwhile
            Native.ShowWindow(hwnd, 4);   // SW_SHOWNOACTIVATE
            last = hwnd;
        }
        if (last != IntPtr.Zero) Native.SetForegroundWindow(last);
        monitor.Current = target;
        Forget();
        Notify();
    }

    public void Step(string screenId, int step)
    {
        var monitor = For(screenId);
        var target = monitor.Current + step;
        if (target < 0) return;
        if (target >= monitor.Count && monitor.Count >= 9) return;
        Switch(screenId, target);
    }

    /// <summary>The window in front goes to the next or previous desktop of its monitor (and the monitor follows it).</summary>
    public void MoveFront(int step)
    {
        var hwnd = Native.GetForegroundWindow();
        if (hwnd == IntPtr.Zero || IsOwn(hwnd)) return;
        var screenId = ScreenOf(hwnd);
        var monitor = For(screenId);
        var target = monitor.Current + step;
        if (target < 0 || target >= 9) return;
        Native.ShowWindow(hwnd, 7);
        monitor.Away[hwnd] = target;
        Switch(screenId, target);
    }

    public void Add(string screenId)
    {
        var monitor = For(screenId);
        monitor.Count = Math.Min(9, monitor.Count + 1);
        Notify();
    }

    /// <summary>The last desktop goes; its windows come to the one before.</summary>
    public void RemoveLast(string screenId)
    {
        var monitor = For(screenId);
        if (monitor.Count <= 1) return;
        var last = monitor.Count - 1;
        if (monitor.Current == last) Switch(screenId, last - 1);
        foreach (var hwnd in monitor.Away.Where(p => p.Value == last).Select(p => p.Key).ToList()) monitor.Away[hwnd] = last - 1;
        monitor.Count--;
        Notify();
    }

    /// <summary>How many windows a desktop has (for the dots).</summary>
    public int Windows(string screenId, int desk)
    {
        var monitor = For(screenId);
        if (desk == monitor.Current) return Native.AppWindows().Count(h => !IsOwn(h) && !Native.IsIconic(h) && ScreenOf(h) == screenId);
        return monitor.Away.Count(p => p.Value == desk);
    }

    void Forget()
    {
        foreach (var monitor in _monitors.Values)
            foreach (var hwnd in monitor.Away.Keys.Where(h => !Native.IsWindow(h)).ToList()) monitor.Away.Remove(hwnd);
    }

    /// <summary>Muna quits or the setting goes off: every window comes back.</summary>
    public void RestoreAll()
    {
        foreach (var monitor in _monitors.Values)
        {
            foreach (var hwnd in monitor.Away.Keys) if (Native.IsWindow(hwnd)) Native.ShowWindow(hwnd, 4);
            monitor.Away.Clear();
            monitor.Current = 0;
        }
        Notify();
    }

    // --- Ctrl+Win+arrows ---------------------------------------------------------------------------

    [StructLayout(LayoutKind.Sequential)]
    struct KBDLLHOOKSTRUCT { public uint Vk, Scan, Flags, Time; public IntPtr Extra; }

    void Hook()
    {
        if (_hook != IntPtr.Zero) return;
        _proc = OnKey;
        _hook = Native.SetWindowsHookEx(13, _proc, Native.GetModuleHandle(null), 0);
    }

    void Unhook()
    {
        if (_hook == IntPtr.Zero) return;
        Native.UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
    }

    static bool Down(int vk) => (Native.GetAsyncKeyState(vk) & 0x8000) != 0;

    IntPtr OnKey(int code, IntPtr w, IntPtr l)
    {
        if (code >= 0)
        {
            var key = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(l);
            var message = w.ToInt32();
            var isDown = message is 0x100 or 0x104;
            if (key.Vk is 0x25 or 0x27 && (key.Extra != Native.MunaKeyMark))
            {
                if (isDown && Down(0x11) && (Down(0x5B) || Down(0x5C)))
                {
                    var step = key.Vk == 0x27 ? 1 : -1;
                    var move = Down(0x10);
                    _swallowUp = true;
                    Application.Current.Dispatcher.BeginInvoke(() =>
                    {
                        // a harmless key, so letting go of Win does not open Start
                        Native.keybd_event(0xE8, 0, 0, UIntPtr.Zero);
                        Native.keybd_event(0xE8, 0, 2, UIntPtr.Zero);
                        if (move) MoveFront(step); else Step(PointerScreen(), step);
                    });
                    return new IntPtr(1);
                }
                if (!isDown && _swallowUp) { _swallowUp = false; return new IntPtr(1); }
            }
        }
        return Native.CallNextHookEx(_hook, code, w, l);
    }

    public void Stop()
    {
        Unhook();
        RestoreAll();
    }
}
