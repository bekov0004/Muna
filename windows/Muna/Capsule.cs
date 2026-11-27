using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Muna.Core;
using Forms = System.Windows.Forms;

namespace Muna;

/// <summary>The sections of the open capsule, as on Linux.</summary>
public enum PanelTab { Muna, Tray, LocalSend, Clipboard, Alerts, Command, Agent, Mirror }

public static class Tabs
{
    /// <summary>The tabs on top (the Command Bar has none: the capsule becomes its field).</summary>
    public static readonly PanelTab[] Visible = { PanelTab.Muna, PanelTab.Tray, PanelTab.LocalSend, PanelTab.Clipboard, PanelTab.Alerts };

    public static string Title(this PanelTab tab) => tab switch
    {
        PanelTab.Muna => "Muna", PanelTab.Tray => "Tray", PanelTab.LocalSend => "LocalSend", PanelTab.Clipboard => "Clipboard",
        PanelTab.Alerts => "Alerts", PanelTab.Command => "Command Bar", PanelTab.Agent => "Agent", _ => "Mirror",
    };

    public static string Glyph(this PanelTab tab) => tab switch
    {
        PanelTab.Tray => Muna.Glyph.Tray, PanelTab.LocalSend => Muna.Glyph.Wifi, PanelTab.Clipboard => Muna.Glyph.Clipboard,
        PanelTab.Alerts => Muna.Glyph.Bell, PanelTab.Command => Muna.Glyph.Search, PanelTab.Mirror => Muna.Glyph.Camera, _ => Muna.Glyph.Sparkle,
    };

    /// <summary>The height of the section under the tabs.</summary>
    public static double BodyHeight(this PanelTab tab) => tab switch
    {
        PanelTab.Muna or PanelTab.Tray => Preferences.Shared.RowHeight,
        PanelTab.LocalSend => 138,
        PanelTab.Clipboard or PanelTab.Alerts => Math.Max(170, Preferences.Shared.RowHeight),
        PanelTab.Command => 250,
        PanelTab.Agent => 120,
        _ => 300,
    };

    /// <summary>Sections whose list can be pulled taller (Linux: a two-finger swipe down at the top).</summary>
    public static bool Growable(this PanelTab tab) => tab is PanelTab.Clipboard or PanelTab.Alerts;

    public static bool HasHeader(this PanelTab tab) => tab is not (PanelTab.Command or PanelTab.Agent or PanelTab.Mirror);
}

/// <summary>A short message the closed capsule shows for a few seconds.</summary>
public sealed record CapsuleCard(string Title, string Details, string Glyph, bool Ok, double? Seconds = null);

/// <summary>What the pages remember while the panel is open: the text fields (kept, so typing is
/// never lost when a page is drawn again), the calendar's day, the group being named …</summary>
public sealed class PanelState
{
    public readonly Field NoteField = new("Write a note, Enter saves it");
    public readonly Field TodoField = new("Add a to-do");
    public readonly Field ClipboardSearch = new("Search the clipboard");
    public readonly Field GroupName = new("Name of the group");
    public readonly Field LocalSendText = new("Write a text to send");
    public bool WritingText;
    public readonly Field ClipNote = new("A note for this item");
    public readonly Field CommandField = new("Search apps, calculate, convert, ;snippets …", 40, 16);
    public readonly Field AgentReply = new("Answer or ask more");
    public DateTime CalendarDay = DateTime.Today;
    public bool NamingGroup;
    public string GroupNameError = "";
    public string? ConfirmDeleteGroup;
    public string? NoteForClip;
    public string? CopiedClip;
}

