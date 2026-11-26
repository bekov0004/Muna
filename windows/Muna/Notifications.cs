using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Threading;
using Muna.Core;

namespace Muna;

/// <summary>The notifications of other apps, for the Alerts section. Windows gives them to Store apps
/// only (UserNotificationListener), but it keeps them for the notification centre in a database of the
/// user's own (%LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db), which Muna reads with the
/// SQLite that comes with Windows (winsqlite3.dll). Only new ones are read, every 3 seconds when the
/// file changed; nothing is written there.</summary>
public sealed class SystemNotifications
{
    public sealed record Toast(long Id, string Aumid, string App, string Title, string Body, DateTime At);

    static string Database => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "Windows", "Notifications", "wpndatabase.db");
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(3) };
    readonly Dictionary<string, string> _names = new();
    long _lastId = -1;
    DateTime _stamp;
    bool _busy;
    public event Action<Toast>? Arrived;
    public string? Problem { get; private set; }

    public SystemNotifications() => _timer.Tick += (_, _) => Poll();

    public void Start()
    {
        if (!_timer.IsEnabled) { _timer.Start(); Poll(); }
    }

    public void Stop() => _timer.Stop();

    DateTime Stamp()
    {
        try
        {
            var wal = Database + "-wal";
            var a = File.GetLastWriteTimeUtc(Database);
            var b = File.Exists(wal) ? File.GetLastWriteTimeUtc(wal) : DateTime.MinValue;
            return a > b ? a : b;
        }
        catch { return DateTime.MinValue; }
    }

    void Poll()
    {
        if (_busy || !File.Exists(Database)) return;
        var stamp = Stamp();
        if (stamp == _stamp && _lastId >= 0) return;
        _stamp = stamp;
        _busy = true;
        var after = _lastId;
        Task.Run(() => Read(after)).ContinueWith(t =>
        {
            System.Windows.Application.Current.Dispatcher.BeginInvoke(() =>
            {
                _busy = false;
                if (t.IsFaulted) { Problem = t.Exception?.InnerException?.Message; return; }
                var (rows, last) = t.Result;
                Problem = null;
                // the first time only remembers where the list is: what came before Muna is not news
                var first = _lastId < 0;
                _lastId = Math.Max(_lastId, last);
                if (first) return;
                foreach (var row in rows) Arrived?.Invoke(row with { App = NameOf(row.Aumid) });
            });
        });
    }

    (List<Toast> Rows, long Last) Read(long after)
    {
        var rows = new List<Toast>();
        var last = after;
        using var db = Sqlite.Open(Database);
        const string query = "SELECT n.Id, n.ArrivalTime, n.Payload, h.PrimaryId FROM Notification n JOIN NotificationHandler h ON n.HandlerId = h.RecordId WHERE n.Type = 'toast' AND n.Id > ?1 ORDER BY n.Id";
        foreach (var row in db.Query(after < 0 ? "SELECT MAX(Id) FROM Notification" : query, after < 0 ? null : after))
        {
            if (after < 0) { last = row.Long(0); break; }
            var id = row.Long(0);
            last = Math.Max(last, id);
            var payload = row.Text(2);
            if (ToastPayload.Parse(payload) is not { } text) continue;
            var arrival = row.Long(1);
            DateTime at;
            try { at = arrival > 0 ? DateTime.FromFileTimeUtc(arrival).ToLocalTime() : DateTime.Now; } catch { at = DateTime.Now; }
            var aumid = row.Text(3);
            rows.Add(new Toast(id, aumid, aumid, text.Title, text.Body, at));
        }
        return (rows, last);
    }

    /// <summary>The app's name as the Start menu shows it (shell:AppsFolder), else a guess from its id.</summary>
    string NameOf(string aumid)
    {
        if (_names.TryGetValue(aumid, out var known)) return known;
        var name = ShellName($"shell:AppsFolder\\{aumid}") ?? ToastPayload.AppName(aumid);
        _names[aumid] = name;
        return name;
    }

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItem item);

    static string? ShellName(string path)
    {
        try
        {
            SHCreateItemFromParsingName(path, IntPtr.Zero, typeof(IShellItem).GUID, out var item);
            item.GetDisplayName(0, out var name);   // SIGDN_NORMALDISPLAY
            return string.IsNullOrWhiteSpace(name) ? null : name;
        }
        catch { return null; }
    }

    /// <summary>Opens the app that sent a notification.</summary>
    public static void OpenApp(string aumid) => CapsuleViews.Launch($"shell:AppsFolder\\{aumid}");
}

