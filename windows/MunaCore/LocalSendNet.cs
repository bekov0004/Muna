using System.Net;
using System.Net.NetworkInformation;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json.Nodes;

namespace Muna.Core;

// --- HTTP/1.1, as much as LocalSend needs ----------------------------------------------------------

public sealed record HttpRequestHead(string Method, string Path, Dictionary<string, string> Query, Dictionary<string, string> Headers)
{
    public long? ContentLength => Headers.TryGetValue("content-length", out var v) && long.TryParse(v.Trim(), out var n) ? n : null;
    public bool Chunked => Headers.TryGetValue("transfer-encoding", out var v) && v.Contains("chunked", StringComparison.OrdinalIgnoreCase);
    public bool KeepAlive => !(Headers.TryGetValue("connection", out var v) && v.Equals("close", StringComparison.OrdinalIgnoreCase));

    public static HttpRequestHead Parse(string text)
    {
        var lines = text.Split("\r\n");
        var start = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (start.Length < 2) throw new InvalidDataException("bad request line");
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon > 0) headers[line[..colon].Trim().ToLowerInvariant()] = line[(colon + 1)..].Trim();
        }
        var target = start[1];
        var question = target.IndexOf('?');
        var path = question < 0 ? target : target[..question];
        var query = new Dictionary<string, string>();
        if (question >= 0)
        {
            foreach (var pair in target[(question + 1)..].Split('&', StringSplitOptions.RemoveEmptyEntries))
            {
                var eq = pair.IndexOf('=');
                var name = Uri.UnescapeDataString((eq < 0 ? pair : pair[..eq]).Replace('+', ' '));
                query[name] = eq < 0 ? "" : Uri.UnescapeDataString(pair[(eq + 1)..].Replace('+', ' '));
            }
        }
        return new HttpRequestHead(start[0].ToUpperInvariant(), Uri.UnescapeDataString(path), query, headers);
    }
}

public sealed record HttpResponse(int Status, string? ContentType = null, byte[]? Body = null)
{
    public static HttpResponse Json(int status, JsonNode value) => new(status, "application/json", Encoding.UTF8.GetBytes(value.ToJsonString()));
    public static HttpResponse Message(int status, string text) => Json(status, new JsonObject { ["message"] = text });

    public byte[] Serialize(bool keepAlive)
    {
        var body = Body ?? Array.Empty<byte>();
        var head = new StringBuilder($"HTTP/1.1 {Status} {Reason(Status)}\r\n");
        if (ContentType is not null) head.Append($"Content-Type: {ContentType}\r\n");
        head.Append($"Content-Length: {body.Length}\r\nConnection: {(keepAlive ? "keep-alive" : "close")}\r\n\r\n");
        return Encoding.ASCII.GetBytes(head.ToString()).Concat(body).ToArray();
    }

    static string Reason(int status) => status switch
    {
        200 => "OK", 204 => "No Content", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found",
        409 => "Conflict", 413 => "Payload Too Large", 500 => "Internal Server Error", _ => "Status",
    };
}

/// <summary>Reads requests one after another from a connection: the head, then the body in pieces.</summary>
public sealed class HttpConnectionReader(Stream stream)
{
    public const int MaxHeadSize = 64 * 1024;
    readonly byte[] _chunk = new byte[64 * 1024];
    byte[] _buffer = Array.Empty<byte>();

    /// <summary>The next request's head; null at the end of the connection.</summary>
    public async Task<HttpRequestHead?> ReadHeadAsync(CancellationToken token)
    {
        while (true)
        {
            var end = IndexOf(_buffer, "\r\n\r\n"u8);
            if (end >= 0)
            {
                var text = Encoding.UTF8.GetString(_buffer, 0, end);
                _buffer = _buffer[(end + 4)..];
                return HttpRequestHead.Parse(text);
            }
            if (_buffer.Length > MaxHeadSize) throw new InvalidDataException("head too large");
            var read = await stream.ReadAsync(_chunk, token);
            if (read == 0) return null;
            _buffer = _buffer.Concat(_chunk.AsSpan(0, read).ToArray()).ToArray();
        }
    }

