using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.Win32;
using Windows.Devices.Radios;
using Muna.Core;

namespace Muna;

/// <summary>The switches of Linux's Controls widget and quick toggles, with what Windows has: radios
/// (Wi-Fi, Bluetooth), night light, and system settings (focus follows the mouse, snapping, animations,
/// mouse acceleration, the Caps Lock sound, Explorer's hidden files and extensions, Windows' clipboard
/// history). Every switch reads the live value, so a change made elsewhere shows too.</summary>
public static class SystemSwitches
{
    public sealed record Switch(string Id, string Group, string Glyph, string Title, string Description, Func<bool> Get, Action<bool> Set);

    public static readonly Switch[] All =
    {
        new("focus", "Windows", Muna.Glyph.Window, "Focus follows mouse", "A window gets the keyboard when the pointer is over it.",
            () => GetBool(0x1000), on => SetBool(0x1001, on)),
        new("snap", "Windows", Muna.Glyph.Desktop, "Snap windows to the screen edges", "Drag a window to an edge to fill half of the screen.",
            () => GetBool(0x0082), on => SetBool(0x0083, on)),
        new("animations", "Windows", Muna.Glyph.Sparkle, "Animations", "Windows and menus move smoothly.",
            () => GetBool(0x1042), on => SetBool(0x1043, on)),
        new("permonitor", "Windows", Muna.Glyph.Monitor, "Separate desktops for every monitor", "Switching desktops on one monitor does not switch the others.",
            () => Preferences.Shared.DesktopsPerMonitor, on => Preferences.Shared.DesktopsPerMonitor = on),
        new("accel", "Mouse and keyboard", Muna.Glyph.Eye, "Disable mouse acceleration", "The pointer moves the same distance at any speed.",
            () => !MouseAcceleration, on => MouseAcceleration = !on),
        new("togglekeys", "Mouse and keyboard", Muna.Glyph.Keyboard, "Beep on Caps Lock and Num Lock", "A sound tells you when a lock key changes.",
            () => ToggleKeys, on => ToggleKeys = on),
        new("hidden", "Files", Muna.Glyph.Folder, "Show hidden files", "Explorer shows hidden files and folders.",
            () => Explorer("Hidden", 2) == 1, on => SetExplorer("Hidden", on ? 1 : 2)),
        new("extensions", "Files", Muna.Glyph.Document, "Show file extensions", "Explorer shows .txt, .exe and the like.",
            () => Explorer("HideFileExt", 1) == 0, on => SetExplorer("HideFileExt", on ? 0 : 1)),
        new("history", "Files", Muna.Glyph.Clipboard, "Keep the clipboard history", "Saved on this computer and restored after a restart.",
            () => Preferences.Shared.ClipboardKeepHistory, on => Preferences.Shared.ClipboardKeepHistory = on),
        new("cleanurl", "Files", Muna.Glyph.Link, "Clean URLs when copied", "Removes tracking parameters from a link the moment it is copied.",
            () => Preferences.Shared.ClipboardCleanUrls, on => Preferences.Shared.ClipboardCleanUrls = on),
    };

    public static bool Read(Switch s)
    {
        try { return s.Get(); }
        catch { return false; }
    }

    public static void Write(Switch s, bool on)
    {
        try { s.Set(on); }
        catch (Exception e) { App.Log($"switch {s.Id}: {e.Message}"); }
    }

    // --- SystemParametersInfo ----------------------------------------------------------------------

    [DllImport("user32.dll", SetLastError = true)] static extern bool SystemParametersInfo(uint action, uint param, ref int value, uint flags);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SystemParametersInfo(uint action, uint param, IntPtr value, uint flags);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SystemParametersInfo(uint action, uint param, int[] value, uint flags);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SystemParametersInfo(uint action, uint param, ref TOGGLEKEYS value, uint flags);
    [StructLayout(LayoutKind.Sequential)] struct TOGGLEKEYS { public uint Size, Flags; }
    const uint SaveAndTell = 0x3;   // SPIF_UPDATEINIFILE | SPIF_SENDCHANGE

    static bool GetBool(uint action)
    {
        var value = 0;
        return SystemParametersInfo(action, 0, ref value, 0) && value != 0;
    }

    static void SetBool(uint action, bool on) => SystemParametersInfo(action, 0, new IntPtr(on ? 1 : 0), SaveAndTell);

