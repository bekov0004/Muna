using System.Diagnostics;
using System.Net.Security;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using Muna.Core;
using Xunit;

namespace Muna.Core.Tests;

/// <summary>A folder of its own for each test.</summary>
public sealed class TempFolder : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "muna-" + Guid.NewGuid().ToString("N"));
    public TempFolder() => Directory.CreateDirectory(Path);
    public string File(string name, string text) { var p = System.IO.Path.Combine(Path, name); System.IO.File.WriteAllText(p, text); return p; }
    public JsonStore Store(string name) => new(name, Path);
    public void Dispose() { try { Directory.Delete(Path, true); } catch { } }
}

public class DataFileTests
{
    [Fact]
    public void ReadsLinuxNotesAndRepairsIds()
    {
        using var t = new TempFolder();
        t.File("notes.json", """{"version":1,"notes":[{"id":5,"text":"a"},{"text":42},{"id":5,"text":"b","private":true},{"text":"c","at":1764060000000}]}""");
        var notes = new NotesStore(t.Store("notes.json"));
        Assert.Equal(new[] { "a", "b", "c" }, notes.Notes.Select(n => n.Text));
        Assert.Equal(new[] { 5, 6, 7 }, notes.Notes.Select(n => n.Id));
        Assert.True(notes.Notes[1].IsPrivate);
        Assert.Equal(1764060000000, notes.Notes[2].At);
    }

    [Fact]
    public void NotesAndTodosAreSavedInTheSharedShape()
    {
        using var t = new TempFolder();
        var notes = new NotesStore(t.Store("notes.json"));
        Assert.False(notes.Add("   "));
        Assert.True(notes.Add("  first "));
        Assert.True(notes.Add(new string('x', 1500)));
        notes.SetPrivate(1, true);
        var file = JsonNode.Parse(File.ReadAllText(System.IO.Path.Combine(t.Path, "notes.json")))!;
        Assert.Equal(1, file["version"]!.GetValue<int>());
        Assert.Equal(1000, file["notes"]![0]!["text"]!.GetValue<string>().Length);
        Assert.Equal("first", file["notes"]![1]!["text"]!.GetValue<string>());
        Assert.True(file["notes"]![1]!["private"]!.GetValue<bool>());

        var todo = new TodoStore(t.Store("todo.json"));
        todo.Add("one"); todo.Add("two"); todo.Toggle(1);
        Assert.Equal(1, todo.OpenCount);
        todo.ClearDone();
        Assert.Equal(new[] { "two" }, new TodoStore(t.Store("todo.json")).Items.Select(i => i.Text));
    }

    [Fact]
    public void BrokenFileIsEmpty()
    {
        using var t = new TempFolder();
        t.File("todo.json", "{not json");
        Assert.Empty(new TodoStore(t.Store("todo.json")).Items);
    }

    [Fact]
    public void ClipboardHistory()
    {
        using var t = new TempFolder();
        var h = new ClipboardHistory(t.Store("clipboard.json")) { Limit = 2 };
        h.AddText("one"); h.AddText("one"); h.AddText("two");
        h.SetSaved(h.Items[1], true);
        h.AddText("three"); h.AddText("four");
        Assert.Equal(new[] { "four", "three", "one" }, h.Items.Select(i => i.Text));
        h.AddText("one");
        Assert.Equal("one", h.Items[0].Text);
        Assert.True(h.Items[0].Saved);
        h.AddFiles(new[] { "file:///tmp/a.png" });
        var first = JsonNode.Parse(File.ReadAllText(System.IO.Path.Combine(t.Path, "clipboard.json")))!["items"]![0]!;
        Assert.Null(first["text"]);                                  // null, as Linux writes it
        Assert.True(((JsonObject)first).ContainsKey("text"));
        Assert.Equal("file:///tmp/a.png", first["files"]![0]!.GetValue<string>());
        h.KeepHistory = false;
        Assert.Equal(new[] { "one" }, new ClipboardHistory(t.Store("clipboard.json")).Items.Select(i => i.Text));
    }

    [Fact]
    public void Tray()
    {
        using var t = new TempFolder();
        var a = t.File("a.txt", "a");
        var tray = new TrayStore(t.Store("tray.json"));
        tray.Add(new[] { a, a, System.IO.Path.Combine(t.Path, "missing") });
        Assert.Equal(new[] { a }, tray.Files);
        Assert.Equal(new[] { a }, new TrayStore(t.Store("tray.json")).Files);
        File.Delete(a);
        Assert.Empty(new TrayStore(t.Store("tray.json")).Files);
    }
}

public class GroupTests
{
    static readonly Device Anvar = new("10.0.0.2", 53317, "https", "Anvar", "Muna", "desktop", "fp-anvar");
    static readonly Device Pixel = new("10.0.0.4", 53317, "https", "Pixel", "Pixel 8", "mobile", "");

    [Fact]
    public void ReadsLinuxGroupsAndMatches()
    {
        using var t = new TempFolder();
        t.File("g.json", """{"version":1,"groups":[{"id":"gx","name":"Office","members":[{"fingerprint":"fp-anvar","alias":"Anvar","deviceModel":"Muna","deviceType":"desktop"},{"fingerprint":"","alias":"Pixel"}]}]}""");
        var store = new GroupsStore(t.Store("g.json"));
        var moved = Anvar with { Ip = "10.0.0.99", Alias = "renamed" };
        var presence = store.Groups[0].Presence(new[] { moved, Pixel });
        Assert.Equal(new[] { "10.0.0.99", "10.0.0.4" }, presence.Found.Select(d => d.Ip));
        Assert.Empty(presence.Missing);
    }

