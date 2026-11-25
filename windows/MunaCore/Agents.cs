using System.Diagnostics;
using System.Text.Json.Nodes;

namespace Muna.Core;

public enum AgentStatus { Starting, Working, Waiting, Idle, Done, Failed, Stopped }
public enum EntryKind { User, Text, Tool, Result, Error, Note }
public enum Decision { Allow, Always, Deny }

public sealed class TaskEntry
{
    public Guid Id { get; } = Guid.NewGuid();
    public required EntryKind Kind { get; init; }
    public string Text { get; set; } = "";
    public string Tool { get; init; } = "";
    public bool? Ok { get; set; }
    public string Output { get; set; } = "";
    public DateTime At { get; } = DateTime.Now;
}

/// <summary>Claude asks before using a tool.</summary>
public sealed record Permission(string RequestId, string Tool, string Verb, string Detail, string Description, JsonNode Input, JsonArray Suggestions);

/// <summary>One Claude Code task in the background, as Linux (linux/service/agents/claudeTask.js):
/// `claude -p` with stream-json in and out, permission questions answered with control_response.
/// Everything is reported through <see cref="Post"/>.</summary>
public sealed class ClaudeTask
{
    public string Id { get; }
    public string Cwd { get; }
    public string Prompt { get; }
    public string Binary { get; }
    public string Model { get; private set; }
    public string SessionId { get; private set; }
    public AgentStatus Status { get; private set; } = AgentStatus.Starting;
    public string Current { get; private set; } = "";
    public DateTime StartedAt { get; } = DateTime.Now;
    public double CostUsd { get; private set; }
    public long Tokens { get; private set; }
    public int Turns { get; private set; }
    public string Error { get; private set; } = "";
    public List<TaskEntry> Transcript { get; } = new();
    public List<Permission> Pending { get; } = new();
    public string Project => Path.GetFileName(Cwd.TrimEnd('/', '\\'));
    public bool Running => _process is not null;

    public Action<Action> Post { get; set; } = action => action();
    public event Action<ClaudeTask>? Changed;
    public event Action<ClaudeTask, Permission>? PermissionAsked;
    public event Action<ClaudeTask, bool>? Finished;
    public event Action<JsonNode>? RateLimit;

    const int TranscriptMax = 400;
    const int TextMax = 4000;
    Process? _process;
    readonly Dictionary<string, TaskEntry> _tools = new();
    readonly List<string> _stderr = new();
    int _requests;
    bool _stopping;
    double _sessionCost;

    public ClaudeTask(string id, string cwd, string prompt, string binary, string model = "", string sessionId = "")
    {
        Id = id;
        Cwd = cwd;
        Prompt = prompt;
        Binary = binary;
        Model = model;
        SessionId = sessionId;
    }

    /// <summary>Folders where claude usually is: an app started from the Start menu may not have the shell's PATH.</summary>
    public static IEnumerable<string> SearchPath()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return new[]
        {
            Path.Combine(home, ".local", "bin"), Path.Combine(home, ".claude", "local"), Path.Combine(appData, "npm"),
            Path.Combine(home, ".npm-global", "bin"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
        };
    }

