using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Muna.Core;

/// <summary>How wide the open capsule is and which widgets go on which page: Linux's rules
/// (linux/src/ui/munaLayout.js). A widget is some cells wide (44 px each).</summary>
public sealed record PanelLayout(double Width, List<List<(string Id, double Width)>> Pages, LayoutLook Look)
{
    public const double Cell = 44, MinWidth = 560, MaxShare = 0.72, ScreenMargin = 24;
    public double Gap => Look.Gap;
    public double Padding => Look.Padding;
    public double RowHeight => Look.RowHeight;
    public bool Dividers => Look.Dividers;

    public static PanelLayout Make(double screenWidth, IReadOnlyList<string> widgets, Func<string, int> cells, double atLeast = 0, LayoutLook? look = null)
    {
        look ??= new LayoutLook();
        var cell = Cell * look.Scale;
        double gap = look.Gap, padding = look.Padding;
        var ids = widgets.Count == 0 ? new List<string> { "media" } : widgets.ToList();
        var maxTotal = Math.Max(MinWidth, Math.Min(screenWidth * MaxShare, screenWidth - 2 * ScreenMargin));
        double Natural(string id) => Math.Max(cells(id), 1) * cell;
        double Total(List<string> list) => list.Sum(Natural) + Math.Max(list.Count - 1, 0) * gap + 2 * padding;
        var pageIds = new List<List<string>>();
        var current = new List<string>();
        foreach (var id in ids)
        {
            if (current.Count > 0 && Total(current.Append(id).ToList()) > maxTotal)
            {
                pageIds.Add(current);
                current = new();
            }
            current.Add(id);
        }
        pageIds.Add(current);
        var width = look.FixedShare is { } share
            ? Math.Max(Math.Max(MinWidth, atLeast), Math.Min(screenWidth * share, maxTotal))
            : Math.Max(Math.Max(MinWidth, atLeast), pageIds.Max(Total));
        width = Math.Round(Math.Min(width, Math.Max(maxTotal, atLeast)));
        var pages = pageIds.Select(list =>
        {
            var inner = width - 2 * padding - Math.Max(list.Count - 1, 0) * gap;
            double sum = list.Sum(id => Math.Max(cells(id), 1));
            return list.Select(id => (id, Math.Floor(inner * Math.Max(cells(id), 1) / sum))).ToList();
        }).ToList();
        return new PanelLayout(width, pages, look);
    }
}

/// <summary>Settings → Appearance (Linux's size-scale, widget-spacing, content-padding, row-height,
/// show-dividers, width-mode and fixed-width). <see cref="FixedShare"/> null: the width follows the widgets.</summary>
public sealed record LayoutLook(double Scale = 1, double Gap = 16, double Padding = 16, double RowHeight = 112, bool Dividers = true, double? FixedShare = null);

/// <summary>What the Command Bar understands, as Linux (linux/src/commandbar/engine.js).</summary>
public static class CommandEngine
{
    static readonly Dictionary<string, Func<double, double>> Functions = new()
    {
        ["sqrt"] = Math.Sqrt, ["abs"] = Math.Abs, ["round"] = v => Math.Floor(v + 0.5), ["floor"] = Math.Floor,
        ["ceil"] = Math.Ceiling, ["sin"] = Math.Sin, ["cos"] = Math.Cos, ["tan"] = Math.Tan, ["ln"] = Math.Log, ["log"] = Math.Log10,
    };
    static readonly Dictionary<string, double> Constants = new() { ["pi"] = Math.PI, ["e"] = Math.E };

