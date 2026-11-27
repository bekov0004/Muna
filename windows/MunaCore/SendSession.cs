namespace Muna.Core;

public enum TransferPhase { Waiting, Sending, Done, Failed, Missing }

/// <summary>One device of a sending and how far it got.</summary>
public sealed class Transfer
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public TransferPhase Phase { get; internal set; }
    public long Sent { get; internal set; }
    public long Total { get; internal set; }
    public string Message { get; internal set; } = "";
    public int Count { get; internal set; }
    public int Skipped { get; internal set; }
    internal Device? Device { get; init; }
    internal GroupMember? Member { get; init; }
}

public enum SessionPhase { Scan, Pick, Sending, Done }

/// <summary>The LocalSend section's logic, like Muna on Linux (linux/src/localsend/localSendSession.js):
/// the devices found, the basket, which devices are chosen, the groups, and the transfers (one per
/// chosen device, all at once). Call it on one thread; <see cref="Post"/> brings the network's
/// answers back to it (the app: the UI thread).</summary>
public sealed class SendSession
{
    readonly ILocalSendTransport _transport;
    readonly GroupsStore _groups;
    readonly Dictionary<string, CancellationTokenSource> _sending = new();
    CancellationTokenSource? _scan;
    DateTime _scannedAt = DateTime.MinValue;
    List<string> _files = new();
    bool _progressPending;

    public Action<Action> Post { get; set; } = action => action();
    public event Action? Changed;
    /// <summary>The end of a sending: (title, details, all received?).</summary>
    public event Action<string, string, bool>? Finished;
    public Func<IEnumerable<string>> Hosts { get; set; } = LocalNetwork.SubnetHosts;

    public SessionPhase Phase { get; private set; } = SessionPhase.Pick;
    public List<Device> Devices { get; private set; } = new();
    public List<string> Basket { get; } = new();
    /// <summary>A text message that goes with the files, or alone ("" : none).</summary>
    public string Text { get; private set; } = "";
    string _text = "";
    public bool HasContent => Basket.Count > 0 || Text.Trim().Length > 0;
    public HashSet<string> Selected { get; private set; } = new();
    public string? ActiveGroupId { get; private set; }
    public List<Transfer> Transfers { get; private set; } = new();
    public string Message { get; private set; } = "";

    public SendSession(ILocalSendTransport transport, GroupsStore groups)
    {
        _transport = transport;
        _groups = groups;
    }

    public IReadOnlyList<DeviceGroup> Groups => _groups.Groups;
    public DeviceGroup? ActiveGroup => _groups.Groups.FirstOrDefault(g => g.Id == ActiveGroupId);
    public bool Busy => Transfers.Any(t => t.Phase is TransferPhase.Waiting or TransferPhase.Sending);
    public List<Device> SelectedDevices => Devices.Where(d => Selected.Contains(d.Key)).ToList();

    void Change() => Changed?.Invoke();

    // the basket

    public void Offer(IEnumerable<string> files)
    {
        foreach (var file in files)
            if (!Basket.Contains(file)) Basket.Add(file);
        BackToPick();
        Change();
    }

    public void Remove(string file) { Basket.Remove(file); Change(); }

    public void SetText(string text)
    {
        Text = text ?? "";
        BackToPick();
        Change();
    }
    public void ClearBasket() { Basket.Clear(); Change(); }

    // choosing

    public bool IsSelected(Device device) => Selected.Contains(device.Key);

    public void Toggle(Device device)
    {
        if (!Selected.Remove(device.Key)) Selected.Add(device.Key);
        if (Selected.Count == 0) ActiveGroupId = null;
        Change();
    }

    public void SelectAll()
    {
        foreach (var device in Devices) Selected.Add(device.Key);
        ActiveGroupId = null;
        Change();
    }

    public void ClearSelection()
    {
        Selected.Clear();
        ActiveGroupId = null;
        Change();
    }

    /// <summary>Chooses the members of a group that are here (again: unchooses them).</summary>
    public void SelectGroup(DeviceGroup group)
    {
        if (ActiveGroupId == group.Id) { ClearSelection(); return; }
        Selected = group.Presence(Devices).Found.Select(d => d.Key).ToHashSet();
        ActiveGroupId = group.Id;
        Change();
    }