    /// <summary>The body of the request whose head was read, piece by piece.</summary>
    public async IAsyncEnumerable<byte[]> ReadBodyAsync(HttpRequestHead head, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken token)
    {
        if (head.Chunked)
        {
            while (true)
            {
                var line = await ReadLineAsync(token);
                var hex = line.Split(';')[0].Trim();
                var size = Convert.ToInt64(hex.Length == 0 ? "0" : hex, 16);
                if (size == 0)
                {
                    while ((await ReadLineAsync(token)).Length > 0) { }
                    yield break;
                }
                await foreach (var piece in ReadExactAsync(size, token)) yield return piece;
                await ReadLineAsync(token);
            }
        }
        await foreach (var piece in ReadExactAsync(head.ContentLength ?? 0, token)) yield return piece;
    }

    async IAsyncEnumerable<byte[]> ReadExactAsync(long size, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken token)
    {
        while (size > 0)
        {
            if (_buffer.Length == 0)
            {
                var read = await stream.ReadAsync(_chunk, token);
                if (read == 0) throw new EndOfStreamException("the sender stopped");
                _buffer = _chunk.AsSpan(0, read).ToArray();
            }
            var take = (int)Math.Min(size, _buffer.Length);
            yield return _buffer[..take];
            _buffer = _buffer[take..];
            size -= take;
        }
    }

    async Task<string> ReadLineAsync(CancellationToken token)
    {
        while (true)
        {
            var end = IndexOf(_buffer, "\r\n"u8);
            if (end >= 0)
            {
                var line = Encoding.ASCII.GetString(_buffer, 0, end);
                _buffer = _buffer[(end + 2)..];
                return line;
            }
            var read = await stream.ReadAsync(_chunk, token);
            if (read == 0) throw new EndOfStreamException();
            _buffer = _buffer.Concat(_chunk.AsSpan(0, read).ToArray()).ToArray();
        }
    }

    static int IndexOf(byte[] data, ReadOnlySpan<byte> pattern) => data.AsSpan().IndexOf(pattern);
}

// --- receiving -------------------------------------------------------------------------------------

public enum IncomingState { Asking, Receiving, Done, Failed, Declined }

public sealed class IncomingFile(string id, string name, long size)
{
    public string Id { get; } = id;
    public string Name { get; } = name;
    public long Size { get; } = size;
    public string Token { get; } = Guid.NewGuid().ToString();
    public long Received { get; internal set; }
    public bool Done { get; internal set; }
    public string? FinalPath { get; internal set; }
    internal string? PartPath { get; set; }
}

/// <summary>One incoming transfer; the user decides with Accept() or Decline().</summary>
public sealed class IncomingTransfer
{
    public string Id { get; } = Guid.NewGuid().ToString();
    public required DeviceInfo Sender { get; init; }
    public required List<IncomingFile> Files { get; init; }
    public required string Folder { get; init; }
    public IncomingState State { get; internal set; } = IncomingState.Asking;
    public string? Error { get; internal set; }
    public long Total => Files.Sum(f => f.Size);
    public long Received => Files.Sum(f => f.Received);
    public IEnumerable<string> Saved => Files.Where(f => f.Done && f.FinalPath is not null).Select(f => f.FinalPath!);
    internal TaskCompletionSource<bool> Decision { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public void Accept() => Decision.TrySetResult(true);
    public void Decline() => Decision.TrySetResult(false);
}

/// <summary>The receiving side of LocalSend (shared/protocols/localsend.md#receiving): an HTTPS
/// server on port 53317; one transfer at a time; the user decides on every one.</summary>
public sealed class LocalSendReceiver
{
    readonly X509Certificate2 _certificate;
    readonly Func<DeviceInfo> _identity;
    readonly Func<string> _folder;
    readonly object _gate = new();
    TcpListener? _listener;
    CancellationTokenSource? _stop;

    public int Port { get; }
    public TimeSpan AskTimeout { get; set; } = LocalSend.AskTimeout;
    public IncomingTransfer? Current { get; private set; }
    /// <summary>A transfer asks the user (call Accept or Decline on it); it moved on (state, progress).
    /// Both come from the server's threads.</summary>
    public event Action<IncomingTransfer>? Incoming;
    public event Action<IncomingTransfer>? Changed;
    /// <summary>Someone sent a text (LocalSend's text message): shown at once, nothing is uploaded.</summary>
    public event Action<DeviceInfo, string>? Message;
    public const int MaxText = 100_000;