    /// <summary>The value of "12*(3+4)", "2^10", "sqrt(2)"; null when it is not a calculation.</summary>
    public static double? Calculate(string text)
    {
        var source = text.Trim().ToLowerInvariant().Replace("×", "*").Replace("÷", "/").Replace(",", ".");
        source = Regex.Replace(source, @"x(?=\s*[\d(])", "*");
        source = Regex.Replace(source, @"\s+", "");
        if (source.Length == 0 || !source.Any(char.IsDigit) || !Regex.IsMatch(source, @"^[\d+\-*/^%().a-z]+$")) return null;
        var tokens = Regex.Matches(source, @"\d+\.?\d*|\.\d+|[a-z]+|[+\-*/^%()]").Select(m => m.Value).ToList();
        if (string.Concat(tokens) != source) return null;
        if (tokens.Count == 1 && double.TryParse(tokens[0], NumberStyles.Float, CultureInfo.InvariantCulture, out _)) return null;
        var index = 0;
        string? Current() => index < tokens.Count ? tokens[index] : null;
        double? Expression()
        {
            var value = Term();
            while (value is not null && Current() is "+" or "-")
            {
                var op = tokens[index++];
                var right = Term();
                if (right is null) return null;
                value = op == "+" ? value + right : value - right;
            }
            return value;
        }
        double? Term()
        {
            var value = Power();
            while (value is not null && Current() is "*" or "/" or "%")
            {
                var op = tokens[index++];
                var right = Power();
                if (right is null) return null;
                value = op == "*" ? value * right : op == "/" ? value / right : value % right;
            }
            return value;
        }
        double? Power()
        {
            var b = Unary();
            if (b is null || Current() != "^") return b;
            index++;
            var exponent = Power();
            return exponent is null ? null : Math.Pow(b.Value, exponent.Value);
        }
        double? Unary()
        {
            if (Current() == "-") { index++; return -Unary(); }
            if (Current() == "+") { index++; return Unary(); }
            return Atom();
        }
        double? Atom()
        {
            var token = Current();
            if (token is null) return null;
            index++;
            if (double.TryParse(token, NumberStyles.Float, CultureInfo.InvariantCulture, out var number)) return number;
            if (token == "(")
            {
                var value = Expression();
                if (value is null || Current() != ")") return null;
                index++;
                return value;
            }
            if (Constants.TryGetValue(token, out var constant)) return constant;
            if (Functions.TryGetValue(token, out var function))
            {
                if (Current() != "(") return null;
                index++;
                var value = Expression();
                if (value is null || Current() != ")") return null;
                index++;
                return function(value.Value);
            }
            return null;
        }
        var result = Expression();
        return result is null || index != tokens.Count || !double.IsFinite(result.Value) ? null : result;
    }