    public static string? FindClaude()
    {
        var fromEnv = Environment.GetEnvironmentVariable("MUNA_CLAUDE_BIN");
        if (!string.IsNullOrEmpty(fromEnv)) return fromEnv;
        var names = OperatingSystem.IsWindows() ? new[] { "claude.exe", "claude.cmd" } : new[] { "claude" };
        var folders = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator).Where(p => p.Length > 0).Concat(SearchPath());
        return folders.SelectMany(f => names.Select(n => Path.Combine(f, n))).FirstOrDefault(File.Exists);
    }

    public void Start(string? message = null)
    {
        var arguments = new List<string> { "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--permission-prompt-tool", "stdio" };
        if (Model.Length > 0) arguments.AddRange(new[] { "--model", Model });
        if (SessionId.Length > 0) arguments.AddRange(new[] { "--resume", SessionId });
        var batch = Binary.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) || Binary.EndsWith(".bat", StringComparison.OrdinalIgnoreCase);
        var info = new ProcessStartInfo
        {
            FileName = batch ? "cmd.exe" : Binary,
            WorkingDirectory = Cwd,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        if (batch) { info.ArgumentList.Add("/c"); info.ArgumentList.Add(Binary); }
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        info.Environment["CLAUDE_CODE_ENTRYPOINT"] = "muna";
        var path = (info.Environment.TryGetValue("PATH", out var p) ? p : "") ?? "";
        info.Environment["PATH"] = string.Join(Path.PathSeparator, path.Split(Path.PathSeparator).Concat(SearchPath()).Where(x => x.Length > 0).Distinct());
        Process process;
        try
        {
            process = Process.Start(info) ?? throw new InvalidOperationException("no process");
        }
        catch (Exception e)
        {
            Fail($"Claude Code could not start: {e.Message}");
            return;
        }
        _process = process;
        _stopping = false;
        _sessionCost = 0;
        Status = AgentStatus.Working;
        Current = "Starting";
        _ = ReadOutput(process);
        _ = ReadErrors(process);
        Write(new JsonObject { ["type"] = "control_request", ["request_id"] = NextRequest(), ["request"] = new JsonObject { ["subtype"] = "initialize" } });
        Say(message ?? Prompt);
        Change();
    }

    async Task ReadOutput(Process process)
    {
        try
        {
            string? line;
            while ((line = await process.StandardOutput.ReadLineAsync()) is not null)
            {
                var text = line;
                Post(() => Handle(text));
            }
            await process.WaitForExitAsync();
        }
        catch { /* gone */ }
        var code = process.HasExited ? process.ExitCode : -1;
        Post(() => Exited(process, code));
    }

    async Task ReadErrors(Process process)
    {
        try
        {
            string? line;
            while ((line = await process.StandardError.ReadLineAsync()) is not null)
            {
                lock (_stderr)
                {
                    _stderr.Add(line);
                    if (_stderr.Count > 20) _stderr.RemoveAt(0);
                }
            }
        }
        catch { /* gone */ }
    }

    /// <summary>More to do: in the running process, or (it ended) continuing the session.</summary>
    public void Send(string text)
    {
        text = text.Trim();
        if (text.Length == 0) return;
        if (_process is null)
        {
            Error = "";
            Start(text);
            return;
        }
        Say(text);
        Change();
    }

    public bool Answer(string requestId, Decision decision)
    {
        var request = Pending.Find(p => p.RequestId == requestId);
        if (request is null) return false;
        Pending.Remove(request);
        var response = decision == Decision.Deny
            ? new JsonObject { ["behavior"] = "deny", ["message"] = "The user denied this in Muna." }
            : new JsonObject { ["behavior"] = "allow", ["updatedInput"] = request.Input.DeepClone() };
        if (decision == Decision.Always && request.Suggestions.Count > 0) response["updatedPermissions"] = request.Suggestions.DeepClone();
        Write(new JsonObject { ["type"] = "control_response", ["response"] = new JsonObject { ["subtype"] = "success", ["request_id"] = requestId, ["response"] = response } });
        var word = decision switch { Decision.Deny => "Denied", Decision.Always => "Allowed for this session", _ => "Allowed" };
        Add(new TaskEntry { Kind = EntryKind.Note, Text = $"{word}: {request.Verb} {request.Detail}".Trim() });
        if (Pending.Count == 0 && Status == AgentStatus.Waiting) Status = AgentStatus.Working;
        Change();
        return true;
    }

    /// <summary>Stops what it does now (the session stays; more can be asked).</summary>
    public void Interrupt()
    {
        if (_process is null) return;
        Write(new JsonObject { ["type"] = "control_request", ["request_id"] = NextRequest(), ["request"] = new JsonObject { ["subtype"] = "interrupt" } });
        foreach (var request in Pending)
            Write(new JsonObject { ["type"] = "control_response", ["response"] = new JsonObject { ["subtype"] = "success", ["request_id"] = request.RequestId, ["response"] = new JsonObject { ["behavior"] = "deny", ["message"] = "Interrupted." } } });
        Pending.Clear();
        Current = "Stopping";
        Change();
    }

    /// <summary>Ends the process (the session can still be continued).</summary>
    public void Stop()
    {
        var process = _process;
        if (process is null) return;
        _stopping = true;
        Interrupt();
        try { process.StandardInput.Close(); } catch { /* closed */ }
        _ = Task.Delay(2500).ContinueWith(_ =>
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { /* gone */ }
        });
    }

    void Say(string text)
    {
        Add(new TaskEntry { Kind = EntryKind.User, Text = Clip(text) });
        Write(new JsonObject { ["type"] = "user", ["message"] = new JsonObject { ["role"] = "user", ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = text }) } });
        Status = AgentStatus.Working;
        Current = "Thinking";
    }

    string NextRequest() => $"muna-{Id}-{++_requests}";

    void Write(JsonObject message)
    {
        try
        {
            _process?.StandardInput.WriteLine(message.ToJsonString());
            _process?.StandardInput.Flush();
        }
        catch { /* the process is gone; its exit is handled there */ }
    }

    void Handle(string line)
    {
        JsonNode? message;
        try { message = JsonNode.Parse(line); } catch { return; }
        switch (message.Str("type"))
        {
            case "system":
                if (message.Str("subtype") == "init")
                {
                    SessionId = message.Str("session_id") ?? SessionId;
                    Model = message.Str("model") ?? Model;
                }
                Current = "Thinking";
                break;
            case "assistant":
                foreach (var block in Blocks(message))
                {
                    switch (block.Str("type"))
                    {
                        case "text" when !string.IsNullOrWhiteSpace(block.Str("text")):
                            Add(new TaskEntry { Kind = EntryKind.Text, Text = Clip(block.Str("text")!) });
                            Current = "Writing";
                            break;
                        case "tool_use":
                            var (verb, detail) = DescribeTool(block.Str("name") ?? "Tool", block?["input"], Cwd);
                            var summary = $"{verb} {detail}".Trim();
                            var entry = Add(new TaskEntry { Kind = EntryKind.Tool, Text = summary, Tool = block.Str("name") ?? "" });
                            if (block.Str("id") is { } toolId) _tools[toolId] = entry;
                            Current = summary;
                            break;
                        case "thinking":
                            Current = "Thinking";
                            break;
                    }
                }
                break;
            case "user":
                foreach (var block in Blocks(message).Where(b => b.Str("type") == "tool_result"))
                {
                    if (block.Str("tool_use_id") is { } toolId && _tools.Remove(toolId, out var entry))
                    {
                        entry.Ok = !(block.Bool("is_error") ?? false);
                        entry.Output = Json.Cut(Clip(ResultText(block?["content"])), 600);
                    }
                    Current = "Thinking";
                }
                break;
            case "rate_limit_event":
                RateLimit?.Invoke(message?["rate_limit_info"] ?? new JsonObject());
                break;
            case "control_request":
                ControlRequest(message!);
                break;
            case "result":
                Turns += (int)(message.Long("num_turns") ?? 0);
                if (message.Double("total_cost_usd") is double total)
                {
                    CostUsd += Math.Max(0, total - _sessionCost);
                    _sessionCost = total;
                }
                var usage = message?["usage"];
                Tokens += new[] { "input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens" }.Sum(k => usage.Long(k) ?? 0);
                var ok = !(message.Bool("is_error") ?? false) && message.Str("subtype") == "success";
                var answer = message.Str("result") ?? (ok ? "" : message.Str("subtype") ?? "Error");
                var last = Transcript.LastOrDefault();
                var repeated = last is { Kind: EntryKind.Text } && last.Text.Trim() == answer.Trim();
                Add(new TaskEntry { Kind = EntryKind.Result, Text = repeated ? "" : Clip(answer), Ok = ok });
                Status = ok ? AgentStatus.Idle : AgentStatus.Failed;
                if (!ok) Error = Json.Cut(message.Str("result") ?? message.Str("subtype") ?? "error", 300);
                Current = ok ? "Done" : "Stopped with an error";
                Finished?.Invoke(this, ok);
                break;
        }
        Change();
    }

    void ControlRequest(JsonNode message)
    {
        var requestId = message.Str("request_id") ?? "";
        var request = message["request"];
        if (request.Str("subtype") != "can_use_tool")
        {
            Write(new JsonObject { ["type"] = "control_response", ["response"] = new JsonObject { ["subtype"] = "error", ["request_id"] = requestId, ["error"] = $"Muna does not handle {request.Str("subtype") ?? "this"}" } });
            return;
        }
        var name = request.Str("tool_name") ?? "Tool";
        var input = request?["input"] ?? new JsonObject();
        var (verb, detail) = DescribeTool(name, input, Cwd);
        var permission = new Permission(requestId, request.Str("display_name") ?? name, verb, detail, request.Str("description") ?? "",
                                        input.DeepClone(), (request?["permission_suggestions"] as JsonArray)?.DeepClone() as JsonArray ?? new JsonArray());
        Pending.Add(permission);
        Status = AgentStatus.Waiting;
        Current = $"Waiting for you: {verb} {detail}".Trim();
        PermissionAsked?.Invoke(this, permission);
    }

    void Exited(Process process, int code)
    {
        if (_process != process) return;
        _process = null;
        Pending.Clear();
        if (_stopping)
        {
            Status = AgentStatus.Stopped;
            Current = "Stopped";
            Add(new TaskEntry { Kind = EntryKind.Note, Text = "Stopped" });
        }
        else if (Status is AgentStatus.Idle or AgentStatus.Done || code == 0)
        {
            Status = AgentStatus.Done;
            Current = "Done";
        }
        else
        {
            string tail;
            lock (_stderr) tail = string.Join(" ", _stderr.TakeLast(3)).Trim();
            Fail(tail.Length == 0 ? $"Claude Code ended ({code})" : tail);
            return;
        }
        Change();
    }

    void Fail(string text)
    {
        Status = AgentStatus.Failed;
        Error = Json.Cut(text, 300);
        Current = "Failed";
        Add(new TaskEntry { Kind = EntryKind.Error, Text = Error });
        Finished?.Invoke(this, false);
        Change();
    }

    TaskEntry Add(TaskEntry entry)
    {
        Transcript.Add(entry);
        if (Transcript.Count > TranscriptMax) Transcript.RemoveRange(0, Transcript.Count - TranscriptMax);
        return entry;
    }

    void Change() => Changed?.Invoke(this);

    static readonly Dictionary<string, string> Verbs = new()
    {
        ["Bash"] = "Running", ["Read"] = "Reading", ["Write"] = "Writing", ["Edit"] = "Editing", ["MultiEdit"] = "Editing",
        ["NotebookEdit"] = "Editing", ["Grep"] = "Searching", ["Glob"] = "Looking for", ["WebFetch"] = "Fetching",
        ["WebSearch"] = "Searching the web for", ["Task"] = "Delegating", ["Agent"] = "Delegating", ["TodoWrite"] = "Planning", ["LS"] = "Listing",
    };

    /// <summary>A tool call in a few words: ("Editing", "src/main.js").</summary>
    public static (string Verb, string Detail) DescribeTool(string name, JsonNode? input, string cwd = "")
    {
        string Relative(string path) => cwd.Length > 0 && (path.StartsWith(cwd + "/") || path.StartsWith(cwd + "\\")) ? path[(cwd.Length + 1)..] : path;
        var detail = "";
        if (input is JsonObject o)
        {
            foreach (var key in new[] { "command", "file_path", "notebook_path", "path", "pattern", "url", "query", "description" })
            {
                if (o.Str(key) is { } value)
                {
                    detail = key is "file_path" or "notebook_path" or "path" ? Relative(value) : value;
                    break;
                }
            }
            if (detail.Length == 0 && name == "TodoWrite") detail = "the to-do list";
            if (detail.Length == 0) detail = o.Select(p => p.Value).OfType<JsonValue>().Select(v => v.TryGetValue(out string? s) ? s : null).FirstOrDefault(s => s is not null) ?? "";
        }
        detail = string.Join(" ", detail.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        if (detail.Length > 120) detail = detail[..117] + "…";
        return (Verbs.GetValueOrDefault(name, name), detail);
    }

    static string Clip(string text) => text.Length > TextMax ? text[..TextMax] + "…" : text;

    static IEnumerable<JsonNode> Blocks(JsonNode? message) =>
        (message?["message"]?["content"] as JsonArray)?.OfType<JsonNode>() ?? Enumerable.Empty<JsonNode>();

    static string ResultText(JsonNode? content) => content switch
    {
        JsonValue v when v.TryGetValue(out string? s) => s,
        JsonArray parts => string.Join("\n", parts.Select(p => p.Str("type") == "text" ? p.Str("text") ?? "" : "")),
        _ => "",
    };
}

