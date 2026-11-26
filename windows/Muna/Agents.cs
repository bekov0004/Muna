using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Muna.Core;

namespace Muna;

/// <summary>AI agents, as Muna on Linux (linux/service/agents): Claude Code tasks run in the
/// background (MunaCore's ClaudeTask), their questions come to the capsule, the agents window follows
/// them, and the plan's limits (5 hours, week) come with the answers.</summary>
public sealed class AgentsModel : Model
{
    public sealed record Limit(double Percent, DateTime ResetsAt);

    public List<ClaudeTask> Tasks { get; } = new();
    public Limit? FiveHour { get; private set; }
    public Limit? SevenDay { get; private set; }
    public string? SelectedId { get; set; }
    public bool Creating { get; set; }
    public string NewFolder { get; set; } = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public string? ClaudePath { get; } = ClaudeTask.FindClaude();
    public List<AgentSession> Sessions { get; private set; } = new();
    public event Action<ClaudeTask, Permission>? PermissionAsked;
    public event Action<ClaudeTask, bool>? TaskFinished;
    int _counter, _watchers;
    readonly DispatcherTimer _sessionTimer = new() { Interval = TimeSpan.FromSeconds(5) };

    public AgentsModel() => _sessionTimer.Tick += (_, _) => ScanSessions();

    public ClaudeTask? Selected => Tasks.FirstOrDefault(t => t.Id == SelectedId) ?? Tasks.FirstOrDefault();

    /// <summary>The first question waiting for an answer.</summary>
    public (ClaudeTask Task, Permission Permission)? Waiting
    {
        get
        {
            foreach (var task in Tasks)
                if (task.Pending.Count > 0) return (task, task.Pending[0]);
            return null;
        }
    }

    public int RunningCount => Tasks.Count(t => t.Status is AgentStatus.Working or AgentStatus.Waiting or AgentStatus.Starting);

    /// <summary>Terminal sessions are read while something shows them.</summary>
    public void WatchSessions()
    {
        if (_watchers++ == 0) { ScanSessions(); _sessionTimer.Start(); }
    }

    public void UnwatchSessions()
    {
        if (--_watchers <= 0) { _watchers = 0; _sessionTimer.Stop(); }
    }

    void ScanSessions()
    {
        var ours = Tasks.Select(t => t.SessionId).Where(s => s.Length > 0).ToHashSet();
        Task.Run(() => AgentSessions.Scan(except: ours)).ContinueWith(t => Ui(() => { Sessions = t.Result; Notify(); }));
    }

    public void Start(string prompt, string folder)
    {
        prompt = prompt.Trim();
        if (prompt.Length == 0 || ClaudePath is null) return;
        _counter++;
        var task = new ClaudeTask($"{DateTimeOffset.Now.ToUnixTimeSeconds()}-{_counter}", folder, prompt, ClaudePath) { Post = action => Ui(action) };
        task.Changed += _ => Notify();
        task.PermissionAsked += (t, p) => PermissionAsked?.Invoke(t, p);
        task.Finished += (t, ok) => TaskFinished?.Invoke(t, ok);
        task.RateLimit += RateLimit;
        Tasks.Insert(0, task);
        SelectedId = task.Id;
        Creating = false;
        task.Start();
        Notify();
    }

    public void Answer(ClaudeTask task, Permission permission, Decision decision) => task.Answer(permission.RequestId, decision);

    public void Remove(ClaudeTask task)
    {
        task.Stop();
        Tasks.Remove(task);
        if (SelectedId == task.Id) SelectedId = Tasks.FirstOrDefault()?.Id;
        Notify();
    }

    public void StopAll()
    {
        foreach (var task in Tasks) task.Stop();
    }

    /// <summary>rate_limit_event: {unifiedWindows: {five_hour: {utilization, resetsAt}, seven_day: …}}</summary>
    void RateLimit(JsonNode info) => Ui(() =>
    {
        if (info["unifiedWindows"] is not JsonObject windows) return;
        Limit? Read(string key)
        {
            if (windows[key] is not JsonObject window) return null;
            var utilization = window.Double("utilization") ?? 0;
            var resets = window.Double("resetsAt") ?? 0;
            return new Limit(Math.Round(utilization * 1000) / 10, DateTimeOffset.FromUnixTimeSeconds((long)resets).LocalDateTime);
        }
        FiveHour = Read("five_hour") ?? FiveHour;
        SevenDay = Read("seven_day") ?? SevenDay;
        Notify();
    });