    public LocalSendReceiver(X509Certificate2 certificate, Func<DeviceInfo> identity, Func<string> folder, int port = LocalSend.Port)
    {
        _certificate = certificate;
        _identity = identity;
        _folder = folder;
        Port = port;
    }

    /// <summary>Starts listening; null, or why it cannot.</summary>
    public string? Start()
    {
        if (_listener is not null) return null;
        try
        {
            var listener = new TcpListener(IPAddress.Any, Port);
            listener.Start();
            _listener = listener;
        }
        catch (SocketException e) when (e.SocketErrorCode == SocketError.AddressAlreadyInUse)
        {
            return $"Port {Port} is busy (is the LocalSend app running?)";
        }
        catch (Exception e)
        {
            return e.Message;
        }
        _stop = new CancellationTokenSource();
        _ = AcceptLoop(_listener, _stop.Token);
        return null;
    }

    public void Stop()
    {
        _stop?.Cancel();
        _listener?.Stop();
        _listener = null;
        lock (_gate)
        {
            if (Current is { State: IncomingState.Asking or IncomingState.Receiving } current)
            {
                current.Decline();
                Fail(current, "Stopped");
            }
        }
    }

    async Task AcceptLoop(TcpListener listener, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(token); }
            catch { return; }
            _ = Serve(client, token);
        }
    }

    async Task Serve(TcpClient client, CancellationToken token)
    {
        using var _ = client;
        try
        {
            await using var tls = new SslStream(client.GetStream(), false);
            await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
            {
                ServerCertificate = _certificate,
                ClientCertificateRequired = false,
            }, token);
            var reader = new HttpConnectionReader(tls);
            var socket = client.Client;
            // the sender went away (asked without reading the TLS stream, which must not be read twice at once)
            bool Closed()
            {
                try { return socket.Poll(0, SelectMode.SelectRead) && socket.Available == 0; }
                catch { return true; }
            }
            while (true)
            {
                var head = await reader.ReadHeadAsync(token);
                if (head is null) return;
                var response = await Handle(head, reader, token, Closed);
                await tls.WriteAsync(response.Serialize(head.KeepAlive), token);
                await tls.FlushAsync(token);
                if (!head.KeepAlive) return;
            }
        }
        catch
        {
            // the other side went away, or spoke something else
        }
    }

    /// <summary>One request, whatever the transport (the tests call it directly).</summary>
    public async Task<HttpResponse> Handle(HttpRequestHead head, HttpConnectionReader reader, CancellationToken token,
                                           Func<bool>? senderGone = null)
    {
        var api = LocalSend.ApiPath;
        switch (head.Method, head.Path)
        {
            case ("GET", var p) when p == api + "/info":
            case ("POST", var r) when r == api + "/register":
                await Drain(head, reader, token);
                return HttpResponse.Json(200, _identity().ToJson());
            case ("POST", var p) when p == api + "/prepare-upload":
                return await Prepare(head, reader, token, senderGone);
            case ("POST", var p) when p == api + "/upload":
                return await Upload(head, reader, token);
            case ("POST", var p) when p == api + "/cancel":
                await Drain(head, reader, token);
                lock (_gate)
                {
                    if (Current is { } current && head.Query.GetValueOrDefault("sessionId") == current.Id)
                        Fail(current, "The sender cancelled");
                }
                return new HttpResponse(200);
            default:
                await Drain(head, reader, token);
                return HttpResponse.Message(404, "Not found");
        }
    }

    static async Task<byte[]> ReadAll(HttpRequestHead head, HttpConnectionReader reader, int max, CancellationToken token)
    {
        using var memory = new MemoryStream();
        await foreach (var piece in reader.ReadBodyAsync(head, token))
        {
            if (memory.Length + piece.Length <= max) memory.Write(piece);
        }
        return memory.ToArray();
    }

    static async Task Drain(HttpRequestHead head, HttpConnectionReader reader, CancellationToken token)
    {
        await foreach (var _ in reader.ReadBodyAsync(head, token)) { }
    }

    async Task<HttpResponse> Prepare(HttpRequestHead head, HttpConnectionReader reader, CancellationToken token, Func<bool>? senderGone)
    {
        JsonNode? request;
        try { request = JsonNode.Parse(await ReadAll(head, reader, 4 * 1024 * 1024, token)); }
        catch (System.Text.Json.JsonException) { return HttpResponse.Message(400, "Invalid body"); }
        var sender = DeviceInfo.From(request?["info"]);
        var entries = (request?["files"] as JsonObject)?.Select(pair => pair.Value).ToList() ?? new();
        if (sender is null || entries.Count == 0 || entries.Count > LocalSend.MaxIncomingFiles)
            return HttpResponse.Message(400, "Invalid body");
        // a text message: one text/plain entry whose words are in "preview"; answered 204 at once, as LocalSend does
        if (entries.Count == 1 && entries[0]?["preview"] is JsonValue preview && preview.TryGetValue<string>(out var words)
            && (entries[0].Str("fileType") ?? "").StartsWith("text/", StringComparison.Ordinal))
        {
            Message?.Invoke(sender, words.Length > MaxText ? words[..MaxText] : words);
            return new HttpResponse(204);
        }
        IncomingTransfer transfer;
        lock (_gate)
        {
            if (Current is { State: IncomingState.Asking or IncomingState.Receiving })
                return HttpResponse.Message(409, "Blocked by another session");
            transfer = new IncomingTransfer
            {
                Sender = sender,
                Folder = _folder(),
                Files = entries.Select((e, i) => new IncomingFile(e.Str("id") ?? i.ToString(), ReceivedFileNames.Safe(e.Str("fileName") ?? ""),
                    Math.Max(0, e.Long("size") ?? 0))).OrderBy(f => f.Id, StringComparer.Ordinal).ToList(),
            };
            Current = transfer;
        }
        Incoming?.Invoke(transfer);
        // the answer waits for the user, the timeout, or the sender going away
        using var waiting = CancellationTokenSource.CreateLinkedTokenSource(token);
        var closed = Task.Run(async () =>
        {
            while (!waiting.Token.IsCancellationRequested && senderGone?.Invoke() != true)
                await Task.Delay(250, waiting.Token);
        }, waiting.Token);
        var timeout = Task.Delay(AskTimeout, waiting.Token);
        var first = await Task.WhenAny(transfer.Decision.Task, closed, timeout);
        waiting.Cancel();
        if (first == closed && closed.IsCanceled) first = timeout;
        var tokens = new JsonObject();
        lock (_gate)
        {
            if (first == closed)
            {
                Fail(transfer, "The sender stopped");
                throw new IOException("the sender stopped");
            }
            var accepted = first == transfer.Decision.Task && transfer.Decision.Task.Result;
            if (!accepted)
            {
                if (transfer.State == IncomingState.Asking) transfer.State = IncomingState.Declined;
                Changed?.Invoke(transfer);
                return HttpResponse.Message(403, "Rejected");
            }
            try { Directory.CreateDirectory(transfer.Folder); }
            catch
            {
                Fail(transfer, "Could not write the file");
                return HttpResponse.Message(500, "Could not write");
            }
            var taken = new HashSet<string>();
            foreach (var file in transfer.Files)
            {
                var path = ReceivedFileNames.Free(transfer.Folder, file.Name, p => taken.Contains(p) || File.Exists(p) || Directory.Exists(p));
                taken.Add(path);
                file.FinalPath = path;
                file.PartPath = path + ".muna-part";
                tokens[file.Id] = file.Token;
            }
            transfer.State = IncomingState.Receiving;
        }
        Changed?.Invoke(transfer);
        return HttpResponse.Json(200, new JsonObject { ["sessionId"] = transfer.Id, ["files"] = tokens });
    }

    async Task<HttpResponse> Upload(HttpRequestHead head, HttpConnectionReader reader, CancellationToken token)
    {
        IncomingTransfer? transfer;
        IncomingFile? file;
        lock (_gate)
        {
            transfer = Current;
            file = transfer?.Files.FirstOrDefault(f => f.Id == head.Query.GetValueOrDefault("fileId"));
            var valid = transfer is { State: IncomingState.Receiving } && head.Query.GetValueOrDefault("sessionId") == transfer.Id
                        && file is { Done: false, PartPath: not null } && file.Token == head.Query.GetValueOrDefault("token");
            if (!valid) file = null;
        }
        if (transfer is null || file is null)
        {
            await Drain(head, reader, token);
            return HttpResponse.Message(403, "Invalid token");
        }
        try
        {
            await using (var output = new FileStream(file.PartPath!, FileMode.Create, FileAccess.Write))
            {
                await foreach (var piece in reader.ReadBodyAsync(head, token))
                {
                    if (transfer.State != IncomingState.Receiving) throw new IOException("stopped");
                    await output.WriteAsync(piece, token);
                    file.Received += piece.Length;
                    Changed?.Invoke(transfer);
                }
            }
            lock (_gate)
            {
                File.Move(file.PartPath!, file.FinalPath!);
                file.Done = true;
                if (transfer.Files.All(f => f.Done)) transfer.State = IncomingState.Done;
            }
            Changed?.Invoke(transfer);
            return new HttpResponse(200);
        }
        catch (Exception) when (transfer.State == IncomingState.Receiving)
        {
            lock (_gate) Fail(transfer, "The sender stopped");
            throw;
        }
    }

    void Fail(IncomingTransfer transfer, string message)
    {
        if (transfer.State is not (IncomingState.Asking or IncomingState.Receiving)) return;
        transfer.State = IncomingState.Failed;
        transfer.Error = message;
        foreach (var file in transfer.Files.Where(f => !f.Done && f.PartPath is not null))
        {
            try { File.Delete(file.PartPath!); } catch { /* gone already */ }
        }
        Changed?.Invoke(transfer);
    }
}