    [Fact]
    public void RulesLikeLinux()
    {
        using var t = new TempFolder();
        var store = new GroupsStore(t.Store("g.json"));
        Assert.Throws<GroupException>(() => store.Save(null, " ", new[] { Anvar.AsMember }));
        Assert.Throws<GroupException>(() => store.Save(null, "Office", Array.Empty<GroupMember>()));
        store.Save(null, "Office", new[] { Anvar.AsMember });
        store.Save(null, "Friends", new[] { Pixel.AsMember });
        var replaced = store.Save(null, "OFFICE", new[] { Anvar.AsMember, Pixel.AsMember });
        Assert.Equal(new[] { "OFFICE", "Friends" }, store.Groups.Select(g => g.Name));
        Assert.Equal(60, store.Save(null, new string('n', 99), new[] { Pixel.AsMember }).Name.Length);
        store.Delete(replaced.Id);
        Assert.Equal("Friends", new GroupsStore(t.Store("g.json")).Groups[0].Name);
        Assert.Equal(new[] { "Anvar", "Pixel" }, Device.Sorted(new[] { Pixel, Anvar }).Select(d => d.Alias));
        Assert.Equal("10.0.0.4:53317", Pixel.Key);
    }
}

public class LocalSendTests
{
    [Fact]
    public void Names()
    {
        Assert.Equal("passwd", ReceivedFileNames.Safe("../../etc/passwd"));
        Assert.Equal("report.pdf", ReceivedFileNames.Safe(@"a\b\report.pdf"));
        Assert.Equal("_bashrc", ReceivedFileNames.Safe(".bashrc"));
        Assert.Equal("file", ReceivedFileNames.Safe(".."));
        var taken = new HashSet<string> { System.IO.Path.Combine("/x", "a.pdf"), System.IO.Path.Combine("/x", "a (1).pdf") };
        Assert.Equal("a (2).pdf", System.IO.Path.GetFileName(ReceivedFileNames.Free("/x", "a.pdf", taken.Contains)));
    }

    [Fact]
    public void InfoIsWhatLinuxSends()
    {
        var json = new DeviceInfo { Alias = "pc", Fingerprint = "abc" }.ToJson();
        Assert.Equal("Muna", json["deviceModel"]!.GetValue<string>());
        Assert.Equal(53317, json["port"]!.GetValue<int>());
        Assert.False(json.ContainsKey("announce"));
        var info = DeviceInfo.From(JsonNode.Parse("""{"alias":"Test Pixel","deviceModel":"Pixel 8","deviceType":"mobile"}"""))!;
        Assert.False(Device.From("1.2.3.4", 53317, "http", info).IsMuna);
        Assert.Null(DeviceInfo.From(JsonNode.Parse("{}")));
    }

    [Fact]
    public void HttpHead()
    {
        var head = HttpRequestHead.Parse("POST /api/localsend/v2/upload?sessionId=s%201&fileId=f0&token=t HTTP/1.1\r\nContent-Length: 10\r\nConnection: close");
        Assert.Equal("/api/localsend/v2/upload", head.Path);
        Assert.Equal("s 1", head.Query["sessionId"]);
        Assert.Equal(10, head.ContentLength);
        Assert.False(head.KeepAlive);
        Assert.StartsWith("HTTP/1.1 403 Forbidden\r\n", Encoding.ASCII.GetString(HttpResponse.Message(403, "Rejected").Serialize(true)));
    }

    [Fact]
    public async Task ChunkedBodies()
    {
        var bytes = Encoding.ASCII.GetBytes("POST /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;x=y\r\npedia\r\n0\r\n\r\nGET /b HTTP/1.1\r\n\r\n");
        var reader = new HttpConnectionReader(new MemoryStream(bytes));
        var head = (await reader.ReadHeadAsync(default))!;
        var body = new List<byte>();
        await foreach (var piece in reader.ReadBodyAsync(head, default)) body.AddRange(piece);
        Assert.Equal("Wikipedia", Encoding.ASCII.GetString(body.ToArray()));
        Assert.Equal("/b", (await reader.ReadHeadAsync(default))!.Path);
    }

    /// <summary>Muna sends to Muna over HTTPS on this machine: accept, a second sender while busy, decline.</summary>
    [Fact]
    public async Task SendAndReceiveOverHttps()
    {
        using var t = new TempFolder();
        var certificate = LocalSendCertificate.LoadOrCreate(t.Path);
        Assert.Equal(64, LocalSendCertificate.Fingerprint(certificate).Length);
        var downloads = System.IO.Path.Combine(t.Path, "Downloads");
        var port = 18000 + Random.Shared.Next(1000);
        var receiver = new LocalSendReceiver(certificate, () => new DeviceInfo { Alias = "me", Fingerprint = "fp-me" }, () => downloads, port);
        Assert.Null(receiver.Start());
        var answer = true;
        receiver.Incoming += transfer => { if (answer) transfer.Accept(); else transfer.Decline(); };
        File.WriteAllText(System.IO.Path.Combine(t.Path, "a.txt"), new string('m', 300000));
        Directory.CreateDirectory(downloads);
        File.WriteAllText(System.IO.Path.Combine(downloads, "a.txt"), "old");
        using var client = new LocalSendClient(() => new DeviceInfo { Alias = "other", Fingerprint = "fp-other" }, certificate);
        var device = new Device("127.0.0.1", port, "https", "me", "Muna", "desktop", "fp-me");
        var phases = new List<string>();
        long last = 0;
        var result = await client.Send(device, new[] { System.IO.Path.Combine(t.Path, "a.txt"), t.Path }, p => { if (phases.LastOrDefault() != p.Phase) phases.Add(p.Phase); last = p.Sent; }, default);
        Assert.Equal(new SendResult(1, 1), result);
        Assert.Equal(new[] { "waiting", "sending" }, phases);
        Assert.Equal(300000, last);
        Assert.Equal(300000, new FileInfo(System.IO.Path.Combine(downloads, "a (1).txt")).Length);
        Assert.Equal(IncomingState.Done, receiver.Current!.State);
        answer = false;
        var declined = await Assert.ThrowsAsync<SendException>(() => client.Send(device, new[] { System.IO.Path.Combine(t.Path, "a.txt") }, _ => { }, default));
        Assert.Equal("me declined", declined.Message);
        Assert.Empty(Directory.GetFiles(downloads, "*.muna-part"));
        receiver.Stop();
    }

