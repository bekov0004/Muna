using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using Muna.Core;

namespace Muna;

/// <summary>What the capsule draws: closed (date · butterfly · time, or what runs), open (the tabs and
/// the section), and the widgets of the Muna section, after Muna on Linux.</summary>
public static class CapsuleViews
{
    /// <summary>What the text fields do on Enter (wired once per capsule).</summary>
    public static void Wire(CapsuleWindow w)
    {
        var state = w.State;
        state.TodoField.Submitted += () => { if (w.App.Todo.Add(state.TodoField.Text)) state.TodoField.Text = ""; };
        state.NoteField.Submitted += () => { if (w.App.Notes.Add(state.NoteField.Text)) state.NoteField.Text = ""; };
        LocalSendPage.Wire(w);
        ClipboardPage.Wire(w);
        CommandView.Wire(w);
        AgentsView.Wire(w);
    }

    // --- closed ------------------------------------------------------------------------------------

    public static UIElement Closed(CapsuleWindow w)
    {
        var app = w.App;
        var session = app.LocalSend.Session;
        UIElement left, right;
        if (Preferences.Shared.ActivitiesInCollapsed && session.Phase == SessionPhase.Sending)
        {
            left = Ui.Icon(Glyph.Up, 13, C.Accent);
            right = new Live(() =>
            {
                long total = session.Transfers.Sum(t => t.Total), sent = session.Transfers.Sum(t => t.Sent);
                return Ui.Digits($"{(total > 0 ? 100 * sent / total : 0)}%", 12, FontWeights.Bold, Brushes.White);
            }, TimeSpan.FromMilliseconds(250));
        }
        else if (Preferences.Shared.ActivitiesInCollapsed && app.Timer.Active)
        {
            left = Ui.Icon(Glyph.Clock, 12, C.Amber);
            right = Ui.Digits(TimerModel.Text(app.Timer.Remaining), 12, FontWeights.Bold, app.Timer.Current == TimerModel.State.Done ? C.Amber : Brushes.White);
        }
        else if (Preferences.Shared.ActivitiesInCollapsed && app.NowPlaying.Track is { } track)
        {
            left = Ui.Artwork(track.Artwork, CapsuleWindow.BarHeight - 12);
            right = new Live(() => Ui.Bars(app.NowPlaying.IsPlaying), TimeSpan.FromMilliseconds(120));
        }
        else
        {
            left = new Live(() => Ui.Semi(DateTime.Now.ToString("ddd d MMM", CultureInfo.CurrentCulture), 12, C.White(0.78)), TimeSpan.FromSeconds(5));
            right = new Live(() => Ui.Digits(DateTime.Now.ToString("t", CultureInfo.CurrentCulture), 12, FontWeights.Bold, Brushes.White), TimeSpan.FromSeconds(5));
        }
        UIElement middle = Preferences.Shared.CapsuleButterfly
            ? Ui.Butterfly(Math.Max(12, CapsuleWindow.BarHeight - 9))
            : new Grid
            {
                Width = 14, Height = 14,
                Children =
                {
                    new Ellipse { Fill = C.Rgb(8, 8, 12), Stroke = C.White(0.1), StrokeThickness = 1 },
                    new Ellipse { Width = 4, Height = 4, Fill = C.Rgb(70, 110, 255, 0.55) },
                },
            };
        var bar = Ui.Row(0, left, Ui.Spacer(), middle, Ui.Spacer(), right).Size(height: CapsuleWindow.BarHeight);
        bar.Margin = new Thickness(16, 0, 16, 0);
        var column = Ui.Column(0, bar);
        if (w.Card is { } card)
        {
            var line = Ui.Row(8, Ui.Icon(card.Glyph, 13, card.Ok ? C.Ok : C.Warning), Ui.Semi(card.Title, 12),
                              Ui.Text(card.Details, 11, color: C.Secondary).Grow());
            line.Margin = new Thickness(22, 0, 22, 0);
            line.Height = CapsuleWindow.CardHeight;
            column.Children.Add(line);
        }
        var box = Ui.Box(column).Align(v: VerticalAlignment.Top);
        return box.OnClick(() => w.Open(w.Tab));
    }

    // --- open --------------------------------------------------------------------------------------

