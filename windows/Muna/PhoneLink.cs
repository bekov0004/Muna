using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Muna.Core;

namespace Muna;

/// <summary>A link to Muna Phone's server (linux/src/phone/phoneLink.js launchServer): Muna starts the
/// server on the phone with adb, the server dials back twice (control and picture) and proves it knows
/// the secret. Then the picture and the touches go over the network, no adb per touch; "h" every
/// 4 seconds tells the phone the computer is still there, and its "H" tells Muna the phone is.</summary>
public sealed class PhoneLinkSession : IDisposable
{
    public const int PreferredPort = 47831;
    TcpClient? _control, _video;
    Process? _server;
    readonly object _write = new();
    DateTime _heard = DateTime.Now;
    Timer? _beat;
    bool _closed;
    public string Info { get; private set; } = "";
    public Stream Video => _video!.GetStream();
    public event Action? Lost;
    public event Action<string>? Line;

    /// <summary>The phone's real screen from "1080x2400 34 MODEL".</summary>
    public (int Width, int Height)? Screen
    {
        get
        {
            var match = System.Text.RegularExpressions.Regex.Match(Info, @"^(\d+)x(\d+)");
            return match.Success ? (int.Parse(match.Groups[1].Value), int.Parse(match.Groups[2].Value)) : null;
        }
    }

    static string Run(string adb, params string[] arguments)
    {
        try
        {
            var info = new ProcessStartInfo(adb) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
            foreach (var a in arguments) info.ArgumentList.Add(a);
            using var process = Process.Start(info)!;
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(8000);
            return output;
        }
        catch { return ""; }
    }

    /// <summary>Whether Muna Phone is installed: the path of its apk.</summary>
    public static string? AppPath(string adb, string serial)
    {
        var match = System.Text.RegularExpressions.Regex.Match(Run(adb, "-s", serial, "shell", "pm", "path", PhoneLinkProtocol.AppId), @"package:(\S+\.apk)");
        return match.Success ? match.Groups[1].Value : null;
    }

    static (IPAddress, int)[] LocalAddresses() => NetworkInterface.GetAllNetworkInterfaces()
        .Where(n => n.OperationalStatus == OperationalStatus.Up)
        .SelectMany(n => n.GetIPProperties().UnicastAddresses)
        .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
        .Select(a => (a.Address, a.PrefixLength)).ToArray();

    /// <summary>Starts the server on the phone and waits (12 s) for its two connections; throws with what went wrong.</summary>
    public static async Task<PhoneLinkSession> Launch(string adb, string serial, string apk)
    {
        var host = PhoneLinkProtocol.LanAddress(Run(adb, "-s", serial, "shell", "ip", "-4", "addr", "show"), LocalAddresses())
                   ?? throw new IOException("the phone and this computer are not in the same network");
        TcpListener listener;
        try { listener = new TcpListener(IPAddress.Any, PreferredPort); listener.Start(); }
        catch (SocketException) { listener = new TcpListener(IPAddress.Any, 0); listener.Start(); }
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var token = PhoneLinkProtocol.RandomToken();
        var session = new PhoneLinkSession();
        try
        {
            var info = new ProcessStartInfo(adb) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var a in new[] { "-s", serial, "shell", $"CLASSPATH='{apk}'", "app_process", "/", PhoneLinkProtocol.ServerClass, host, port.ToString(), token })
                info.ArgumentList.Add(a);
            session._server = Process.Start(info);
            using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(12));
            while (session._control is null || session._video is null)
            {
                var client = await listener.AcceptTcpClientAsync(cancel.Token);
                client.NoDelay = true;
                // whoever knocks has a few seconds to finish the greeting
                using var greeting = CancellationTokenSource.CreateLinkedTokenSource(cancel.Token);
                greeting.CancelAfter(TimeSpan.FromSeconds(8));
                (char Role, string Info)? accepted;
                try { accepted = await PhoneLinkProtocol.Accept(client.GetStream(), token, greeting.Token); }
                catch { accepted = null; }
                if (accepted is not { } a || (a.Role == 'C' ? session._control : session._video) is not null) { client.Dispose(); continue; }
                if (a.Role == 'C') session._control = client; else session._video = client;
                session.Info = a.Info;
            }
        }
        catch (OperationCanceledException)
        {
            session.Dispose();
            throw new IOException("the phone did not connect (Windows' firewall may block Muna: allow it on private networks)");
        }
        catch
        {
            session.Dispose();
            throw;
        }
        finally { listener.Stop(); }
        session.StartBeat();
        return session;
    }

    void StartBeat()
    {
        var stream = _control!.GetStream();
        Task.Run(async () =>
        {
            while (!_closed)
            {
                string? line;
                try { line = await PhoneLinkProtocol.ReadLine(stream, CancellationToken.None); }
                catch { line = null; }
                if (line is null) { Close(true); return; }
                _heard = DateTime.Now;
                if (line != "H") Line?.Invoke(line);
            }
        });
        _beat = new Timer(_ =>
        {
            if ((DateTime.Now - _heard).TotalSeconds > 15 || !Send("h")) Close(true);
        }, null, 4000, 4000);
    }

    /// <summary>One control line (d/m/u x y, k code, t text, p mode, w 1|0, z); false when the link is gone.</summary>
    public bool Send(string line)
    {
        if (_closed || _control is null) return false;
        try
        {
            lock (_write)
            {
                var bytes = Encoding.UTF8.GetBytes(line + "\n");
                _control.GetStream().Write(bytes, 0, bytes.Length);
            }
            return true;
        }
        catch { return false; }
    }

    void Close(bool lost)
    {
        if (_closed) return;
        _closed = true;
        _beat?.Dispose();
        try { _control?.Dispose(); } catch { }
        try { _video?.Dispose(); } catch { }
        try { if (_server is { HasExited: false }) _server.Kill(); } catch { }
        if (lost) Lost?.Invoke();
    }

    /// <summary>The session ends ("q": the phone's server stops and gives back what it changed).</summary>
    public void Dispose()
    {
        if (!_closed) Send("q");
        Close(false);
    }
}