    [Fact]
    public async Task SenderGoneWhileAsked()
    {
        using var t = new TempFolder();
        var port = 19000 + Random.Shared.Next(1000);
        var receiver = new LocalSendReceiver(LocalSendCertificate.LoadOrCreate(t.Path), () => new DeviceInfo { Alias = "me" }, () => t.Path, port);
        receiver.Start();
        using var tcp = new TcpClient();
        await tcp.ConnectAsync("127.0.0.1", port);
        var tls = new SslStream(tcp.GetStream(), false, (_, _, _, _) => true);
        await tls.AuthenticateAsClientAsync("muna");
        var body = """{"info":{"alias":"x"},"files":{"f0":{"id":"f0","fileName":"a.txt","size":5}}}""";
        await tls.WriteAsync(Encoding.ASCII.GetBytes($"POST /api/localsend/v2/prepare-upload HTTP/1.1\r\nContent-Length: {body.Length}\r\n\r\n{body}"));
        for (var i = 0; i < 40 && receiver.Current is null; i++) await Task.Delay(50);
        Assert.Equal(IncomingState.Asking, receiver.Current!.State);
        tcp.Close();
        for (var i = 0; i < 40 && receiver.Current.State == IncomingState.Asking; i++) await Task.Delay(100);
        Assert.Equal(IncomingState.Failed, receiver.Current.State);
        Assert.Equal("The sender stopped", receiver.Current.Error);
        receiver.Stop();
    }

    /// <summary>The client against shared/testing/fakels.py (plain HTTP, like a LocalSend app).</summary>
    [Fact]
    public async Task ClientAgainstFakeDevices()
    {
        var fake = System.IO.Path.GetFullPath(System.IO.Path.Combine(AppContext.BaseDirectory, "../../../../../shared/testing/fakels.py"));
        if (!File.Exists(fake) || !File.Exists("/usr/bin/python3")) return;
        var processes = new[] { ("127.0.0.22", "Ali", "accept"), ("127.0.0.23", "Vali", "decline") }
            .Select(d => Process.Start("/usr/bin/python3", new[] { fake, d.Item1, d.Item2, "Muna", "fp-" + d.Item2, d.Item3, "0.2" })!).ToList();
        try
        {
            await Task.Delay(1000);
            using var t = new TempFolder();
            var file = t.File("c.txt", new string('x', 100000));
            using var client = new LocalSendClient(() => new DeviceInfo { Alias = "pc", Fingerprint = "fp-pc" }, null);
            var ali = await client.Probe("127.0.0.22", default);
            Assert.Equal("Ali", ali?.Alias);
            Assert.Equal("http", ali?.Protocol);
            Assert.True(ali!.IsMuna);
            Assert.Null(await client.Probe("127.0.0.29", default));
            Assert.Equal(new SendResult(1, 0), await client.Send(ali, new[] { file }, _ => { }, default));
            Assert.Equal(100000, new FileInfo("/tmp/ls-group/Ali/c.txt").Length);
            var vali = (await client.Probe("127.0.0.23", default))!;
            Assert.Equal("Vali declined", (await Assert.ThrowsAsync<SendException>(() => client.Send(vali, new[] { file }, _ => { }, default))).Message);
        }
        finally { foreach (var p in processes) p.Kill(); }
    }
}

/// <summary>A network of pretend devices for the session.</summary>
sealed class FakeTransport : ILocalSendTransport
{
    public Dictionary<string, Device> Devices = new();
    public HashSet<string> Declines = new();
    public List<string> Sent = new();

    public Task<Device?> Probe(string ip, CancellationToken token) => Task.FromResult(Devices.GetValueOrDefault(ip));

    public async Task<SendResult> Send(Device device, IReadOnlyList<string> files, Action<SendProgress> onState, CancellationToken token)
    {
        onState(new SendProgress("waiting", 0, 10, 0));
        await Task.Delay(50, token);
        if (Declines.Contains(device.Alias)) throw new SendException($"{device.Alias} declined");
        onState(new SendProgress("sending", 5, 10, 0));
        lock (Sent) Sent.Add(device.Alias);
        return new SendResult(files.Count, 0);
    }
}

