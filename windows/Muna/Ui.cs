using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

namespace Muna;

/// <summary>Muna's colours (shared/design/colors.json "capsule", linux/stylesheet.css).</summary>
public static class C
{
    public static SolidColorBrush Rgb(byte r, byte g, byte b, double a = 1) => Freeze(new SolidColorBrush(Color.FromArgb((byte)Math.Round(a * 255), r, g, b)));
    public static SolidColorBrush White(double a) => Rgb(255, 255, 255, a);
    static SolidColorBrush Freeze(SolidColorBrush brush) { brush.Freeze(); return brush; }

    public static readonly SolidColorBrush Tile = White(0.07);
    public static readonly SolidColorBrush TileHover = Rgb(77, 141, 255, 0.28);
    public static readonly SolidColorBrush Text = White(0.92);
    public static readonly SolidColorBrush Secondary = White(0.45);
    public static readonly SolidColorBrush Caption = White(0.55);
    public static readonly SolidColorBrush Divider = White(0.08);
    public static readonly SolidColorBrush Accent = Rgb(77, 141, 255);
    public static readonly SolidColorBrush Muna = Rgb(179, 154, 255);
    public static readonly SolidColorBrush Ok = Rgb(87, 227, 137);
    public static readonly SolidColorBrush Warning = Rgb(255, 163, 72);
    public static readonly SolidColorBrush Amber = Rgb(242, 169, 59);
    public static readonly SolidColorBrush Red = Rgb(255, 115, 115);
    public static readonly SolidColorBrush Clear = Rgb(0, 0, 0, 0);
    public static readonly SolidColorBrush Black = Rgb(0, 0, 0);

    // Muna's windows (settings, agents, scratchpad): dark or light, as Settings → General → Appearance
    // chooses (Linux's color-scheme: "default" follows Windows' apps mode)
    public static bool Light => Preferences.Shared.Text("color-scheme") switch
    {
        "light" => true,
        "dark" => false,
        _ => (Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")?.GetValue("AppsUseLightTheme") as int? ?? 0) == 1,
    };

    static readonly SolidColorBrush DarkBackground = Rgb(0x10, 0x10, 0x12), LightBackground = Rgb(0xf5, 0xf5, 0xf7);
    static readonly SolidColorBrush DarkSurface = Rgb(0x15, 0x15, 0x17), LightSurface = Rgb(0xeb, 0xeb, 0xef);
    static readonly SolidColorBrush DarkCard = Rgb(0x1d, 0x1d, 0x20), LightCard = Rgb(0xff, 0xff, 0xff);
    static readonly SolidColorBrush DarkControl = Rgb(0x29, 0x29, 0x2c), LightControl = Rgb(0xe3, 0xe3, 0xe8);
    static readonly SolidColorBrush DarkBorder = White(0.09), LightBorder = Rgb(0, 0, 0, 0.1);
    static readonly SolidColorBrush DarkText = Rgb(0xf5, 0xf5, 0xf7), LightText = Rgb(0x1d, 0x1d, 0x1f);
    static readonly SolidColorBrush DarkSecondary = Rgb(0x98, 0x98, 0x9d), LightSecondary = Rgb(0x6e, 0x6e, 0x73);

    public static SolidColorBrush WinBackground => Light ? LightBackground : DarkBackground;
    public static SolidColorBrush WinSurface => Light ? LightSurface : DarkSurface;
    public static SolidColorBrush WinCard => Light ? LightCard : DarkCard;
    public static SolidColorBrush WinControl => Light ? LightControl : DarkControl;
    public static SolidColorBrush WinBorder => Light ? LightBorder : DarkBorder;
    public static SolidColorBrush WinText => Light ? LightText : DarkText;
    public static SolidColorBrush WinSecondary => Light ? LightSecondary : DarkSecondary;
    public static readonly SolidColorBrush WinAccent = Rgb(0x12, 0x83, 0xff);
}

/// <summary>Segoe Fluent Icons (Windows 11) / Segoe MDL2 Assets (Windows 10) glyphs.</summary>
public static class Glyph
{
    public const string Play = "", Pause = "", Previous = "", Next = "", Music = "";
    public const string Calendar = "", Camera = "", Clock = "", Stopwatch = "", Checklist = "";
    public const string Note = "", Apps = "", Emoji = "", Close = "", Copy = "";
    public const string Lock = "", Unlock = "", Pin = "", Unpin = "", Settings = "";
    public const string Wifi = "", Tray = "", Clipboard = "", Bell = "", Search = "";
    public const string Send = "", Add = "", Remove = "", Refresh = "", Check = "";
    public const string CheckCircle = "", Circle = "", Folder = "", Document = "", Up = "";
    public const string Down = "", Volume = "", Mute = "", Microphone = "", Brightness = "";
    public const string Power = "", Phone = "", Robot = "", Delete = "", Back = "";
    public const string Forward = "", Left = "", Right = "", Expand = "", Shrink = "";
    public const string Battery = "", Network = "", Globe = "", Monitor = "", Keyboard = "";
    public const string Warning = "", Info = "", Shield = "", Fingerprint = "", Eyedropper = "";
    public const string Screenshot = "", Moon = "", Eye = "", Flag = "", Bulb = "";
    public const string Coffee = "", Download = "", Window = "", Desktop = "", Edit = "";
    public const string More = "", Cpu = "", Memory = "", Disk = "", Link = "";
    public const string Sparkle = "", Mail = "", Video = "", VideoOff = "", Ruler = "";
    public const string Sliders = "\uE9E9", Bluetooth = "\uE702", Airplane = "\uE709", Thermometer = "\uE9CA", Grid = "\uF0E2", Gesture = "\uED5F";
    public const string Broom = "", Calculator = "", Code = "", Terminal = "", Sun = "";
}

/// <summary>A row or column whose children are spaced; children marked with <see cref="SetGrow"/>
/// share the space left (SwiftUI's Spacer / maxWidth: .infinity).</summary>
public class Flex : Panel
{
    public static readonly DependencyProperty GrowProperty = DependencyProperty.RegisterAttached("Grow", typeof(double), typeof(Flex),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsParentMeasure));
    public static void SetGrow(UIElement element, double value) => element.SetValue(GrowProperty, value);
    public static double GetGrow(UIElement element) => (double)element.GetValue(GrowProperty);

