using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using Microsoft.Win32;
using Muna.Core;
using Forms = System.Windows.Forms;

namespace Muna;

/// <summary>Everything the app has, made once.</summary>
public sealed class AppState
{
    public readonly NowPlaying NowPlaying = new();
    public readonly NotesModel Notes = new();
    public readonly TodoModel Todo = new();
    public readonly TrayModel Tray = new();
    public readonly ClipboardModel Clipboard = new();
    public readonly CalendarModel Calendar = new();
    public readonly LocalSendController LocalSend = new();
    public readonly TimerModel Timer = new();
    public readonly AlertsModel Alerts = new();
    public readonly CameraModel Camera = new();
    public readonly SnippetsModel Snippets = new();
    public readonly CommandModel Command;
    public readonly SystemMonitor Monitor = new();
    public readonly KeepAwake Awake = new();
    public readonly FocusModel Focus = new();
    public readonly RemindersModel Reminders = new();
    public readonly DownloadsModel Downloads = new();
    public readonly SoundModel Sound = new();
    public readonly AgentsModel Agents = new();
    public readonly PrivacyModel Privacy = new();
    public readonly CompanionModel Companion = new();
    public readonly ScratchpadModel Scratchpad = new();
    public readonly WindowsModel Windows = new();
    public readonly DisplaysModel Displays = new();
    public readonly PhoneModel Phone = new();
    public readonly MonitorDesktops Desktops = new();
    public readonly PowerModel Power = new();
    public KeyboardCards? KeyboardCards { get; private set; }
    public readonly SystemNotifications Notifications = new();
    public GestureActions Gestures { get; }
    public SystemAlerts SystemAlerts { get; }
    public CapsuleManager Capsules { get; }
    public MunaBars Bars { get; }

    SettingsWindow? _settings;
    AgentsWindow? _agentsWindow;
    ScratchpadWindow? _scratchpadWindow;
    QuickPanel? _quick;

    public AppState()
    {
        Command = new CommandModel(Clipboard, Snippets);
        Capsules = new CapsuleManager(this);
        Bars = new MunaBars(this);
        SystemAlerts = new SystemAlerts(this);
        Gestures = new GestureActions(this);
        Notifications.Arrived += toast => Alerts.AddFromApp(toast.App, toast.Aumid, toast.Title, toast.Body, toast.At);
        Preferences.Shared.Changed += key =>
        {
            if (key == "app-notifications") Application.Current.Dispatcher.BeginInvoke(() => { if (Preferences.Shared.AppNotifications) Notifications.Start(); else Notifications.Stop(); });
        };
    }

    public void Start()
    {
        NowPlaying.Start();
        Clipboard.Start();
        Calendar.Start();
        LocalSend.Start();
        Downloads.Start();
        Reminders.Start();
        NowPlaying.PlayingChanged += playing => Companion.MusicPlaying = playing;
        Command.Scratchpad += ShowScratchpad;
        Capsules.Show();
        Desktops.Start();
        Bars.Rebuild();
        SystemAlerts.Start();
        KeyboardCards = new KeyboardCards((title, glyph) => Capsules.Tell(title, "", glyph, true));
        KeyboardCards.Start();
        if (Preferences.Shared.AwakeOnStart) Awake.Start(null, false);
        Gestures.Start();
        if (Preferences.Shared.AppNotifications) Notifications.Start();
    }

    /// <summary>The panel opened on a section: bring what it shows up to date.</summary>
    public void PanelOpened(PanelTab tab)
    {
        Tray.Refresh();
        if (tab == PanelTab.LocalSend) LocalSend.Session.Refresh();
    }

    /// <summary>The panel closed: the camera goes off at once.</summary>
    public void PanelClosed() => Camera.Stop();

    public void ShowSettings() => ShowSettings(null);

    public void ShowSettings(string? page)
    {
        _settings ??= new SettingsWindow(this);
        if (page is not null) _settings.Page = page;
        _settings.ShowFront();
    }