    /// <summary>Up to 12 significant digits, no trailing ".0".</summary>
    public static string Format(double value)
    {
        var rounded = double.Parse(value.ToString("G12", CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);
        if (rounded == Math.Round(rounded) && Math.Abs(rounded) < 1e15) return ((long)rounded).ToString(CultureInfo.InvariantCulture);
        return rounded.ToString("G12", CultureInfo.InvariantCulture);
    }

    static readonly Dictionary<string, double>[] Units =
    {
        new() { ["m"] = 1, ["km"] = 1000, ["cm"] = 0.01, ["mm"] = 0.001, ["mi"] = 1609.344, ["mile"] = 1609.344, ["miles"] = 1609.344, ["yd"] = 0.9144, ["ft"] = 0.3048, ["foot"] = 0.3048, ["feet"] = 0.3048, ["in"] = 0.0254, ["inch"] = 0.0254, ["inches"] = 0.0254 },
        new() { ["kg"] = 1, ["g"] = 0.001, ["mg"] = 0.000001, ["t"] = 1000, ["lb"] = 0.45359237, ["lbs"] = 0.45359237, ["oz"] = 0.028349523125 },
        new() { ["l"] = 1, ["ml"] = 0.001, ["gal"] = 3.785411784, ["cup"] = 0.2365882365, ["floz"] = 0.0295735295625 },
        new() { ["s"] = 1, ["sec"] = 1, ["min"] = 60, ["h"] = 3600, ["hr"] = 3600, ["d"] = 86400, ["day"] = 86400, ["days"] = 86400, ["week"] = 604800, ["weeks"] = 604800 },
        new() { ["b"] = 1, ["kb"] = 1024, ["mb"] = 1048576, ["gb"] = 1073741824, ["tb"] = 1099511627776 },
        new() { ["m/s"] = 1, ["km/h"] = 1 / 3.6, ["kmh"] = 1 / 3.6, ["mph"] = 0.44704, ["kn"] = 0.514444 },
    };
    static readonly Dictionary<string, string> Temperature = new()
    {
        ["c"] = "c", ["°c"] = "c", ["celsius"] = "c", ["f"] = "f", ["°f"] = "f", ["fahrenheit"] = "f", ["k"] = "k", ["kelvin"] = "k",
    };

    /// <summary>"5 km to mi" → (3.1068…, "5 km = 3.106856 mi").</summary>
    public static (double Value, string Text)? Convert(string text)
    {
        var source = text.Trim().ToLowerInvariant().Replace(",", ".");
        var match = Regex.Match(source, @"^(-?\d+\.?\d*)\s*([a-z°/]+)\s*(?:to|in|into|=|->|→)\s*([a-z°/]+)$");
        if (!match.Success) return null;
        var value = double.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture);
        var from = match.Groups[2].Value;
        var to = match.Groups[3].Value;
        if (Temperature.TryGetValue(from, out var a) && Temperature.TryGetValue(to, out var b))
        {
            var celsius = a == "c" ? value : a == "f" ? (value - 32) * 5 / 9 : value - 273.15;
            var result = b == "c" ? celsius : b == "f" ? celsius * 9 / 5 + 32 : celsius + 273.15;
            return (result, $"{Format(value)} {from} = {Format(Math.Round(result * 1000) / 1000)} {to}");
        }
        foreach (var table in Units)
        {
            if (table.TryGetValue(from, out var f) && table.TryGetValue(to, out var t))
            {
                var result = value * f / t;
                return (result, $"{Format(value)} {from} = {Format(Math.Round(result * 1e6) / 1e6)} {to}");
            }
        }
        return null;
    }

    /// <summary>How well `query` matches `name` (0: not at all).</summary>
    public static int MatchScore(string name, string query)
    {
        var n = name.ToLowerInvariant();
        var q = query.ToLowerInvariant().Trim();
        if (q.Length == 0) return 0;
        if (n == q) return 100;
        if (n.StartsWith(q, StringComparison.Ordinal)) return 80;
        if (Regex.Split(n, @"[\s\-_.]+").Any(word => word.StartsWith(q, StringComparison.Ordinal))) return 60;
        if (n.Contains(q, StringComparison.Ordinal)) return 40;
        if (q.Length < 3) return 0;
        int at = 0, first = -1;
        foreach (var ch in q)
        {
            at = n.IndexOf(ch, at);
            if (at < 0) return 0;
            if (first < 0) first = at;
            at++;
        }
        return at - first <= q.Length + 1 ? 20 : 0;
    }
}

/// <summary>Tracking parameters out of copied links (linux/src/utils/cleanUrl.js).</summary>
public static class LinkCleaner
{
    static readonly HashSet<string> Tracking = new()
    {
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "igshid", "yclid",
        "_hsenc", "_hsmi", "vero_id", "ref_src", "ref_url", "spm", "share_id", "si",
    };

    static bool IsTracking(string name)
    {
        var lower = name.ToLowerInvariant();
        return Tracking.Contains(lower) || Regex.IsMatch(lower, "^utm_[a-z0-9_]+$");
    }

