using System.Text.Json;
using System.Text.Json.Nodes;

namespace Muna.Core;

/// <summary>Where Muna keeps the user's data (shared/formats/data-files.md): %APPDATA%\Muna on
/// Windows. MUNA_DATA_DIR replaces it (tests).</summary>
public static class DataDirectory
{
    public static string Path
    {
        get
        {
            var overridden = Environment.GetEnvironmentVariable("MUNA_DATA_DIR");
            if (!string.IsNullOrEmpty(overridden)) return overridden;
            if (OperatingSystem.IsWindows())
                return System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Muna");
            var xdg = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return System.IO.Path.Combine(string.IsNullOrEmpty(xdg) ? System.IO.Path.Combine(home, ".local", "share") : xdg, "muna");
        }
    }
}

/// <summary>One small JSON file of the user's data: read whole, written whole and atomically.</summary>
public sealed class JsonStore
{
    public string FilePath { get; }

    public JsonStore(string name, string? folder = null) =>
        FilePath = System.IO.Path.Combine(folder ?? DataDirectory.Path, name);

    /// <summary>The parsed file, or null when it is missing or broken.</summary>
    public JsonObject? Load()
    {
        try
        {
            return JsonNode.Parse(File.ReadAllText(FilePath)) as JsonObject;
        }
        catch
        {
            return null;
        }
    }

    public void Save(JsonObject value)
    {
        var folder = System.IO.Path.GetDirectoryName(FilePath)!;
        Directory.CreateDirectory(folder);
        // the new contents go to a temporary file first, which then takes the place of the old one
        var temporary = System.IO.Path.Combine(folder, $".{System.IO.Path.GetFileName(FilePath)}.{Guid.NewGuid():N}.tmp");
        File.WriteAllText(temporary, value.ToJsonString(new JsonSerializerOptions { WriteIndented = false }));
        File.Move(temporary, FilePath, overwrite: true);
    }
}

/// <summary>Reading JSON leniently: a field that is missing or of another type gives the default.</summary>
public static class Json
{
    public static string? Str(this JsonNode? node, string key) =>
        node is JsonObject o && o[key] is JsonValue v && v.TryGetValue(out string? s) ? s : null;

    public static long? Long(this JsonNode? node, string key)
    {
        if (node is not JsonObject o || o[key] is not JsonValue v) return null;
        if (v.TryGetValue(out long l)) return l;
        if (v.TryGetValue(out double d)) return (long)d;
        return null;
    }

    public static double? Double(this JsonNode? node, string key)
    {
        if (node is not JsonObject o || o[key] is not JsonValue v) return null;
        return v.TryGetValue(out double d) ? d : v.TryGetValue(out long l) ? l : null;
    }

    public static bool? Bool(this JsonNode? node, string key) =>
        node is JsonObject o && o[key] is JsonValue v && v.TryGetValue(out bool b) ? b : null;

    public static JsonArray? Arr(this JsonNode? node, string key) => node is JsonObject o ? o[key] as JsonArray : null;

    public static long NowMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    /// <summary>Gives a fresh id to entries without one (&lt;= 0) or with one used before, like Linux.</summary>
    public static int RepairIds<T>(List<T> items, Func<T, int> get, Action<T, int> set)
    {
        var next = Math.Max(1, 1 + (items.Count == 0 ? 0 : items.Max(get)));
        var seen = new HashSet<int>();
        foreach (var item in items)
        {
            if (get(item) <= 0 || seen.Contains(get(item))) set(item, next++);
            seen.Add(get(item));
        }
        return next;
    }

    public static string Cut(string text, int max) => text.Length > max ? text[..max] : text;
}

// --- notes and to-dos ---------------------------------------------------------------------------

public sealed class Note
{
    public int Id { get; set; }
    public string Text { get; set; } = "";
    public long At { get; set; }
    public bool IsPrivate { get; set; }
}

/// <summary>The quick notes, newest first (notes.json).</summary>
public sealed class NotesStore
{
    public const int MaxNotes = 100;
    public const int MaxLength = 1000;
    readonly JsonStore _store;
    int _next = 1;
    public List<Note> Notes { get; private set; } = new();

    public NotesStore(JsonStore? store = null)
    {
        _store = store ?? new JsonStore("notes.json");
        Load();
    }

    public void Load()
    {
        var list = new List<Note>();
        foreach (var node in _store.Load().Arr("notes") ?? new JsonArray())
        {
            var text = node.Str("text");
            if (text is null) continue;
            list.Add(new Note { Id = (int)(node.Long("id") ?? 0), Text = Json.Cut(text, MaxLength), At = node.Long("at") ?? 0, IsPrivate = node.Bool("private") ?? false });
            if (list.Count >= MaxNotes) break;
        }
        _next = Json.RepairIds(list, n => n.Id, (n, id) => n.Id = id);
        Notes = list;
    }