    public static UIElement Open(CapsuleWindow w)
    {
        UIElement body = w.Tab switch
        {
            PanelTab.Muna => MunaPage(w),
            PanelTab.Tray => TrayPage(w),
            PanelTab.LocalSend => LocalSendPage.Build(w),
            PanelTab.Clipboard => ClipboardPage.Build(w),
            PanelTab.Alerts => AlertsPage(w),
            PanelTab.Command => CommandView.Build(w),
            PanelTab.Agent => AgentsView.Permission(w),
            _ => MirrorLarge(w),
        };
        var holder = new Border { Child = body, Height = w.Tab.BodyHeight(), ClipToBounds = w.Tab != PanelTab.Command };
        var column = Ui.Column(0, w.Tab.HasHeader() ? Header(w) : new Border { Height = 8 }, holder);
        column.VerticalAlignment = VerticalAlignment.Top;
        TextElement.SetForeground(column, C.Text);
        // the panel's padding (16, as munaLayout.js counts it: the widgets fill the rest exactly)
        return new Border { Child = column, Padding = new Thickness(PanelLayout.Padding, 0, PanelLayout.Padding, CapsuleWindow.BottomPadding) };
    }

    static UIElement Header(CapsuleWindow w)
    {
        var row = Ui.Row(4);
        foreach (var tab in Tabs.Visible)
        {
            var selected = w.Tab == tab;
            var color = selected ? Brushes.White : C.White(0.55);
            UIElement icon = tab == PanelTab.Muna ? Ui.Butterfly(12) : Ui.Icon(tab.Glyph(), 11, color);
            var button = Ui.Box(Ui.Row(6, icon, Ui.Bold(tab.Title(), 12, color)), selected ? C.White(0.13) : C.Clear, 12, 10).Size(height: 24);
            row.Children.Add(button.OnClick(() => w.SetTab(tab), selected ? null : C.White(0.06)));
        }
        row.Children.Add(Ui.Spacer());
        if (w.Tab == PanelTab.Muna && w.Layout.Pages.Count > 1)
        {
            var dots = Ui.Row(6);
            for (var i = 0; i < w.Layout.Pages.Count; i++)
            {
                var index = i;
                var dot = new Ellipse { Width = 5, Height = 5, Fill = C.White(index == w.PageIndex ? 0.85 : 0.22) };
                dots.Children.Add(Ui.Box(dot).Size(13, 13).OnClick(() => { w.PageIndex = index; w.Invalidate(); }));
            }
            dots.Margin = new Thickness(0, 0, 6, 0);
            row.Children.Add(dots);
        }
        row.Children.Add(Ui.ControlButton(Glyph.Settings, () => w.App.ShowSettings(), 13, 24, 24, C.White(0.6)).Tip("Settings"));
        row.Height = 24;
        row.Margin = new Thickness(0, 6, 0, 6);
        return row;
    }

    /// <summary>The Muna section: the chosen widgets side by side (thin lines between them), several
    /// pages when they do not fit; the wheel or the dots change the page.</summary>
    static UIElement MunaPage(CapsuleWindow w)
    {
        var pages = w.Layout.Pages;
        var slots = w.PageIndex < pages.Count ? pages[w.PageIndex] : pages.FirstOrDefault() ?? new();
        var row = Ui.Row(0);
        row.Center = false;
        for (var i = 0; i < slots.Count; i++)
        {
            if (i > 0)
                row.Children.Add(new Grid { Width = PanelLayout.Gap, Children = { Ui.Line(true).Align(HorizontalAlignment.Center) } });
            var (id, width) = slots[i];
            row.Children.Add(new Border { Width = width, Height = PanelLayout.RowHeight, Child = Widget(w, id), ClipToBounds = id != "companion" });
        }
        return row;
    }

    static UIElement Widget(CapsuleWindow w, string id) => id switch
    {
        "media" => Media(w),
        "calendar" => Calendar(w),
        "mirror" => Mirror(w),
        "timer" => TimerWidget(w),
        "todo" => Todo(w),
        "notes" => Notes(w),
        "shortcuts" => Shortcuts(w),
        "companion" => CompanionView.Build(w.App.Companion),
        _ => new Border(),
    };

    static UIElement Empty(string glyph, string title, string? subtitle = null, UIElement? action = null)
    {
        var column = Ui.Column(6, Ui.Icon(glyph, 24, C.White(0.28)), Ui.Semi(title, 11, C.White(0.4)).Align(HorizontalAlignment.Center));
        if (subtitle is not null) column.Children.Add(Ui.Text(subtitle, 10, color: C.White(0.3)).Align(HorizontalAlignment.Center));
        if (action is not null) column.Children.Add(Ui.Detach(action));
        column.Center = true;
        return column.Align(HorizontalAlignment.Center, VerticalAlignment.Center);
    }

