namespace Muna.Core;

/// <summary>A finger on the touchpad: its contact id and where it is (0–1 across, 0–1 down).</summary>
public readonly record struct Contact(int Id, double X, double Y);

/// <summary>What the touchpad's fingers did (see <see cref="TouchGestures"/>).</summary>
public abstract record GestureEvent;
/// <summary>Three or four fingers locked to a swipe direction ("swipe3-left").</summary>
public sealed record SwipeLocked(string Gesture) : GestureEvent;
/// <summary>The fingers of a locked swipe moved this far along its direction since the last event (touchpad widths, + = the direction).</summary>
public sealed record SwipeMoved(string Gesture, double Delta) : GestureEvent;
/// <summary>A locked swipe went far enough for a one-off action.</summary>
public sealed record SwipeTriggered(string Gesture) : GestureEvent;
public sealed record SwipeEnded(string Gesture) : GestureEvent;
/// <summary>"pinch3-in", "pinch4-out".</summary>
public sealed record Pinched(string Gesture) : GestureEvent;
/// <summary>"hold3": the fingers rested still and lifted.</summary>
public sealed record Held(string Gesture) : GestureEvent;
/// <summary>One finger started along an edge ("left", "right", "top", "bottom").</summary>
public sealed record EdgeBegan(string Edge) : GestureEvent;
/// <summary>A step along the edge: +1 up (left, right edges) or to the right (top, bottom), −1 the other way.</summary>
public sealed record EdgeStep(string Edge, int Direction) : GestureEvent;
public sealed record EdgeEnded(string Edge) : GestureEvent;
/// <summary>A double tap in a zone (the left and right edges, the middle of the top and bottom edges).</summary>
public sealed record EdgeDoubleTap(string Zone) : GestureEvent;
/// <summary>A finger resting still in a zone for half a second.</summary>
public sealed record EdgeHold(string Zone) : GestureEvent;

/// <summary>Turns touchpad frames (the fingers on it, at a time) into Linux's gestures: three and four
/// finger swipes, pinches and holds (linux/src/gestures/recognizer.js), and one finger along the edges,
/// double taps and holds at them (linux/service/edges/muna-edges.py). Two fingers stay the system's
/// (scrolling, zoom). Pure: the tests feed it frames.</summary>
public sealed class TouchGestures
{
    // many fingers (shares of the touchpad's width)
    public const double LockDistance = 0.03, TriggerDistance = 0.16, PinchIn = 0.78, PinchOut = 1.3, HoldSeconds = 0.35;
    // one finger at an edge (as muna-edges.py)
    public const double EdgeX = 0.06, EdgeY = 0.08, Start = 0.035, Step = 0.07, TapSeconds = 0.22, DoubleSeconds = 0.40, EdgeHoldSeconds = 0.55, Still = 0.02;

    /// <summary>Height of the touchpad over its width (a move up counts in the same units as one sideways).</summary>
    public double Aspect { get; set; } = 0.62;
    /// <summary>Percent: more is a shorter swipe (Linux's gesture-sensitivity).</summary>
    public double Sensitivity { get; set; } = 100;
    public bool Edges { get; set; } = true;

    sealed class Many
    {
        public int Fingers;
        public double StartX, StartY, StartSpread, LastAlong, Time;
        public string? Gesture;
        public char Axis;
        public int Sign;
        public bool Triggered, Moved, Pinched, Over;
    }

    sealed class Single
    {
        public int Id;
        public double X0, Y0, T0, Base;
        public string? Edge, Zone;
        public bool Active, Moved, HeldDone;
    }

    Many? _many;
    Single? _single;
    (string Zone, double Time)? _lastTap;
    double _now;

    double Trigger => TriggerDistance * 100 / Math.Clamp(Sensitivity, 25, 400);

    /// <summary>One frame: the fingers touching now (none: all lifted).</summary>
    public List<GestureEvent> Frame(IReadOnlyList<Contact> contacts, double time)
    {
        _now = time;
        var events = new List<GestureEvent>();
        if (contacts.Count >= 3) { FinishSingle(events); ManyFrame(contacts, events); }
        else
        {
            if (_many is not null) EndMany(events);
            if (contacts.Count == 1 && Edges) SingleFrame(contacts[0], events);
            else FinishSingle(events);
        }
        return events;
    }

    /// <summary>Time passes with nothing new from the touchpad (a finger resting still).</summary>
    public List<GestureEvent> Tick(double time)
    {
        _now = time;
        var events = new List<GestureEvent>();
        HoldCheck(events);
        return events;
    }