    public bool Add(string text)
    {
        var trimmed = Json.Cut(text.Trim(), MaxLength);
        if (trimmed.Length == 0) return false;
        Notes.Insert(0, new Note { Id = _next++, Text = trimmed, At = Json.NowMs() });
        if (Notes.Count > MaxNotes) Notes.RemoveRange(MaxNotes, Notes.Count - MaxNotes);
        Save();
        return true;
    }

    public void Remove(int id) { Notes.RemoveAll(n => n.Id == id); Save(); }

    public void SetPrivate(int id, bool on)
    {
        var note = Notes.Find(n => n.Id == id);
        if (note is null) return;
        note.IsPrivate = on;
        Save();
    }

    void Save()
    {
        var array = new JsonArray();
        foreach (var n in Notes) array.Add(new JsonObject { ["id"] = n.Id, ["text"] = n.Text, ["at"] = n.At, ["private"] = n.IsPrivate });
        _store.Save(new JsonObject { ["version"] = 1, ["notes"] = array });
    }
}

public sealed class TodoItem
{
    public int Id { get; set; }
    public string Text { get; set; } = "";
    public bool Done { get; set; }
}

/// <summary>The to-do list, in the order the items were added (todo.json).</summary>
public sealed class TodoStore
{
    public const int MaxItems = 200;
    public const int MaxLength = 200;
    readonly JsonStore _store;
    int _next = 1;
    public List<TodoItem> Items { get; private set; } = new();
    public int OpenCount => Items.Count(i => !i.Done);
    public bool HasDone => Items.Any(i => i.Done);

    public TodoStore(JsonStore? store = null)
    {
        _store = store ?? new JsonStore("todo.json");
        var list = new List<TodoItem>();
        foreach (var node in _store.Load().Arr("items") ?? new JsonArray())
        {
            var text = node.Str("text");
            if (text is null) continue;
            list.Add(new TodoItem { Id = (int)(node.Long("id") ?? 0), Text = text, Done = node.Bool("done") ?? false });
            if (list.Count >= MaxItems) break;
        }
        _next = Json.RepairIds(list, i => i.Id, (i, id) => i.Id = id);
        Items = list;
    }

    public bool Add(string text)
    {
        var trimmed = Json.Cut(text.Trim(), MaxLength);
        if (trimmed.Length == 0 || Items.Count >= MaxItems) return false;
        Items.Add(new TodoItem { Id = _next++, Text = trimmed });
        Save();
        return true;
    }

    public void Toggle(int id)
    {
        var item = Items.Find(i => i.Id == id);
        if (item is null) return;
        item.Done = !item.Done;
        Save();
    }

    public void Remove(int id) { Items.RemoveAll(i => i.Id == id); Save(); }
    public void ClearDone() { Items.RemoveAll(i => i.Done); Save(); }

    void Save()
    {
        var array = new JsonArray();
        foreach (var i in Items) array.Add(new JsonObject { ["id"] = i.Id, ["text"] = i.Text, ["done"] = i.Done });
        _store.Save(new JsonObject { ["version"] = 1, ["items"] = array });
    }
}

// --- clipboard and tray ---------------------------------------------------------------------------

public sealed class ClipItem
{
    public string? Text { get; set; }
    public List<string>? Files { get; set; }
    public bool Saved { get; set; }
    public string Note { get; set; } = "";
    public bool IsPrivate { get; set; }
    public long At { get; set; } = Json.NowMs();
    public string Id => $"{At}-{Text?.GetHashCode() ?? 0}-{string.Join("|", Files ?? new())}";
    public bool SameContent(ClipItem other) => Text == other.Text && (Files ?? new()).SequenceEqual(other.Files ?? new());
    public string SearchText => string.Join(" ", Text ?? "", Note, string.Join(" ", Files ?? new()));
}

/// <summary>The clipboard history, newest first (clipboard.json): pinned ("saved") items always stay;
/// the others up to <see cref="Limit"/>, written only when the history is kept.</summary>
public sealed class ClipboardHistory
{
    public const int MaxSaved = 100;
    public const int MaxLength = 20000;
    readonly JsonStore _store;
    int _limit = 50;
    bool _keep = true;
    public List<ClipItem> Items { get; private set; } = new();
    public int Limit { get => _limit; set { _limit = value; Trim(); Persist(); } }
    public bool KeepHistory { get => _keep; set { _keep = value; Persist(); } }

    public ClipboardHistory(JsonStore? store = null)
    {
        _store = store ?? new JsonStore("clipboard.json");
        foreach (var node in _store.Load().Arr("items") ?? new JsonArray())
        {
            var text = node.Str("text");
            var files = node.Arr("files")?.Select(f => f?.GetValue<string>()).OfType<string>().ToList();
            if (text is null && (files is null || files.Count == 0)) continue;
            Items.Add(new ClipItem { Text = text, Files = files, Saved = node.Bool("saved") ?? false, Note = node.Str("note") ?? "", IsPrivate = node.Bool("private") ?? false, At = node.Long("at") ?? 0 });
        }
        Trim();
    }

    public void AddText(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        Add(new ClipItem { Text = Json.Cut(text, MaxLength) });
    }