    /// <summary>Saves the chosen devices as a group. Throws GroupException.</summary>
    public void SaveGroup(string name)
    {
        ActiveGroupId = _groups.Save(null, name, SelectedDevices.Select(d => d.AsMember)).Id;
        Change();
    }

    public void DeleteGroup(string id)
    {
        _groups.Delete(id);
        if (ActiveGroupId == id) ActiveGroupId = null;
        Change();
    }

    // finding devices

    /// <summary>The section was opened: look again unless a recent list or a sending is there.</summary>
    public void Refresh(bool force = false)
    {
        if (Busy) return;
        BackToPick();
        if (force || DateTime.UtcNow - _scannedAt > TimeSpan.FromSeconds(60)) Scan();
        else Change();
    }

    public void Scan()
    {
        if (Busy) return;
        _scan?.Cancel();
        var scan = new CancellationTokenSource();
        _scan = scan;
        Devices = new();
        Phase = SessionPhase.Scan;
        _scannedAt = DateTime.UtcNow;
        Change();
        var hosts = Hosts().ToList();
        _ = Task.Run(async () =>
        {
            await LocalNetwork.Scan(hosts, _transport, device => Post(() => Found(device)), scan.Token);
            Post(() =>
            {
                if (_scan != scan || Phase != SessionPhase.Scan) return;
                Phase = SessionPhase.Pick;
                Change();
            });
        });
    }

    /// <summary>A device answered (a scan, or one that announced itself).</summary>
    public void Found(Device device)
    {
        if (Devices.Any(d => d.Ip == device.Ip)) return;
        Devices = Device.Sorted(Devices.Append(device));
        // the members of the chosen group that answer late join the choice
        if (ActiveGroup is { } group && group.Members.Any(device.IsMember)) Selected.Add(device.Key);
        Change();
    }

    public void CancelScan()
    {
        _scan?.Cancel();
        _scan = null;
        if (Phase == SessionPhase.Scan) { Phase = SessionPhase.Pick; Change(); }
    }

    // sending

    /// <summary>Sends the basket to every chosen device at once; the task ends with the summary.</summary>
    public Task Send()
    {
        var chosen = SelectedDevices;
        if (Busy || chosen.Count == 0 || !HasContent) return Task.CompletedTask;
        _files = Basket.ToList();
        _text = Text.Trim();
        return Start(chosen, ActiveGroup?.Presence(Devices).Missing ?? new(), new());
    }

    public Task SendTo(Device device)
    {
        if (Busy) return Task.CompletedTask;
        Selected = new HashSet<string> { device.Key };
        ActiveGroupId = null;
        return Send();
    }

    /// <summary>Tries again for those that did not get the files; members not found are looked for again.</summary>
    public Task RetryFailed()
    {
        if (Busy || Phase != SessionPhase.Done) return Task.CompletedTask;
        var failed = Transfers.Where(t => t.Phase == TransferPhase.Failed).Select(t => t.Device!).ToList();
        var missing = Transfers.Where(t => t.Phase == TransferPhase.Missing).Select(t => t.Member!).ToList();
        var nowFound = missing.Select(m => Devices.FirstOrDefault(d => d.IsMember(m))).OfType<Device>().ToList();
        var stillMissing = missing.Where(m => !Devices.Any(d => d.IsMember(m))).ToList();
        if (failed.Count + nowFound.Count == 0) return Task.CompletedTask;
        return Start(failed.Concat(nowFound).ToList(), stillMissing, Transfers.Where(t => t.Phase == TransferPhase.Done).ToList());
    }

    public void Cancel()
    {
        foreach (var source in _sending.Values) source.Cancel();
    }

    /// <summary>Leaves the summary of the last sending.</summary>
    public void Dismiss()
    {
        if (Busy) return;
        BackToPick();
        Change();
    }

    void BackToPick()
    {
        if (Phase != SessionPhase.Done) return;
        Phase = SessionPhase.Pick;
        Transfers = new();
    }

