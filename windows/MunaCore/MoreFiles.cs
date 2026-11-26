using System.Text.Json.Nodes;

namespace Muna.Core;

// The rest of the shared data files (shared/formats/data-files.md): focus, reminders, scratchpad.

public sealed class FocusConfig
{
    public int Work { get; set; } = 25;
    public int Short { get; set; } = 5;
    public int Long { get; set; } = 15;
    public int Every { get; set; } = 4;

    public FocusConfig Clean() => new()
    {
        Work = Math.Clamp(Work, 1, 180), Short = Math.Clamp(Short, 1, 60), Long = Math.Clamp(Long, 1, 120), Every = Math.Clamp(Every, 2, 10),
    };

    public double Minutes(string phase) => phase == "work" ? Work : phase == "long" ? Long : Short;
}

public sealed class FocusStopwatch
{
    public string State { get; set; } = "idle";
    public double Since { get; set; }
    public double Elapsed { get; set; }
    public List<double> Laps { get; set; } = new();
}

public sealed class Pomodoro
{
    public string State { get; set; } = "idle";
    public string Phase { get; set; } = "work";
    public double EndAt { get; set; }
    public double Remaining { get; set; } = 25 * 60_000;
    public int Round { get; set; } = 1;
    public int Done { get; set; }
    public FocusConfig Config { get; set; } = new();
}

/// <summary>focus.json: the stopwatch and the focus (Pomodoro) timer, with the Linux rules.</summary>
public sealed class FocusFile
{
    static readonly string[] States = { "idle", "running", "paused" };
    readonly JsonStore _store;
    public FocusStopwatch Stopwatch { get; private set; } = new();
    public Pomodoro Pomo { get; private set; } = new();

    public FocusFile(JsonStore? store = null, double? nowMs = null)
    {
        _store = store ?? new JsonStore("focus.json");
        var now = nowMs ?? Json.NowMs();
        var root = _store.Load();
        if (root?["stopwatch"] is JsonObject sw && States.Contains(sw.Str("state")))
        {
            Stopwatch = new FocusStopwatch
            {
                State = sw.Str("state")!, Since = sw.Double("since") ?? 0, Elapsed = sw.Double("elapsed") ?? 0,
                Laps = (sw.Arr("laps") ?? new JsonArray()).Select(l => l?.GetValue<double>() ?? 0).TakeLast(50).ToList(),
            };
        }
        if (root?["pomo"] is JsonObject p)
        {
            var c = p["config"];
            Pomo = new Pomodoro
            {
                State = States.Contains(p.Str("state")) ? p.Str("state")! : "idle",
                Phase = p.Str("phase") is "work" or "break" or "long" ? p.Str("phase")! : "work",
                EndAt = p.Double("endAt") ?? 0,
                Remaining = Math.Max(0, p.Double("remaining") ?? 25 * 60_000),
                Round = Math.Max(1, (int)(p.Long("round") ?? 1)),
                Done = Math.Max(0, (int)(p.Long("done") ?? 0)),
                Config = new FocusConfig
                {
                    Work = (int)(c.Long("work") ?? 25), Short = (int)(c.Long("short") ?? 5), Long = (int)(c.Long("long") ?? 15), Every = (int)(c.Long("every") ?? 4),
                }.Clean(),
            };
            // a timer that ran out while Muna was closed starts again idle
            if (Pomo.State == "running" && Pomo.EndAt <= now) ResetPomo();
        }
    }

    public void ResetPomo()
    {
        Pomo.State = "idle";
        Pomo.Phase = "work";
        Pomo.Round = 1;
        Pomo.Done = 0;
        Pomo.EndAt = 0;
        Pomo.Remaining = Pomo.Config.Minutes("work") * 60_000;
    }

    public void Save()
    {
        var c = Pomo.Config;
        _store.Save(new JsonObject
        {
            ["version"] = 1,
            ["stopwatch"] = new JsonObject
            {
                ["state"] = Stopwatch.State, ["since"] = Stopwatch.Since, ["elapsed"] = Stopwatch.Elapsed,
                ["laps"] = new JsonArray(Stopwatch.Laps.TakeLast(50).Select(l => (JsonNode?)l).ToArray()),
            },
            ["pomo"] = new JsonObject
            {
                ["state"] = Pomo.State, ["phase"] = Pomo.Phase, ["endAt"] = Pomo.EndAt, ["remaining"] = Pomo.Remaining,
                ["round"] = Pomo.Round, ["done"] = Pomo.Done,
                ["config"] = new JsonObject { ["work"] = c.Work, ["short"] = c.Short, ["long"] = c.Long, ["every"] = c.Every },
            },
        });
    }