    // --- media ---------------------------------------------------------------------------------------

    static UIElement Media(CapsuleWindow w)
    {
        var now = w.App.NowPlaying;
        if (now.Track is not { } track) return Empty(Glyph.Music, "Nothing is playing", "Music from any app shows here");
        var title = Ui.Bold(track.Title, 13, Brushes.White);
        var middle = new Live(() => now.LyricLine() is { } line
            ? Ui.Semi(line, 11, C.Muna)
            : Ui.Text(track.Album.Length > 0 ? track.Album : track.App, 11, color: C.White(0.6)), TimeSpan.FromMilliseconds(500));
        var artist = Ui.Text(track.Artist, 11, color: C.White(0.45));
        var controls = Ui.Row(2,
            Ui.ControlButton(Glyph.Previous, now.Previous, 12, 26, 24),
            Ui.ControlButton(now.IsPlaying ? Glyph.Pause : Glyph.Play, now.PlayPause, 15, 26, 24),
            Ui.ControlButton(Glyph.Next, now.Next, 12, 26, 24),
            Ui.Spacer(),
            new Live(() => Ui.Bars(now.IsPlaying, C.Muna), TimeSpan.FromMilliseconds(120)).Margin(0, 0, 4, 0));
        controls.Margin = new Thickness(0, 2, 0, 0);
        var text = Ui.Column(1, title, middle, artist, controls).Grow();
        var top = Ui.Row(12, Ui.Artwork(track.Artwork, 64, 10).Align(v: VerticalAlignment.Top), text);
        top.Center = false;
        var column = Ui.Column(8, top);
        if (track.Duration > 0) column.Children.Add(new Live(() => Progress(now, track.Duration), TimeSpan.FromSeconds(1)));
        return column;
    }

    static string Clock(double seconds)
    {
        var total = (int)seconds;
        return $"{total / 60}:{total % 60:00}";
    }

    /// <summary>The time played, a thin bar (a click jumps there), the length.</summary>
    static UIElement Progress(NowPlaying now, double duration)
    {
        var position = now.CurrentPosition();
        var track = new Grid { Height = 10, Background = C.Clear, Cursor = Cursors.Hand };
        track.Children.Add(new Rectangle { Height = 3, RadiusX = 1.5, RadiusY = 1.5, Fill = C.White(0.14) });
        var fill = new Rectangle { Height = 3, RadiusX = 1.5, RadiusY = 1.5, Fill = Brushes.White, HorizontalAlignment = HorizontalAlignment.Left };
        track.Children.Add(fill);
        track.SizeChanged += (_, _) => fill.Width = Math.Max(0, track.ActualWidth * Math.Clamp(position / duration, 0, 1));
        track.MouseLeftButtonUp += (_, e) =>
        {
            var share = Math.Clamp(e.GetPosition(track).X / Math.Max(1, track.ActualWidth), 0, 1);
            now.Seek(share * duration);
            e.Handled = true;
        };
        return Ui.Row(8, Ui.Digits(Clock(position), 9, color: C.White(0.45)), track.Grow(), Ui.Digits(Clock(duration), 9, color: C.White(0.45)));
    }

    // --- calendar ------------------------------------------------------------------------------------