    public static string StatusText(ClaudeTask task) => task.Status switch
    {
        AgentStatus.Starting => "Starting",
        AgentStatus.Working => task.Current.Length == 0 ? "Working" : task.Current,
        AgentStatus.Waiting => "Needs you",
        AgentStatus.Idle => "Done, waiting for more",
        AgentStatus.Done => "Done",
        AgentStatus.Failed => task.Error.Length == 0 ? "Failed" : task.Error,
        _ => "Stopped",
    };

    public static (string Glyph, Brush Tint) StatusGlyph(ClaudeTask task) => task.Status switch
    {
        AgentStatus.Starting or AgentStatus.Working => (Glyph.More, C.Accent),
        AgentStatus.Waiting => (Glyph.Info, C.Amber),
        AgentStatus.Idle or AgentStatus.Done => (Glyph.CheckCircle, C.Ok),
        AgentStatus.Failed => (Glyph.Warning, C.Warning),
        _ => (Glyph.Close, C.Secondary),
    };

    public static string ResetText(DateTime at)
    {
        var minutes = Math.Max(0, (int)(at - DateTime.Now).TotalMinutes);
        if (minutes >= 1440) return $"resets in {minutes / 1440} d";
        if (minutes >= 60) return $"resets in {minutes / 60} h {minutes % 60} min";
        return $"resets in {minutes} min";
    }
}

public static class AgentsView
{
    public static void Wire(CapsuleWindow w) { }

    /// <summary>A task asks before doing something: in the capsule, with Deny / Always / Allow.</summary>
    public static UIElement Permission(CapsuleWindow w)
    {
        var agents = w.App.Agents;
        if (agents.Waiting is not { } waiting)
        {
            var column = Ui.Column(6, Ui.Icon(Glyph.CheckCircle, 22, C.Ok), Ui.Text("Nothing to answer", 12, color: C.Secondary));
            column.Center = true;
            return column.Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        }
        var (task, permission) = waiting;
        var text = Ui.Column(2, Ui.Text($"{permission.Verb} {permission.Detail}", 14, FontWeights.SemiBold, lines: 2));
        if (permission.Description.Length > 0) text.Children.Add(Ui.Text(permission.Description, 11, color: C.Secondary));
        return Ui.Column(10,
            Ui.Caption($"{task.Project} · Claude wants to", Ui.Pill("Open agents", w.App.ShowAgents)),
            Ui.Row(12, Ui.Icon(Glyph.Info, 24, C.Amber), text.Grow()),
            Ui.Row(8, Ui.Spacer(),
                Ui.Pill("Deny", () => agents.Answer(task, permission, Decision.Deny)),
                Ui.Pill("Always in this task", () => agents.Answer(task, permission, Decision.Always)),
                Ui.Pill("Allow", () => agents.Answer(task, permission, Decision.Allow), accent: true)));
    }
}

/// <summary>The agents window: the tasks on the left, the chosen one's conversation on the right.</summary>
public sealed class AgentsWindow : DarkWindow
{
    readonly AgentsModel _agents;
    readonly TextBox _prompt = DarkWindow.Input(multiline: true);
    readonly TextBox _draft = DarkWindow.Input();
    bool _queued;