public class SessionTests
{
    [Fact]
    public async Task GroupSendSummaryAndRetry()
    {
        using var t = new TempFolder();
        var transport = new FakeTransport
        {
            Devices =
            {
                ["10.0.0.2"] = new Device("10.0.0.2", 53317, "https", "Anvar", "Muna", "desktop", "fp-anvar"),
                ["10.0.0.3"] = new Device("10.0.0.3", 53317, "https", "Dilnoza", "Muna", "desktop", "fp-dilnoza"),
                ["10.0.0.4"] = new Device("10.0.0.4", 53317, "https", "Pixel", "Pixel 8", "mobile", ""),
            },
            Declines = { "Pixel" },
        };
        var groups = new GroupsStore(t.Store("g.json"));
        var session = new SendSession(transport, groups) { Hosts = () => new[] { "10.0.0.4", "10.0.0.3", "10.0.0.2", "10.0.0.9" } };
        var gate = new object();
        session.Post = action => { lock (gate) action(); };
        var finished = new List<string>();
        session.Finished += (title, details, _) => finished.Add($"{title} | {details}");
        lock (gate) session.Scan();
        for (var i = 0; i < 100 && session.Phase == SessionPhase.Scan; i++) await Task.Delay(20);
        lock (gate)
        {
            Assert.Equal(new[] { "Anvar", "Dilnoza", "Pixel" }, session.Devices.Select(d => d.Alias));
            session.Offer(new[] { "/tmp/a.txt" });
            session.Toggle(session.Devices[0]);
            session.Toggle(session.Devices[2]);
            session.SaveGroup("Office");
            var office = session.ActiveGroup!;
            groups.Save(office.Id, "Office", office.Members.Append(new GroupMember("fp-bekzod", "Bekzod")));
            session.ClearSelection();
            session.SelectGroup(session.Groups[0]);
            Assert.Equal(new[] { "Anvar", "Pixel" }, session.SelectedDevices.Select(d => d.Alias));
        }
        Task sending;
        lock (gate) sending = session.Send();
        await sending;
        lock (gate)
        {
            Assert.Equal("1 of 3 received", session.Message);
            Assert.Equal(new[] { "Anvar:Done", "Pixel:Failed", "Bekzod:Missing" }, session.Transfers.Select(x => $"{x.Name}:{x.Phase}"));
            Assert.Single(session.Basket);
            Assert.Equal("1 of 3 received | Not received: Pixel, Bekzod", finished.Last());
            transport.Declines.Clear();
            sending = session.RetryFailed();
        }
        await sending;
        lock (gate)
        {
            Assert.Equal("2 of 3 received", session.Message);
            session.Dismiss();
            sending = session.SendTo(session.Devices[1]);
        }
        await sending;
        lock (gate)
        {
            Assert.Equal("Sent to Dilnoza", session.Message);
            Assert.Empty(session.Basket);
        }
    }
}

public class ToolTests
{
    [Fact]
    public void LayoutLikeLinux()
    {
        var cells = new Dictionary<string, int> { ["media"] = 5, ["calendar"] = 4, ["mirror"] = 3, ["timer"] = 3 };
        var layout = PanelLayout.Make(1920, new[] { "media", "calendar", "mirror", "timer" }, id => cells.GetValueOrDefault(id, 4));
        Assert.Equal(740, layout.Width);
        Assert.Equal(new double[] { 220, 176, 132, 132 }, layout.Pages[0].Select(s => s.Width));
        Assert.Equal(560, PanelLayout.Make(1920, new[] { "timer" }, _ => 3).Width);
        // a bigger size, a fixed width
        var big = PanelLayout.Make(1920, new[] { "media", "calendar" }, _ => 5, look: new LayoutLook(Scale: 1.2, Gap: 10, Padding: 20));
        Assert.Equal(Math.Round(10 * 44 * 1.2 + 10 + 40), big.Width);
        Assert.Equal(20, big.Padding);
        var fixedWidth = PanelLayout.Make(1920, new[] { "timer" }, _ => 3, look: new LayoutLook(FixedShare: 0.5));
        Assert.Equal(960, fixedWidth.Width);
        Assert.Equal(960 - 32, fixedWidth.Pages[0][0].Width);
    }

    [Fact]
    public void CommandEngineLikeLinux()
    {
        Assert.Equal(84, CommandEngine.Calculate("12*(3+4)"));
        Assert.Equal(1024, CommandEngine.Calculate("2^10"));
        Assert.Equal(6, CommandEngine.Calculate("2 x 3"));
        Assert.Equal(5, CommandEngine.Calculate("sqrt(16) + 1"));
        Assert.Equal(1, CommandEngine.Calculate("10 % 3"));
        Assert.Equal(4, CommandEngine.Calculate("-2^2"));
        Assert.Null(CommandEngine.Calculate("5"));
        Assert.Null(CommandEngine.Calculate("1/0"));
        Assert.Equal("0.3", CommandEngine.Format(0.1 + 0.2));
        Assert.Equal("5 km = 3.106856 mi", CommandEngine.Convert("5 km to mi")?.Text);
        Assert.Equal(212, CommandEngine.Convert("100 c to f")?.Value);
        Assert.Null(CommandEngine.Convert("5 km to kg"));
        Assert.Equal(80, CommandEngine.MatchScore("Safari", "saf"));
        Assert.Equal(60, CommandEngine.MatchScore("Visual Studio Code", "stu"));
        Assert.Equal(0, CommandEngine.MatchScore("Notes", "nts"));
        Assert.Equal(20, CommandEngine.MatchScore("Finder", "fnd"));
    }

    [Theory]
    [InlineData("https://example.com/page?utm_source=x&utm_medium=y&id=5#top", "https://example.com/page?id=5#top")]
    [InlineData("https://www.youtube.com/watch?v=abc&si=XyZ", "https://www.youtube.com/watch?v=abc")]
    [InlineData("https://shop.com/?fbclid=1", "https://shop.com/")]
    [InlineData("HTTP://a.b/c?UTM_Campaign=1&q=2", null)]
    [InlineData("http://a.b/c?UTM_Campaign=1&q=2", "http://a.b/c?q=2")]
    [InlineData("  https://a.b/?gclid=1&&q=3  ", "https://a.b/?q=3")]
    [InlineData("https://a.b/?q=1", null)]
    [InlineData("hello ?utm_source=1", null)]
    [InlineData("https://a.b/?utm_=1&x", null)]
    [InlineData("https://a.b/?q=1&gclid", "https://a.b/?q=1")]
    public void LinkCleanerLikeLinux(string input, string? expected) => Assert.Equal(expected, LinkCleaner.Clean(input));