    /// <summary>The month, a strip of seven days around the chosen one (today in blue), and that day's events.</summary>
    static UIElement Calendar(CapsuleWindow w)
    {
        var calendar = w.App.Calendar;
        var selected = w.State.CalendarDay;
        void Move(int days) { w.State.CalendarDay = selected.AddDays(days); w.Invalidate(); }
        var head = Ui.Row(2, Ui.Text(selected.ToString("MMMM", CultureInfo.CurrentCulture), 15, FontWeights.Black, Brushes.White), Ui.Spacer(),
                          Ui.ControlButton(Glyph.Left, () => Move(-7), 9, 20, 20, C.White(0.45)),
                          Ui.ControlButton(Glyph.Right, () => Move(7), 9, 20, 20, C.White(0.45)));
        var days = new Grid();
        for (var offset = -3; offset <= 3; offset++)
        {
            days.ColumnDefinitions.Add(new ColumnDefinition());
            var day = selected.AddDays(offset);
            var today = day.Date == DateTime.Today;
            var weekend = day.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday;
            var cell = Ui.Column(1,
                Ui.Bold(CultureInfo.CurrentCulture.DateTimeFormat.GetShortestDayName(day.DayOfWeek)[..1].ToUpperInvariant(), 9, C.White(0.32)).Align(HorizontalAlignment.Center),
                Ui.Digits(day.Day.ToString(), 12, today ? FontWeights.Black : FontWeights.SemiBold,
                          today ? C.Accent : weekend ? C.Rgb(255, 115, 115, 0.85) : C.White(0.78)).Align(HorizontalAlignment.Center),
                new Ellipse { Width = 3, Height = 3, Fill = calendar.EventsOn(day).Count > 0 ? C.White(0.5) : C.Clear, HorizontalAlignment = HorizontalAlignment.Center });
            var box = Ui.Box(cell, offset == 0 ? C.White(0.10) : C.Clear, 10, 0, 3);
            var picked = day;
            box.OnClick(() => { w.State.CalendarDay = picked; w.Invalidate(); });
            Grid.SetColumn(box, offset + 3);
            days.Children.Add(box);
        }
        return Ui.Column(4, head, days, Events(w, selected));
    }

    static UIElement Events(CapsuleWindow w, DateTime day)
    {
        var calendar = w.App.Calendar;
        if (!calendar.HasSource)
            return Ui.Pill("Add a calendar link", () => w.App.ShowSettings("calendar"), accent: true).Align(HorizontalAlignment.Center);
        if (calendar.Error.Length > 0)
            return Ui.Text(calendar.Error, 10, color: C.White(0.4));
        var events = calendar.EventsOn(day);
        if (events.Count == 0)
        {
            var row = Ui.Row(6, Ui.Icon(Glyph.Calendar, 11, C.White(0.4)), Ui.Text(day.Date == DateTime.Today ? "Nothing for today" : "Nothing this day", 11, color: C.White(0.4)));
            return row.Align(HorizontalAlignment.Center).Margin(0, 4, 0, 0);
        }
        var list = Ui.Column(2);
        foreach (var e in events.Take(2))
            list.Children.Add(Ui.Row(6, new Rectangle { Width = 3, Height = 12, RadiusX = 1, RadiusY = 1, Fill = C.Accent },
                Ui.Digits(e.AllDay ? "All day" : e.Start.ToString("t", CultureInfo.CurrentCulture), 10, FontWeights.SemiBold, C.White(0.5)),
                Ui.Semi(e.Title, 11).Grow()));
        if (events.Count > 2) list.Children.Add(Ui.Text($"+{events.Count - 2} more", 10, color: C.White(0.4)));
        return list;
    }

    // --- mirror ----------------------------------------------------------------------------------

    /// <summary>A round camera preview, running only while it is seen.</summary>
    static UIElement Mirror(CapsuleWindow w)
    {
        var camera = w.App.Camera;
        var side = PanelLayout.RowHeight - 6;
        var grid = new Grid { Width = side, Height = side };
        grid.Children.Add(new Ellipse { Fill = C.White(0.06) });
        switch (camera.Access)
        {
            case CameraModel.State.Running or CameraModel.State.Starting:
                var image = new Image { Source = camera.Frame, Stretch = Stretch.UniformToFill, RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = new ScaleTransform(-1, 1) };
                image.Clip = new EllipseGeometry(new Point(side / 2, side / 2), side / 2, side / 2);
                grid.Children.Add(image);
                break;
            case CameraModel.State.Off:
                grid.Children.Add(Label(Glyph.Camera, "Mirror").OnClick(camera.Start));
                break;
            case CameraModel.State.Denied:
                grid.Children.Add(Label(Glyph.VideoOff, "Allow the camera in Settings → Privacy"));
                break;
            default:
                grid.Children.Add(Label(Glyph.VideoOff, "No camera"));
                break;
        }
        grid.Loaded += (_, _) => camera.Want(true);
        grid.Unloaded += (_, _) => camera.Want(false);
        var outer = new Grid();
        outer.Children.Add(grid);
        if (camera.Access == CameraModel.State.Running)
            outer.Children.Add(Ui.IconButton(Glyph.Expand, () => w.SetTab(PanelTab.Mirror), tip: "Bigger").Align(HorizontalAlignment.Right, VerticalAlignment.Top));
        return outer;

        static Border Label(string glyph, string text)
        {
            var column = Ui.Column(6, Ui.Icon(glyph, 20, C.White(0.75)), Ui.Text(text, 11, FontWeights.SemiBold, C.White(0.75), lines: 2));
            ((TextBlock)column.Children[1]).TextAlignment = TextAlignment.Center;
            column.Center = true;
            return Ui.Box(column.Align(HorizontalAlignment.Center, VerticalAlignment.Center), C.Clear, 0, 10);
        }
    }