    /// <summary>The cleaned link, or null when it is not a link or nothing changed.</summary>
    public static string? Clean(string text)
    {
        var trimmed = text.Trim();
        var scheme = trimmed.StartsWith("https://", StringComparison.Ordinal) ? 8 : trimmed.StartsWith("http://", StringComparison.Ordinal) ? 7 : 0;
        if (scheme == 0 || trimmed.Length <= scheme || trimmed.Any(char.IsWhiteSpace)) return null;
        var hash = trimmed.IndexOf('#');
        var main = hash < 0 ? trimmed : trimmed[..hash];
        var fragment = hash < 0 ? "" : trimmed[hash..];
        var question = main.IndexOf('?');
        if (question < 0) return null;
        var parameters = main[(question + 1)..].Split('&', StringSplitOptions.RemoveEmptyEntries);
        var kept = parameters.Where(p => !IsTracking(p.Split('=', 2)[0])).ToList();
        if (kept.Count == parameters.Length) return null;
        return main[..question] + (kept.Count == 0 ? "" : "?" + string.Join("&", kept)) + fragment;
    }
}

public sealed record Snippet(string Trigger, string Text);

/// <summary>Text snippets (snippets.json), ";trigger" in the Command Bar.</summary>
public sealed class SnippetsStore
{
    public const int MaxSnippets = 200;
    public const int MaxLength = 5000;
    readonly JsonStore _store;
    public List<Snippet> Snippets { get; private set; } = new();

    public SnippetsStore(JsonStore? store = null)
    {
        _store = store ?? new JsonStore("snippets.json");
        foreach (var node in _store.Load().Arr("snippets") ?? new JsonArray())
        {
            var trigger = node.Str("trigger");
            var text = node.Str("text");
            if (trigger is not null && text is not null) Snippets.Add(new Snippet(trigger, text));
            if (Snippets.Count >= MaxSnippets) break;
        }
    }

    public void Add(string trigger, string text)
    {
        trigger = trigger.Trim();
        if (trigger.Length == 0 || text.Length == 0) throw new ArgumentException("A snippet needs a trigger and a text");
        Snippets = new[] { new Snippet(trigger, Json.Cut(text, MaxLength)) }.Concat(Snippets.Where(s => s.Trigger != trigger)).Take(MaxSnippets).ToList();
        Persist();
    }

    public void Remove(string trigger) { Snippets.RemoveAll(s => s.Trigger == trigger); Persist(); }

    void Persist() => _store.Save(new JsonObject
    {
        ["version"] = 1,
        ["snippets"] = new JsonArray(Snippets.Select(s => (JsonNode?)new JsonObject { ["trigger"] = s.Trigger, ["text"] = s.Text }).ToArray()),
    });

    /// <summary>{date}, {time} and {datetime} filled in.</summary>
    public static string Expand(string text, DateTime? now = null)
    {
        var t = now ?? DateTime.Now;
        var date = t.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var time = t.ToString("HH:mm", CultureInfo.InvariantCulture);
        return text.Replace("{datetime}", $"{date} {time}").Replace("{date}", date).Replace("{time}", time);
    }
}

public sealed record LyricLine(int T, string Text);

public sealed record LyricsResult(List<LyricLine>? Lines = null, string? Plain = null)
{
    public LyricLine? LineAt(double seconds)
    {
        if (Lines is null) return null;
        var ms = (int)(seconds * 1000);
        return Lines.LastOrDefault(l => l.T <= ms);
    }
}