// --- sending ----------------------------------------------------------------------------------------

public sealed record SendProgress(string Phase, long Sent, long Total, int Skipped);
public sealed record SendResult(int Count, int Skipped);
public sealed class SendException(string message) : Exception(message);

/// <summary>What sending needs from the network (a fake one in tests).</summary>
public interface ILocalSendTransport
{
    Task<Device?> Probe(string ip, CancellationToken token);
    /// <summary>Sends files and, when <paramref name="text"/> is given, a text message with them (or alone).</summary>
    Task<SendResult> Send(Device device, IReadOnlyList<string> files, Action<SendProgress> onState, CancellationToken token, string? text = null);
}

/// <summary>LocalSend over HTTPS / HTTP (shared/protocols/localsend.md).</summary>
public sealed class LocalSendClient : ILocalSendTransport, IDisposable
{
    readonly Func<DeviceInfo> _identity;
    readonly HttpClient _http;
    readonly HttpClient _probe;

    public LocalSendClient(Func<DeviceInfo> identity, X509Certificate2? certificate)
    {
        _identity = identity;
        HttpClient Make(TimeSpan timeout, TimeSpan connect)
        {
            var handler = new SocketsHttpHandler { ConnectTimeout = connect };
            // every LocalSend device has a self-signed certificate; some ask for ours
            handler.SslOptions.RemoteCertificateValidationCallback = (_, _, _, _) => true;
            if (certificate is not null) handler.SslOptions.ClientCertificates = new X509CertificateCollection { certificate };
            return new HttpClient(handler) { Timeout = timeout };
        }
        _http = Make(Timeout.InfiniteTimeSpan, TimeSpan.FromSeconds(5));
        _probe = Make(TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
    }

    public async Task<Device?> Probe(string ip, CancellationToken token)
    {
        foreach (var scheme in new[] { "https", "http" })
        {
            try
            {
                using var response = await _probe.GetAsync($"{scheme}://{ip}:{LocalSend.Port}{LocalSend.ApiPath}/info", token);
                if (response.StatusCode != HttpStatusCode.OK) return null;
                var info = DeviceInfo.From(JsonNode.Parse(await response.Content.ReadAsStringAsync(token)));
                return info is null ? null : Device.From(ip, LocalSend.Port, scheme, info);
            }
            catch (HttpRequestException e) when (e.InnerException is SocketException)
            {
                return null;   // nobody there: no need to try the other protocol
            }
            catch (TaskCanceledException)
            {
                return null;
            }
            catch
            {
                // a refusal to talk TLS (or plain HTTP): try the other one
            }
        }
        return null;
    }

    /// <summary>Introduces this device to another one; the answer is not needed.</summary>
    public async Task Register(Device device)
    {
        try
        {
            using var content = new StringContent(_identity().ToJson().ToJsonString(), Encoding.UTF8, "application/json");
            using var _ = await _probe.PostAsync($"{device.Protocol}://{device.Ip}:{device.Port}{LocalSend.ApiPath}/register", content);
        }
        catch { /* gone */ }
    }

    public async Task<SendResult> Send(Device device, IReadOnlyList<string> files, Action<SendProgress> onState, CancellationToken token, string? text = null)
    {
        var entries = new List<(string Id, string Path, long Size, byte[]? Text)>();
        var skipped = 0;
        foreach (var path in files)
        {
            if (!File.Exists(path)) { skipped++; continue; }
            entries.Add(($"file{entries.Count}", path, new FileInfo(path).Length, null));
        }
        // a text goes as LocalSend's text message: a text/plain entry with its words in "preview"
        // (a receiver that knows it answers 204; an older one takes it as message.txt)
        if (!string.IsNullOrEmpty(text))
        {
            var bytes = Encoding.UTF8.GetBytes(text);
            entries.Add(($"text{entries.Count}", "message.txt", bytes.Length, bytes));
        }
        if (entries.Count == 0) throw new SendException("Nothing to send (folders are not supported yet)");
        var total = entries.Sum(e => e.Size);
        var root = $"{device.Protocol}://{device.Ip}:{device.Port}{LocalSend.ApiPath}";
        var me = _identity();
        me.Protocol = "http";
        me.Announce = null;
        string? session = null;
        try
        {
            onState(new SendProgress("waiting", 0, total, skipped));
            var described = new JsonObject();
            foreach (var e in entries)
                described[e.Id] = e.Text is null
                    ? new JsonObject { ["id"] = e.Id, ["fileName"] = Path.GetFileName(e.Path), ["size"] = e.Size, ["fileType"] = "application/octet-stream" }
                    : new JsonObject { ["id"] = e.Id, ["fileName"] = e.Path, ["size"] = e.Size, ["fileType"] = "text/plain", ["preview"] = text };
            using var prepareBody = new StringContent(new JsonObject { ["info"] = me.ToJson(), ["files"] = described }.ToJsonString(), Encoding.UTF8, "application/json");
            using var prepare = await _http.PostAsync($"{root}/prepare-upload", prepareBody, token);
            switch ((int)prepare.StatusCode)
            {
                case 200: break;
                case 204: return new SendResult(entries.Count, skipped);
                case 403: throw new SendException($"{device.Alias} declined");
                case 409 or 429: throw new SendException($"{device.Alias} is busy");
                default: throw new SendException($"{device.Alias} answered {(int)prepare.StatusCode}");
            }
            var answer = JsonNode.Parse(await prepare.Content.ReadAsStringAsync(token));
            session = answer.Str("sessionId") ?? throw new SendException($"{device.Alias} answered something odd");
            var tokens = answer?["files"] as JsonObject;
            long sent = 0;
            onState(new SendProgress("sending", 0, total, skipped));
            foreach (var e in entries)
            {
                var fileToken = tokens?[e.Id]?.GetValue<string>();
                if (fileToken is null) continue;
                var url = $"{root}/upload?sessionId={Uri.EscapeDataString(session)}&fileId={Uri.EscapeDataString(e.Id)}&token={Uri.EscapeDataString(fileToken)}";
                var before = sent;
                await using Stream stream = e.Text is null ? File.OpenRead(e.Path) : new MemoryStream(e.Text);
                using var content = new ProgressContent(stream, e.Size, bytes => onState(new SendProgress("sending", Math.Min(before + bytes, total), total, skipped)));
                using var upload = await _http.PostAsync(url, content, token);
                if (upload.StatusCode != HttpStatusCode.OK) throw new SendException($"{device.Alias} stopped the transfer");
                sent = before + e.Size;
                onState(new SendProgress("sending", sent, total, skipped));
            }
            return new SendResult(entries.Count, skipped);
        }
        catch (Exception e)
        {
            if (session is not null && !(e is SendException s && s.Message.EndsWith("declined")))
                _ = _probe.PostAsync($"{root}/cancel?sessionId={Uri.EscapeDataString(session)}", null);
            if (token.IsCancellationRequested) throw new SendException("Cancelled");
            if (e is SendException) throw;
            throw new SendException($"Could not reach {device.Alias}");
        }
    }

    public void Dispose()
    {
        _http.Dispose();
        _probe.Dispose();
    }

    /// <summary>A file as the body of a request, telling how much was sent.</summary>
    sealed class ProgressContent(Stream source, long length, Action<long> progress) : HttpContent
    {
        protected override async Task SerializeToStreamAsync(Stream target, TransportContext? context)
        {
            var buffer = new byte[256 * 1024];
            long done = 0;
            int read;
            while ((read = await source.ReadAsync(buffer)) > 0)
            {
                await target.WriteAsync(buffer.AsMemory(0, read));
                done += read;
                progress(done);
            }
        }

        protected override bool TryComputeLength(out long size)
        {
            size = length;
            return true;
        }
    }
}

// --- finding devices ---------------------------------------------------------------------------------

public static class LocalNetwork
{
    /// <summary>Every address of the /24 around each of this machine's IPv4 LAN addresses, except its own.</summary>
    public static List<string> SubnetHosts()
    {
        var hosts = new List<string>();
        var seen = new HashSet<string>();
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up) continue;
            if (nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;
            var name = (nic.Name + " " + nic.Description).ToLowerInvariant();
            if (new[] { "virtual", "vmware", "hyper-v", "vethernet", "docker", "wsl", "vpn", "tap", "zerotier" }.Any(name.Contains)) continue;
            foreach (var address in nic.GetIPProperties().UnicastAddresses)
            {
                if (address.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                var b = address.Address.GetAddressBytes();
                if (b[0] == 127 || (b[0] == 169 && b[1] == 254)) continue;
                for (var host = 1; host < 255; host++)
                {
                    if (host == b[3]) continue;
                    var ip = $"{b[0]}.{b[1]}.{b[2]}.{host}";
                    if (seen.Add(ip)) hosts.Add(ip);
                }
            }
        }
        return hosts;
    }