    [Fact]
    public void Snippets()
    {
        using var t = new TempFolder();
        var store = new SnippetsStore(t.Store("snippets.json"));
        store.Add(";sig", "Best");
        store.Add(";mail", "me@x");
        Assert.Throws<ArgumentException>(() => store.Add(" ", "x"));
        Assert.Equal(new[] { ";mail", ";sig" }, new SnippetsStore(t.Store("snippets.json")).Snippets.Select(s => s.Trigger));
        Assert.Equal("2026-11-25 at 09:05 / 2026-11-25 09:05", SnippetsStore.Expand("{date} at {time} / {datetime}", new DateTime(2026, 11, 25, 9, 5, 0)));
    }

    [Fact]
    public void LyricsLikeLinux()
    {
        var lines = LyricsClient.ParseLrc("[ar:Someone]\n[00:12.50] First line\n[01:02.00][00:05.00] Twice\nno stamp\n[00:12.50]");
        Assert.Equal(new[] { new LyricLine(5000, "Twice"), new LyricLine(12500, "First line"), new LyricLine(12500, ""), new LyricLine(62000, "Twice") }, lines);
        Assert.Equal("Twice", new LyricsResult(lines).LineAt(100)?.Text);
        Assert.Null(new LyricsResult(lines).LineAt(4.9));
    }