    public void ShowAgents()
    {
        _agentsWindow ??= new AgentsWindow(Agents);
        _agentsWindow.ShowFront();
    }

    public void ShowScratchpad()
    {
        _scratchpadWindow ??= new ScratchpadWindow(Scratchpad);
        _scratchpadWindow.ShowFront();
    }

    /// One action by its name (Linux's names: the settings' "Try it" buttons, the radial menu, gestures' "muna:…").
    public void Perform(string id)
    {
        switch (id)
        {
            case "quickpanel": ShowQuickPanel(null); break;
            case var page when page.StartsWith("quickpanel:"): ShowQuickPanel(page[11..]); break;
            case "command": Capsules.OpenCommand(); break;
            case "radial": ToggleRadial(); break;
            case "cleaning": CleaningMode.Start(); break;
            case "scratchpad": ShowScratchpad(); break;
            case "screenshot": QuickTools.Screenshot(); break;
            case "record" or "recording": Keys.Chord(0x5B, 0x10, 0x52); break;       // Win+Shift+R: the Snipping Tool's recording
            case "color": ColorPicker.Pick(hex => Capsules.Tell("Colour copied", hex, Glyph.Eyedropper, true)); break;
            case "dark": QuickTools.ToggleDarkMode(); break;
            case "night": SystemSwitches.SetNightLight(!(SystemSwitches.NightLight ?? false)); break;
            case "output": Sound.NextOutput(); break;
            case "mic": Sound.Refresh(); Sound.ToggleMicrophone(); break;
            case "awake": if (Awake.IsOn) Awake.Stop(); else Awake.Start(null, true); break;
            case "lock": Native.LockWorkStation(); break;
            case "downloads": DownloadsModel.OpenFolder(); break;
            case "clipboard": Capsules.Open(PanelTab.Clipboard); break;
            case var tab when tab.StartsWith("capsule:") && Enum.TryParse<PanelTab>(tab[8..], out var t): Capsules.Open(t); break;
        }
    }

    public event Action? RadialRequested;
    public void ToggleRadial() => RadialRequested?.Invoke();

    public void ToggleQuickPanel()
    {
        _quick ??= new QuickPanel(this);
        _quick.Toggle();
    }

    /// <summary>The quick panel on a page (a reading, the Muna bar); null: as it was.</summary>
    public void ShowQuickPanel(string? page)
    {
        _quick ??= new QuickPanel(this);
        _quick.ShowPage(page);
    }

    public void Shutdown()
    {
        Camera.Stop();
        Awake.Stop();
        Agents.StopAll();
        Scratchpad.Save();
        Displays.Restore();
        Desktops.Stop();
        Gestures.Stop();
        Bars.CloseAll();
        CleaningMode.Stop();
        LocalSend.Shutdown();
        foreach (var window in new DarkWindow?[] { _settings, _agentsWindow, _scratchpadWindow })
            if (window is not null) window.Quitting = true;
    }
}

/// <summary>The capsules of all monitors (Settings → General → Screens: every monitor or the main one).
/// What happens once for the whole app (a card, a file coming in, the Command Bar) is handled here;
/// the capsule that opens for it is the one of the monitor with the pointer.</summary>
public sealed class CapsuleManager
{
    readonly AppState _app;
    readonly List<CapsuleWindow> _capsules = new();
    readonly DispatcherTimer _pointer = new(DispatcherPriority.Input) { Interval = TimeSpan.FromMilliseconds(50) };
    readonly DispatcherTimer _fullScreen = new() { Interval = TimeSpan.FromSeconds(1) };
    bool _mouseWasDown, _agentWaiting;
    IncomingState? _incomingState;