    public AgentsWindow(AgentsModel agents)
    {
        _agents = agents;
        Title = "Agents";
        Width = 960;
        Height = 640;
        MinWidth = 700;
        MinHeight = 440;
        _agents.Changed += Queue;
        _draft.KeyDown += (_, e) => { if (e.Key == Key.Enter) { Send(); e.Handled = true; } };
        _prompt.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.Control) { StartTask(); e.Handled = true; }
        };
        Render();
    }

    void Queue()
    {
        if (_queued || !IsVisible) return;
        _queued = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Background, () => { _queued = false; Render(); });
    }

    protected override void OnShown() => Render();

    void Send()
    {
        if (_agents.Selected is not { } task || _draft.Text.Trim().Length == 0) return;
        task.Send(_draft.Text);
        _draft.Text = "";
    }

    void StartTask()
    {
        _agents.Start(_prompt.Text, _agents.NewFolder);
        if (!_agents.Creating) _prompt.Text = "";
    }

    void Render()
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(260) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        var side = Sidebar();
        grid.Children.Add(side);
        UIElement main = _agents.Creating || _agents.Tasks.Count == 0 ? NewTask() : _agents.Selected is { } task ? TaskView(task) : new Border();
        var mainBox = new Border { Child = main, Background = Brushes.Black };
        Grid.SetColumn(mainBox, 1);
        grid.Children.Add(mainBox);
        Content = grid;
    }

    UIElement Sidebar()
    {
        var list = Ui.Column(4);
        foreach (var task in _agents.Tasks)
        {
            var (glyph, tint) = AgentsModel.StatusGlyph(task);
            var text = Ui.Column(2, Ui.Semi(task.Project, 13), Ui.Text(task.Prompt, 11, color: C.Secondary), Ui.Text(AgentsModel.StatusText(task), 11, color: tint));
            var row = Ui.Row(8, Ui.Icon(glyph, 13, tint).Align(v: VerticalAlignment.Top).Margin(0, 2, 0, 0), text.Grow());
            row.Center = false;
            var selected = !_agents.Creating && _agents.Selected == task;
            var t = task;
            list.Children.Add(Ui.Box(row, selected ? C.Rgb(77, 141, 255, 0.25) : C.Clear, 10, 8, 8).OnClick(() =>
            {
                _agents.Creating = false;
                _agents.SelectedId = t.Id;
                Render();
            }, C.White(0.05)));
        }
        var head = Ui.Row(8, Ui.Box(Ui.Icon(Glyph.Add, 13), C.White(0.1), 15).Size(30, 30).OnClick(() => { _agents.Creating = true; Render(); }).Tip("New task"),
                          Ui.Spacer(), Ui.Bold("Agents", 14), Ui.Spacer(), new Border { Width = 30 });
        var column = Ui.Column(6, head, Ui.Scroll(list).Grow());
        foreach (var (label, limit) in new[] { ("5 hours", _agents.FiveHour), ("Week", _agents.SevenDay) })
            if (limit is not null) column.Children.Add(LimitLine(label, limit));
        return new Border { Child = column, Background = C.Rgb(23, 23, 23), Padding = new Thickness(12) };
    }

    public static UIElement LimitLine(string label, AgentsModel.Limit limit) => Ui.Column(3,
        Ui.Row(4, Ui.Semi(label, 11), Ui.Spacer(), Ui.Text($"{(int)limit.Percent}% · {AgentsModel.ResetText(limit.ResetsAt)}", 10, color: C.Secondary)),
        Meter(limit.Percent / 100));

    public static UIElement Meter(double share, Brush? color = null)
    {
        var grid = new Grid { Height = 5 };
        grid.Children.Add(new Border { CornerRadius = new CornerRadius(2.5), Background = C.White(0.12) });
        var fill = new Border { CornerRadius = new CornerRadius(2.5), Background = color ?? C.Accent, HorizontalAlignment = HorizontalAlignment.Left };
        grid.Children.Add(fill);
        grid.SizeChanged += (_, _) => fill.Width = grid.ActualWidth * Math.Clamp(share, 0, 1);
        return grid;
    }

    UIElement NewTask()
    {
        var column = Ui.Column(14, Ui.Bold("New task", 20));
        if (_agents.ClaudePath is null)
            column.Children.Add(Ui.Text("Claude Code is not installed: the claude command was not found (on the PATH, in %USERPROFILE%\\.local\\bin or npm).", 12, color: C.Warning, wrap: true));
        column.Children.Add(Ui.Row(8, Ui.Column(2, Ui.Semi("Folder", 12), Ui.Text(_agents.NewFolder, 12, color: C.Secondary)).Grow(),
            DarkWindow.Button("Choose…", () =>
            {
                var dialog = new Microsoft.Win32.OpenFolderDialog { InitialDirectory = _agents.NewFolder };
                if (dialog.ShowDialog(this) == true) { _agents.NewFolder = dialog.FolderName; Render(); }
            })));
        column.Children.Add(Ui.Semi("What should Claude do?", 12));
        _prompt.MinHeight = 120;
        column.Children.Add(Ui.Detach(_prompt));
        column.Children.Add(Ui.Row(8, Ui.Spacer(), DarkWindow.Button("Start (Ctrl+Enter)", StartTask, accent: true)));
        column.Children.Add(Ui.Text("Claude Code works in the folder and asks before it changes anything: the question comes to the capsule and here.", 11, color: C.Secondary, wrap: true));
        return new Border { Child = column, Padding = new Thickness(28) };
    }

    UIElement TaskView(ClaudeTask task)
    {
        var head = Ui.Row(10,
            Ui.Column(2, Ui.Bold($"{task.Project} · {AgentsModel.StatusText(task)}", 14),
                      Ui.Text($"{task.CostUsd.ToString("$0.00", CultureInfo.InvariantCulture)} · {(task.Model.Length == 0 ? "claude" : task.Model)}", 11, color: C.Secondary)).Grow(),
            DarkWindow.Button("Folder", () => CapsuleViews.Launch(task.Cwd)));
        if (task.Running)
        {
            head.Children.Add(DarkWindow.Button("Pause", task.Interrupt));
            head.Children.Add(DarkWindow.Button("Stop", task.Stop));
        }
        head.Children.Add(DarkWindow.Button("Forget", () => _agents.Remove(task)));
        head.Margin = new Thickness(18, 18, 18, 10);
        var entries = Ui.Column(10);
        foreach (var entry in task.Transcript) entries.Children.Add(Entry(entry));
        foreach (var permission in task.Pending.ToList())
        {
            var p = permission;
            var detail = new TextBox { Text = permission.Detail, IsReadOnly = true, FontFamily = Ui.Mono, FontSize = 12, Foreground = C.Text, Background = C.White(0.06), BorderThickness = new Thickness(0), Padding = new Thickness(8), TextWrapping = TextWrapping.Wrap };
            var box = Ui.Column(8, Ui.Semi($"Claude wants to: {permission.Verb}", 13), detail,
                Ui.Row(8, Ui.Spacer(), DarkWindow.Button("Deny", () => _agents.Answer(task, p, Decision.Deny)),
                    DarkWindow.Button("Always in this task", () => _agents.Answer(task, p, Decision.Always)),
                    DarkWindow.Button("Allow", () => _agents.Answer(task, p, Decision.Allow), accent: true)));
            entries.Children.Add(new Border { Child = box, Padding = new Thickness(12), CornerRadius = new CornerRadius(12), BorderBrush = C.Amber, BorderThickness = new Thickness(1) });
        }
        var scroller = Ui.Scroll(entries.Margin(18, 18, 18, 18));
        scroller.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        scroller.Loaded += (_, _) => scroller.ScrollToEnd();
        _draft.ToolTip = "Tell Claude more, or ask it to change something…";
        var bottom = Ui.Row(8, Ui.Detach(_draft).Grow(), DarkWindow.Button("Send", Send, accent: true));
        bottom.Margin = new Thickness(14);
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition());
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        void Add(UIElement e, int row) { Grid.SetRow(e, row); grid.Children.Add(e); }
        Add(head, 0);
        Add(Ui.Line(), 1);
        Add(scroller, 2);
        Add(Ui.Line(), 3);
        Add(bottom, 4);
        return grid;
    }

    static UIElement Selectable(string text, double size, Brush? color = null, FontFamily? font = null) => new TextBox
    {
        Text = text, IsReadOnly = true, BorderThickness = new Thickness(0), Background = C.Clear, Foreground = color ?? C.Text,
        FontFamily = font ?? Ui.Font, FontSize = size, TextWrapping = TextWrapping.Wrap, Padding = new Thickness(0),
    };

    static UIElement Entry(TaskEntry entry)
    {
        switch (entry.Kind)
        {
            case EntryKind.User:
                var bubble = Ui.Box(Selectable(entry.Text, 13), C.Rgb(77, 141, 255, 0.3), 14, 12, 8);
                bubble.HorizontalAlignment = HorizontalAlignment.Right;
                bubble.Margin = new Thickness(80, 0, 0, 0);
                return bubble;
            case EntryKind.Text:
                return Selectable(entry.Text, 13);
            case EntryKind.Tool:
                var column = Ui.Column(4, Ui.Row(6,
                    Ui.Icon(entry.Ok is null ? Glyph.More : entry.Ok == true ? Glyph.Check : Glyph.Close, 11, entry.Ok == false ? C.Warning : C.Ok),
                    Ui.Text(entry.Text, 12, color: C.Secondary).Grow()));
                if (entry.Output.Length > 0)
                    column.Children.Add(Ui.Text(entry.Output, 11, color: C.Secondary, lines: 6).Margin(20, 0, 0, 0));
                return column;
            case EntryKind.Note:
                return Ui.Text(entry.Text, 11, color: C.Secondary, wrap: true);
            case EntryKind.Result:
                var result = Ui.Column(4, Ui.Semi(entry.Ok == false ? "Stopped with an error" : "Done", 13));
                if (entry.Text.Length > 0) result.Children.Add(Selectable(entry.Text, 12));
                return new Border { Child = result, Padding = new Thickness(10), CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1), BorderBrush = entry.Ok == false ? C.Warning : C.Ok };
            default:
                return Ui.Text(entry.Text, 12, color: C.Warning, wrap: true);
        }
    }
}