    public bool Vertical { get; set; }
    public double Spacing { get; set; }
    /// <summary>Across the main axis: children are centred (true) or stretched to the panel (false).</summary>
    public bool Center { get; set; } = true;

    double Main(Size s) => Vertical ? s.Height : s.Width;
    double Cross(Size s) => Vertical ? s.Width : s.Height;
    Size Make(double main, double cross) => Vertical ? new Size(cross, main) : new Size(main, cross);

    protected override Size MeasureOverride(Size available)
    {
        var children = InternalChildren.Cast<UIElement>().Where(c => c.Visibility != Visibility.Collapsed).ToList();
        var availableMain = Main(available);
        var availableCross = Cross(available);
        double used = Spacing * Math.Max(0, children.Count - 1), cross = 0, grow = 0;
        foreach (var child in children)
        {
            var g = GetGrow(child);
            if (g > 0) { grow += g; continue; }
            child.Measure(Make(double.PositiveInfinity, availableCross));
            used += Main(child.DesiredSize);
            cross = Math.Max(cross, Cross(child.DesiredSize));
        }
        var left = double.IsInfinity(availableMain) ? double.PositiveInfinity : Math.Max(0, availableMain - used);
        double growUsed = 0;
        foreach (var child in children.Where(c => GetGrow(c) > 0))
        {
            var share = double.IsInfinity(left) ? double.PositiveInfinity : left * GetGrow(child) / grow;
            child.Measure(Make(share, availableCross));
            growUsed += Main(child.DesiredSize);
            cross = Math.Max(cross, Cross(child.DesiredSize));
        }
        var main = grow > 0 && !double.IsInfinity(availableMain) ? Math.Max(availableMain, used) : used + growUsed;
        return Make(main, cross);
    }