    public CapsuleManager(AppState app)
    {
        _app = app;
        SystemEvents.DisplaySettingsChanged += (_, _) => Application.Current.Dispatcher.BeginInvoke(Rebuild);
        Preferences.Shared.Changed += key => Application.Current.Dispatcher.BeginInvoke(() => PreferenceChanged(key));
        app.LocalSend.Notified += (title, details, ok) => Tell(title, details, ok ? Glyph.CheckCircle : Glyph.Warning, ok);
        app.LocalSend.IncomingAsked += () =>
        {
            if (Current is not { } capsule) return;
            capsule.SetTab(PanelTab.LocalSend);
            capsule.OpenNow();
        };
        app.LocalSend.Changed += () =>
        {
            // what keeps a capsule open changed only when a sending is asked or answered (not at every byte)
            var state = app.LocalSend.Incoming?.State;
            var asked = state != _incomingState;
            _incomingState = state;
            All(c => { c.ActivityChanged(); if (c.IsOpen) c.Invalidate(); if (asked) c.ScheduleUpdate(); });
        };
        app.Timer.Finished += () => Tell("Time is up", "The timer ended", Glyph.Clock, true);
        app.Focus.PhaseEnded += (title, details) => Tell(title, details, Glyph.Flag, true);
        app.Reminders.Due += text => { if (Preferences.Shared.ReminderSound) System.Media.SystemSounds.Exclamation.Play(); Tell("Reminder", text, Glyph.Bell, true); };
        app.Downloads.Finished += path => { if (Preferences.Shared.Bool("activity-downloads")) Tell("Downloaded", System.IO.Path.GetFileName(path), Glyph.Download, true); };
        app.Agents.PermissionAsked += (task, permission) =>
        {
            if (Current is { } capsule)
            {
                capsule.SetTab(PanelTab.Agent);
                capsule.OpenNow();
            }
            // Settings → Fingerprint → Claude Code's questions: Windows Hello allows it
            if (Preferences.Shared.Bool("fingerprint-agents")) ConfirmWithHello(task, permission);
        };
        app.Agents.TaskFinished += (task, ok) => { if (Preferences.Shared.AgentsAlerts) Tell(ok ? $"{task.Project} is done" : $"{task.Project} stopped", ok ? task.Current : task.Error, ok ? Glyph.Sparkle : Glyph.Warning, ok); };
        app.Agents.Changed += () =>
        {
            var waiting = app.Agents.Waiting is not null;
            var answered = _agentWaiting && !waiting;
            _agentWaiting = waiting;
            All(c =>
            {
                if (c.IsOpen && c.Tab == PanelTab.Agent) { c.Invalidate(); if (answered) c.ScheduleUpdate(); }
            });
        };
        app.Command.Done += () => All(c => { if (c.IsOpen && c.Tab == PanelTab.Command) c.Close_(); });
        // what the open pages show
        void Redraw() => All(c => c.Invalidate());
        // Live Activities: the next meeting from 10 minutes before it, files added to the tray
        var meetings = new DispatcherTimer { Interval = TimeSpan.FromSeconds(30) };
        var told = new HashSet<string>();
        meetings.Tick += (_, _) =>
        {
            if (!Preferences.Shared.Bool("activity-calendar")) return;
            foreach (var e in app.Calendar.EventsOn(DateTime.Today).Where(e => !e.AllDay))
            {
                var minutes = (e.Start - DateTime.Now).TotalMinutes;
                if (minutes is > 0 and <= 10 && told.Add($"{e.Uid}-{e.Start:o}"))
                    Tell(e.Title, $"In {(int)Math.Ceiling(minutes)} min · {e.Start.ToString("t", System.Globalization.CultureInfo.CurrentCulture)}", Glyph.Calendar, true, Preferences.Shared.Number("peek-calendar-seconds"));
            }
        };
        meetings.Start();
        app.Tray.FilesAdded += count =>
        {
            if (Preferences.Shared.Bool("activity-files"))
                Tell(count == 1 ? "Added a file" : $"Added {count} files", "To the Tray", Glyph.Tray, true, Preferences.Shared.Number("peek-files-seconds"));
        };
        foreach (var model in new Model[] { app.NowPlaying, app.Notes, app.Todo, app.Tray, app.Clipboard, app.Calendar, app.Timer, app.Alerts, app.Camera, app.Command, app.Privacy })
            model.Changed += Redraw;
        app.NowPlaying.Changed += () => All(c => c.ActivityChanged());
        app.Timer.Changed += () => All(c => c.ActivityChanged());
        _pointer.Tick += (_, _) => WatchPointer();
        _fullScreen.Tick += (_, _) => WatchFullScreen();
    }