    /// <summary>The Mirror enlarged: a big round-cornered picture (Linux's enlarged Mirror card).</summary>
    static UIElement MirrorLarge(CapsuleWindow w)
    {
        var camera = w.App.Camera;
        var image = new Image { Source = camera.Frame, Stretch = Stretch.UniformToFill, Width = 250, Height = 250, RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = new ScaleTransform(-1, 1) };
        image.Clip = new RectangleGeometry(new Rect(0, 0, 250, 250), 28, 28);
        var column = Ui.Column(10, image, Ui.Pill("Smaller", () => w.SetTab(PanelTab.Muna)).Align(HorizontalAlignment.Center));
        column.Center = true;
        column.Loaded += (_, _) => camera.Want(true);
        column.Unloaded += (_, _) => camera.Want(false);
        return column.Align(HorizontalAlignment.Center, VerticalAlignment.Center);
    }

    // --- timer ---------------------------------------------------------------------------------------

    static UIElement TimerWidget(CapsuleWindow w)
    {
        var timer = w.App.Timer;
        var time = Ui.Digits(TimerModel.Text(timer.Current == TimerModel.State.Idle ? timer.Duration : timer.Remaining), 26, FontWeights.Light,
                             timer.Current == TimerModel.State.Done ? C.Amber : Brushes.White);
        time.TextAlignment = TextAlignment.Center;
        var top = Ui.Row(6, Step(Glyph.Remove, () => timer.Step(-1)), new Viewbox { Child = time, StretchDirection = StretchDirection.DownOnly }.Grow(), Step(Glyph.Add, () => timer.Step(1)));
        var column = Ui.Column(8, top);
        switch (timer.Current)
        {
            case TimerModel.State.Idle:
                var presets = new Grid();
                foreach (var minutes in TimerModel.Presets)
                {
                    presets.ColumnDefinitions.Add(new ColumnDefinition());
                    var m = minutes;
                    var b = Ui.Box(Ui.Semi($"{minutes}m", 11, C.White(0.85)).Align(HorizontalAlignment.Center, VerticalAlignment.Center), C.White(0.08), 11).Size(height: 22);
                    b.Margin = new Thickness(3, 0, 3, 0);
                    b.OnClick(() => timer.Set(m));
                    Grid.SetColumn(b, presets.Children.Count);
                    presets.Children.Add(b);
                }
                column.Children.Add(presets);
                column.Children.Add(Ui.WideButton(Glyph.Play, "Start", timer.Start, true));
                break;
            case TimerModel.State.Running:
                column.Children.Add(Pair(Ui.WideButton(Glyph.Pause, "Pause", timer.Pause, true), Ui.WideButton(Glyph.Refresh, "Reset", timer.Reset)));
                break;
            case TimerModel.State.Paused:
                column.Children.Add(Pair(Ui.WideButton(Glyph.Play, "Resume", timer.Start, true), Ui.WideButton(Glyph.Refresh, "Reset", timer.Reset)));
                break;
            default:
                column.Children.Add(Ui.Semi("Time is up", 11, C.Amber).Align(HorizontalAlignment.Center));
                column.Children.Add(Pair(Ui.WideButton(Glyph.Add, "1 min", () => timer.Step(1)), Ui.WideButton(Glyph.Check, "OK", timer.Reset, true)));
                break;
        }
        return column.Align(v: VerticalAlignment.Center);

        static UIElement Step(string glyph, Action action) =>
            Ui.Box(Ui.Icon(glyph, 10, C.White(0.8)), C.White(0.08), 13).Size(26, 26).OnClick(action, C.White(0.14));

        static UIElement Pair(UIElement a, UIElement b) => Ui.Row(6, a.Grow(), b.Grow());
    }

    // --- to-do, notes ----------------------------------------------------------------------------------