    /// <summary>A note written in the clipboard section ("+ Note"): kept like a pinned item, newest first.
    /// The same text already there moves up and is pinned. False when there is nothing to keep.</summary>
    public bool AddNote(string text)
    {
        var words = Json.Cut(text.Trim(), MaxLength);
        if (words.Length == 0) return false;
        var item = new ClipItem { Text = words };
        var old = Items.FindIndex(i => i.SameContent(item));
        if (old >= 0)
        {
            item.Note = Items[old].Note;
            item.IsPrivate = Items[old].IsPrivate;
            Items.RemoveAt(old);
        }
        item.Saved = true;
        Items.Insert(0, item);
        Trim();
        Persist();
        return true;
    }

    public void AddFiles(IEnumerable<string> uris)
    {
        var list = uris.ToList();
        if (list.Count > 0) Add(new ClipItem { Files = list });
    }

    void Add(ClipItem item)
    {
        if (Items.Count > 0 && Items[0].SameContent(item)) return;
        var old = Items.FindIndex(i => i.SameContent(item));
        if (old >= 0)
        {
            item.Saved = Items[old].Saved;
            item.Note = Items[old].Note;
            item.IsPrivate = Items[old].IsPrivate;
            Items.RemoveAt(old);
        }
        Items.Insert(0, item);
        Trim();
        Persist();
    }

    public void SetSaved(ClipItem item, bool on) => Change(item, i => i.Saved = on);
    public void SetPrivate(ClipItem item, bool on) => Change(item, i => i.IsPrivate = on);
    public void SetNote(ClipItem item, string note) => Change(item, i => i.Note = Json.Cut(note, 200));
    public void Remove(ClipItem item) { Items.RemoveAll(i => i.Id == item.Id); Persist(); }
    public void Clear() { Items.RemoveAll(i => !i.Saved); Persist(); }

    void Change(ClipItem item, Action<ClipItem> edit)
    {
        var found = Items.Find(i => i.Id == item.Id);
        if (found is null) return;
        edit(found);
        Trim();
        Persist();
    }

    void Trim()
    {
        var unsaved = 0;
        Items = Items.Where(i => i.Saved || ++unsaved <= _limit).ToList();
        var saved = Items.Where(i => i.Saved).ToList();
        if (saved.Count > MaxSaved)
        {
            var drop = saved.Skip(MaxSaved).Select(i => i.Id).ToHashSet();
            Items.RemoveAll(i => drop.Contains(i.Id));
        }
    }

    void Persist()
    {
        var array = new JsonArray();
        foreach (var i in Items.Where(i => _keep || i.Saved))
        {
            JsonNode? files = i.Files is null ? null : new JsonArray(i.Files.Select(f => (JsonNode?)JsonValue.Create(f)).ToArray());
            array.Add(new JsonObject
            {
                ["text"] = i.Text is null ? null : JsonValue.Create(i.Text),
                ["files"] = files,
                ["saved"] = i.Saved, ["note"] = i.Note, ["private"] = i.IsPrivate, ["at"] = i.At,
            });
        }
        _store.Save(new JsonObject { ["version"] = 1, ["items"] = array });
    }
}

/// <summary>The files waiting in the Tray, as file:// URIs (tray.json).</summary>
public sealed class TrayStore
{
    readonly JsonStore _store;
    bool _keep = true;
    public List<string> Files { get; private set; } = new();   // local paths
    public bool Keep { get => _keep; set { _keep = value; Persist(); } }

    public TrayStore(JsonStore? store = null)
    {
        _store = store ?? new JsonStore("tray.json");
        var uris = (_store.Load().Arr("files") ?? new JsonArray()).Select(f => f?.GetValue<string>()).OfType<string>().ToList();
        Files = uris.Select(PathOf).OfType<string>().Where(p => File.Exists(p) || Directory.Exists(p)).ToList();
        if (Files.Count != uris.Count) Persist();
    }

    public static string? PathOf(string uri) =>
        Uri.TryCreate(uri, UriKind.Absolute, out var u) && u.IsFile ? u.LocalPath : null;

    public static string UriOf(string path) => new Uri(System.IO.Path.GetFullPath(path)).AbsoluteUri;

    public void Add(IEnumerable<string> paths)
    {
        var fresh = paths.Where(p => (File.Exists(p) || Directory.Exists(p)) && !Files.Contains(p)).Distinct().ToList();
        if (fresh.Count == 0) return;
        Files.AddRange(fresh);
        Persist();
    }

    public void Remove(string path) { Files.Remove(path); Persist(); }
    public void Clear() { Files.Clear(); Persist(); }

    public void DropMissing()
    {
        var before = Files.Count;
        Files = Files.Where(p => File.Exists(p) || Directory.Exists(p)).ToList();
        if (Files.Count != before) Persist();
    }

    void Persist() => _store.Save(new JsonObject
    {
        ["version"] = 1,
        ["files"] = new JsonArray((_keep ? Files : new List<string>()).Select(p => (JsonNode?)JsonValue.Create(UriOf(p))).ToArray()),
    });
}