/// <summary>A Claude Code or Codex session running in a terminal, from its log.</summary>
public sealed record AgentSession(string Agent, string LogPath, string Cwd, DateTime Modified, bool Working)
{
    public string Project => Cwd.Length == 0 ? "session" : Path.GetFileName(Cwd.TrimEnd('/', '\\'));
    public string SessionId => Path.GetFileNameWithoutExtension(LogPath);
}

/// <summary>Agents in terminals, as Linux reads them (linux/service/agents/module.js).</summary>
public static class AgentSessions
{
    public static readonly TimeSpan Active = TimeSpan.FromSeconds(20);

    public static string ClaudeRoot => Environment.GetEnvironmentVariable("MUNA_CLAUDE_DIR")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "projects");
    public static string CodexRoot => Environment.GetEnvironmentVariable("MUNA_CODEX_DIR")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "sessions");

    public static List<AgentSession> Scan(string? claudeRoot = null, string? codexRoot = null, ISet<string>? except = null, DateTime? now = null)
    {
        var at = now ?? DateTime.UtcNow;
        var result = new List<AgentSession>();
        foreach (var (agent, root, depth) in new[] { ("Claude Code", claudeRoot ?? ClaudeRoot, 2), ("Codex", codexRoot ?? CodexRoot, 4) })
        {
            if (!Directory.Exists(root)) continue;
            IEnumerable<string> logs;
            try { logs = Directory.EnumerateFiles(root, "*.jsonl", new EnumerationOptions { RecurseSubdirectories = true, MaxRecursionDepth = depth }); }
            catch { continue; }
            foreach (var log in logs)
            {
                var modified = File.GetLastWriteTimeUtc(log);
                if (at - modified > TimeSpan.FromDays(7)) continue;
                if (except?.Contains(Path.GetFileNameWithoutExtension(log)) == true) continue;
                result.Add(new AgentSession(agent, log, LastCwd(log), modified, at - modified <= Active));
            }
        }
        return result.OrderByDescending(s => s.Modified).ToList();
    }

    /// <summary>The folder the session works in: the last "cwd" of its log (Codex: payload.cwd).</summary>
    static string LastCwd(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            stream.Seek(Math.Max(0, stream.Length - 65536), SeekOrigin.Begin);
            using var reader = new StreamReader(stream);
            var lines = reader.ReadToEnd().Split('\n');
            foreach (var line in lines.Reverse())
            {
                JsonNode? node;
                try { node = JsonNode.Parse(line); } catch { continue; }
                if (node.Str("cwd") is { Length: > 0 } cwd) return cwd;
                if (node?["payload"].Str("cwd") is { Length: > 0 } inner) return inner;
            }
        }
        catch { /* unreadable */ }
        return "";
    }
}
