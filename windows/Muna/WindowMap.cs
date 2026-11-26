using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Muna.Core;
using Forms = System.Windows.Forms;

namespace Muna;

/// <summary>Arranging every window of a monitor at once (linux/src/windows/layout.js tile()): columns,
/// rows, a grid as square as possible, or the window you work in on the left (60%) with the others
/// stacked beside it; undo puts them back. Also what the window map needs: the windows of a monitor
/// and pictures of them.</summary>
public static class Tiling
{
    public static readonly (string Id, string Label)[] Modes = { ("columns", "Columns"), ("rows", "Rows"), ("grid", "Grid"), ("main", "Main + side") };
    static List<(IntPtr Hwnd, Native.RECT Frame, bool Maximized)> _before = new();

    static bool IsOwn(IntPtr hwnd)
    {
        Native.GetWindowThreadProcessId(hwnd, out var process);
        return process == Environment.ProcessId;
    }

    /// <summary>The windows on a monitor, front to back, not minimised, not Muna's.</summary>
    public static List<IntPtr> On(Forms.Screen screen) =>
        Native.AppWindows().Where(h => !IsOwn(h) && !Native.IsIconic(h) && Forms.Screen.FromHandle(h).DeviceName == screen.DeviceName).ToList();

    /// <summary>The share of the work area each window gets, for n windows (MunaCore, tested).</summary>
    public static List<Rect> Slots(string mode, int n) => TileSlots.For(mode, n).Select(c => new Rect(c.X, c.Y, c.W, c.H)).ToList();

    /// <summary>Arranges the windows of the monitor of <paramref name="anchor"/> (or the main one); how many.</summary>
    public static int Tile(string mode, IntPtr anchor, Forms.Screen screen)
    {
        var windows = On(screen);
        if (windows.Count == 0) return 0;
        // top to bottom, left to right, as they are now; "main": the one you work in first
        windows = windows.OrderBy(h => Native.VisibleFrame(h).Top).ThenBy(h => Native.VisibleFrame(h).Left).ToList();
        if (mode == "main" && windows.Contains(anchor)) { windows.Remove(anchor); windows.Insert(0, anchor); }
        _before = windows.Select(h => (h, Native.VisibleFrame(h), Native.IsZoomed(h))).ToList();
        var area = screen.WorkingArea;
        var slots = Slots(mode, windows.Count);
        for (var i = 0; i < windows.Count; i++)
        {
            var s = slots[i];
            Native.PlaceWindow(windows[i], area.Left + (int)Math.Round(s.X * area.Width), area.Top + (int)Math.Round(s.Y * area.Height),
                               (int)Math.Round(s.Width * area.Width), (int)Math.Round(s.Height * area.Height));
        }
        return windows.Count;
    }

    /// <summary>Puts the windows of the last arrangement back; false when there was none.</summary>
    public static bool Undo()
    {
        var before = _before.Where(b => Native.IsWindow(b.Hwnd)).ToList();
        _before = new();
        foreach (var (hwnd, frame, maximized) in before)
        {
            Native.PlaceWindow(hwnd, frame.Left, frame.Top, frame.Width, frame.Height);
            if (maximized) Native.ShowWindow(hwnd, 3);
        }
        return before.Count > 0;
    }

    // --- pictures of windows -------------------------------------------------------------------------

    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr dc, uint flags);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr handle);

    /// <summary>A picture of a window as it is now (also when covered), at most <paramref name="width"/> wide.</summary>
    public static BitmapSource? Picture(IntPtr hwnd, int width)
    {
        try
        {
            Native.GetWindowRect(hwnd, out var r);
            if (r.Width < 8 || r.Height < 8) return null;
            using var bitmap = new System.Drawing.Bitmap(r.Width, r.Height);
            using (var g = System.Drawing.Graphics.FromImage(bitmap))
            {
                var dc = g.GetHdc();
                try { if (!PrintWindow(hwnd, dc, 2)) return null; }   // PW_RENDERFULLCONTENT
                finally { g.ReleaseHdc(dc); }
            }
            var scale = Math.Min(1.0, (double)width / r.Width);
            using var small = new System.Drawing.Bitmap(bitmap, Math.Max(1, (int)(r.Width * scale)), Math.Max(1, (int)(r.Height * scale)));
            var handle = small.GetHbitmap();
            try
            {
                var source = Imaging.CreateBitmapSourceFromHBitmap(handle, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                source.Freeze();
                return source;
            }
            finally { DeleteObject(handle); }
        }
        catch { return null; }
    }
}