    protected override Size ArrangeOverride(Size final)
    {
        var children = InternalChildren.Cast<UIElement>().Where(c => c.Visibility != Visibility.Collapsed).ToList();
        double used = Spacing * Math.Max(0, children.Count - 1), grow = 0;
        foreach (var child in children)
        {
            if (GetGrow(child) > 0) grow += GetGrow(child);
            else used += Main(child.DesiredSize);
        }
        var left = Math.Max(0, Main(final) - used);
        double at = 0;
        foreach (var child in children)
        {
            var g = GetGrow(child);
            var size = g > 0 ? left * g / grow : Main(child.DesiredSize);
            var crossSize = Center ? Math.Min(Cross(child.DesiredSize), Cross(final)) : Cross(final);
            var offset = Center ? (Cross(final) - crossSize) / 2 : 0;
            child.Arrange(Vertical ? new Rect(offset, at, crossSize, size) : new Rect(at, offset, size, crossSize));
            at += size + Spacing;
        }
        return final;
    }
}

/// <summary>Builds the pieces of the capsule's pages (code, not XAML: the pages are drawn again when
/// their model changes, like SwiftUI views).</summary>
public static class Ui
{
    public static readonly FontFamily Font = new("Segoe UI Variable Text, Segoe UI");
    public static readonly FontFamily Icons = new("Segoe Fluent Icons, Segoe MDL2 Assets");
    public static readonly FontFamily Mono = new("Cascadia Mono, Consolas");

    public static TextBlock Text(string text, double size = 12, FontWeight? weight = null, Brush? color = null, bool wrap = false, int lines = 1)
    {
        var block = new TextBlock
        {
            Text = text, FontFamily = Font, FontSize = size, FontWeight = weight ?? FontWeights.Normal,
            Foreground = color ?? C.Text, TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = wrap || lines > 1 ? TextWrapping.Wrap : TextWrapping.NoWrap,
        };
        if (lines > 1) block.MaxHeight = size * 1.36 * lines;
        TextOptions.SetTextFormattingMode(block, TextFormattingMode.Display);
        return block;
    }

    public static TextBlock Bold(string text, double size = 12, Brush? color = null) => Text(text, size, FontWeights.Bold, color);
    public static TextBlock Semi(string text, double size = 12, Brush? color = null) => Text(text, size, FontWeights.SemiBold, color);
    public static TextBlock Digits(string text, double size = 12, FontWeight? weight = null, Brush? color = null)
    {
        var block = Text(text, size, weight, color);
        Typography.SetNumeralAlignment(block, FontNumeralAlignment.Tabular);
        return block;
    }

    public static TextBlock Icon(string glyph, double size = 12, Brush? color = null) => new()
    {
        Text = glyph, FontFamily = Icons, FontSize = size, Foreground = color ?? C.Text,
        VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
    };

    public static Flex Row(double spacing, params UIElement?[] children) => Fill(new Flex { Spacing = spacing }, children);
    public static Flex Column(double spacing, params UIElement?[] children) => Fill(new Flex { Vertical = true, Spacing = spacing, Center = false }, children);

    static Flex Fill(Flex flex, UIElement?[] children)
    {
        foreach (var child in children)
            if (child is not null) flex.Children.Add(Detach(child));
        return flex;
    }

    /// <summary>A view kept between drawings (a text field) leaves its old parent first.</summary>
    public static T Detach<T>(T element) where T : UIElement
    {
        switch (VisualTreeHelper.GetParent(element) ?? (element as FrameworkElement)?.Parent)
        {
            case Panel panel: panel.Children.Remove(element); break;
            case Decorator decorator when decorator.Child == element: decorator.Child = null; break;
            case ContentControl control when control.Content == element: control.Content = null; break;
            case ContentPresenter presenter when presenter.Content == element: presenter.Content = null; break;
        }
        return element;
    }

    /// <summary>Takes the space left in a <see cref="Flex"/>.</summary>
    public static T Grow<T>(this T element, double weight = 1) where T : UIElement
    {
        Flex.SetGrow(element, weight);
        return element;
    }

    public static UIElement Spacer() => new Border { Background = null }.Grow();