/// <summary>The few calls of Windows' own SQLite (winsqlite3.dll, in System32 since Windows 10).</summary>
sealed class Sqlite : IDisposable
{
    const string Dll = "winsqlite3.dll";
    [DllImport(Dll)] static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
    [DllImport(Dll)] static extern int sqlite3_close_v2(IntPtr db);
    [DllImport(Dll)] static extern int sqlite3_busy_timeout(IntPtr db, int ms);
    [DllImport(Dll)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int bytes, out IntPtr statement, IntPtr tail);
    [DllImport(Dll)] static extern int sqlite3_bind_int64(IntPtr statement, int index, long value);
    [DllImport(Dll)] static extern int sqlite3_step(IntPtr statement);
    [DllImport(Dll)] static extern int sqlite3_finalize(IntPtr statement);
    [DllImport(Dll)] static extern long sqlite3_column_int64(IntPtr statement, int column);
    [DllImport(Dll)] static extern IntPtr sqlite3_column_blob(IntPtr statement, int column);
    [DllImport(Dll)] static extern int sqlite3_column_bytes(IntPtr statement, int column);
    [DllImport(Dll)] static extern IntPtr sqlite3_errmsg(IntPtr db);

    readonly IntPtr _db;

    Sqlite(IntPtr db) => _db = db;

    static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text + "\0");

    /// <summary>Opens a database to read (the notification service keeps writing to it meanwhile).</summary>
    public static Sqlite Open(string path)
    {
        const int readOnly = 0x1, uri = 0x40;
        var url = "file:" + new Uri(path).AbsolutePath + "?mode=ro";
        if (sqlite3_open_v2(Utf8(url), out var db, readOnly | uri, IntPtr.Zero) != 0)
        {
            var message = db == IntPtr.Zero ? "cannot open" : Marshal.PtrToStringUTF8(sqlite3_errmsg(db));
            if (db != IntPtr.Zero) sqlite3_close_v2(db);
            throw new IOException($"The notification list could not be read: {message}");
        }
        sqlite3_busy_timeout(db, 1500);
        return new Sqlite(db);
    }

    public readonly struct Row
    {
        readonly IntPtr _statement;
        public Row(IntPtr statement) => _statement = statement;
        public long Long(int column) => sqlite3_column_int64(_statement, column);

        public string Text(int column)
        {
            var length = sqlite3_column_bytes(_statement, column);
            var pointer = sqlite3_column_blob(_statement, column);
            if (pointer == IntPtr.Zero || length <= 0) return "";
            var bytes = new byte[length];
            Marshal.Copy(pointer, bytes, 0, length);
            return Encoding.UTF8.GetString(bytes);
        }
    }

    public IEnumerable<Row> Query(string sql, long? parameter)
    {
        if (sqlite3_prepare_v2(_db, Utf8(sql), -1, out var statement, IntPtr.Zero) != 0)
            throw new IOException(Marshal.PtrToStringUTF8(sqlite3_errmsg(_db)) ?? "bad query");
        try
        {
            if (parameter is { } p) sqlite3_bind_int64(statement, 1, p);
            while (sqlite3_step(statement) == 100)   // SQLITE_ROW
                yield return new Row(statement);
        }
        finally { sqlite3_finalize(statement); }
    }

    public void Dispose() => sqlite3_close_v2(_db);
}

/// <summary>Linux's system alerts: a card when the processor stays busy, the computer gets hot, the
/// disk or the memory is nearly full, or the battery runs low (each once until it is fine again).</summary>
public sealed class SystemAlerts
{
    readonly AppState _app;
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(10) };
    readonly HashSet<string> _told = new();
    int _busyTicks;

    public SystemAlerts(AppState app)
    {
        _app = app;
        _timer.Tick += (_, _) => Check();
    }

    public void Start() => _timer.Start();

    void Check()
    {
        if (!Preferences.Shared.SystemAlerts) return;
        var m = _app.Monitor;
        if (!m.Watched) m.Sample();
        var p = Preferences.Shared;
        _busyTicks = m.Cpu * 100 >= p.AlertCpu ? _busyTicks + 1 : 0;
        Tell("cpu", _busyTicks >= 6, "The processor is busy", $"Over {p.AlertCpu}% for a minute", Glyph.Cpu);
        Tell("temp", m.Temperature >= p.AlertTemp, "The computer is hot", m.Temperature is { } c ? SystemMonitor.TemperatureText(c) : "", Glyph.Thermometer);
        var (free, total) = SystemMonitor.SystemDisk();
        Tell("disk", total > 0 && free * 100.0 / total < p.AlertDisk, "The disk is nearly full", $"{Ui.SizeText(free)} free", Glyph.Disk);
        Tell("memory", 100 - m.MemoryPercent < p.AlertMemory, "Memory is nearly full", $"{m.MemoryPercent}% in use", Glyph.Memory);
        var battery = SystemMonitor.Battery();
        Tell("battery", battery.HasBattery && !battery.Charging && battery.Percent <= p.AlertBattery, "The battery is low", $"{battery.Percent}% left", Glyph.Battery);
    }

    void Tell(string id, bool bad, string title, string details, string glyph)
    {
        if (!bad) { _told.Remove(id); return; }
        if (!_told.Add(id)) return;
        _app.Capsules.Tell(title, details, glyph, false);
    }
}
