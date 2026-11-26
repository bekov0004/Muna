using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Threading;

namespace Muna;

/// <summary>Sound: the output's volume and mute, the microphone's mute, the output device (Windows'
/// Core Audio).</summary>
public sealed class SoundModel : Model
{
    public sealed record Output(string Id, string Name);

    public double Volume { get; private set; }
    public bool Muted { get; private set; }
    public bool MicrophoneMuted { get; private set; }
    public bool HasMicrophone { get; private set; }
    public List<Output> Outputs { get; private set; } = new();
    public string DefaultOutput { get; private set; } = "";
    int _watchers;
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };

    public SoundModel() => _timer.Tick += (_, _) => Refresh();

    public void Watch()
    {
        if (_watchers++ == 0) { Refresh(); _timer.Start(); }
    }

    public void Unwatch()
    {
        if (--_watchers <= 0) { _watchers = 0; _timer.Stop(); }
    }

    public void Refresh()
    {
        try
        {
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
            if (Endpoint(enumerator, 0) is { } output)
            {
                output.GetMasterVolumeLevelScalar(out var level);
                output.GetMute(out var mute);
                Volume = level;
                Muted = mute;
            }
            if (Endpoint(enumerator, 1) is { } microphone)
            {
                microphone.GetMute(out var mute);
                MicrophoneMuted = mute;
                HasMicrophone = true;
            }
            else HasMicrophone = false;
            Outputs = Devices(enumerator);
            DefaultOutput = DefaultId(enumerator, 0) ?? "";
        }
        catch { /* no audio service */ }
        Notify();
    }

    public void SetVolume(double value)
    {
        try
        {
            if (Endpoint((IMMDeviceEnumerator)new MMDeviceEnumerator(), 0) is { } output)
            {
                var guid = Guid.Empty;
                output.SetMasterVolumeLevelScalar((float)Math.Clamp(value, 0, 1), ref guid);
                if (value > 0 && Muted) output.SetMute(false, ref guid);
            }
        }
        catch { }
        Volume = value;
        Notify();
    }

    public void ToggleMute() => SetMute(0, !Muted);
    public void ToggleMicrophone() => SetMute(1, !MicrophoneMuted);

    void SetMute(int flow, bool on)
    {
        try
        {
            if (Endpoint((IMMDeviceEnumerator)new MMDeviceEnumerator(), flow) is { } endpoint)
            {
                var guid = Guid.Empty;
                endpoint.SetMute(on, ref guid);
            }
        }
        catch { }
        Refresh();
    }

    /// <summary>Makes a device the default output (for every role).</summary>
    /// <summary>The next sound output (the radial menu and the gestures' "next output").</summary>
    public void NextOutput()
    {
        if (Outputs.Count == 0) Refresh();
        if (Outputs.Count < 2) return;
        var index = Outputs.FindIndex(o => o.Id == DefaultOutput);
        SelectOutput(Outputs[(index + 1) % Outputs.Count].Id);
    }

    public void SelectOutput(string id)
    {
        try
        {
            var policy = (IPolicyConfig)new PolicyConfigClient();
            for (var role = 0; role < 3; role++) policy.SetDefaultEndpoint(id, role);
        }
        catch { }
        Refresh();
    }

    static IAudioEndpointVolume? Endpoint(IMMDeviceEnumerator enumerator, int flow)
    {
        if (enumerator.GetDefaultAudioEndpoint(flow, 1, out var device) != 0 || device is null) return null;
        var iid = typeof(IAudioEndpointVolume).GUID;
        device.Activate(ref iid, 23, IntPtr.Zero, out var volume);
        return volume as IAudioEndpointVolume;
    }

    static string? DefaultId(IMMDeviceEnumerator enumerator, int flow)
    {
        if (enumerator.GetDefaultAudioEndpoint(flow, 1, out var device) != 0 || device is null) return null;
        device.GetId(out var id);
        return id;
    }

    static List<Output> Devices(IMMDeviceEnumerator enumerator)
    {
        var list = new List<Output>();
        if (enumerator.EnumAudioEndpoints(0, 1, out var collection) != 0) return list;
        collection.GetCount(out var count);
        for (uint i = 0; i < count; i++)
        {
            collection.Item(i, out var device);
            device.GetId(out var id);
            var name = id;
            if (device.OpenPropertyStore(0, out var store) == 0)
            {
                var key = new PropertyKey { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };   // the friendly name
                if (store.GetValue(ref key, out var value) == 0 && value.vt == 31) name = Marshal.PtrToStringUni(value.pointer) ?? id;
            }
            list.Add(new Output(id, name));
        }
        return list;
    }

    // --- Core Audio COM -----------------------------------------------------------------------------

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }
    [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] class PolicyConfigClient { }

    [StructLayout(LayoutKind.Sequential)] struct PropertyKey { public Guid fmtid; public int pid; }
    [StructLayout(LayoutKind.Sequential)] struct PropVariant { public ushort vt; ushort r1, r2, r3; public IntPtr pointer; IntPtr extra; }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int flow, int mask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice device);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int context, IntPtr parameters, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
        [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetAt(int index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int GetChannelCount(out int count);
        [PreserveSig] int SetMasterVolumeLevel(float level, ref Guid context);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid context);
        [PreserveSig] int GetMasterVolumeLevel(out float level);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint channel, float level, ref Guid context);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid context);
        [PreserveSig] int GetChannelVolumeLevel(uint channel, out float level);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid context);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }

    /// <summary>Not documented, but how every sound switcher sets the default device.</summary>
    [ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPolicyConfig
    {
        [PreserveSig] int GetMixFormat(string id, IntPtr format);
        [PreserveSig] int GetDeviceFormat(string id, bool def, IntPtr format);
        [PreserveSig] int ResetDeviceFormat(string id);
        [PreserveSig] int SetDeviceFormat(string id, IntPtr endpointFormat, IntPtr mixFormat);
        [PreserveSig] int GetProcessingPeriod(string id, bool def, IntPtr defaultPeriod, IntPtr minimumPeriod);
        [PreserveSig] int SetProcessingPeriod(string id, IntPtr period);
        [PreserveSig] int GetShareMode(string id, IntPtr mode);
        [PreserveSig] int SetShareMode(string id, IntPtr mode);
        [PreserveSig] int GetPropertyValue(string id, IntPtr key, IntPtr value);
        [PreserveSig] int SetPropertyValue(string id, IntPtr key, IntPtr value);
        [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
        [PreserveSig] int SetEndpointVisibility(string id, bool visible);
    }
}