    /// <summary>The phase after the current one ends (work → break or, every N, a long break → work).</summary>
    public string Advance(double nowMs)
    {
        var finished = Pomo.Phase;
        string next;
        if (finished == "work")
        {
            Pomo.Done++;
            next = Pomo.Done % Pomo.Config.Every == 0 ? "long" : "break";
        }
        else
        {
            next = "work";
            Pomo.Round = finished == "long" ? 1 : Pomo.Round + 1;
        }
        Pomo.Phase = next;
        Pomo.Remaining = Pomo.Config.Minutes(next) * 60_000;
        Pomo.EndAt = nowMs + Pomo.Remaining;
        Pomo.State = "running";
        return next;
    }
}

public sealed class Reminder
{
    public int Id { get; set; }
    public string Text { get; set; } = "";
    public long At { get; set; }
    public bool Done { get; set; }
}

/// <summary>reminders.json: shown once at their time, then removed.</summary>
public sealed class RemindersStore
{
    public const int MaxReminders = 100;
    readonly JsonStore _store;
    public List<Reminder> Reminders { get; private set; } = new();

    public RemindersStore(JsonStore? store = null)
    {
        _store = store ?? new JsonStore("reminders.json");
        foreach (var node in _store.Load().Arr("reminders") ?? new JsonArray())
        {
            if (node.Str("text") is not { } text || node.Long("at") is not { } at) continue;
            Reminders.Add(new Reminder { Id = (int)(node.Long("id") ?? 0), Text = text, At = at, Done = node.Bool("done") ?? false });
        }
        Json.RepairIds(Reminders, r => r.Id, (r, id) => r.Id = id);
    }

    /// <summary>The time today, or tomorrow when it has passed.</summary>
    public static DateTime NextAt(int hour, int minute, DateTime now)
    {
        var at = now.Date.AddHours(hour).AddMinutes(minute);
        return at <= now ? at.AddDays(1) : at;
    }

    public Reminder Add(string text, DateTime at)
    {
        text = Json.Cut(text.Trim(), 200);
        if (text.Length == 0) throw new ArgumentException("A reminder needs a text");
        var reminder = new Reminder { Id = Reminders.Count == 0 ? 1 : Reminders.Max(r => r.Id) + 1, Text = text, At = new DateTimeOffset(at).ToUnixTimeMilliseconds() };
        Reminders.Add(reminder);
        Reminders = Reminders.OrderBy(r => r.At).Take(MaxReminders).ToList();
        Save();
        return reminder;
    }

    public void Remove(int id) { Reminders.RemoveAll(r => r.Id == id); Save(); }

    /// <summary>The reminders whose time has come (taken out of the list).</summary>
    public List<Reminder> TakeDue(DateTime now)
    {
        var ms = new DateTimeOffset(now).ToUnixTimeMilliseconds();
        var due = Reminders.Where(r => r.At <= ms).ToList();
        if (due.Count == 0) return due;
        Reminders.RemoveAll(r => r.At <= ms);
        Save();
        return due;
    }

    void Save() => _store.Save(new JsonObject
    {
        ["version"] = 1,
        ["reminders"] = new JsonArray(Reminders.Select(r => (JsonNode?)new JsonObject { ["id"] = r.Id, ["text"] = r.Text, ["at"] = r.At, ["done"] = r.Done }).ToArray()),
    });
}

/// <summary>scratchpad.json: long notes; this window edits the first one and keeps the others.</summary>
public sealed class ScratchpadStore
{
    readonly JsonStore _store;
    readonly List<(string Text, long At)> _notes = new();

    public ScratchpadStore(JsonStore? store = null)
    {
        _store = store ?? new JsonStore("scratchpad.json");
        foreach (var node in _store.Load().Arr("notes") ?? new JsonArray())
            if (node.Str("text") is { } text) _notes.Add((text, node.Long("at") ?? Json.NowMs()));
    }

    public string Text => _notes.Count > 0 ? _notes[0].Text : "";

    public void SetText(string text)
    {
        if (_notes.Count == 0) _notes.Add((text, Json.NowMs()));
        else _notes[0] = (text, _notes[0].At);
        _store.Save(new JsonObject
        {
            ["version"] = 1,
            ["notes"] = new JsonArray(_notes.Take(200).Select(n => (JsonNode?)new JsonObject { ["text"] = n.Text, ["at"] = n.At }).ToArray()),
        });
    }
}