    Task Start(List<Device> devices, List<GroupMember> missing, List<Transfer> keep)
    {
        CancelScan();
        Phase = SessionPhase.Sending;
        Message = "";
        Transfers = keep
            .Concat(devices.Select(d => new Transfer { Id = d.Key, Name = d.Alias, Phase = TransferPhase.Waiting, Device = d }))
            .Concat(missing.Select(m => new Transfer
            {
                Id = "missing:" + (m.Fingerprint.Length > 0 ? m.Fingerprint : m.Alias), Name = m.Alias,
                Phase = TransferPhase.Missing, Message = "Not on the network", Member = m,
            }))
            .ToList();
        Change();
        var files = _files;
        var text = _text;
        var done = new TaskCompletionSource();
        var waiting = Transfers.Where(t => t.Phase == TransferPhase.Waiting).ToList();
        foreach (var transfer in waiting)
        {
            var cancel = new CancellationTokenSource();
            _sending[transfer.Id] = cancel;
            var device = transfer.Device!;
            _ = Task.Run(async () =>
            {
                SendResult? result = null;
                string? error = null;
                try
                {
                    result = await _transport.Send(device, files, progress => Post(() => Progress(transfer, progress)), cancel.Token, text.Length > 0 ? text : null);
                }
                catch (Exception e)
                {
                    error = e is SendException ? e.Message : e.Message;
                }
                Post(() =>
                {
                    Ended(transfer, result, error);
                    if (!Busy) done.TrySetResult();
                });
            });
        }
        if (waiting.Count == 0) done.TrySetResult();
        return done.Task;
    }

    void Progress(Transfer transfer, SendProgress progress)
    {
        if (transfer.Phase is not (TransferPhase.Waiting or TransferPhase.Sending)) return;
        var phase = progress.Phase == "waiting" ? TransferPhase.Waiting : TransferPhase.Sending;
        var changed = transfer.Phase != phase;
        transfer.Phase = phase;
        transfer.Sent = progress.Sent;
        transfer.Total = progress.Total;
        if (changed) { Change(); return; }
        if (_progressPending) return;
        // many devices send many updates: redraw at most ten times a second
        _progressPending = true;
        _ = Task.Delay(100).ContinueWith(_ => Post(() => { _progressPending = false; Change(); }));
    }

    void Ended(Transfer transfer, SendResult? result, string? error)
    {
        _sending.Remove(transfer.Id);
        if (result is not null)
        {
            transfer.Phase = TransferPhase.Done;
            transfer.Sent = transfer.Total;
            transfer.Count = result.Count;
            transfer.Skipped = result.Skipped;
            transfer.Message = "Received";
        }
        else
        {
            transfer.Phase = TransferPhase.Failed;
            transfer.Message = error ?? "Failed";
        }
        if (Busy) Change(); else Finish();
    }

    void Finish()
    {
        var done = Transfers.Where(t => t.Phase == TransferPhase.Done).ToList();
        if (done.Count == Transfers.Count)
        {
            Basket.RemoveAll(_files.Contains);
            if (_text.Length > 0 && Text.Trim() == _text) Text = "";
        }
        var files = done.Count == 0 ? 0 : done.Max(t => t.Count);
        var skipped = done.Count == 0 ? 0 : done.Max(t => t.Skipped);
        var filesText = _files.Count == 0 ? "A text" : $"{_files.Count} file{(_files.Count == 1 ? "" : "s")}{(_text.Length > 0 ? " and a text" : "")}";
        string details;
        if (Transfers.Count == 1)
        {
            var one = Transfers[0];
            Message = one.Phase == TransferPhase.Done ? $"Sent to {one.Name}" : one.Message;
            details = one.Phase == TransferPhase.Done ? (skipped > 0 ? $"{skipped} folder skipped" : filesText) : "";
        }
        else
        {
            Message = done.Count == Transfers.Count ? $"Sent to all {Transfers.Count}" : $"{done.Count} of {Transfers.Count} received";
            var left = Transfers.Where(t => t.Phase != TransferPhase.Done).Select(t => t.Name).ToList();
            details = left.Count == 0 ? filesText : "Not received: " + string.Join(", ", left);
        }
        Phase = SessionPhase.Done;
        var onlyCancelled = done.Count == 0 && Transfers.All(t => t.Message == "Cancelled" || t.Phase == TransferPhase.Missing);
        if (!onlyCancelled) Finished?.Invoke(Message, details, done.Count == Transfers.Count);
        Change();
    }
}