    // --- three and four fingers --------------------------------------------------------------------

    static (double X, double Y) Center(IReadOnlyList<Contact> c) => (c.Average(p => p.X), c.Average(p => p.Y));

    double Spread(IReadOnlyList<Contact> c, double cx, double cy) => c.Average(p => Math.Sqrt(Math.Pow(p.X - cx, 2) + Math.Pow((p.Y - cy) * Aspect, 2)));

    void ManyFrame(IReadOnlyList<Contact> contacts, List<GestureEvent> events)
    {
        var (cx, cy) = Center(contacts);
        var spread = Spread(contacts, cx, cy);
        var fingers = Math.Min(4, contacts.Count);
        if (_many is null || (_many.Gesture is null && !_many.Pinched && fingers != _many.Fingers))
        {
            // a new gesture (or a finger more while they settle)
            _many = new Many { Fingers = fingers, StartX = cx, StartY = cy, StartSpread = Math.Max(spread, 0.001), Time = _now };
            return;
        }
        var m = _many;
        if (m.Over) return;
        double dx = cx - m.StartX, dy = (cy - m.StartY) * Aspect;
        if (Math.Sqrt(dx * dx + dy * dy) > Still) m.Moved = true;
        // a pinch: the fingers came together or apart, before any swipe locked
        if (m.Gesture is null && !m.Pinched)
        {
            var ratio = spread / m.StartSpread;
            if (ratio < PinchIn || ratio > PinchOut)
            {
                m.Pinched = true;
                m.Over = true;
                events.Add(new Pinched($"pinch{m.Fingers}-{(ratio < 1 ? "in" : "out")}"));
                return;
            }
        }
        if (m.Gesture is null)
        {
            if (Math.Sqrt(dx * dx + dy * dy) < LockDistance) return;
            var horizontal = Math.Abs(dx) > Math.Abs(dy);
            var direction = horizontal ? (dx < 0 ? "left" : "right") : (dy < 0 ? "up" : "down");
            m.Axis = horizontal ? 'x' : 'y';
            m.Sign = (horizontal ? dx : dy) < 0 ? -1 : 1;
            m.Gesture = $"swipe{m.Fingers}-{direction}";
            events.Add(new SwipeLocked(m.Gesture));
            m.LastAlong = 0;
        }
        var along = (m.Axis == 'x' ? dx : dy) * m.Sign;
        if (Math.Abs(along - m.LastAlong) > 1e-9)
        {
            events.Add(new SwipeMoved(m.Gesture, along - m.LastAlong));
            m.LastAlong = along;
        }
        if (!m.Triggered && along >= Trigger)
        {
            m.Triggered = true;
            events.Add(new SwipeTriggered(m.Gesture));
        }
    }

    void EndMany(List<GestureEvent> events)
    {
        var m = _many!;
        _many = null;
        if (m.Gesture is not null) { events.Add(new SwipeEnded(m.Gesture)); return; }
        if (!m.Pinched && !m.Moved && _now - m.Time >= HoldSeconds) events.Add(new Held($"hold{m.Fingers}"));
    }

    // --- one finger at an edge -----------------------------------------------------------------------

    void SingleFrame(Contact c, List<GestureEvent> events)
    {
        var s = _single;
        if (s is null || s.Id != c.Id)
        {
            FinishSingle(events);
            _single = new Single { Id = c.Id, X0 = c.X, Y0 = c.Y, T0 = _now, Edge = EdgeAt(c.X, c.Y), Zone = ZoneAt(c.X, c.Y) };
            return;
        }
        if (Math.Max(Math.Abs(c.X - s.X0), Math.Abs(c.Y - s.Y0)) > Still) s.Moved = true;
        HoldCheck(events);
        if (s.Edge is null) return;
        var vertical = s.Edge is "left" or "right";
        var along = vertical ? s.Y0 - c.Y : c.X - s.X0;
        var across = vertical ? Math.Abs(c.X - s.X0) : Math.Abs(c.Y - s.Y0);
        if (!s.Active)
        {
            if (across > Start * 1.5 && across > Math.Abs(along)) { s.Edge = null; return; }   // away from the edge: the pointer moves
            if (Math.Abs(along) >= Start && Math.Abs(along) > 2 * across)
            {
                s.Active = true;
                s.Base = along;
                events.Add(new EdgeBegan(s.Edge));
            }
            return;
        }
        while (along - s.Base >= Step) { s.Base += Step; events.Add(new EdgeStep(s.Edge, 1)); }
        while (s.Base - along >= Step) { s.Base -= Step; events.Add(new EdgeStep(s.Edge, -1)); }
    }