    async void ConfirmWithHello(ClaudeTask task, Permission permission)
    {
        try
        {
            if (await global::Windows.Security.Credentials.UI.UserConsentVerifier.CheckAvailabilityAsync() != global::Windows.Security.Credentials.UI.UserConsentVerifierAvailability.Available) return;
            var result = await global::Windows.Security.Credentials.UI.UserConsentVerifier.RequestVerificationAsync($"Allow Claude to {permission.Verb.ToLowerInvariant()} {permission.Detail}");
            if (result == global::Windows.Security.Credentials.UI.UserConsentVerificationResult.Verified && _app.Agents.Waiting?.Permission.RequestId == permission.RequestId)
                _app.Agents.Answer(task, permission, Decision.Allow);
        }
        catch { /* Windows Hello did not answer: the buttons stay */ }
    }

    void All(Action<CapsuleWindow> action)
    {
        foreach (var capsule in _capsules.ToList()) action(capsule);
    }

    void PreferenceChanged(string key)
    {
        switch (key)
        {
            case "capsule-screens":
                Rebuild();
                break;
            case "enabled-widgets" or "widget-cells" or "size-scale" or "row-height" or "content-padding" or "widget-spacing"
                or "show-dividers" or "width-mode" or "fixed-width" or "appearance" or "capsule-color" or "shadow-strength"
                or "background-opacity" or "corner-radius":
                All(c => c.LayoutChanged());
                break;
            case "activities-in-collapsed":
                All(c => c.ActivityChanged());
                break;
            default:
                All(c => c.Invalidate());
                break;
        }
    }

    /// <summary>Shows the capsules, and once where Muna is.</summary>
    public void Show()
    {
        Rebuild();
        _pointer.Start();
        _fullScreen.Start();
        var hello = new DispatcherTimer { Interval = TimeSpan.FromSeconds(0.8) };
        hello.Tick += (_, _) =>
        {
            hello.Stop();
            Current?.ShowCard(new CapsuleCard("Muna is here", "Point at the capsule or click it", Glyph.Sparkle, true));
        };
        hello.Start();
    }

    IEnumerable<Forms.Screen> Screens => Preferences.Shared.CapsuleScreens == "main"
        ? Forms.Screen.AllScreens.Where(s => s.Primary)
        : Forms.Screen.AllScreens;

    /// <summary>Makes, keeps or removes a capsule for each monitor.</summary>
    public void Rebuild()
    {
        var wanted = Screens.ToList();
        foreach (var capsule in _capsules.Where(c => wanted.All(s => s.DeviceName != c.ScreenId)).ToList())
        {
            capsule.Close();
            _capsules.Remove(capsule);
        }
        foreach (var screen in wanted)
        {
            var existing = _capsules.FirstOrDefault(c => c.ScreenId == screen.DeviceName);
            if (existing is not null)
            {
                existing.Update(screen);
                continue;
            }
            var capsule = new CapsuleWindow(_app, screen);
            capsule.Show();
            capsule.ActivityChanged();
            _capsules.Add(capsule);
        }
    }

    /// <summary>The capsule of the monitor with the pointer (else the first one).</summary>
    /// <summary>Puts the capsules above other topmost windows of Muna's (the Muna bar).</summary>
    public void Raise() => All(c => c.Raise());

    public bool HasCapsule(string screenId) => _capsules.Any(c => c.ScreenId == screenId);