/// <summary>Lyrics from lrclib.net, as Linux (linux/service/lyrics/module.js); answers cached.</summary>
public sealed class LyricsClient
{
    readonly string _base;
    readonly string _cache;
    readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(8) };
    readonly Dictionary<string, LyricsResult> _memory = new();

    public LyricsClient(string? baseUrl = null, string? cache = null)
    {
        _base = baseUrl ?? Environment.GetEnvironmentVariable("MUNA_LYRICS_URL") ?? "https://lrclib.net";
        _cache = cache ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Muna", "lyrics");
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("Muna (https://github.com/bekov0004/Muna)");
    }

    /// <summary>"[01:23.45] text" lines → timed lines sorted by time.</summary>
    public static List<LyricLine> ParseLrc(string? lrc)
    {
        var lines = new List<LyricLine>();
        if (lrc is null) return lines;
        foreach (var raw in lrc.Split('\n'))
        {
            var stamps = Regex.Matches(raw, @"\[(\d+):(\d+(?:\.\d+)?)\]");
            if (stamps.Count == 0) continue;
            var text = Regex.Replace(raw, @"\[[^\]]*\]", "").Trim();
            foreach (Match stamp in stamps)
            {
                var ms = (double.Parse(stamp.Groups[1].Value, CultureInfo.InvariantCulture) * 60
                          + double.Parse(stamp.Groups[2].Value, CultureInfo.InvariantCulture)) * 1000;
                lines.Add(new LyricLine((int)Math.Floor(ms + 0.5), text));   // as JavaScript's Math.round
            }
        }
        return lines.Select((l, i) => (l, i)).OrderBy(p => p.l.T).ThenBy(p => p.i).Select(p => p.l).ToList();
    }

    static string Key(string artist, string title, string album, double length)
    {
        ulong hash = 0xcbf29ce484222325;
        foreach (var b in Encoding.UTF8.GetBytes($"{artist}\n{title}\n{album}\n{(int)Math.Round(length)}"))
        {
            hash ^= b;
            hash *= 0x100000001b3;
        }
        return hash.ToString("x");
    }

    /// <summary>An empty result when there are none; null when the service could not be reached.</summary>
    public async Task<LyricsResult?> Lookup(string artist, string title, string album, double length)
    {
        title = title.Trim();
        if (title.Length == 0) return new LyricsResult();
        var key = Key(artist, title, album, length);
        lock (_memory) if (_memory.TryGetValue(key, out var known)) return known;
        var file = Path.Combine(_cache, key + ".json");
        try
        {
            if (File.Exists(file) && JsonNode.Parse(File.ReadAllText(file)) is JsonObject cached)
                return Remember(key, FromJson(cached));
        }
        catch { /* broken cache file */ }
        try
        {
            var found = await Fetch(artist, title, album, length);
            var result = new LyricsResult();
            if (found is not null)
            {
                var lines = ParseLrc(found.Str("syncedLyrics"));
                result = new LyricsResult(lines.Count > 0 ? lines : null, found.Str("plainLyrics"));
            }
            Directory.CreateDirectory(_cache);
            File.WriteAllText(file, ToJson(result).ToJsonString());
            return Remember(key, result);
        }
        catch
        {
            return null;
        }
    }

    LyricsResult Remember(string key, LyricsResult result)
    {
        lock (_memory) _memory[key] = result;
        return result;
    }

    async Task<JsonNode?> Get(string path, params (string Name, string Value)[] query)
    {
        var q = string.Join("&", query.Where(p => p.Value.Length > 0 && p.Value != "0").Select(p => $"{p.Name}={Uri.EscapeDataString(p.Value)}"));
        using var response = await _http.GetAsync($"{_base}{path}?{q}");
        if ((int)response.StatusCode == 404) return null;
        response.EnsureSuccessStatusCode();
        return JsonNode.Parse(await response.Content.ReadAsStringAsync());
    }

    async Task<JsonNode?> Fetch(string artist, string title, string album, double length)
    {
        var duration = ((int)Math.Round(length)).ToString(CultureInfo.InvariantCulture);
        var exact = await Get("/api/get", ("artist_name", artist), ("track_name", title), ("album_name", album), ("duration", duration));
        if (exact.Str("syncedLyrics") is not null || exact.Str("plainLyrics") is not null) return exact;
        var search = await Get("/api/search", ("track_name", title), ("artist_name", artist)) as JsonArray ?? new JsonArray();
        return search.FirstOrDefault(r => r.Str("syncedLyrics") is not null) ?? search.FirstOrDefault(r => r.Str("plainLyrics") is not null);
    }

    static JsonObject ToJson(LyricsResult r) => new()
    {
        ["lines"] = r.Lines is null ? null : new JsonArray(r.Lines.Select(l => (JsonNode?)new JsonObject { ["t"] = l.T, ["text"] = l.Text }).ToArray()),
        ["plain"] = r.Plain,
    };

    static LyricsResult FromJson(JsonObject o) => new(
        o.Arr("lines")?.Select(l => new LyricLine((int)(l.Long("t") ?? 0), l.Str("text") ?? "")).ToList(), o.Str("plain"));
}

