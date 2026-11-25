using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.IO;
using System.Linq;
using System.Media;
using System.Net.Http;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using Muna.Core;

namespace Muna;

/// <summary>Something the views draw; <see cref="Changed"/> asks them to draw again.</summary>
public abstract class Model
{
    public event Action? Changed;
    protected void Notify() => Changed?.Invoke();

    /// <summary>Runs on the UI thread (from the network, timers, other threads).</summary>
    protected static void Ui(Action action)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess()) action();
        else dispatcher.BeginInvoke(action);
    }
}

/// <summary>The quick notes (MunaCore's NotesStore).</summary>
public sealed class NotesModel : Model
{
    readonly NotesStore _store = new();
    public List<Note> Notes => _store.Notes;

    public bool Add(string text)
    {
        var added = _store.Add(text);
        Notify();
        return added;
    }

    public void Remove(Note note) { _store.Remove(note.Id); Notify(); }
    public void TogglePrivate(Note note) { _store.SetPrivate(note.Id, !note.IsPrivate); Notify(); }
}

/// <summary>The to-do list (MunaCore's TodoStore).</summary>
public sealed class TodoModel : Model
{
    readonly TodoStore _store = new();
    public List<TodoItem> Items => _store.Items;
    public int OpenCount => _store.OpenCount;
    public bool HasDone => _store.HasDone;

    public bool Add(string text)
    {
        var added = _store.Add(text);
        Notify();
        return added;
    }

    public void Toggle(TodoItem item) { _store.Toggle(item.Id); Notify(); }
    public void Remove(TodoItem item) { _store.Remove(item.Id); Notify(); }
    public void ClearDone() { _store.ClearDone(); Notify(); }
}

/// <summary>The Tray: files dropped on the capsule wait here (as references, not copies).</summary>
public sealed class TrayModel : Model
{
    readonly TrayStore _store = new();
    public List<string> Files => _store.Files;

    public TrayModel()
    {
        _store.Keep = Preferences.Shared.TrayKeepFiles;
        Preferences.Shared.Changed += key => { if (key == "tray-keep-files") _store.Keep = Preferences.Shared.TrayKeepFiles; };
    }

    public void Add(IEnumerable<string> paths) { _store.Add(paths); Notify(); }
    public void Remove(string path) { _store.Remove(path); Notify(); }
    public void Clear() { _store.Clear(); Notify(); }
    public void Refresh() { _store.DropMissing(); Notify(); }
}

/// <summary>The clipboard history: listens to the clipboard and keeps what was copied (MunaCore's ClipboardHistory).</summary>
public sealed class ClipboardModel : Model
{
    readonly ClipboardHistory _history = new();
    HwndSource? _listener;
    bool _ignoreNext;
    public List<ClipItem> Items => _history.Items;

    /// <summary>Copies that password managers mark as not to be kept or shown in the clipboard history.</summary>
    static readonly string[] SecretFormats = { "ExcludeClipboardContentFromMonitorProcessing", "Clipboard Viewer Ignore" };

    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool AddClipboardFormatListener(IntPtr hwnd);

    public ClipboardModel()
    {
        var preferences = Preferences.Shared;
        _history.KeepHistory = preferences.ClipboardKeepHistory;
        _history.Limit = Math.Max(5, preferences.ClipboardMaxItems);
        preferences.Changed += key =>
        {
            if (key == "clipboard-keep-history") _history.KeepHistory = preferences.ClipboardKeepHistory;
            if (key == "clipboard-max-items") { _history.Limit = Math.Max(5, preferences.ClipboardMaxItems); Notify(); }
        };
    }