    public CapsuleWindow? Current
    {
        get
        {
            var pointer = Native.Cursor();
            return _capsules.FirstOrDefault(c => c.Contains(pointer)) ?? _capsules.FirstOrDefault();
        }
    }

    public void Open(PanelTab tab) => Current?.Open(tab);

    /// <summary>The Command Bar in the capsule under the pointer (again: it closes).</summary>
    public void OpenCommand()
    {
        var open = _capsules.FirstOrDefault(c => c.IsOpen && c.Tab == PanelTab.Command);
        if (open is not null) { open.Close_(); return; }
        Current?.OpenCommand();
    }

    /// <summary>Something happened: a card in every closed capsule, and a line in the Alerts section.</summary>
    public void Tell(string title, string details, string glyph, bool ok, double? seconds = null)
    {
        _app.Alerts.Add(title, details, glyph, ok);
        _app.Companion.Surprise();
        var card = new CapsuleCard(title, details, glyph, ok, seconds);
        All(c => c.ShowCard(card));
    }

    /// <summary>Which capsule the pointer is on, and clicks outside the open ones.</summary>
    void WatchPointer()
    {
        var pointer = Native.Cursor();
        foreach (var capsule in _capsules)
        {
            var rect = capsule.ScreenRect;
            var inside = !rect.IsEmpty && capsule.IsVisible && rect.Contains(pointer);
            capsule.Pointer(inside);
        }
        var down = Native.MouseDown();
        if (down && !_mouseWasDown) All(c => c.ClickedOutside());
        _mouseWasDown = down;
    }

    /// <summary>A game or a video fills the screen: its capsule steps aside.</summary>
    void WatchFullScreen()
    {
        foreach (var capsule in _capsules)
        {
            var hide = Preferences.Shared.HideInFullscreen && !capsule.IsOpen && Native.ForegroundIsFullScreen(capsule.Screen.Bounds)
                       && !capsule.IsActive;
            var visibility = hide ? Visibility.Hidden : Visibility.Visible;
            if (capsule.Visibility != visibility) capsule.Visibility = visibility;
        }
    }
}

/// <summary>Keys that work whichever app is in front.</summary>
public sealed class HotKeys : IDisposable
{
    readonly HwndSource _window;
    readonly Dictionary<int, Action> _actions = new();
    int _next = 1;

    public HotKeys()
    {
        _window = new HwndSource(new HwndSourceParameters("MunaKeys") { Width = 0, Height = 0, ParentWindow = new IntPtr(-3) });
        _window.AddHook((IntPtr hwnd, int message, IntPtr w, IntPtr l, ref bool handled) =>
        {
            if (message == Native.WM_HOTKEY && _actions.TryGetValue(w.ToInt32(), out var action))
            {
                handled = true;
                action();
            }
            return IntPtr.Zero;
        });
    }

    /// <summary>Registers a key; the id, or 0 when another app has it already.</summary>
    public int Add(uint modifiers, uint key, Action action)
    {
        var id = _next++;
        if (!Native.RegisterHotKey(_window.Handle, id, modifiers | Native.MOD_NOREPEAT, key)) return 0;
        _actions[id] = action;
        return id;
    }

    public void Remove(int id)
    {
        if (id == 0) return;
        Native.UnregisterHotKey(_window.Handle, id);
        _actions.Remove(id);
    }

    public void Dispose()
    {
        foreach (var id in _actions.Keys.ToList()) Remove(id);
        _window.Dispose();
    }
}

public sealed class App : Application
{
    const string InstanceName = "Muna-capsule-instance";
    const string OpenSignal = "Muna-capsule-open";
    static Mutex? _instance;

    public static AppState State { get; private set; } = null!;
    Forms.NotifyIcon? _icon;
    ReadingIcons? _readings;
    HotKeys? _keys;
    int _commandKey, _radialKey;
    readonly List<int> _sectionKeys = new();
    RadialMenu? _radial;