    /// <summary>Asks every host (64 at once); `found` is called for each device as it answers.</summary>
    public static async Task Scan(IEnumerable<string> hosts, ILocalSendTransport transport, Action<Device> found, CancellationToken token)
    {
        using var gate = new SemaphoreSlim(64);
        var work = hosts.Select(async ip =>
        {
            await gate.WaitAsync(token).ConfigureAwait(false);
            try
            {
                if (await transport.Probe(ip, token).ConfigureAwait(false) is { } device) found(device);
            }
            finally { gate.Release(); }
        });
        try { await Task.WhenAll(work).ConfigureAwait(false); }
        catch (OperationCanceledException) { }
    }
}

/// <summary>LocalSend's announcements on UDP 224.0.0.167:53317.</summary>
public sealed class LocalSendMulticast : IDisposable
{
    UdpClient? _socket;
    CancellationTokenSource? _stop;
    public event Action<DeviceInfo, string>? Announced;

    public void Start()
    {
        if (_socket is not null) return;
        var socket = new UdpClient { ExclusiveAddressUse = false };
        socket.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        socket.Client.Bind(new IPEndPoint(IPAddress.Any, LocalSend.Port));
        socket.JoinMulticastGroup(IPAddress.Parse(LocalSend.MulticastAddress));
        _socket = socket;
        _stop = new CancellationTokenSource();
        _ = Listen(socket, _stop.Token);
    }

    async Task Listen(UdpClient socket, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                var packet = await socket.ReceiveAsync(token);
                var info = DeviceInfo.From(JsonNode.Parse(packet.Buffer));
                if (info?.Announce == true) Announced?.Invoke(info, packet.RemoteEndPoint.Address.ToString());
            }
            catch (OperationCanceledException) { return; }
            catch { /* not LocalSend */ }
        }
    }

    public void Announce(DeviceInfo info)
    {
        info.Announce = true;
        var data = Encoding.UTF8.GetBytes(info.ToJson().ToJsonString());
        try
        {
            using var sender = new UdpClient();
            sender.Send(data, data.Length, new IPEndPoint(IPAddress.Parse(LocalSend.MulticastAddress), LocalSend.Port));
        }
        catch { /* no network */ }
    }

    public void Stop()
    {
        _stop?.Cancel();
        _socket?.Dispose();
        _socket = null;
    }

    public void Dispose() => Stop();
}