    public void Start()
    {
        var parameters = new HwndSourceParameters("MunaClipboard") { Width = 0, Height = 0, ParentWindow = new IntPtr(-3) };   // a message-only window
        _listener = new HwndSource(parameters);
        _listener.AddHook((IntPtr hwnd, int message, IntPtr w, IntPtr l, ref bool handled) =>
        {
            if (message == 0x031D) Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background, Changed_);
            return IntPtr.Zero;
        });
        AddClipboardFormatListener(_listener.Handle);
    }

    void Changed_()
    {
        if (_ignoreNext) { _ignoreNext = false; return; }
        try
        {
            var data = Clipboard.GetDataObject();
            if (data is null) return;
            if (SecretFormats.Any(data.GetDataPresent)) return;
            if (data.GetDataPresent("CanIncludeInClipboardHistory") && data.GetData("CanIncludeInClipboardHistory") is MemoryStream m && m.Length >= 4 && m.ReadByte() == 0) return;
            if (Clipboard.ContainsFileDropList())
            {
                var files = Clipboard.GetFileDropList().Cast<string>().ToList();
                if (files.Count > 0) _history.AddFiles(files.Select(TrayStore.UriOf));
            }
            else if (Clipboard.ContainsText())
            {
                var text = Clipboard.GetText();
                // a copied link loses its tracking parameters (as on Linux, when chosen)
                if (Preferences.Shared.ClipboardCleanUrls && LinkCleaner.Clean(text) is { } clean)
                {
                    _ignoreNext = true;
                    Clipboard.SetText(clean);
                    text = clean;
                }
                _history.AddText(text);
            }
            else return;
            Notify();
        }
        catch
        {
            // another app holds the clipboard; the next change comes
        }
    }

    /// <summary>Puts an item back on the clipboard (Ctrl+V pastes it); it moves to the top.</summary>
    public void Copy(ClipItem item)
    {
        try
        {
            _ignoreNext = true;
            if (item.Files is { } files)
            {
                var list = new StringCollection();
                list.AddRange(files.Select(TrayStore.PathOf).OfType<string>().ToArray());
                Clipboard.SetFileDropList(list);
                _history.AddFiles(files);
            }
            else if (item.Text is { } text)
            {
                Clipboard.SetText(text);
                _history.AddText(text);
            }
        }
        catch { _ignoreNext = false; }
        Notify();
    }

    public static void SetText(string text)
    {
        try { Clipboard.SetText(text); } catch { /* busy */ }
    }

    public void TogglePinned(ClipItem item) { _history.SetSaved(item, !item.Saved); Notify(); }
    public void TogglePrivate(ClipItem item) { _history.SetPrivate(item, !item.IsPrivate); Notify(); }
    public void SetNote(ClipItem item, string note) { _history.SetNote(item, note.Trim()); Notify(); }
    public void Remove(ClipItem item) { _history.Remove(item); Notify(); }
    public void Clear() { _history.Clear(); Notify(); }
}

/// <summary>The text snippets (MunaCore's SnippetsStore): ";trigger" in the Command Bar.</summary>
public sealed class SnippetsModel : Model
{
    readonly SnippetsStore _store = new();
    public List<Snippet> Snippets => _store.Snippets;

    public string? Add(string trigger, string text)
    {
        try
        {
            _store.Add(trigger, text);
            Notify();
            return null;
        }
        catch
        {
            return "A snippet needs a trigger and a text";
        }
    }

    public void Remove(Snippet snippet) { _store.Remove(snippet.Trigger); Notify(); }
}

/// <summary>The calendar: the events of an iCalendar link (Outlook and Google give one), read every 15 minutes.</summary>
public sealed class CalendarModel : Model
{
    List<CalendarEvent> _events = new();
    readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(20) };
    DispatcherTimer? _timer;
    public string Error { get; private set; } = "";
    public bool Loading { get; private set; }
    public bool HasSource => Preferences.Shared.CalendarUrl.Length > 0;

    public void Start()
    {
        _timer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(15) };
        _timer.Tick += (_, _) => Load();
        _timer.Start();
        Preferences.Shared.Changed += key => { if (key == "calendar-url") Load(); };
        Load();
    }

    public async void Load()
    {
        var url = Preferences.Shared.CalendarUrl.Trim();
        if (url.Length == 0)
        {
            _events = new();
            Error = "";
            Notify();
            return;
        }
        if (url.StartsWith("webcal://", StringComparison.OrdinalIgnoreCase)) url = "https://" + url[9..];
        Loading = true;
        Notify();
        try
        {
            var text = File.Exists(url) ? await File.ReadAllTextAsync(url) : await _http.GetStringAsync(url);
            _events = IcsCalendar.Parse(text);
            Error = "";
        }
        catch (Exception e)
        {
            Error = e is HttpRequestException ? "The calendar link could not be read" : "The calendar could not be read";
        }
        Loading = false;
        Notify();
    }

    /// <summary>The events of a day, all-day ones first.</summary>
    public List<CalendarEvent> EventsOn(DateTime day) => IcsCalendar.Occurrences(_events, day.Date, day.Date.AddDays(1))
        .OrderBy(e => e.AllDay ? 0 : 1).ThenBy(e => e.Start).ToList();
}