/// <summary>Linux's window map (linux/src/windows/windowMap.js): a picture of one monitor with its
/// windows (their live pictures, renewed every second and a half). Drag a window to move it (let go at
/// an edge: it takes half or a quarter of the screen, at the top all of it), click it to bring it
/// forward, ✕ closes it.</summary>
public sealed class WindowMap : Grid
{
    const double Edge = 0.1;
    readonly Forms.Screen _screen;
    readonly Canvas _canvas = new() { ClipToBounds = true };
    readonly Dictionary<IntPtr, BitmapSource?> _pictures;
    readonly Action _changed;
    readonly double _scale;

    public WindowMap(Forms.Screen screen, Dictionary<IntPtr, BitmapSource?> pictures, Action changed, double width = 310)
    {
        _screen = screen;
        _pictures = pictures;
        _changed = changed;
        var b = screen.Bounds;
        _scale = width / b.Width;
        Width = width;
        Height = b.Height * _scale;
        Children.Add(new Border { Background = C.White(0.05), CornerRadius = new CornerRadius(6), BorderBrush = C.White(0.15), BorderThickness = new Thickness(1) });
        Children.Add(_canvas);
        // back to front, so the front window is drawn last
        foreach (var hwnd in Tiling.On(screen).AsEnumerable().Reverse()) _canvas.Children.Add(Item(hwnd));
    }

    UIElement Item(IntPtr hwnd)
    {
        var b = _screen.Bounds;
        var r = Native.VisibleFrame(hwnd);
        double x = (r.Left - b.Left) * _scale, y = (r.Top - b.Top) * _scale, w = Math.Max(14, r.Width * _scale), h = Math.Max(10, r.Height * _scale);
        var grid = new Grid { Width = w, Height = h, Cursor = Cursors.SizeAll, ToolTip = Native.WindowTitle(hwnd) };
        var frame = new Border { CornerRadius = new CornerRadius(3), BorderBrush = C.White(0.4), BorderThickness = new Thickness(1), Background = C.Rgb(40, 40, 46), ClipToBounds = true };
        if (_pictures.TryGetValue(hwnd, out var picture) && picture is not null)
            frame.Child = new Image { Source = picture, Stretch = Stretch.Fill };
        else
        {
            var icon = WindowIcon(hwnd);
            frame.Child = icon is null ? Ui.Text(Native.WindowTitle(hwnd), 8, color: C.Secondary).Margin(3, 2, 3, 2) : new Image { Source = icon, Width = 16, Height = 16 };
        }
        grid.Children.Add(frame);
        var close = Ui.Box(Ui.Icon(Glyph.Close, 6, Brushes.White), C.Rgb(220, 60, 60, 0.9), 6).Size(12, 12).Align(HorizontalAlignment.Right, VerticalAlignment.Top).Margin(0, 2, 2, 0);
        close.Visibility = Visibility.Hidden;
        close.OnClick(() => { Native.SendMessage(hwnd, 0x0010, IntPtr.Zero, IntPtr.Zero); _changed(); });   // WM_CLOSE
        grid.Children.Add(close);
        grid.MouseEnter += (_, _) => { close.Visibility = Visibility.Visible; frame.BorderBrush = C.Accent; };
        grid.MouseLeave += (_, _) => { close.Visibility = Visibility.Hidden; frame.BorderBrush = C.White(0.4); };
        Canvas.SetLeft(grid, x);
        Canvas.SetTop(grid, y);
        Point? start = null;
        Point origin = default;
        grid.MouseLeftButtonDown += (_, e) =>
        {
            if (e.OriginalSource is DependencyObject d && IsInside(d, close)) return;
            start = e.GetPosition(_canvas);
            origin = new Point(Canvas.GetLeft(grid), Canvas.GetTop(grid));
            grid.CaptureMouse();
            e.Handled = true;
        };
        grid.MouseMove += (_, e) =>
        {
            if (start is not { } s || !grid.IsMouseCaptured) return;
            var p = e.GetPosition(_canvas);
            Canvas.SetLeft(grid, origin.X + p.X - s.X);
            Canvas.SetTop(grid, origin.Y + p.Y - s.Y);
        };
        grid.MouseLeftButtonUp += (_, e) =>
        {
            if (start is not { } s) return;
            start = null;
            grid.ReleaseMouseCapture();
            e.Handled = true;
            var p = e.GetPosition(_canvas);
            if ((p - s).Length < 4)
            {
                if (Native.IsIconic(hwnd)) Native.ShowWindow(hwnd, 9);
                Native.SetForegroundWindow(hwnd);
                _changed();
                return;
            }
            LetGo(hwnd, p, new Point(Canvas.GetLeft(grid), Canvas.GetTop(grid)));
            _changed();
        };
        return grid;
    }