    public static T Margin<T>(this T element, double left, double top, double right, double bottom) where T : FrameworkElement
    {
        element.Margin = new Thickness(left, top, right, bottom);
        return element;
    }

    public static T Size<T>(this T element, double width = double.NaN, double height = double.NaN) where T : FrameworkElement
    {
        if (!double.IsNaN(width)) element.Width = width;
        if (!double.IsNaN(height)) element.Height = height;
        return element;
    }

    public static T Align<T>(this T element, HorizontalAlignment h = HorizontalAlignment.Stretch, VerticalAlignment v = VerticalAlignment.Stretch) where T : FrameworkElement
    {
        element.HorizontalAlignment = h;
        element.VerticalAlignment = v;
        return element;
    }

    public static T Tip<T>(this T element, string tip) where T : FrameworkElement
    {
        element.ToolTip = tip;
        return element;
    }

    public static T Faded<T>(this T element, double opacity) where T : UIElement
    {
        element.Opacity = opacity;
        return element;
    }

    public static Border Box(UIElement? child, Brush? background = null, double radius = 0, double padH = 0, double padV = 0) => new()
    {
        Child = child is null ? null : Detach(child), Background = background, CornerRadius = new CornerRadius(radius),
        Padding = new Thickness(padH, padV, padH, padV),
    };

    /// <summary>Makes anything a button: a click (press and release on it) runs the action; it shows
    /// the hand and, when given, a background under the pointer.</summary>
    public static T OnClick<T>(this T element, Action action, Brush? hover = null) where T : FrameworkElement
    {
        element.Cursor = Cursors.Hand;
        if (element is Border b && b.Background is null) b.Background = C.Clear;
        if (element is Panel p && p.Background is null) p.Background = C.Clear;
        Brush? normal = null;
        if (hover is not null && element is Border hb)
        {
            element.MouseEnter += (_, _) => { normal = hb.Background; hb.Background = hover; };
            element.MouseLeave += (_, _) => { if (normal is not null) hb.Background = normal; };
        }
        var pressed = false;
        element.MouseLeftButtonDown += (_, e) => { pressed = true; e.Handled = true; };
        element.MouseLeave += (_, _) => pressed = false;
        element.MouseLeftButtonUp += (_, e) =>
        {
            if (!pressed) return;
            pressed = false;
            e.Handled = true;
            action();
        };
        return element;
    }

    public static T OnRightClick<T>(this T element, Action action) where T : FrameworkElement
    {
        if (element is Border b && b.Background is null) b.Background = C.Clear;
        element.MouseRightButtonUp += (_, e) => { e.Handled = true; action(); };
        return element;
    }

    /// <summary>"CAPTION" on the left, small buttons on the right.</summary>
    public static Flex Caption(string text, params UIElement?[] trailing)
    {
        var caption = Text(text.ToUpperInvariant(), 10, FontWeights.Black, C.Caption);
        caption.Margin = new Thickness(0, 0, 8, 0);
        var row = Row(6, caption, Spacer());
        foreach (var t in trailing) if (t is not null) row.Children.Add(t);
        return row;
    }

    /// <summary>A small text button of a caption.</summary>
    public static Border Pill(string label, Action action, bool accent = false, bool active = false, bool disabled = false)
    {
        var pill = Box(Semi(label, 10, accent || active ? Brushes.White : C.White(0.82)),
                       accent ? C.Accent : active ? C.Rgb(77, 141, 255, 0.6) : C.White(0.09), 10, 10, 3);
        if (disabled) pill.Opacity = 0.45;
        else pill.OnClick(action);
        return pill;
    }

    /// <summary>A little round button with an icon (remove, pin ...).</summary>
    public static Border IconButton(string glyph, Action action, Brush? tint = null, string? tip = null)
    {
        var button = Box(Icon(glyph, 8, tint ?? C.Secondary), C.White(0.08), 9).Size(18, 18);
        button.OnClick(action, C.White(0.16));
        if (tip is not null) button.ToolTip = tip;
        return button;
    }