/// <summary>The countdown of the Timer widget (like linux/service/timer).</summary>
public sealed class TimerModel : Model
{
    public enum State { Idle, Running, Paused, Done }
    public static readonly int[] Presets = { 5, 10, 25 };

    public State Current { get; private set; } = State.Idle;
    public TimeSpan Duration { get; private set; } = TimeSpan.FromMinutes(5);
    public TimeSpan Remaining { get; private set; } = TimeSpan.FromMinutes(5);
    public event Action? Finished;
    DateTime? _endAt;
    readonly DispatcherTimer _ticker = new() { Interval = TimeSpan.FromMilliseconds(250) };

    public TimerModel() => _ticker.Tick += (_, _) => Tick();

    public bool Active => Current is State.Running or State.Paused or State.Done;

    public void Set(int minutes)
    {
        if (Current != State.Idle) return;
        Duration = TimeSpan.FromMinutes(Math.Clamp(minutes, 1, 24 * 60));
        Remaining = Duration;
        Notify();
    }

    /// <summary>−1 / +1 minute (also while it runs; at the end "+1 min" starts it again for a minute).</summary>
    public void Step(int minutes)
    {
        switch (Current)
        {
            case State.Idle:
                Set((int)Duration.TotalMinutes + minutes);
                break;
            case State.Running when _endAt is { } end:
                var next = end.AddMinutes(minutes);
                _endAt = next < DateTime.Now.AddSeconds(1) ? DateTime.Now.AddSeconds(1) : next;
                Tick();
                Notify();
                break;
            case State.Paused:
                Remaining = TimeSpan.FromSeconds(Math.Max(1, (Remaining + TimeSpan.FromMinutes(minutes)).TotalSeconds));
                Notify();
                break;
            case State.Done when minutes > 0:
                Remaining = TimeSpan.FromMinutes(minutes);
                Start();
                break;
        }
    }

    public void Start()
    {
        if (Current == State.Running) return;
        if (Current == State.Idle || (Current == State.Done && Remaining <= TimeSpan.Zero)) Remaining = Duration;
        _endAt = DateTime.Now + Remaining;
        Current = State.Running;
        _ticker.Start();
        Notify();
    }

    public void Pause()
    {
        if (Current != State.Running) return;
        Tick();
        _ticker.Stop();
        Current = State.Paused;
        Notify();
    }

    public void Reset()
    {
        _ticker.Stop();
        _endAt = null;
        Current = State.Idle;
        Remaining = Duration;
        Notify();
    }

    void Tick()
    {
        if (Current != State.Running || _endAt is not { } end) return;
        var left = end - DateTime.Now;
        if (left <= TimeSpan.Zero)
        {
            Remaining = TimeSpan.Zero;
            _ticker.Stop();
            Current = State.Done;
            SystemSounds.Asterisk.Play();
            Finished?.Invoke();
            Notify();
        }
        else if ((int)Math.Ceiling(left.TotalSeconds) != (int)Math.Ceiling(Remaining.TotalSeconds))
        {
            Remaining = left;
            Notify();
        }
    }

    /// <summary>"04:59", "1:02:03".</summary>
    public static string Text(TimeSpan time)
    {
        var total = (int)Math.Ceiling(time.TotalSeconds);
        int h = total / 3600, m = total / 60 % 60, s = total % 60;
        return h > 0 ? $"{h}:{m:00}:{s:00}" : $"{m:00}:{s:00}";
    }
}

/// <summary>The Alerts tab: what Muna told you lately (sendings, received files, the timer …).</summary>
public sealed class AlertsModel : Model
{
    public sealed record Alert(Guid Id, string Title, string Details, string Glyph, bool Ok, DateTime At);

    public List<Alert> Alerts { get; } = new();

    public void Add(string title, string details, string glyph, bool ok)
    {
        Alerts.Insert(0, new Alert(Guid.NewGuid(), title, details, glyph, ok, DateTime.Now));
        if (Alerts.Count > 50) Alerts.RemoveRange(50, Alerts.Count - 50);
        Notify();
    }

    public void Remove(Alert alert) { Alerts.RemoveAll(a => a.Id == alert.Id); Notify(); }
    public void Clear() { Alerts.Clear(); Notify(); }
}
