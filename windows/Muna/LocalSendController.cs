using System;
using System.Diagnostics;
using System.Linq;
using System.Security.Cryptography.X509Certificates;
using System.Threading.Tasks;
using Muna.Core;

namespace Muna;

/// <summary>LocalSend for the views: finding devices, sending to several at once, groups, receiving.</summary>
public sealed class LocalSendController : Model
{
    public SendSession Session { get; }
    public IncomingTransfer? Incoming { get; private set; }
    public bool Receiving { get; private set; }
    public string? ReceiveProblem { get; private set; }
    /// <summary>The capsule shows a short message (title, details, ok).</summary>
    public event Action<string, string, bool>? Notified;
    /// <summary>Someone wants to send: the capsule opens.</summary>
    public event Action? IncomingAsked;
    /// <summary>A text someone sent (LocalSend's text message), until it is put away.</summary>
    public (string From, string Text)? Message { get; private set; }
    /// The received text was copied (its Copy button says "Copied").
    public bool MessageCopied { get; private set; }

    public void CopyMessage()
    {
        if (Message is not { } message) return;
        ClipboardModel.SetText(message.Text);
        MessageCopied = true;
        Notify();
    }

    readonly X509Certificate2? _certificate;
    readonly string _fingerprint;
    readonly LocalSendClient _client;
    readonly LocalSendReceiver? _receiver;
    readonly LocalSendMulticast _multicast = new();
    DateTime _lastProgress;

    public static string Alias => Preferences.Shared.LocalSendAlias.Trim() is { Length: > 0 } alias ? alias : Environment.MachineName;

    public LocalSendController()
    {
        try { _certificate = LocalSendCertificate.LoadOrCreate(); }
        catch { _certificate = null; }
        _fingerprint = _certificate is null ? Guid.NewGuid().ToString("N") + Guid.NewGuid().ToString("N") : LocalSendCertificate.Fingerprint(_certificate);
        DeviceInfo Identity() => new() { Alias = Alias, Fingerprint = _fingerprint, Download = false };
        _client = new LocalSendClient(Identity, _certificate);
        Session = new SendSession(_client, new GroupsStore()) { Post = action => Ui(action) };
        Session.Changed += Notify;
        Session.Finished += (title, details, ok) => Notified?.Invoke(title, details, ok);
        if (_certificate is not null)
        {
            _receiver = new LocalSendReceiver(_certificate, Identity, () => Preferences.Shared.ReceiveFolder);
            _receiver.Incoming += transfer => Ui(() =>
            {
                Incoming = transfer;
                Notify();
                IncomingAsked?.Invoke();
            });
            _receiver.Message += (sender, text) => Ui(() =>
            {
                Message = (sender.Alias, text);
                MessageCopied = false;
                Notify();
                IncomingAsked?.Invoke();
            });
            _receiver.Changed += transfer =>
            {
                // progress comes for every piece: draw at most ten times a second
                if (transfer.State == IncomingState.Receiving && (DateTime.Now - _lastProgress).TotalMilliseconds < 100) return;
                _lastProgress = DateTime.Now;
                Ui(() => Changed_(transfer));
            };
        }
        _multicast.Announced += (info, ip) =>
        {
            if (info.Fingerprint == _fingerprint) return;
            var device = Device.From(ip, info.Port, info.Protocol == "http" ? "http" : "https", info);
            _ = _client.Register(device);
            Ui(() => Session.Found(device));
        };
    }

    (string Id, IncomingState State) _told;

    void Changed_(IncomingTransfer transfer)
    {
        Incoming = transfer;
        // the end is told once, however many updates arrive late
        if (_told == (transfer.Id, transfer.State)) { Notify(); return; }
        if (transfer.State is IncomingState.Done or IncomingState.Failed) _told = (transfer.Id, transfer.State);
        if (transfer.State == IncomingState.Done)
        {
            var count = transfer.Files.Count(f => f.Done);
            Notified?.Invoke($"Received from {transfer.Sender.Alias}", $"{count} file{(count == 1 ? "" : "s")}", true);
        }
        else if (transfer.State == IncomingState.Failed)
        {
            Notified?.Invoke($"From {transfer.Sender.Alias}", transfer.Error ?? "Failed", false);
        }
        Notify();
    }

    /// <summary>Receiving follows the setting (the menu, the settings window and the LocalSend page change it).</summary>
    public void Start()
    {
        Apply(Preferences.Shared.LocalSendReceive);
        Preferences.Shared.Changed += key => { if (key == "localsend-receive") Apply(Preferences.Shared.LocalSendReceive); };
    }

    public void SetReceiving(bool on) => Preferences.Shared.LocalSendReceive = on;

    public void Shutdown()
    {
        _receiver?.Stop();
        _multicast.Stop();
    }

    void Apply(bool on)
    {
        if (on == Receiving && ReceiveProblem is null) return;
        if (on)
        {
            if (_receiver is null)
            {
                ReceiveProblem = "No certificate could be made";
                Receiving = false;
            }
            else if (_receiver.Start() is { } problem)
            {
                ReceiveProblem = problem;
                Receiving = false;
            }
            else
            {
                ReceiveProblem = null;
                Receiving = true;
                try
                {
                    _multicast.Start();
                    _multicast.Announce(new DeviceInfo { Alias = Alias, Fingerprint = _fingerprint });
                }
                catch { /* announcements are a bonus: the scan still finds us */ }
            }
        }
        else
        {
            _receiver?.Stop();
            _multicast.Stop();
            Receiving = false;
            ReceiveProblem = null;
        }
        Notify();
    }

    public void Accept() => Incoming?.Accept();
    public void Decline() => Incoming?.Decline();

    public void DismissMessage()
    {
        Message = null;
        Notify();
    }

    /// <summary>The incoming card is put away.</summary>
    public void DismissIncoming()
    {
        if (Incoming is null || Incoming.State is IncomingState.Asking or IncomingState.Receiving) return;
        Incoming = null;
        Notify();
    }

    public void ShowReceived()
    {
        var first = Incoming?.Saved.FirstOrDefault();
        if (first is null) return;
        try { Process.Start("explorer.exe", $"/select,\"{first}\""); } catch { /* no Explorer */ }
    }
}