    static UIElement Todo(CapsuleWindow w)
    {
        var todo = w.App.Todo;
        var list = Ui.Column(2);
        foreach (var item in todo.Items)
        {
            var check = Ui.Box(Ui.Icon(item.Done ? Glyph.CheckCircle : Glyph.Circle, 12, item.Done ? C.Ok : C.White(0.45))).OnClick(() => todo.Toggle(item));
            var text = Ui.Text(item.Text, 11, color: item.Done ? C.White(0.4) : C.Text);
            if (item.Done) text.TextDecorations = TextDecorations.Strikethrough;
            list.Children.Add(Ui.Row(6, check, text.Grow(), Ui.IconButton(Glyph.Close, () => todo.Remove(item))));
        }
        var field = w.State.TodoField;
        return Ui.Column(6,
            Ui.Caption(todo.Items.Count == 0 ? "To-do" : $"To-do · {todo.OpenCount}", todo.HasDone ? Ui.Pill("Clear done", todo.ClearDone) : null),
            Ui.Scroll(list).Grow(),
            field);
    }

    static UIElement Notes(CapsuleWindow w)
    {
        var notes = w.App.Notes;
        var privacy = w.App.Privacy;
        var list = Ui.Column(3);
        foreach (var note in notes.Notes)
        {
            var hidden = note.IsPrivate && !privacy.Unlocked;
            var text = Ui.Text(hidden ? "Private · Windows Hello" : note.Text, 11, color: hidden ? C.White(0.4) : C.Text, lines: 2);
            var textBox = Ui.Box(text).Grow();
            if (hidden) textBox.OnClick(privacy.Unlock);
            var row = Ui.Row(6, textBox);
            row.Center = false;
            if (!hidden) row.Children.Add(Ui.IconButton(Glyph.Copy, () => ClipboardModel.SetText(note.Text), tip: "Copy"));
            row.Children.Add(Ui.IconButton(note.IsPrivate ? Glyph.Lock : Glyph.Unlock, () => { if (hidden) privacy.Unlock(); else notes.TogglePrivate(note); },
                                           note.IsPrivate ? C.Amber : C.Secondary, note.IsPrivate ? "Private" : "Make private"));
            row.Children.Add(Ui.IconButton(Glyph.Close, () => notes.Remove(note)));
            list.Children.Add(row);
        }
        var field = w.State.NoteField;
        return Ui.Column(6, Ui.Caption(notes.Notes.Count == 0 ? "Notes" : $"Notes · {notes.Notes.Count}"), Ui.Scroll(list).Grow(), field);
    }

    // --- shortcuts -------------------------------------------------------------------------------------

    /// <summary>Favourite apps (chosen in the settings); a click starts one.</summary>
    static UIElement Shortcuts(CapsuleWindow w)
    {
        var apps = Preferences.Shared.ShortcutApps;
        if (apps.Count == 0)
            return Empty(Glyph.Apps, "No apps yet", null, Ui.Pill("Choose apps", () => w.App.ShowSettings("widgets")));
        var wrap = new WrapPanel();
        foreach (var app in apps)
        {
            var path = app;
            var icon = Ui.Box(Ui.FileIconView(path, 34), C.Clear, 8, 3, 3).Tip(System.IO.Path.GetFileNameWithoutExtension(path));
            icon.Margin = new Thickness(0, 0, 6, 6);
            wrap.Children.Add(icon.OnClick(() => Launch(path), C.White(0.08)));
        }
        return Ui.Scroll(wrap);
    }

    public static void Launch(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch { /* gone */ }
    }

    // --- tray, alerts ------------------------------------------------------------------------------------

    /// <summary>The Tray: files dropped on the capsule wait here, to be dragged out, opened, or sent.</summary>
    static UIElement TrayPage(CapsuleWindow w)
    {
        var tray = w.App.Tray;
        var files = tray.Files;
        var caption = Ui.Caption(files.Count == 0 ? "Tray" : $"Tray · {files.Count}",
            files.Count == 0 ? null : Ui.Pill("Send with LocalSend", () =>
            {
                w.App.LocalSend.Session.Offer(files.ToList());
                w.SetTab(PanelTab.LocalSend);
                w.App.LocalSend.Session.Refresh();
            }),
            files.Count == 0 ? null : Ui.Pill("Clear", tray.Clear));
        if (files.Count == 0)
        {
            var empty = Ui.Column(8, Ui.Icon(Glyph.Tray, 26, C.Secondary), Ui.Text("Drop files on the capsule to keep them here", 12, color: C.Secondary));
            empty.Center = true;
            return Ui.Column(10, caption, empty.Align(HorizontalAlignment.Center, VerticalAlignment.Center).Grow());
        }
        var row = Ui.Row(10);
        foreach (var file in files) row.Children.Add(TrayItem(tray, file));
        var scroller = Ui.Scroll(row, horizontal: true);
        scroller.PreviewMouseWheel += (_, e) => { scroller.ScrollToHorizontalOffset(scroller.HorizontalOffset - e.Delta / 2.0); e.Handled = true; };
        return Ui.Column(6, caption, scroller.Grow());
    }