    /// <summary>A plain icon button (media controls, navigation).</summary>
    public static Border ControlButton(string glyph, Action action, double size = 14, double width = 30, double height = 30, Brush? color = null)
    {
        var button = Box(Icon(glyph, size, color ?? C.White(0.85)), C.Clear, Math.Min(width, height) / 2).Size(width, height);
        return button.OnClick(action, C.White(0.08));
    }

    /// <summary>A full-width round button (Start in white, as on Linux).</summary>
    public static Border WideButton(string glyph, string label, Action action, bool primary = false)
    {
        var color = primary ? Brushes.Black : Brushes.White;
        var content = Row(6, Icon(glyph, 9, color), Bold(label, 12, color));
        content.HorizontalAlignment = HorizontalAlignment.Center;
        var button = Box(content, primary ? Brushes.White : C.White(0.1), 13).Size(height: 26);
        return button.OnClick(action);
    }

    public static Rectangle Line(bool vertical = false, Brush? color = null) => vertical
        ? new Rectangle { Width = 1, Fill = color ?? C.Divider }
        : new Rectangle { Height = 1, Fill = color ?? C.Divider };

    public static ScrollViewer Scroll(UIElement content, bool horizontal = false) => new WheelScroller
    {
        Content = Detach(content), Focusable = false,
        VerticalScrollBarVisibility = horizontal ? ScrollBarVisibility.Disabled : ScrollBarVisibility.Hidden,
        HorizontalScrollBarVisibility = horizontal ? ScrollBarVisibility.Hidden : ScrollBarVisibility.Disabled,
        PanningMode = horizontal ? PanningMode.HorizontalOnly : PanningMode.VerticalOnly,
    };

    /// <summary>A list that scrolls as far as the wheel or the touchpad turned: WPF moves 48 px for
    /// every wheel message, so a precision touchpad's many small messages raced the list away. A
    /// list at its end lets the wheel go on to the list around it.</summary>
    public sealed class WheelScroller : ScrollViewer
    {
        protected override void OnMouseWheel(System.Windows.Input.MouseWheelEventArgs e)
        {
            if (e.Handled) return;
            var step = e.Delta * 0.4;   // 120 (one notch) = 48 px, as before
            if (HorizontalScrollBarVisibility != ScrollBarVisibility.Disabled && VerticalScrollBarVisibility == ScrollBarVisibility.Disabled)
            {
                if (ScrollableWidth <= 0 || (step > 0 && HorizontalOffset <= 0) || (step < 0 && HorizontalOffset >= ScrollableWidth)) return;
                ScrollToHorizontalOffset(HorizontalOffset - step);
            }
            else
            {
                if (ScrollableHeight <= 0 || (step > 0 && VerticalOffset <= 0) || (step < 0 && VerticalOffset >= ScrollableHeight)) return;
                ScrollToVerticalOffset(VerticalOffset - step);
            }
            e.Handled = true;
        }
    }

    /// <summary>Bars that move while the music plays (redrawn by the caller's clock).</summary>
    /// Settings → Live Activities → Effect type and Colored effects: Linux's spectrum (bars) or waves,
    /// white or in the album's colour.
    public static UIElement MediaEffect(bool playing, ImageSource? artwork, Brush fallback, double height = 14)
    {
        var p = Preferences.Shared;
        var color = p.Bool("colored-effects") && AlbumColor(artwork) is { } album ? album : fallback;
        return p.Text("media-effect") == "waves" ? Waves(playing, color, height) : Bars(playing, color, height);
    }

    static readonly System.Runtime.CompilerServices.ConditionalWeakTable<ImageSource, Brush> AlbumColors = new();