    [STAThread]
    public static void Main()
    {
        _instance = new Mutex(true, InstanceName, out var first);
        if (!first)
        {
            // Muna runs already: started again from the Start menu, it opens the panel
            try { EventWaitHandle.OpenExisting(OpenSignal).Set(); } catch { /* the other one is starting */ }
            return;
        }
        var app = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Run();
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += (_, args) =>
        {
            Log(args.Exception);
            args.Handled = true;
        };
        State = new AppState();
        State.Start();
        SetUpTrayIcon();
        SetUpKeys();
        Preferences.Shared.Changed += key =>
        {
            if (key is "command-hotkey" or "radial-hotkey" or "section-hotkeys") Dispatcher.BeginInvoke(SetUpKeys);
        };
        var signal = new EventWaitHandle(false, EventResetMode.AutoReset, OpenSignal);
        new Thread(() =>
        {
            while (signal.WaitOne()) Dispatcher.BeginInvoke(() => State.Capsules.Open(PanelTab.Muna));
        }) { IsBackground = true }.Start();
        AutoStart.Refresh();
    }

    public static void Log(string text)
    {
        try
        {
            System.IO.Directory.CreateDirectory(DataDirectory.Path);
            System.IO.File.AppendAllText(System.IO.Path.Combine(DataDirectory.Path, "muna.log"), $"{DateTime.Now:s} {text}\n");
        }
        catch { /* nowhere to write */ }
    }

    public static void Log(Exception exception)
    {
        try
        {
            var file = System.IO.Path.Combine(DataDirectory.Path, "muna.log");
            System.IO.Directory.CreateDirectory(DataDirectory.Path);
            System.IO.File.AppendAllText(file, $"{DateTime.Now:s} {exception}\n\n");
        }
        catch { /* nowhere to write */ }
    }

    void SetUpKeys()
    {
        _keys ??= new HotKeys();
        _keys.Remove(_commandKey);
        _keys.Remove(_radialKey);
        foreach (var id in _sectionKeys) _keys.Remove(id);
        _sectionKeys.Clear();
        var preferences = Preferences.Shared;
        const uint space = 0x20;
        _commandKey = preferences.CommandHotKey ? _keys.Add(Native.MOD_ALT, space, State.Capsules.OpenCommand) : 0;
        if (_radial is null)
        {
            _radial = new RadialMenu(State);
            State.RadialRequested += _radial.Toggle;
        }
        _radialKey = preferences.RadialHotKey ? _keys.Add(Native.MOD_CONTROL | Native.MOD_ALT, space, _radial.Toggle) : 0;
        if (preferences.SectionHotKeys)
        {
            for (var i = 0; i < Tabs.Visible.Length; i++)
            {
                var tab = Tabs.Visible[i];
                _sectionKeys.Add(_keys.Add(Native.MOD_CONTROL | Native.MOD_ALT, (uint)(0x31 + i), () => State.Capsules.Open(tab)));
            }
        }
    }