/// <summary>The capsule's outline, as on Linux: it hangs from the top edge, meets it with two concave
/// "ears" (fillets) and has round corners below.</summary>
public sealed class CapsuleShape : FrameworkElement
{
    public static readonly DependencyProperty RadiusProperty = DependencyProperty.Register(nameof(Radius), typeof(double), typeof(CapsuleShape),
        new FrameworkPropertyMetadata(12.0, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty EarProperty = DependencyProperty.Register(nameof(Ear), typeof(double), typeof(CapsuleShape),
        new FrameworkPropertyMetadata(7.0, FrameworkPropertyMetadataOptions.AffectsRender));
    public double Radius { get => (double)GetValue(RadiusProperty); set => SetValue(RadiusProperty, value); }
    public double Ear { get => (double)GetValue(EarProperty); set => SetValue(EarProperty, value); }
    public Brush Fill { get; set; } = Brushes.Black;
    public Pen? Stroke { get; set; }

    public static Geometry Outline(double width, double height, double radius, double ear)
    {
        var e = Math.Min(ear, Math.Min(width / 4, height / 2));
        double left = e, right = width - e;
        var r = Math.Max(0, Math.Min(radius, Math.Min(height / 2, (right - left) / 2)));
        var g = new StreamGeometry();
        using (var c = g.Open())
        {
            c.BeginFigure(new Point(0, 0), true, true);
            c.LineTo(new Point(width, 0), false, false);
            c.QuadraticBezierTo(new Point(right, 0), new Point(right, e), false, true);
            c.LineTo(new Point(right, height - r), false, false);
            c.QuadraticBezierTo(new Point(right, height), new Point(right - r, height), false, true);
            c.LineTo(new Point(left + r, height), false, false);
            c.QuadraticBezierTo(new Point(left, height), new Point(left, height - r), false, true);
            c.LineTo(new Point(left, e), false, false);
            c.QuadraticBezierTo(new Point(left, 0), new Point(0, 0), false, true);
        }
        g.Freeze();
        return g;
    }

    protected override void OnRender(DrawingContext dc)
    {
        if (ActualWidth < 1 || ActualHeight < 1) return;
        dc.DrawGeometry(Fill, Stroke, Outline(ActualWidth, ActualHeight, Radius, Ear));
    }
}

/// <summary>A piece that draws itself again on a clock while it is shown (the time, the bars,
/// a song's progress), so the page around it is not drawn again.</summary>
public sealed class Live : Border
{
    readonly DispatcherTimer _timer;

    public Live(Func<UIElement> build, TimeSpan every)
    {
        Child = build();
        _timer = new DispatcherTimer(DispatcherPriority.Render) { Interval = every };
        _timer.Tick += (_, _) => Child = build();
        Loaded += (_, _) => _timer.Start();
        Unloaded += (_, _) => _timer.Stop();
    }
}

/// <summary>The capsule of one monitor: a transparent, topmost window across the top of the screen
/// (its empty parts let clicks through), with the capsule drawn in it. Opens under the pointer,
/// closes when it leaves; the same rules as the Mac and Linux capsules.</summary>
public sealed class CapsuleWindow : Window
{
    public const double BarHeight = 30, PillWidth = 200, HoverGrow = 14, HeaderHeight = 36, BottomPadding = 12, CardHeight = 34;
    double _windowHeight = 520;

    public AppState App { get; }
    public PanelState State { get; } = new();
    public Forms.Screen Screen { get; private set; }
    public string ScreenId { get; }

    public bool IsOpen { get; private set; }

    /// <summary>The butterfly of the closed capsule: one for the life of the window, so a redraw does
    /// not cut its wing beat.</summary>
    public readonly MunaButterfly Butterfly = new();
    readonly DispatcherTimer _flapTimer = new() { Interval = TimeSpan.FromSeconds(30) };
    public bool IsHovering { get; private set; }
    public PanelTab Tab { get; private set; } = PanelTab.Muna;
    public int PageIndex { get; set; }
    public PanelLayout Layout { get; private set; } = PanelLayout.Make(1920, new[] { "media" }, _ => 4);
    /// <summary>How much taller than normal the list section is now (pulled with two fingers).</summary>
    public double Extra { get; private set; }
    public double BodyHeight => Tab == PanelTab.Command ? CommandHeight() : Tab.BodyHeight() + (Tab.Growable() ? Extra : 0);

    /// <summary>The Command Bar grows with its results (as on Linux), from 250 to 450.</summary>
    double CommandHeight()
    {
        var rows = App.Command.Results.Count;
        return rows == 0 ? PanelTab.Command.BodyHeight() : Math.Clamp(64 + rows * 47, PanelTab.Command.BodyHeight(), 450);
    }
    public bool IsEditing { get; private set; }
    public bool IsDropTarget { get; private set; }
    public CapsuleCard? Card { get; private set; }
    public bool HasActivity { get; private set; }

    readonly Grid _capsule = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top };
    readonly CapsuleShape _shape = new();
    readonly Border _content = new() { ClipToBounds = true };
    readonly CapsuleShape _dropRing = new() { Fill = Brushes.Transparent, Stroke = new Pen(C.Accent, 2), Visibility = Visibility.Collapsed, IsHitTestVisible = false };
    IntPtr _hwnd, _previousForeground;
    double _scale = 1;
    bool _pinned, _renderQueued;
    DispatcherTimer? _pending, _pinTimer, _cardTimer, _closeLater;
    double _windowWidth = 800;

    public CapsuleWindow(AppState app, Forms.Screen screen)
    {
        App = app;
        Screen = screen;
        ScreenId = screen.DeviceName;
        // now and then the butterfly beats its wings, where it is seen: the capsule closed, no card over it (Linux)
        _flapTimer.Tick += (_, _) =>
        {
            var p = Preferences.Shared;
            _flapTimer.Interval = TimeSpan.FromSeconds(Math.Max(5, p.Number("butterfly-flap-every")));
            if (p.CapsuleButterfly && p.Bool("butterfly-flap") && !IsOpen && Card is null) Butterfly.Flap();
        };
        _flapTimer.Start();
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Title = "Muna";
        FontFamily = Ui.Font;
        UseLayoutRounding = true;
        _capsule.Children.Add(_shape);
        _capsule.Children.Add(_content);
        _capsule.Children.Add(_dropRing);
        _capsule.AllowDrop = true;
        _capsule.DragEnter += OnDragEnter;
        _capsule.DragOver += (_, e) => { e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None; e.Handled = true; };
        _capsule.DragLeave += OnDragLeave;
        _capsule.Drop += OnDrop;
        _capsule.MouseWheel += OnWheel;
        _capsule.MouseDown += OnMiddleClick;
        _capsule.PreviewMouseWheel += OnPull;
        var root = new Grid();
        root.Children.Add(_capsule);
        Content = root;
        SourceInitialized += (_, _) =>
        {
            _hwnd = new WindowInteropHelper(this).Handle;
            Native.AddExStyle(_hwnd, Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE);
            // the sideways wheel (two fingers sideways on a touchpad) has no WPF event
            HwndSource.FromHwnd(_hwnd)?.AddHook((IntPtr hwnd, int message, IntPtr w, IntPtr l, ref bool handled) =>
            {
                if (message == 0x020E) { SidewaysSwipe((short)((w.ToInt64() >> 16) & 0xffff)); handled = true; }
                return IntPtr.Zero;
            });
            Place();
        };
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(Place);
        Loaded += (_, _) => Place();
        Deactivated += (_, _) =>
        {
            Native.AddExStyle(_hwnd, Native.WS_EX_NOACTIVATE);
            if (IsEditing) { IsEditing = false; ScheduleUpdate(); }
        };
        foreach (var field in new[] { State.NoteField, State.TodoField, State.ClipboardSearch, State.GroupName, State.LocalSendText, State.ClipNote, State.CommandField, State.AgentReply })
            field.FocusChanged += focused => { IsEditing = focused; ScheduleUpdate(); };
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape && IsOpen) { e.Handled = true; _pinned = false; Close_(); }
        };
        CapsuleViews.Wire(this);
        RefreshLayout();
        SetSize(ClosedSize(), false);
        Render();
    }

    // --- geometry ----------------------------------------------------------------------------

    System.Drawing.Rectangle Area => Screen.Bounds;

    /// <summary>Puts the window across the top middle of its monitor (in pixels; its size in the
    /// monitor's scale).</summary>
    public void Place()
    {
        if (_hwnd == IntPtr.Zero) return;
        var bounds = Screen.Bounds;
        var monitor = Native.MonitorAt(bounds.Left + bounds.Width / 2, bounds.Top + 1);
        _scale = Native.Scale(monitor);
        var screenWidth = bounds.Width / _scale;
        _windowWidth = Math.Min(screenWidth, Math.Max(620, screenWidth * PanelLayout.MaxShare + 60));
        // a taskbar on top: hang below it (a Muna bar there: the capsule sits in it, as on Linux)
        var top = Screen.WorkingArea.Top > bounds.Top && !MunaBars.Reserved.Contains(ScreenId) ? Screen.WorkingArea.Top : bounds.Top;
        // tall enough for a list pulled to 40% of the screen
        _windowHeight = Math.Max(520, bounds.Height / _scale * 0.4 + HeaderHeight + BottomPadding + 40);
        var widthPx = (int)Math.Round(_windowWidth * _scale);
        Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, bounds.Left + (bounds.Width - widthPx) / 2, top,
                            widthPx, (int)Math.Round(_windowHeight * _scale), Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        RefreshLayout();
    }

    public void Raise()
    {
        if (_hwnd != IntPtr.Zero) Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
    }

    public void Update(Forms.Screen screen)
    {
        Screen = screen;
        Place();
        SetSize(IsOpen ? OpenSize() : ClosedSize(), false);
        Invalidate();
    }

    public void RefreshLayout()
    {
        var preferences = Preferences.Shared;
        var screenWidth = Area.Width / Math.Max(_scale, 0.5);
        Layout = PanelLayout.Make(Math.Min(screenWidth, _windowWidth / PanelLayout.MaxShare), preferences.EnabledWidgets, preferences.Cells, look: preferences.Look);
        if (PageIndex >= Layout.Pages.Count) PageIndex = 0;
    }

    public double HeaderHeightNow => Tab.HasHeader() ? HeaderHeight : 8;

    Size ClosedSize()
    {
        // Settings → General → Collapsed width
        var width = Math.Max(120, PillWidth + Preferences.Shared.Number("collapsed-width-adjust")) + (IsHovering && !IsOpen ? HoverGrow : 0);
        var height = BarHeight;
        if (Card is not null)
        {
            width = Math.Max(width, 380);
            height += CardHeight;
        }
        return new Size(width, height);
    }

    /// <summary>The open panel's ears (the curves into the top edge) stand outside its width, as on Linux.</summary>
    public const double OpenEar = 20;

    Size OpenSize() => new(Math.Min(Layout.Width + 2 * OpenEar, _windowWidth), HeaderHeightNow + BodyHeight + BottomPadding);

    /// <summary>The capsule's rectangle on the screen, in pixels.</summary>
    public Rect ScreenRect
    {
        get
        {
            try
            {
                if (PresentationSource.FromVisual(_capsule) is null) return Rect.Empty;
                var a = _capsule.PointToScreen(new Point(0, 0));
                var b = _capsule.PointToScreen(new Point(_capsule.ActualWidth, _capsule.ActualHeight));
                return new Rect(a, b);
            }
            catch { return Rect.Empty; }
        }
    }

    public bool Contains(Point screenPixel) =>
        screenPixel.X >= Area.Left && screenPixel.X < Area.Right && screenPixel.Y >= Area.Top && screenPixel.Y < Area.Bottom;

    TimeSpan AnimationTime => TimeSpan.FromSeconds(0.38 / Preferences.Shared.AnimationSpeed);

    void SetSize(Size size, bool animate = true)
    {
        var open = IsOpen;
        var radius = open ? Preferences.Shared.CornerRadius : 12;
        var ear = open ? OpenEar : 7;
        var look = Preferences.Shared;
        var tint = look.CapsuleColor;
        _shape.Fill = C.Rgb(tint.R, tint.G, tint.B, look.BackgroundOpacity);
        // Linux's shadow: deeper under the open panel
        if (look.ShadowStrength <= 0.01) _shape.Effect = null;
        else _shape.Effect = new System.Windows.Media.Effects.DropShadowEffect
        {
            Color = Colors.Black, Direction = 270, ShadowDepth = open ? 8 : 2, BlurRadius = open ? 26 : 10,
            Opacity = (open ? 0.55 : 0.4) * look.ShadowStrength, RenderingBias = System.Windows.Media.Effects.RenderingBias.Performance,
        };
        if (!animate || !IsLoaded)
        {
            _capsule.BeginAnimation(WidthProperty, null);
            _capsule.BeginAnimation(HeightProperty, null);
            _capsule.Width = size.Width;
            _capsule.Height = size.Height;
            _shape.Radius = radius;
            _shape.Ear = ear;
            _dropRing.Radius = radius;
            _dropRing.Ear = ear;
            return;
        }
        var ease = new BackEase { Amplitude = 0.18, EasingMode = EasingMode.EaseOut };
        var duration = new Duration(AnimationTime);
        _capsule.BeginAnimation(WidthProperty, new DoubleAnimation(size.Width, duration) { EasingFunction = ease });
        _capsule.BeginAnimation(HeightProperty, new DoubleAnimation(size.Height, duration) { EasingFunction = ease });
        _shape.BeginAnimation(CapsuleShape.RadiusProperty, new DoubleAnimation(radius, duration));
        _shape.BeginAnimation(CapsuleShape.EarProperty, new DoubleAnimation(ear, duration));
        _dropRing.Radius = radius;
        _dropRing.Ear = ear;
    }

    // --- drawing ---------------------------------------------------------------------------

    /// <summary>Draws the capsule again soon (many changes at once draw once).</summary>
    public void Invalidate()
    {
        if (_renderQueued) return;
        _renderQueued = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            _renderQueued = false;
            // never replace what is being clicked
            if (IsMouseOver && Mouse.LeftButton == MouseButtonState.Pressed)
            {
                var later = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(120) };
                later.Tick += (_, _) => { later.Stop(); Invalidate(); };
                later.Start();
                return;
            }
            Render();
        });
    }

    void Render()
    {
        _dropRing.Visibility = IsDropTarget ? Visibility.Visible : Visibility.Collapsed;
        UIElement view;
        try
        {
            view = IsOpen ? CapsuleViews.Open(this) : CapsuleViews.Closed(this);
        }
        catch (Exception e)
        {
            Muna.App.Log(e);
            view = Ui.Text("Muna: " + e.Message, 11, color: C.Warning).Margin(16, 8, 16, 8);
        }
        // the page has its final size at once and is uncovered as the capsule grows (no reflow while it moves)
        if (view is FrameworkElement page)
        {
            var size = IsOpen ? OpenSize() : ClosedSize();
            page.Width = size.Width;
            page.Height = size.Height;
            page.HorizontalAlignment = HorizontalAlignment.Center;
            page.VerticalAlignment = VerticalAlignment.Top;
        }
        // a text field keeps the keyboard when the page around it is drawn again
        var focused = Keyboard.FocusedElement as TextBox;
        var caret = focused?.CaretIndex ?? 0;
        _content.Child = view;
        if (focused is not null && IsActive)
            Dispatcher.BeginInvoke(DispatcherPriority.Input, () =>
            {
                if (!focused.IsVisible) return;
                focused.Focus();
                focused.CaretIndex = Math.Min(caret, focused.Text.Length);
            });
    }

    // --- opening and closing ---------------------------------------------------------------------

    bool KeepsOpen =>
        (IsHovering && Preferences.Shared.AutoCollapse) || _pinned || IsEditing || IsDropTarget
        || App.LocalSend.Incoming?.State == IncomingState.Asking || (!Preferences.Shared.AutoCollapse && IsOpen)
        || (Tab == PanelTab.Agent && App.Agents.Waiting is not null);

    /// <summary>The pointer came onto the capsule or left it (the manager watches the pointer).</summary>
    public void Pointer(bool inside)
    {
        if (inside == IsHovering) return;
        IsHovering = inside;
        if (inside) _pinTimer?.Stop();
        else if (_pinned) _pinned = false;
        if (!IsOpen && Card is null)
        {
            SetSize(ClosedSize());
        }
        ScheduleUpdate();
    }

    /// <summary>Opens or closes after the chosen wait (a pointer passing by does nothing).</summary>
    public void ScheduleUpdate()
    {
        _pending?.Stop();
        var preferences = Preferences.Shared;
        var wantsOpen = KeepsOpen || (IsHovering && preferences.OpenOnHover && !IsOpen);
        var delay = Math.Max(0.05, wantsOpen ? preferences.OpenDelay : preferences.CloseDelay);
        _pending = new DispatcherTimer { Interval = TimeSpan.FromSeconds(delay) };
        _pending.Tick += (_, _) =>
        {
            _pending?.Stop();
            var hoverOpens = IsHovering && preferences.OpenOnHover;
            if (KeepsOpen || (hoverOpens && !IsOpen)) OpenNow();
            else if (IsOpen && !(IsHovering && !preferences.AutoCollapse)) Close_();
        };
        _pending.Start();
    }

    /// <summary>Opens the panel on a section (a click, the menu, a key): it stays open until the
    /// pointer has come and gone, or a while if it never comes.</summary>
    public void Open(PanelTab tab)
    {
        SetTab(tab);
        _pinned = true;
        _pinTimer?.Stop();
        _pinTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
        _pinTimer.Tick += (_, _) =>
        {
            _pinTimer?.Stop();
            if (IsHovering) return;
            _pinned = false;
            ScheduleUpdate();
        };
        _pinTimer.Start();
        OpenNow();
    }

    public void SetTab(PanelTab tab)
    {
        if (Tab == tab) return;
        Tab = tab;
        Extra = 0;
        if (IsOpen)
        {
            SetSize(OpenSize());
            App.PanelOpened(tab);
        }
        Invalidate();
    }

    /// <summary>The Command Bar: the capsule becomes one big field with the keyboard in it.</summary>
    public void OpenCommand()
    {
        if (IsOpen && Tab == PanelTab.Command)
        {
            _pinned = false;
            Close_();
            return;
        }
        App.Command.Reset();
        State.CommandField.Text = "";
        Open(PanelTab.Command);
        Dispatcher.BeginInvoke(DispatcherPriority.Input, () => TakeKeyboard(State.CommandField));
    }

    /// <summary>A short message in the closed capsule (when it is open, the panel shows things itself).</summary>
    public void ShowCard(CapsuleCard card)
    {
        if (IsOpen) return;
        Card = card;
        // something happened: warm wings and a beat of them, until the capsule opens (Linux's setActivity)
        if (!Butterfly.Warm) Butterfly.Flap();
        Butterfly.Warm = true;
        SetSize(ClosedSize());
        Invalidate();
        _cardTimer?.Stop();
        _cardTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(card.Seconds ?? Preferences.Shared.CardSeconds) };
        _cardTimer.Tick += (_, _) =>
        {
            _cardTimer?.Stop();
            Card = null;
            if (!IsOpen) SetSize(ClosedSize());
            Invalidate();
        };
        _cardTimer.Start();
    }

    public void ActivityChanged()
    {
        var session = App.LocalSend.Session;
        // Settings → Live Activities: each kind can be switched off
        var p = Preferences.Shared;
        var active = p.ActivitiesInCollapsed
                     && ((p.Bool("activity-media") && App.NowPlaying.Track is not null) || (p.Bool("activity-timer") && App.Timer.Active) || session.Phase == SessionPhase.Sending);
        HasActivity = active;
        if (!IsOpen) Invalidate();
    }

    public void OpenNow()
    {
        _closeLater?.Stop();
        if (IsOpen) return;
        if (Visibility != Visibility.Visible) Show();
        _cardTimer?.Stop();
        Card = null;
        IsOpen = true;
        Butterfly.Warm = false;
        SetSize(OpenSize());
        Render();
        App.PanelOpened(Tab);
    }

    public void Close_()
    {
        if (!IsOpen) return;
        if (IsActive)
        {
            IsEditing = false;
            Keyboard.ClearFocus();
            Native.AddExStyle(_hwnd, Native.WS_EX_NOACTIVATE);
            // the keyboard goes back to the app that had it
            if (_previousForeground != IntPtr.Zero && Native.IsWindowVisible(_previousForeground)) Native.SetForegroundWindow(_previousForeground);
            _previousForeground = IntPtr.Zero;
        }
        IsOpen = false;
        Extra = 0;
        SetSize(ClosedSize());
        Render();
        App.PanelClosed();
        _closeLater = new DispatcherTimer { Interval = AnimationTime };
        _closeLater.Tick += (_, _) =>
        {
            _closeLater?.Stop();
            if (!IsOpen && !Tab.HasHeader()) { Tab = PanelTab.Muna; }
        };
        _closeLater.Start();
    }

    /// <summary>A click anywhere else (the manager sees it): a capsule open by itself closes.</summary>
    public void ClickedOutside()
    {
        if (!IsOpen || IsHovering) return;
        _pinned = false;
        if (!Preferences.Shared.AutoCollapse || !KeepsOpen) Close_();
    }

    public void LayoutChanged()
    {
        RefreshLayout();
        SetSize(IsOpen ? OpenSize() : ClosedSize());
        Invalidate();
    }

    /// <summary>A text field was clicked: the capsule takes the keyboard (it never does otherwise,
    /// so the app in front keeps typing).</summary>
    public static void TakeKeyboard(Field field)
    {
        if (GetWindow(field) is not Window window) return;
        var hwnd = new WindowInteropHelper(window).Handle;
        var front = Native.GetForegroundWindow();
        if (window is CapsuleWindow capsule && front != hwnd)
        {
            Native.GetWindowThreadProcessId(front, out var process);
            if (process != Environment.ProcessId) capsule._previousForeground = front;
        }
        Native.AddExStyle(hwnd, 0, Native.WS_EX_NOACTIVATE);
        window.Activate();
        Native.SetForegroundWindow(hwnd);
        field.Box.Focus();
        Keyboard.Focus(field.Box);
    }

    // --- files dropped, the wheel ------------------------------------------------------------------

    void OnDragEnter(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        e.Effects = DragDropEffects.Copy;
        IsDropTarget = true;
        _dropRing.Visibility = Visibility.Visible;
        OpenNow();
    }

    void OnDragLeave(object sender, DragEventArgs e)
    {
        var p = e.GetPosition(_capsule);
        if (p.X > 0 && p.Y > 0 && p.X < _capsule.ActualWidth && p.Y < _capsule.ActualHeight) return;
        IsDropTarget = false;
        _dropRing.Visibility = Visibility.Collapsed;
        ScheduleUpdate();
    }

    /// <summary>Files dropped on the capsule: to LocalSend when that section is open, else to the Tray.</summary>
    void OnDrop(object sender, DragEventArgs e)
    {
        IsDropTarget = false;
        _dropRing.Visibility = Visibility.Collapsed;
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] files || files.Length == 0) return;
        if (IsOpen && Tab == PanelTab.LocalSend) App.LocalSend.Session.Offer(files);
        else
        {
            App.Tray.Add(files);
            SetTab(PanelTab.Tray);
        }
        _pinned = true;
        ScheduleUpdate();
    }

    /// <summary>On the Muna page, the wheel (or a two-finger swipe sideways) changes the page.</summary>
    double _swipeSum;
    DateTime _swipeAt;

    /// Linux's capsule gestures (Settings → Gestures): a two-finger swipe down over the closed capsule
    /// opens it, up over the open one (its first page) closes it; "Invert direction" swaps them.
    bool CapsuleSwipe(MouseWheelEventArgs e)
    {
        var p = Preferences.Shared;
        var now = DateTime.Now;
        if ((now - _swipeAt).TotalMilliseconds > 250) _swipeSum = 0;
        _swipeAt = now;
        // with natural scrolling (Windows' default for touchpads) fingers moving down scroll up
        var fingersDown = e.Delta > 0 != p.Bool("gestures-invert");
        if (!IsOpen && fingersDown && p.Bool("gestures-swipe-open"))
        {
            _swipeSum += Math.Abs(e.Delta);
            if (_swipeSum >= 120) { _swipeSum = -100000; Open(Tab.HasHeader() ? Tab : PanelTab.Muna); }
            return true;
        }
        if (IsOpen && !fingersDown && p.Bool("gestures-swipe-close") && PageIndex == 0 && !Tab.Growable() && Tab is PanelTab.Muna or PanelTab.Tray)
        {
            if (e.OriginalSource is DependencyObject d && FindScroller(d) is { ScrollableHeight: > 0 }) return false;
            _swipeSum += Math.Abs(e.Delta);
            if (_swipeSum >= 120) { _swipeSum = -100000; _pinned = false; Close_(); }
            return true;
        }
        return false;
    }

    /// A sideways two-finger swipe (WM_MOUSEHWHEEL): on the capsule, while music plays, the next or previous track.
    public void SidewaysSwipe(int delta)
    {
        if (!Preferences.Shared.Bool("gestures-media-swipe") || App.NowPlaying.Track is null || (IsOpen && Tab == PanelTab.Muna && Layout.Pages.Count > 1)) return;
        var now = DateTime.Now;
        if ((now - _swipeAt).TotalMilliseconds > 250) _swipeSum = 0;
        _swipeAt = now;
        _swipeSum += delta;
        if (Math.Abs(_swipeSum) < 120) return;
        Native.TapKey(_swipeSum > 0 ? Native.VK_MEDIA_NEXT : Native.VK_MEDIA_PREV);
        _swipeSum = 0;
        _swipeAt = now.AddMilliseconds(600);
    }

    /// Settings → Gestures → Middle click on the collapsed capsule.
    void OnMiddleClick(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Middle || IsOpen) return;
        switch (Preferences.Shared.Text("gestures-middle-click"))
        {
            case "play-pause": Native.TapKey(Native.VK_MEDIA_PLAY_PAUSE); e.Handled = true; break;
            case "activity": Open(App.NowPlaying.Track is not null ? PanelTab.Muna : App.LocalSend.Session.Phase == SessionPhase.Sending ? PanelTab.LocalSend : PanelTab.Muna); e.Handled = true; break;
        }
    }

    void OnWheel(object sender, MouseWheelEventArgs e)
    {
        if (CapsuleSwipe(e)) { e.Handled = true; return; }
        if (!IsOpen || Tab != PanelTab.Muna || Layout.Pages.Count < 2) return;
        if (e.OriginalSource is DependencyObject d && FindScroller(d) is { } scroller && scroller.ScrollableHeight > 0) return;
        PageIndex = Math.Clamp(PageIndex + (e.Delta < 0 ? 1 : -1), 0, Layout.Pages.Count - 1);
        e.Handled = true;
        Invalidate();
    }

    double _pullSum;
    DateTime _pullAt;

    /// <summary>Linux's two-finger pull: when the list cannot scroll further toward the top, swiping
    /// on makes the section taller (to show everything, at most 40% of the screen); swiping back when it
    /// cannot scroll further down makes it normal again. A pause starts a new swipe.</summary>
    void OnPull(object sender, MouseWheelEventArgs e)
    {
        if (!IsOpen || !Tab.Growable()) return;
        var scroller = e.OriginalSource is DependencyObject d ? FindScroller(d) : null;
        var towardTop = e.Delta > 0;
        if (scroller is not null && scroller.ScrollableHeight > 1 &&
            (towardTop ? scroller.VerticalOffset > 1 : scroller.VerticalOffset < scroller.ScrollableHeight - 1)) { _pullSum = 0; return; }
        var now = DateTime.Now;
        if ((now - _pullAt).TotalMilliseconds > 250) _pullSum = 0;
        _pullAt = now;
        var cap = Math.Max(0, Area.Height / Math.Max(_scale, 0.5) * 0.4 - Tab.BodyHeight());
        double target;
        if (towardTop && Extra < cap) target = Math.Min(cap, Extra + (scroller?.ScrollableHeight ?? cap) + (scroller is null ? 0 : 1));
        else if (!towardTop && Extra > 0) target = 0;
        else return;
        e.Handled = true;
        _pullSum += Math.Abs(e.Delta);
        if (_pullSum < 120) return;
        _pullSum = -100000;   // once per swipe
        Extra = Math.Round(target);
        SetSize(OpenSize());
        Invalidate();
    }

    static ScrollViewer? FindScroller(DependencyObject d)
    {
        for (var node = d; node is not null; node = VisualTreeHelper.GetParent(node))
            if (node is ScrollViewer s) return s;
        return null;
    }
}