    [Fact]
    public void Phone()
    {
        var devices = PhoneAdb.ParseDevices("List of devices attached\nR58N12ABC\tdevice usb:1-1 product:a52 model:SM_A525F\n192.168.1.5:5555\tunauthorized\n");
        Assert.Equal(new[] { "R58N12ABC", "192.168.1.5:5555" }, devices.Select(d => d.Serial));
        Assert.Equal("SM A525F", devices[0].Model);
        Assert.False(devices[1].Ready);
        Assert.Equal((87, true), PhoneAdb.ParseBattery("  USB powered: true\n  level: 87\n  scale: 100\n"));
        Assert.Equal("hello%sworld", PhoneAdb.EscapeInputText("hello world"));
        Assert.Equal(@"50\%%s\$x%s\""q\""", PhoneAdb.EscapeInputText("50% $x \"q\""));
    }

    [Fact]
    public void TerminalSessions()
    {
        using var t = new TempFolder();
        var claude = Directory.CreateDirectory(System.IO.Path.Combine(t.Path, "claude", "-home-me-app")).FullName;
        var codex = Directory.CreateDirectory(System.IO.Path.Combine(t.Path, "codex", "2026", "11", "25")).FullName;
        var now = DateTime.UtcNow;
        void Write(string path, string text, double ageSeconds) { File.WriteAllText(path, text); File.SetLastWriteTimeUtc(path, now.AddSeconds(-ageSeconds)); }
        Write(System.IO.Path.Combine(claude, "s-working.jsonl"), "{\"cwd\":\"/home/me/old\"}\n{\"cwd\":\"/home/me/app\"}\nnot json", 5);
        Write(System.IO.Path.Combine(claude, "s-ours.jsonl"), "{\"cwd\":\"/x\"}", 1);
        Write(System.IO.Path.Combine(claude, "s-old.jsonl"), "{\"cwd\":\"/x\"}", 8 * 86400);
        Write(System.IO.Path.Combine(codex, "rollout-1.jsonl"), "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/home/me/site\"}}", 600);
        var sessions = AgentSessions.Scan(System.IO.Path.Combine(t.Path, "claude"), System.IO.Path.Combine(t.Path, "codex"), new HashSet<string> { "s-ours" }, now);
        Assert.Equal(new[] { "s-working", "rollout-1" }, sessions.Select(s => s.SessionId));
        Assert.Equal(new[] { true, false }, sessions.Select(s => s.Working));
        Assert.Equal(new[] { "app", "site" }, sessions.Select(s => s.Project));
    }
}

public class ClaudeTaskTests
{
    [Fact]
    public async Task TurnPermissionAndFollowUp()
    {
        var fake = System.IO.Path.GetFullPath(System.IO.Path.Combine(AppContext.BaseDirectory, "../../../../../linux/service/agents/test/fake_claude.py"));
        if (!File.Exists(fake) || !File.Exists("/usr/bin/python3")) return;
        using var t = new TempFolder();
        var task = new ClaudeTask("t1", t.Path, "Add a README", fake);
        var gate = new object();
        task.Post = action => { lock (gate) action(); };
        var permissions = new List<Permission>();
        var finished = new List<bool>();
        task.PermissionAsked += (task, p) => { permissions.Add(p); task.Answer(p.RequestId, permissions.Count == 1 ? Decision.Allow : Decision.Deny); };
        task.Finished += (_, ok) => finished.Add(ok);
        lock (gate) task.Start();
        for (var i = 0; i < 200 && finished.Count < 1; i++) await Task.Delay(50);
        lock (gate)
        {
            Assert.Equal(AgentStatus.Idle, task.Status);
            Assert.Equal("claude-fake", task.Model);
            Assert.Equal("Writing", permissions[0].Verb);
            Assert.Equal("README.md", permissions[0].Detail);
            Assert.Equal(new[] { EntryKind.User, EntryKind.Text, EntryKind.Tool, EntryKind.Note, EntryKind.Text, EntryKind.Result }, task.Transcript.Select(e => e.Kind));
            Assert.True(task.Transcript[2].Ok);
            Assert.Equal(0.01, task.CostUsd, 4);
            Assert.Equal(15, task.Tokens);
            task.Send("Now add a license");
        }
        for (var i = 0; i < 200 && finished.Count < 2; i++) await Task.Delay(50);
        lock (gate)
        {
            Assert.Equal("Nothing was changed.", task.Transcript.Last().Text);
            Assert.Equal(0.02, task.CostUsd, 4);
            task.Stop();
        }
        for (var i = 0; i < 100 && task.Running; i++) await Task.Delay(50);
        Assert.Equal(AgentStatus.Stopped, task.Status);
    }
}

public class CalendarTests
{
    const string Ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" +
        "BEGIN:VEVENT\r\nUID:a\r\nDTSTART;VALUE=DATE:20261125\r\nDTEND;VALUE=DATE:20261126\r\nSUMMARY:Holiday\\, all day\r\nEND:VEVENT\r\n" +
        "BEGIN:VEVENT\r\nUID:b\r\nDTSTART:20261125T090000\r\nDURATION:PT1H30M\r\nSUMMARY:Stand-up with a very long\r\n  title\r\nEND:VEVENT\r\n" +
        "BEGIN:VEVENT\r\nUID:c\r\nDTSTART:20261102T140000\r\nDTEND:20261102T150000\r\nRRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=8\r\nEXDATE:20261111T140000\r\nSUMMARY:Gym\r\nEND:VEVENT\r\n" +
        "BEGIN:VEVENT\r\nUID:c\r\nRECURRENCE-ID:20261118T140000\r\nDTSTART:20261119T180000\r\nDTEND:20261119T190000\r\nSUMMARY:Gym (moved)\r\nEND:VEVENT\r\n" +
        "BEGIN:VEVENT\r\nUID:d\r\nDTSTART:20261125T100000\r\nSTATUS:CANCELLED\r\nSUMMARY:Gone\r\nEND:VEVENT\r\n" +
        "END:VCALENDAR\r\n";

    static List<string> On(List<CalendarEvent> events, int day) =>
        IcsCalendar.Occurrences(events, new DateTime(2026, 11, day), new DateTime(2026, 11, day).AddDays(1)).OrderBy(e => e.Start).Select(e => $"{e.Start:HH:mm} {e.Title}").ToList();

    [Fact]
    public void ReadsEventsAndRepeats()
    {
        var events = IcsCalendar.Parse(Ics);
        // the 8th Gym (11th skipped still counts) is on the 25th
        Assert.Equal(new[] { "00:00 Holiday, all day", "09:00 Stand-up with a very long title", "14:00 Gym" }, On(events, 25));
        Assert.Empty(On(events, 26));
        Assert.Equal(new[] { "14:00 Gym" }, On(events, 2));
        Assert.Equal(new[] { "14:00 Gym" }, On(events, 4));
        Assert.Empty(On(events, 11));                       // skipped
        Assert.Empty(On(events, 18));                       // moved …
        Assert.Equal(new[] { "18:00 Gym (moved)" }, On(events, 19));
        Assert.Equal(new[] { "14:00 Gym" }, On(events, 23));
        Assert.Empty(On(events, 30));                       // the 8 occurrences ended on the 25th
    }

    [Fact]
    public void UtcAndUntil()
    {
        var events = IcsCalendar.Parse("BEGIN:VEVENT\nUID:x\nDTSTART:20261125T120000Z\nDTEND:20261125T130000Z\nRRULE:FREQ=DAILY;UNTIL=20261127T120000Z\nSUMMARY:Daily\nEND:VEVENT\n");
        var local = new DateTime(2026, 11, 25, 12, 0, 0, DateTimeKind.Utc).ToLocalTime();
        var all = IcsCalendar.Occurrences(events, new DateTime(2026, 11, 20), new DateTime(2026, 12, 5));
        Assert.Equal(3, all.Count);
        Assert.Equal(local, all[0].Start);
    }
}

public class MoreFileTests
{
    [Fact]
    public void FocusLikeLinux()
    {
        using var t = new TempFolder();
        var now = 1764060000000.0;
        t.File("focus.json", """{"version":1,"stopwatch":{"state":"paused","since":0,"elapsed":12000,"laps":[5000]},"pomo":{"state":"running","phase":"work","endAt":1764059000000,"remaining":5,"round":2,"done":1,"config":{"work":500,"short":0,"long":15,"every":1}}}""");
        var focus = new FocusFile(t.Store("focus.json"), now);
        Assert.Equal("paused", focus.Stopwatch.State);
        Assert.Equal("idle", focus.Pomo.State);                       // it ran out while closed
        Assert.Equal(180, focus.Pomo.Config.Work);
        Assert.Equal(1, focus.Pomo.Config.Short);
        Assert.Equal(2, focus.Pomo.Config.Every);
        Assert.Equal("break", focus.Advance(now));
        Assert.Equal("work", focus.Advance(now));
        Assert.Equal(2, focus.Pomo.Round);
        Assert.Equal("long", focus.Advance(now));
        Assert.Equal("work", focus.Advance(now));
        Assert.Equal(1, focus.Pomo.Round);
        focus.Save();
        Assert.Equal(2, new FocusFile(t.Store("focus.json"), now).Pomo.Done);
    }

    [Fact]
    public void QrCodesAsLinux()
    {
        // made by linux/src/utils/qr.js with node: the same modules
        foreach (var (text, size, modules) in new[]
        {
            ("WIFI:T:ADB;S:muna-abcde;P:123456;;", 29, "1111111000000001111000111111110000010101011101000001000001101110101011010100001010111011011101010111000111010101110110111010000100011101101011101100000100011100101101010000011111111010101010101010111111100000000100110111001000000000100000101111000000000110011100110010101011100100101001000110101011100001111010011101000001111010010010100110010100010110001100100100001110101000100000000000110010101101110100011111111010000111101011001001100000101010001101011100111111111011000110001110000101011101001001001111100011110110001101011110110001111100110110110100101001101011000110010011101111110000101111111111111000000000011101011100010001001111111110001000011111101010100100000100100101010101000110011011101000111111001111111111110111010011000110001010010001101110100000100101100111110101000001000101000000001001110111111110100101011111011110000"),
            ("https://example.org/a-much-longer-text-that-needs-version-seven-or-more-of-the-qr-code-to-fit-in-it-0123456789abcdefghij0123456789abcdefghij", 49, "1111111001111011001010011000011010011000101111111100000100010111010010011110100010110001110100000110111010110001011011010111101100101000011010111011011101010011011100101101001011101111101001011101101110101111101100000111111111110000010000101110110000010110010010101001000110001111110100010000011111111010101010101010101010101010101010101111111000000001100001011000010001011101101010110000000010111110011000100010111111100111001110001011111000110100110100011010100011100111110000101001011110000110111100011010111010101011000110111011001101111011100101110100100010100011000111001010000100110111111100010101001000101010011000001101100001110111000011111101011111010000001110001100000101001000010010100101101110111110101100001110110000011110100000110101010100110110001011011010100010010001000001101110110010001101111011010000100111100110001011000001011011011010100011111000010000110000001011001110110001001011110110100101100110000101011100011001001010011100100011011001010000001011001101010011111101110110111110110110001111001110001110010010111000001010000010110011010011100011110000110011111000000100001111111101011011001011111101101011000110000101011001000111111111100011000100010010101011111101001111101010000100011110101011111101110001101000001110110001001110001100110001000000111111101101010001001111101001111110101111100010000110011110000111100011001111010000110000001001110010100100010010110100111100110101110100101111100011101011010011110010101110011110011000011000001000011100101101111100000101100111110111001100111110011000000001101100111001100001101010011001000111001011110011100000110101110011011011011101111101101100001010101101101101101111000010000110100000100110111010011010110101110110010111111000110101111011101001000010000001110101110110001101000000010111001000000000010011100101011101101101110110111101100010010011100110111100101110001010110010111001000110111001011101101110010000111101110111010110111000101010111001110110111111010100110100000011111000111101100000101011111101100011110111111111000000000111110011001011000111110100001001000101101111111001011000100000101010100111111110101010011100000101000111101110110001111001010010010001000110111010101001000100001111100110000110001111101001011101010011100111111100000101110001100101111101101110101000001000001111110101010110101101010100010000010011100100101100000011000110101000110000011111111010010011111010010100011100101011000001111"),
        })
        {
            var qr = Qr.Encode(text);
            Assert.Equal(size, qr.GetLength(0));
            var built = new System.Text.StringBuilder();
            for (var y = 0; y < size; y++)
                for (var x = 0; x < size; x++) built.Append(qr[y, x] ? '1' : '0');
            Assert.Equal(modules, built.ToString());
        }
    }

    [Fact]
    public void AdbMdns()
    {
        var found = PhoneAdb.ParseMdns("List of discovered mdns services\nmuna-abcde\t_adb-tls-pairing._tcp.\t192.168.1.20:37215\nadb-R58N-x1\t_adb-tls-connect._tcp\t192.168.1.20:41877\n");
        Assert.Equal(2, found.Count);
        Assert.Equal(("muna-abcde", "pairing", "192.168.1.20:37215"), found[0]);
        Assert.Equal("connect", found[1].Type);
    }

    [Fact]
    public void Toasts()
    {
        var xml = "<toast launch=\"x\"><visual><binding template=\"ToastGeneric\"><text>Anna</text><text>See you at 5?</text><text placement=\"attribution\">via Chat</text></binding></visual></toast>";
        Assert.Equal(("Anna", "See you at 5?"), ToastPayload.Parse(xml));
        Assert.Equal(("Done", ""), ToastPayload.Parse("<toast><visual><binding template=\"ToastText01\"><text id=\"1\">Done</text></binding></visual></toast>"));
        Assert.Null(ToastPayload.Parse("<toast><visual><binding/></visual></toast>"));
        Assert.Null(ToastPayload.Parse("not xml"));
        Assert.Equal("Windows Store", ToastPayload.AppName("Microsoft.WindowsStore_8wekyb3d8bbwe!App"));
        Assert.Equal("Chrome", ToastPayload.AppName("Chrome"));
        Assert.Equal("Code", ToastPayload.AppName(@"C:\Users\me\AppData\Local\Programs\Microsoft VS Code\Code.exe"));
    }

    [Fact]
    public void TokenCounts()
    {
        using var t = new TempFolder();
        var claude = Path.Combine(t.Path, "claude", "-home-me-Muna");
        var codex = Path.Combine(t.Path, "codex", "2026", "11", "26");
        Directory.CreateDirectory(claude);
        Directory.CreateDirectory(codex);
        var now = DateTime.UtcNow;
        string Stamp(double hoursAgo) => now.AddHours(-hoursAgo).ToString("o");
        var log = Path.Combine(claude, "s1.jsonl");
        File.WriteAllText(log,
            $"{{\"timestamp\":\"{Stamp(1)}\",\"message\":{{\"usage\":{{\"input_tokens\":100,\"output_tokens\":50,\"cache_read_input_tokens\":1000}}}}}}\n" +
            $"{{\"timestamp\":\"{Stamp(30)}\",\"message\":{{\"usage\":{{\"input_tokens\":7,\"output_tokens\":3}}}}}}\n" +
            "{\"type\":\"user\",\"message\":{\"content\":\"no usage here\"}}\n" +
            "{\"half\": ");
        File.WriteAllText(Path.Combine(codex, "rollout.jsonl"),
            $"{{\"timestamp\":\"{Stamp(2)}\",\"payload\":{{\"info\":{{\"last_token_usage\":{{\"input_tokens\":20,\"output_tokens\":5}}}}}}}}\n");
        var usage = new TokenUsage();
        var first = usage.Update(Path.Combine(t.Path, "claude"), Path.Combine(t.Path, "codex"), now);
        var c = first.Single(s => s.Agent == "Claude Code");
        Assert.Equal(1150, c.Tokens5h);
        Assert.Equal(1160, c.Tokens7d);
        Assert.Equal(1, c.Messages5h);
        Assert.Equal(25, first.Single(s => s.Agent == "Codex").Tokens5h);
        // the half line is finished later: read once, not twice
        File.AppendAllText(log, $"\"x\"}}\n{{\"timestamp\":\"{Stamp(0.5)}\",\"message\":{{\"usage\":{{\"output_tokens\":40}}}}}}\n");
        var second = usage.Update(Path.Combine(t.Path, "claude"), Path.Combine(t.Path, "codex"), now).Single(s => s.Agent == "Claude Code");
        Assert.Equal(1190, second.Tokens5h);
        Assert.Equal(2, second.Messages5h);
        Assert.Equal("1.2M", TokenUsage.Short(1_190_000));
        Assert.Equal("840K", TokenUsage.Short(840_123));
    }

    [Fact]
    public void Tiling()
    {
        Assert.Equal(new[] { (0.0, 0.0, 1 / 3.0, 1.0), (1 / 3.0, 0.0, 1 / 3.0, 1.0), (2 / 3.0, 0.0, 1 / 3.0, 1.0) }, TileSlots.For("columns", 3));
        Assert.Equal((0.0, 0.5, 1.0, 0.5), TileSlots.For("rows", 2)[1]);
        // 5 windows: 3 on top, 2 below (wider)
        var grid = TileSlots.For("grid", 5);
        Assert.Equal(5, grid.Count);
        Assert.Equal((0.0, 0.5, 0.5, 0.5), grid[3]);
        var main = TileSlots.For("main", 3);
        Assert.Equal((0.0, 0.0, 0.6, 1.0), main[0]);
        Assert.Equal((0.6, 0.5, 0.4, 0.5), main[2]);
        Assert.Single(TileSlots.For("main", 1));
        Assert.Empty(TileSlots.For("grid", 0));
    }

    [Fact]
    public void NightLightState()
    {
        // Windows' record with night light off: byte 18 is 0x13; "on" adds 0x10 0x00 after byte 22
        var off = new byte[] { 0x43, 0x42, 0x01, 0x00, 0x0A, 0x02, 0x01, 0x00, 0x2A, 0x06, 0xA1, 0xB2, 0xC3, 0xD4, 0x06, 0x2A, 0x2B, 0x0E, 0x13, 0x43, 0x42, 0x01, 0x00, 0xCA, 0x14, 0x0E, 0x15, 0x00, 0x00, 0x00, 0x00 };
        Assert.False(NightLightBlob.IsOn(off));
        var on = NightLightBlob.With(off, true)!;
        Assert.True(NightLightBlob.IsOn(on));
        Assert.Equal(off.Length + 2, on.Length);
        Assert.Equal(new byte[] { 0x10, 0x00 }, on[23..25]);
        Assert.Equal(0xA2, on[10]);                       // the timestamp grew
        var back = NightLightBlob.With(on, false)!;
        Assert.False(NightLightBlob.IsOn(back));
        Assert.Equal(off[19..], back[19..]);
        Assert.Equal(0xA3, back[10]);
        Assert.Null(NightLightBlob.With(new byte[] { 1, 2, 3 }, true));
    }

    [Fact]
    public void Reminders()
    {
        using var t = new TempFolder();
        var store = new RemindersStore(t.Store("r.json"));
        var now = new DateTime(2026, 11, 25, 15, 0, 0);
        Assert.Equal(new DateTime(2026, 11, 26, 9, 0, 0), RemindersStore.NextAt(9, 0, now));
        Assert.Equal(new DateTime(2026, 11, 25, 16, 30, 0), RemindersStore.NextAt(16, 30, now));
        store.Add("Later", now.AddHours(2));
        store.Add("Soon", now.AddMinutes(1));
        Assert.Throws<ArgumentException>(() => store.Add(" ", now));
        Assert.Equal(new[] { "Soon", "Later" }, new RemindersStore(t.Store("r.json")).Reminders.Select(r => r.Text));
        Assert.Equal(new[] { "Soon" }, store.TakeDue(now.AddMinutes(5)).Select(r => r.Text));
        Assert.Equal(new[] { "Later" }, new RemindersStore(t.Store("r.json")).Reminders.Select(r => r.Text));
    }

    [Fact]
    public void Scratchpad()
    {
        using var t = new TempFolder();
        t.File("s.json", """{"version":1,"notes":[{"text":"first","at":1},{"text":"second","at":2}]}""");
        var pad = new ScratchpadStore(t.Store("s.json"));
        Assert.Equal("first", pad.Text);
        pad.SetText("changed");
        var file = File.ReadAllText(System.IO.Path.Combine(t.Path, "s.json"));
        Assert.Contains("changed", file);
        Assert.Contains("second", file);
    }
}