    static bool IsInside(DependencyObject d, DependencyObject target)
    {
        for (var node = d; node is not null; node = VisualTreeHelper.GetParent(node))
            if (node == target) return true;
        return false;
    }

    /// <summary>Let go: at an edge the window takes that zone, else it moves where it was dropped.</summary>
    void LetGo(IntPtr hwnd, Point pointer, Point topLeft)
    {
        var a = _screen.WorkingArea;
        var b = _screen.Bounds;
        double u = pointer.X / ActualWidth, v = pointer.Y / ActualHeight;
        bool left = u < Edge, right = u > 1 - Edge, top = v < Edge, bottom = v > 1 - Edge;
        Rect? zone = (top, left, right, bottom) switch
        {
            (true, true, _, _) => new Rect(0, 0, 0.5, 0.5),
            (true, _, true, _) => new Rect(0.5, 0, 0.5, 0.5),
            (_, true, _, true) => new Rect(0, 0.5, 0.5, 0.5),
            (_, _, true, true) => new Rect(0.5, 0.5, 0.5, 0.5),
            (_, true, _, _) => new Rect(0, 0, 0.5, 1),
            (_, _, true, _) => new Rect(0.5, 0, 0.5, 1),
            (true, _, _, _) => new Rect(0, 0, 1, 1),
            _ => null,
        };
        if (zone is { } z)
        {
            if (z.Width >= 1 && z.Height >= 1) { Native.ShowWindow(hwnd, 3); return; }
            Native.PlaceWindow(hwnd, a.Left + (int)(z.X * a.Width), a.Top + (int)(z.Y * a.Height), (int)(z.Width * a.Width), (int)(z.Height * a.Height));
            return;
        }
        var frame = Native.VisibleFrame(hwnd);
        var x = b.Left + (int)(topLeft.X / _scale);
        var y = Math.Max(a.Top, b.Top + (int)(topLeft.Y / _scale));
        Native.PlaceWindow(hwnd, x, y, frame.Width, frame.Height);
    }

    static ImageSource? WindowIcon(IntPtr hwnd)
    {
        try
        {
            Native.GetWindowThreadProcessId(hwnd, out var pid);
            var path = System.Diagnostics.Process.GetProcessById((int)pid).MainModule?.FileName;
            return path is null ? null : Native.ShellIcon(path, false);
        }
        catch { return null; }
    }
}