    /// <summary>"Enhance pointer precision".</summary>
    static bool MouseAcceleration
    {
        get
        {
            var values = new int[3];
            return SystemParametersInfo(0x0003, 0, values, 0) && values[2] != 0;
        }
        set
        {
            var values = value ? new[] { 6, 10, 1 } : new[] { 0, 0, 0 };
            SystemParametersInfo(0x0004, 0, values, SaveAndTell);
        }
    }

    static bool ToggleKeys
    {
        get
        {
            var keys = new TOGGLEKEYS { Size = (uint)Marshal.SizeOf<TOGGLEKEYS>() };
            return SystemParametersInfo(0x0034, keys.Size, ref keys, 0) && (keys.Flags & 1) != 0;
        }
        set
        {
            var keys = new TOGGLEKEYS { Size = (uint)Marshal.SizeOf<TOGGLEKEYS>() };
            SystemParametersInfo(0x0034, keys.Size, ref keys, 0);
            keys.Flags = value ? keys.Flags | 1 : keys.Flags & ~1u;
            SystemParametersInfo(0x0035, keys.Size, ref keys, SaveAndTell);
        }
    }

    // --- Explorer ------------------------------------------------------------------------------------

    const string Advanced = @"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced";

    static int Explorer(string name, int fallback)
    {
        using var key = Registry.CurrentUser.OpenSubKey(Advanced);
        return key?.GetValue(name) as int? ?? fallback;
    }

    [DllImport("shell32.dll")] static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);

    static void SetExplorer(string name, int value)
    {
        using (var key = Registry.CurrentUser.CreateSubKey(Advanced)) key.SetValue(name, value, RegistryValueKind.DWord);
        // open Explorer windows read it again
        SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero);   // SHCNE_ASSOCCHANGED
        Native.SendMessage(new IntPtr(0xffff), 0x001A, IntPtr.Zero, IntPtr.Zero);
    }

    // --- radios --------------------------------------------------------------------------------------

    /// <summary>The state of the Wi-Fi or Bluetooth radio: null when the computer has none (or Windows
    /// does not let Muna see it).</summary>
    public static async Task<bool?> RadioOn(RadioKind kind)
    {
        try
        {
            var radio = (await Radio.GetRadiosAsync()).FirstOrDefault(r => r.Kind == kind);
            return radio is null ? null : radio.State == RadioState.On;
        }
        catch { return null; }
    }

    /// <summary>Turns a radio on or off; returns an error to show, or null.</summary>
    public static async Task<string?> SetRadio(RadioKind kind, bool on)
    {
        try
        {
            if (await Radio.RequestAccessAsync() != RadioAccessStatus.Allowed)
                return "Windows does not let apps switch radios: Settings → Privacy → Radios";
            var radio = (await Radio.GetRadiosAsync()).FirstOrDefault(r => r.Kind == kind);
            if (radio is null) return kind == RadioKind.Bluetooth ? "No Bluetooth here" : "No Wi-Fi here";
            var result = await radio.SetStateAsync(on ? RadioState.On : RadioState.Off);
            return result == RadioAccessStatus.Allowed ? null : "Windows refused to switch it";
        }
        catch (Exception e) { return e.Message; }
    }

    /// <summary>Every radio off (or back on): the airplane mode of the quick toggles.</summary>
    public static async Task<string?> SetAllRadios(bool on)
    {
        try
        {
            if (await Radio.RequestAccessAsync() != RadioAccessStatus.Allowed) return "Windows does not let apps switch radios";
            foreach (var radio in await Radio.GetRadiosAsync()) await radio.SetStateAsync(on ? RadioState.On : RadioState.Off);
            return null;
        }
        catch (Exception e) { return e.Message; }
    }

    // --- night light ---------------------------------------------------------------------------------

    const string NightLightKey = @"Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.bluelightreductionstate\windows.data.bluelightreduction.bluelightreductionstate";

    /// <summary>Night light on now; null when Windows has not stored its state yet (never opened).</summary>
    public static bool? NightLight
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(NightLightKey);
                return key?.GetValue("Data") is byte[] data ? NightLightBlob.IsOn(data) : null;
            }
            catch { return null; }
        }
    }

    /// <summary>Turns night light on or off by writing the state Windows' own switch writes (Windows
    /// watches that value and follows at once). False when it could not.</summary>
    public static bool SetNightLight(bool on)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(NightLightKey, true);
            if (key?.GetValue("Data") is not byte[] data) return false;
            var changed = NightLightBlob.With(data, on);
            if (changed is null) return false;
            key.SetValue("Data", changed, RegistryValueKind.Binary);
            return true;
        }
        catch { return false; }
    }
}