    /// The average colour of a cover, lightened so it shows on black.
    static Brush? AlbumColor(ImageSource? artwork)
    {
        if (artwork is not BitmapSource bitmap) return null;
        if (AlbumColors.TryGetValue(artwork, out var known)) return known;
        try
        {
            var small = new TransformedBitmap(new FormatConvertedBitmap(bitmap, PixelFormats.Bgra32, null, 0), new ScaleTransform(8.0 / bitmap.PixelWidth, 8.0 / bitmap.PixelHeight));
            var pixels = new byte[small.PixelWidth * small.PixelHeight * 4];
            small.CopyPixels(pixels, small.PixelWidth * 4, 0);
            double r = 0, g = 0, b = 0;
            var n = pixels.Length / 4;
            for (var i = 0; i < pixels.Length; i += 4) { b += pixels[i]; g += pixels[i + 1]; r += pixels[i + 2]; }
            (r, g, b) = (r / n, g / n, b / n);
            var lift = 200 / Math.Max(1, Math.Max(r, Math.Max(g, b)));
            var brush = C.Rgb((byte)Math.Min(255, r * lift), (byte)Math.Min(255, g * lift), (byte)Math.Min(255, b * lift));
            AlbumColors.Add(artwork, brush);
            return brush;
        }
        catch { return null; }
    }

    public static Flex Waves(bool playing, Brush color, double height = 14)
    {
        var t = DateTime.Now.TimeOfDay.TotalSeconds;
        var row = Row(1);
        for (var i = 0; i < 7; i++)
        {
            var level = playing ? 0.3 + 0.7 * (0.5 + 0.5 * Math.Sin(t * 4 - i * 0.9)) : 0.25;
            row.Children.Add(new Ellipse { Width = 3, Height = 3, Fill = color, Margin = new Thickness(0, (1 - level) * height, 0, 0) });
        }
        return row;
    }

    public static Flex Bars(bool playing, Brush? color = null, double height = 14)
    {
        var t = DateTime.Now.TimeOfDay.TotalSeconds;
        var row = Row(2);
        for (var i = 0; i < 3; i++)
        {
            var level = playing ? 0.35 + 0.65 * Math.Abs(Math.Sin(t * 5 + i * 1.7)) : 0.3;
            row.Children.Add(new Rectangle { Width = 3, Height = height * level, RadiusX = 1.5, RadiusY = 1.5, Fill = color ?? C.Accent });
        }
        return row;
    }

    static BitmapImage? _butterfly;
    public static BitmapImage ButterflySource => _butterfly ??= LoadResource("Assets/butterfly.png");

    public static BitmapImage LoadResource(string path)
    {
        var image = new BitmapImage(new Uri($"pack://application:,,,/{path}"));
        image.Freeze();
        return image;
    }

    public static Image Butterfly(double height = 16) => new()
    {
        Source = ButterflySource, Height = height, Width = height * 72 / 64, Stretch = Stretch.Uniform,
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// The butterfly of the closed capsule: now and then it beats its wings (Settings → Appearance).
    public static Image FlappingButterfly(double height)
    {
        var image = Butterfly(height);
        var scale = new ScaleTransform(1, 1);
        image.RenderTransform = scale;
        image.RenderTransformOrigin = new Point(0.5, 0.5);
        var timer = new System.Windows.Threading.DispatcherTimer();
        timer.Tick += (_, _) =>
        {
            var p = Preferences.Shared;
            timer.Interval = TimeSpan.FromSeconds(Math.Max(5, p.Number("butterfly-flap-every")));
            if (!p.Bool("butterfly-flap")) return;
            var flap = new System.Windows.Media.Animation.DoubleAnimation(1, 0.3, TimeSpan.FromMilliseconds(140)) { AutoReverse = true, RepeatBehavior = new System.Windows.Media.Animation.RepeatBehavior(2) };
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, flap);
        };
        image.Loaded += (_, _) => { timer.Interval = TimeSpan.FromSeconds(3); timer.Start(); };
        image.Unloaded += (_, _) => timer.Stop();
        return image;
    }

    /// <summary>A picture with round corners (a cover), or a note on a tile.</summary>
    public static Border Artwork(ImageSource? source, double size, double? radius = null)
    {
        var r = radius ?? size * 0.22;
        UIElement inner = source is null
            ? Icon(Glyph.Music, size * 0.4, C.Secondary)
            : new Image { Source = source, Stretch = Stretch.UniformToFill };
        var box = Box(inner, C.Tile, r).Size(size, size);
        box.Clip = new RectangleGeometry(new Rect(0, 0, size, size), r, r);
        return box;
    }

    static readonly Dictionary<string, ImageSource?> IconCache = new();