    static UIElement TrayItem(TrayModel tray, string path)
    {
        var name = Ui.Text(System.IO.Path.GetFileName(path), 11, FontWeights.Medium, lines: 2);
        name.TextAlignment = TextAlignment.Center;
        name.Width = 96;
        var column = Ui.Column(4, Ui.FileIconView(path, 40).Align(HorizontalAlignment.Center), name);
        var item = Ui.Box(column, C.Tile, 14, 10, 6).Tip(path);
        var grid = new Grid { Children = { item } };
        var remove = Ui.IconButton(Glyph.Close, () => tray.Remove(path)).Align(HorizontalAlignment.Right, VerticalAlignment.Top).Margin(0, 5, 5, 0);
        remove.Opacity = 0.55;
        grid.Children.Add(remove);
        grid.MouseEnter += (_, _) => { item.Background = C.TileHover; remove.Opacity = 1; };
        grid.MouseLeave += (_, _) => { item.Background = C.Tile; remove.Opacity = 0.55; };
        DragOut.Attach(item, () => new[] { path }, () => Launch(path));
        return grid;
    }

    static UIElement AlertsPage(CapsuleWindow w)
    {
        var alerts = w.App.Alerts;
        var caption = Ui.Caption(alerts.Alerts.Count == 0 ? "Alerts" : $"Alerts · {alerts.Alerts.Count}",
                                 alerts.Alerts.Count == 0 ? null : Ui.Pill("Clear", alerts.Clear));
        if (alerts.Alerts.Count == 0)
            return Ui.Column(8, caption, Empty(Glyph.Bell, "Nothing new").Grow());
        var list = Ui.Column(4);
        foreach (var alert in alerts.Alerts)
        {
            var text = Ui.Column(1, Ui.Semi(alert.Title, 12), Ui.Text(alert.Details, 11, color: C.Secondary));
            var row = Ui.Row(10, Ui.Icon(alert.Glyph, 13, alert.Ok ? C.Ok : C.Warning).Size(22), text.Grow(),
                             Ui.Digits(alert.At.ToString("t", CultureInfo.CurrentCulture), 10, color: C.Secondary),
                             Ui.IconButton(Glyph.Close, () => alerts.Remove(alert)));
            list.Children.Add(Ui.Box(row, C.Tile, 12, 10, 7));
        }
        return Ui.Column(8, caption, Ui.Scroll(list).Grow());
    }
}

/// <summary>Files dragged out of the capsule (Tray items, clipboard files) to Explorer or another app;
/// a click without moving opens them.</summary>
public static class DragOut
{
    public static void Attach(FrameworkElement element, Func<string[]> files, Action click)
    {
        Point? start = null;
        element.Cursor = Cursors.Hand;
        element.MouseLeftButtonDown += (_, e) => { start = e.GetPosition(element); e.Handled = true; };
        element.MouseMove += (_, e) =>
        {
            if (start is not { } s || e.LeftButton != MouseButtonState.Pressed) return;
            var p = e.GetPosition(element);
            if (Math.Abs(p.X - s.X) < 6 && Math.Abs(p.Y - s.Y) < 6) return;
            start = null;
            var list = files().Where(f => File.Exists(f) || Directory.Exists(f)).ToArray();
            if (list.Length == 0) return;
            var data = new DataObject(DataFormats.FileDrop, list);
            try { DragDrop.DoDragDrop(element, data, DragDropEffects.Copy | DragDropEffects.Move | DragDropEffects.Link); }
            catch { /* the drop target failed */ }
        };
        element.MouseLeftButtonUp += (_, e) =>
        {
            if (start is null) return;
            start = null;
            e.Handled = true;
            click();
        };
        element.MouseLeave += (_, e) => { if (e.LeftButton != MouseButtonState.Pressed) start = null; };
    }
}