    void HoldCheck(List<GestureEvent> events)
    {
        var s = _single;
        if (s is { Zone: not null, Moved: false, HeldDone: false, Active: false } && _now - s.T0 >= EdgeHoldSeconds)
        {
            s.HeldDone = true;
            events.Add(new EdgeHold(s.Zone));
        }
    }

    void FinishSingle(List<GestureEvent> events)
    {
        var s = _single;
        _single = null;
        if (s is null) return;
        if (s.Active && s.Edge is not null) { events.Add(new EdgeEnded(s.Edge)); return; }
        if (s.Zone is not null && !s.Moved && !s.HeldDone && _now - s.T0 <= TapSeconds)
        {
            if (_lastTap is { } last && last.Zone == s.Zone && s.T0 - last.Time <= DoubleSeconds)
            {
                events.Add(new EdgeDoubleTap(s.Zone));
                _lastTap = null;
            }
            else _lastTap = (s.Zone, _now);
        }
    }

    static string? EdgeAt(double x, double y)
    {
        var near = new List<(double, string)>();
        if (x <= EdgeX) near.Add((x / EdgeX, "left"));
        if (x >= 1 - EdgeX) near.Add(((1 - x) / EdgeX, "right"));
        if (y <= EdgeY) near.Add((y / EdgeY, "top"));
        if (y >= 1 - EdgeY) near.Add(((1 - y) / EdgeY, "bottom"));
        return near.Count == 0 ? null : near.MinBy(n => n.Item1).Item2;
    }

    static string? ZoneAt(double x, double y)
    {
        if (x <= EdgeX) return "left";
        if (x >= 1 - EdgeX) return "right";
        if (x >= 1 / 3.0 && x <= 2 / 3.0)
        {
            if (y <= EdgeY) return "top";
            if (y >= 1 - EdgeY) return "bottom";
        }
        return null;
    }
}

/// <summary>What gestures can do on Windows (Linux's catalog, linux/src/gestures/catalog.js, with
/// Windows' own counterparts), and the defaults.</summary>
public static class GestureCatalog
{
    public sealed record Action(string Id, string Group, string Title, bool Live = false, string? Keys = null);

    public static readonly string[] Gestures =
    {
        "swipe3-left", "swipe3-right", "swipe3-up", "swipe3-down", "swipe4-left", "swipe4-right", "swipe4-up", "swipe4-down",
        "pinch3-in", "pinch3-out", "pinch4-in", "pinch4-out", "hold3", "hold4",
    };

