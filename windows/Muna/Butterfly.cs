using System;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

namespace Muna;

/// <summary>The little butterfly of the capsule, looking at you, drawn as Linux draws it
/// (linux/src/ui/butterfly.js): a round face, big eyes, pink cheeks, a smile, round wings and antennae.
/// Now and then it beats its wings (<see cref="Flap"/>): they fold towards the body and open again,
/// twice; a moment later it blinks. Its wings turn warm while something happened.
/// Coordinates: x -38..38, y -32..32.</summary>
public sealed class MunaButterfly : FrameworkElement
{
    // cx, cy, rx, ry, rotation (degrees) of the left wings
    static readonly double[] Upper = { -20, -6, 16, 12, -25 };
    static readonly double[] Lower = { -15, 13, 10, 8, 25 };
    static readonly Color Face = Color.FromRgb(0xe9, 0xe6, 0xff);
    static readonly Color Ink = Color.FromRgb(10, 10, 16);
    static readonly Color[] Cool = { Color.FromRgb(0x6f, 0xe7, 0xff), Color.FromRgb(0xc0, 0x8b, 0xff) };
    static readonly Color[] Hot = { Color.FromRgb(0xff, 0xd3, 0x6e), Color.FromRgb(0xff, 0x8a, 0x3d), Color.FromRgb(0xff, 0x3d, 0x77) };
    const double FlapMs = 900, BlinkAfterMs = 900, BlinkMs = 150;

    double _open = 1;      // 1: wings spread, 0: folded against the body
    bool _blink, _warm;
    DispatcherTimer? _flap;
    DateTime _flapStart;

    public MunaButterfly(double height = 26)
    {
        Height = height;
        Width = height * 76 / 64;
        SnapsToDevicePixels = true;
        IsHitTestVisible = false;
    }

    /// <summary>Something happened: warm wings (amber to pink) until the capsule opens.</summary>
    public bool Warm
    {
        get => _warm;
        set { if (_warm == value) return; _warm = value; InvalidateVisual(); }
    }

    /// <summary>Two beats of the wings, then a blink; nothing when animations are off.</summary>
    public void Flap()
    {
        var speed = Preferences.Shared.AnimationSpeed;
        if (_flap is not null || speed <= 0 || !IsVisible) return;
        var duration = FlapMs / speed;
        _flapStart = DateTime.Now;
        _flap = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(16) };
        _flap.Tick += (_, _) =>
        {
            var t = (DateTime.Now - _flapStart).TotalMilliseconds / duration;
            if (t >= 1)
            {
                _flap!.Stop();
                _flap = null;
                _open = 1;
                InvalidateVisual();
                Later(BlinkAfterMs, Blink);
                return;
            }
            _open = 1 - 0.85 * Math.Abs(Math.Sin(2 * Math.PI * t));
            InvalidateVisual();
        };
        _flap.Start();
    }

    /// <summary>It closes its eyes for a moment.</summary>
    public void Blink()
    {
        if (_blink) return;
        _blink = true;
        InvalidateVisual();
        Later(BlinkMs, () => { _blink = false; InvalidateVisual(); });
    }

    void Later(double ms, Action action)
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(ms) };
        timer.Tick += (_, _) => { timer.Stop(); action(); };
        timer.Start();
    }

    Brush Wing(int sign)
    {
        var colors = _warm ? Hot : Cool;
        var brush = new LinearGradientBrush { MappingMode = BrushMappingMode.Absolute, StartPoint = new Point(sign * -36, -18), EndPoint = new Point(sign * -4, 22) };
        for (var i = 0; i < colors.Length; i++) brush.GradientStops.Add(new GradientStop(colors[i], i / (double)(colors.Length - 1)));
        brush.Freeze();
        return brush;
    }

    static Geometry Oval(double cx, double cy, double rx, double ry, double degrees) =>
        new EllipseGeometry(new Point(cx, cy), rx, ry) { Transform = new RotateTransform(degrees, cx, cy) };

    static void Dot(DrawingContext dc, Brush brush, double x, double y, double r) => dc.DrawEllipse(brush, null, new Point(x, y), r, r);

    protected override void OnRender(DrawingContext dc)
    {
        double width = ActualWidth, height = ActualHeight;
        if (width < 1 || height < 1) return;
        var scale = Math.Min(width / 76, height / 64);
        dc.PushTransform(new TranslateTransform(width / 2, height / 2));
        dc.PushTransform(new ScaleTransform(scale, scale));

        // the wings, folding towards the body
        foreach (var sign in new[] { -1, 1 })
        {
            dc.PushTransform(new ScaleTransform(Math.Max(0.12, _open), 1));
            var brush = Wing(sign);
            dc.DrawGeometry(brush, null, Oval(sign * Upper[0], Upper[1], Upper[2], Upper[3], sign * Upper[4]));
            dc.PushOpacity(0.8);
            dc.DrawGeometry(brush, null, Oval(sign * Lower[0], Lower[1], Lower[2], Lower[3], sign * Lower[4]));
            dc.Pop();
            dc.Pop();
        }

        // antennae
        var face = new SolidColorBrush(Face);
        var line = new Pen(face, 2) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        foreach (var sign in new[] { -1, 1 })
        {
            var path = new StreamGeometry();
            using (var c = path.Open())
            {
                c.BeginFigure(new Point(sign * 5, -12), false, false);
                c.BezierTo(new Point(sign * 7.67, -18.67), new Point(sign * 10.67, -23), new Point(sign * 14, -25), true, false);
            }
            dc.DrawGeometry(null, line, path);
            Dot(dc, face, sign * 14, -25, 2.4);
        }

        // the face
        Dot(dc, face, 0, 2, 13);
        var ink = new SolidColorBrush(Ink);
        const double r = 4.6;
        foreach (var sign in new[] { -1, 1 })
        {
            var x = sign * 5.4;
            if (_blink)
            {
                var closed = new StreamGeometry();
                using (var c = closed.Open())
                {
                    c.BeginFigure(new Point(x - r, 0), false, false);
                    c.BezierTo(new Point(x - r / 3, r * 0.47), new Point(x + r / 3, r * 0.47), new Point(x + r, 0), true, false);
                }
                dc.DrawGeometry(null, new Pen(ink, r * 0.45) { StartLineCap = PenLineCap.Flat, EndLineCap = PenLineCap.Flat }, closed);
                continue;
            }
            Dot(dc, Brushes.White, x, 0, r);
            Dot(dc, ink, x, r * 0.1, r * 0.55);
            Dot(dc, Brushes.White, x + r * 0.22, -r * 0.15, r * 0.18);
        }
        // cheeks and a smile
        var cheek = new SolidColorBrush(Color.FromArgb((byte)(0.7 * 255), 255, (byte)(0.62 * 255), (byte)(0.78 * 255)));
        foreach (var sign in new[] { -1, 1 }) Dot(dc, cheek, sign * 8.5, 7, 2);
        var smile = new StreamGeometry();
        using (var c = smile.Open())
        {
            c.BeginFigure(new Point(-3, 8), false, false);
            c.BezierTo(new Point(-1, 9.67), new Point(1, 9.67), new Point(3, 8), true, false);
        }
        dc.DrawGeometry(null, new Pen(ink, 1.4), smile);
        dc.Pop();
        dc.Pop();
    }
}