    /// <summary>Muna's icon in the notification area: a click opens the quick panel (as the top-bar
    /// button on Linux), a right click the menu.</summary>
    void SetUpTrayIcon()
    {
        Icon icon;
        try
        {
            using var stream = GetResourceStream(new Uri("pack://application:,,,/Assets/Tray.ico"))!.Stream;
            icon = new Icon(stream, Forms.SystemInformation.SmallIconSize);
        }
        catch { icon = SystemIcons.Application; }
        _icon = new Forms.NotifyIcon { Icon = icon, Text = "Muna", Visible = true, ContextMenuStrip = new Forms.ContextMenuStrip() };
        _icon.ContextMenuStrip.Opening += (_, _) => BuildMenu(_icon.ContextMenuStrip);
        _icon.MouseUp += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left) State.ToggleQuickPanel();
        };
        _readings = new ReadingIcons(State);
        var readings = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        readings.Tick += (_, _) =>
        {
            var p = Preferences.Shared;
            var needed = p.MenuBarReadings || p.BarMetrics.Count > 0 || p.MunaBarScreens != "off";
            if (needed && !State.Monitor.Watched) State.Monitor.Sample();
            _readings.Update();
            if (!p.MenuBarReadings) { if (_icon.Text != "Muna") _icon.Text = "Muna"; return; }
            var text = $"Muna · CPU {(int)(State.Monitor.Cpu * 100)}% · RAM {State.Monitor.MemoryPercent}%";
            _icon.Text = text.Length > 63 ? text[..63] : text;
        };
        readings.Start();
    }

    void BuildMenu(Forms.ContextMenuStrip menu)
    {
        menu.Items.Clear();
        menu.Renderer = new Forms.ToolStripProfessionalRenderer(new DarkMenuColors());
        menu.ForeColor = System.Drawing.Color.FromArgb(245, 245, 247);
        foreach (var tab in Tabs.Visible)
        {
            var t = tab;
            menu.Items.Add($"Open {tab.Title()}", null, (_, _) => State.Capsules.Open(t));
        }
        menu.Items.Add("Command Bar   Alt+Space", null, (_, _) => State.Capsules.OpenCommand());
        menu.Items.Add(new Forms.ToolStripSeparator());
        var receive = new Forms.ToolStripMenuItem("Receive files (LocalSend)") { Checked = Preferences.Shared.LocalSendReceive };
        receive.Click += (_, _) => Preferences.Shared.LocalSendReceive = !Preferences.Shared.LocalSendReceive;
        menu.Items.Add(receive);
        if (State.LocalSend.ReceiveProblem is { } problem) menu.Items.Add(new Forms.ToolStripMenuItem(problem) { Enabled = false });
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Agents", null, (_, _) => State.ShowAgents());
        menu.Items.Add("Scratchpad", null, (_, _) => State.ShowScratchpad());
        menu.Items.Add("Settings…", null, (_, _) => State.ShowSettings());
        menu.Items.Add("About Muna", null, (_, _) => State.ShowSettings("about"));
        menu.Items.Add("Quit Muna", null, (_, _) => Quit());
    }

    void Quit()
    {
        State.Shutdown();
        if (_icon is not null) { _icon.Visible = false; _icon.Dispose(); }
        _readings?.Dispose();
        _keys?.Dispose();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_icon is not null) _icon.Visible = false;
        base.OnExit(e);
    }

    sealed class DarkMenuColors : Forms.ProfessionalColorTable
    {
        static readonly System.Drawing.Color Back = System.Drawing.Color.FromArgb(32, 32, 35);
        static readonly System.Drawing.Color Hover = System.Drawing.Color.FromArgb(52, 52, 56);
        public override System.Drawing.Color ToolStripDropDownBackground => Back;
        public override System.Drawing.Color ImageMarginGradientBegin => Back;
        public override System.Drawing.Color ImageMarginGradientMiddle => Back;
        public override System.Drawing.Color ImageMarginGradientEnd => Back;
        public override System.Drawing.Color MenuItemSelected => Hover;
        public override System.Drawing.Color MenuItemBorder => Hover;
        public override System.Drawing.Color MenuBorder => System.Drawing.Color.FromArgb(60, 60, 64);
        public override System.Drawing.Color SeparatorDark => System.Drawing.Color.FromArgb(60, 60, 64);
        public override System.Drawing.Color SeparatorLight => Back;
        public override System.Drawing.Color CheckBackground => Hover;
        public override System.Drawing.Color CheckSelectedBackground => Hover;
    }
}

/// <summary>Open at login: a value in the current user's Run key.</summary>
public static class AutoStart
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static bool Enabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(Key);
            return key?.GetValue("Muna") is string;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(Key);
            if (value) key.SetValue("Muna", $"\"{Environment.ProcessPath}\"");
            else key.DeleteValue("Muna", false);
        }
    }

    /// <summary>Muna moved (a new build in another folder): the entry follows it.</summary>
    public static void Refresh()
    {
        try { if (Enabled) Enabled = true; } catch { /* no registry */ }
    }
}