    public static readonly Action[] Actions =
    {
        new("none", "", "Nothing"),
        new("app-switcher", "Apps and windows", "Switch apps (like Alt+Tab)", Live: true),
        new("previous-app", "Apps and windows", "Back to the previous app", Keys: "<Alt>Tab"),
        new("show-desktop", "Apps and windows", "Show the desktop", Keys: "<Super>d"),
        new("window-maximize", "Apps and windows", "Maximize or restore the window"),
        new("window-minimize", "Apps and windows", "Minimize the window"),
        new("window-fullscreen", "Apps and windows", "Full screen on or off", Keys: "F11"),
        new("window-close", "Apps and windows", "Close the window", Keys: "<Alt>F4"),
        new("tile-left", "Apps and windows", "Window to the left half", Keys: "<Super>Left"),
        new("tile-right", "Apps and windows", "Window to the right half", Keys: "<Super>Right"),
        new("workspace-left", "Windows", "Desktop on the left"),
        new("workspace-right", "Windows", "Desktop on the right"),
        new("overview-toggle", "Windows", "Task view", Keys: "<Super>Tab"),
        new("app-grid", "Windows", "Start", Keys: "Super"),
        new("notifications", "Windows", "Notifications and calendar", Keys: "<Super>n"),
        new("quick-settings", "Windows", "Quick settings", Keys: "<Super>a"),
        new("screenshot-ui", "Windows", "Screenshot (Windows)", Keys: "<Super><Shift>s"),
        new("lock", "Windows", "Lock the screen"),
        new("volume-up", "Sound and light", "Volume up"),
        new("volume-down", "Sound and light", "Volume down"),
        new("volume-mute", "Sound and light", "Mute or unmute"),
        new("brightness-up", "Sound and light", "Brighter screen"),
        new("brightness-down", "Sound and light", "Darker screen"),
        new("play-pause", "Sound and light", "Play or pause"),
        new("next", "Sound and light", "Next track"),
        new("prev", "Sound and light", "Previous track"),
        new("back", "Browser and documents", "Back", Keys: "<Alt>Left"),
        new("forward", "Browser and documents", "Forward", Keys: "<Alt>Right"),
        new("tab-next", "Browser and documents", "Next tab", Keys: "<Control>Page_Down"),
        new("tab-prev", "Browser and documents", "Previous tab", Keys: "<Control>Page_Up"),
        new("tab-new", "Browser and documents", "New tab", Keys: "<Control>t"),
        new("tab-close", "Browser and documents", "Close the tab", Keys: "<Control>w"),
        new("tab-reopen", "Browser and documents", "Reopen the closed tab", Keys: "<Control><Shift>t"),
        new("reload", "Browser and documents", "Reload", Keys: "F5"),
        new("zoom-in", "Browser and documents", "Zoom in", Keys: "<Control>plus"),
        new("zoom-out", "Browser and documents", "Zoom out", Keys: "<Control>minus"),
        new("copy", "Browser and documents", "Copy", Keys: "<Control>c"),
        new("paste", "Browser and documents", "Paste", Keys: "<Control>v"),
        new("undo", "Browser and documents", "Undo", Keys: "<Control>z"),
        new("muna:muna", "Muna", "Open Muna"),
        new("muna:tray", "Muna", "Tray"),
        new("muna:clipboard", "Muna", "Clipboard history"),
        new("muna:notifications", "Muna", "Alerts"),
        new("muna:command", "Muna", "Search (command bar)"),
        new("muna:quickpanel", "Muna", "Quick panel"),
        new("muna:radial", "Muna", "Radial menu"),
        new("muna:color", "Muna", "Colour picker"),
        new("muna:mic", "Muna", "Microphone on or off"),
        new("muna:awake", "Muna", "Keep awake"),
        new("muna:output", "Muna", "Next sound output"),
        new("muna:dark", "Muna", "Dark style on or off"),
        new("muna:night", "Muna", "Night light on or off"),
        new("muna:cleaning", "Muna", "Cleaning mode"),
    };

    /// <summary>Linux's defaults with Windows' counterparts: three fingers switch apps, four the desktops,
    /// up is task view. (Windows' own three- and four-finger gestures must be set to "Nothing" first.)</summary>
    public static readonly Dictionary<string, string> Defaults = new()
    {
        ["swipe3-left"] = "app-switcher", ["swipe3-right"] = "app-switcher", ["swipe3-up"] = "overview-toggle", ["swipe3-down"] = "show-desktop",
        ["swipe4-left"] = "workspace-right", ["swipe4-right"] = "workspace-left", ["swipe4-up"] = "overview-toggle", ["swipe4-down"] = "show-desktop",
    };

    /// <summary>Linux's edge defaults: brightness on the left and top, volume on the right and bottom, a double tap on top plays or pauses.</summary>
    public static readonly Dictionary<string, string> EdgeDefaults = new()
    {
        ["edge-left-plus"] = "brightness-up", ["edge-left-minus"] = "brightness-down", ["edge-right-plus"] = "volume-up", ["edge-right-minus"] = "volume-down",
        ["edge-top-plus"] = "brightness-up", ["edge-top-minus"] = "brightness-down", ["edge-bottom-plus"] = "volume-up", ["edge-bottom-minus"] = "volume-down",
        ["edge-tap-left"] = "none", ["edge-tap-right"] = "none", ["edge-tap-top"] = "play-pause", ["edge-tap-bottom"] = "none",
        ["edge-hold-left"] = "none", ["edge-hold-right"] = "none", ["edge-hold-top"] = "none", ["edge-hold-bottom"] = "none",
    };

    public static Action Find(string? id) => Actions.FirstOrDefault(a => a.Id == id) ?? Actions[0];

    /// <summary>"<Control><Shift>t" → (modifiers, key name).</summary>
    public static (List<string> Modifiers, string Key)? ParseKeys(string accel)
    {
        var modifiers = System.Text.RegularExpressions.Regex.Matches(accel, "<([^>]+)>").Select(m => m.Groups[1].Value.ToLowerInvariant()).ToList();
        var key = System.Text.RegularExpressions.Regex.Replace(accel, "<[^>]+>", "");
        if (modifiers.Any(m => m is not ("control" or "ctrl" or "primary" or "shift" or "alt" or "super"))) return null;
        return (modifiers, key);
    }
}