public sealed record PhoneDevice(string Serial, string State, string Model)
{
    public bool Ready => State == "device";
}

/// <summary>An Android phone with adb, as Linux without its helper (linux/src/phone/phoneControl.js).</summary>
public static class PhoneAdb
{
    public const int Back = 4, Home = 3, Recents = 187, Wake = 224;

    public static string? FindAdb()
    {
        var fromEnv = Environment.GetEnvironmentVariable("MUNA_ADB");
        if (!string.IsNullOrEmpty(fromEnv)) return fromEnv;
        var name = OperatingSystem.IsWindows() ? "adb.exe" : "adb";
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var candidates = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Where(p => p.Length > 0).Select(p => Path.Combine(p, name))
            .Append(Path.Combine(local, "Android", "Sdk", "platform-tools", name))
            .Append(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "platform-tools", name));
        return candidates.FirstOrDefault(File.Exists);
    }

    public static List<PhoneDevice> ParseDevices(string output) =>
        output.Split('\n').Select(l => l.TrimEnd('\r')).Where(l => !l.StartsWith("List of devices") && !l.StartsWith('*'))
            .Select(l => l.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries))
            .Where(p => p.Length >= 2)
            .Select(p => new PhoneDevice(p[0], p[1], p.Skip(2).FirstOrDefault(x => x.StartsWith("model:"))?[6..].Replace('_', ' ') ?? p[0]))
            .ToList();

    public static (int Percent, bool Charging)? ParseBattery(string output)
    {
        int? level = null;
        var scale = 100;
        var charging = false;
        foreach (var line in output.Split('\n'))
        {
            var parts = line.Split(':', 2);
            if (parts.Length != 2) continue;
            var (name, value) = (parts[0].Trim(), parts[1].Trim());
            if (name == "level" && int.TryParse(value, out var l)) level = l;
            else if (name == "scale" && int.TryParse(value, out var s)) scale = s;
            else if (name is "AC powered" or "USB powered" or "Wireless powered" && value == "true") charging = true;
        }
        return level is int lv && scale > 0 ? (lv * 100 / scale, charging) : null;
    }

    /// <summary>What `adb shell input text` needs: spaces as %s, the shell's special characters escaped.</summary>
    public static string EscapeInputText(string text)
    {
        var builder = new StringBuilder();
        foreach (var ch in text)
        {
            if (char.IsAsciiLetterOrDigit(ch) || "._,@:/+=-".Contains(ch)) builder.Append(ch);
            else if (ch == ' ') builder.Append("%s");
            else builder.Append('\\').Append(ch);
        }
        return builder.ToString();
    }
}

/// <summary>Windows keeps night light's state as a small CloudStore record: byte 18 is 0x15 when on
/// (0x13 when off), and "on" carries two more bytes (0x10 0x00) after byte 22. Bytes 10–14 are a
/// timestamp that must grow, or Windows ignores the change.</summary>
public static class NightLightBlob
{
    public static bool IsOn(byte[] data) => data.Length > 18 && data[18] == 0x15;

    public static byte[]? With(byte[] data, bool on)
    {
        if (data.Length < 25 || data[18] is not (0x13 or 0x15)) return null;
        if (IsOn(data) == on) return data;
        var list = new List<byte>(data);
        if (on)
        {
            list[18] = 0x15;
            list.InsertRange(23, new byte[] { 0x10, 0x00 });
        }
        else
        {
            list[18] = 0x13;
            if (list[23] == 0x10 && list[24] == 0x00) list.RemoveRange(23, 2);
        }
        for (var i = 10; i < 15; i++)
        {
            if (list[i] != 0xff) { list[i]++; break; }
        }
        return list.ToArray();
    }
}