    /// <summary>The shell's icon of a file (by extension, folders and programs by path).</summary>
    public static ImageSource? FileIcon(string path)
    {
        // an app of the Start menu's list (Store apps): its own icon
        var shellItem = path.StartsWith("shell:", StringComparison.OrdinalIgnoreCase);
        var ext = shellItem ? "" : System.IO.Path.GetExtension(path).ToLowerInvariant();
        var key = shellItem ? path : Directory.Exists(path) ? "<folder>" : ext is ".exe" or ".lnk" or ".ico" or "" ? path : ext;
        if (IconCache.TryGetValue(key, out var cached)) return cached;
        ImageSource? result = null;
        try
        {
            result = shellItem ? Native.ShellItemIcon(path) : Native.ShellIcon(path);
        }
        catch { /* no icon */ }
        IconCache[key] = result;
        return result;
    }

    public static FrameworkElement FileIconView(string path, double size = 32)
    {
        var source = FileIcon(path);
        return source is null
            ? Icon(Directory.Exists(path) ? Glyph.Folder : Glyph.Document, size * 0.7, C.Secondary)
            : new Image { Source = source, Width = size, Height = size, Stretch = Stretch.Uniform };
    }

    public static string SizeText(long bytes)
    {
        string[] units = { "bytes", "KB", "MB", "GB", "TB" };
        double value = bytes;
        var unit = 0;
        while (value >= 1000 && unit < units.Length - 1) { value /= 1000; unit++; }
        return unit == 0 ? $"{bytes} bytes" : $"{value:0.#} {units[unit]}";
    }

    public static string Ago(DateTime at)
    {
        var span = DateTime.Now - at;
        if (span.TotalMinutes < 1) return "now";
        if (span.TotalHours < 1) return $"{(int)span.TotalMinutes} min";
        if (span.TotalDays < 1) return $"{(int)span.TotalHours} h";
        return at.ToString("d MMM");
    }
}

/// <summary>A one-line text field of the capsule (dark, round, with a placeholder). The capsule keeps
/// the instance between drawings so typing is never lost.</summary>
public sealed class Field : Border
{
    public TextBox Box { get; }
    readonly TextBlock _placeholder;
    public event Action? Submitted;
    public event Action<bool>? FocusChanged;

    public Field(string placeholder, double height = 24, double size = 12)
    {
        Box = new TextBox
        {
            Background = C.Clear, BorderThickness = new Thickness(0), Foreground = C.Text, CaretBrush = Brushes.White,
            FontFamily = Ui.Font, FontSize = size, VerticalContentAlignment = VerticalAlignment.Center, Padding = new Thickness(0),
            SelectionBrush = C.Accent,
        };
        _placeholder = Ui.Text(placeholder, size, color: C.White(0.35));
        _placeholder.IsHitTestVisible = false;
        _placeholder.VerticalAlignment = VerticalAlignment.Center;
        _placeholder.Margin = new Thickness(2, 0, 0, 0);
        var grid = new Grid();
        grid.Children.Add(_placeholder);
        grid.Children.Add(Box);
        Child = grid;
        Height = height;
        CornerRadius = new CornerRadius(height / 2);
        Padding = new Thickness(10, 0, 10, 0);
        Background = C.White(0.08);
        Box.TextChanged += (_, _) => _placeholder.Visibility = Box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Box.GotKeyboardFocus += (_, _) => { Background = C.White(0.14); FocusChanged?.Invoke(true); };
        Box.LostKeyboardFocus += (_, _) => { Background = C.White(0.08); FocusChanged?.Invoke(false); };
        Box.PreviewMouseLeftButtonDown += (_, _) => CapsuleWindow.TakeKeyboard(this);
        Box.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter) { e.Handled = true; Submitted?.Invoke(); }
            if (e.Key == Key.Escape) { e.Handled = true; Keyboard.ClearFocus(); FocusChanged?.Invoke(false); }
        };
    }

    public string Text
    {
        get => Box.Text;
        set => Box.Text = value;
    }

    public string Placeholder
    {
        set => _placeholder.Text = value;
    }
}
