using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace Muna;

/// <summary>Companion: a small friend that lives in the capsule. Its eyes follow the pointer, it blinks,
/// it sways to the music, looks surprised when a card pops up, and falls asleep when nothing happens.</summary>
public sealed class CompanionModel
{
    public double Time { get; private set; }
    public Point Look { get; private set; }
    public bool Blinking { get; private set; }
    public bool Surprised { get; private set; }
    public bool Asleep { get; private set; }
    public bool MusicPlaying { get; set; }
    /// <summary>Where the capsule hangs (pixels): the eyes look from there.</summary>
    public Point Anchor { get; set; }
    double _blink, _nextBlink = 2.5, _surpriseLeft, _idle;
    Point _last;
    readonly Random _random = new();

    public void Surprise()
    {
        _surpriseLeft = 1.2;
        _idle = 0;
    }

    public void Step(double dt)
    {
        Time += dt;
        var mouse = Native.Cursor();
        if (Math.Abs(mouse.X - _last.X) + Math.Abs(mouse.Y - _last.Y) > 2) _idle = 0; else _idle += dt;
        _last = mouse;
        if (MusicPlaying) _idle = 0;
        _nextBlink -= dt;
        if (_nextBlink <= 0)
        {
            _blink = 0.14;
            _nextBlink = 2 + _random.NextDouble() * 4;
        }
        _blink = Math.Max(0, _blink - dt);
        _surpriseLeft = Math.Max(0, _surpriseLeft - dt);
        var dx = mouse.X - Anchor.X;
        var dy = mouse.Y - Anchor.Y;
        var d = Math.Max(1, Math.Sqrt(dx * dx + dy * dy));
        var reach = Math.Min(1, d / 200);
        Look = new Point(dx / d * reach, dy / d * reach);
        Blinking = _blink > 0;
        Surprised = _surpriseLeft > 0;
        Asleep = _idle > 25 && !MusicPlaying;
    }
}

public static class CompanionView
{
    static readonly Brush Ink = C.Rgb(26, 31, 51);

    /// <summary>The widget: drawn again 20 times a second while it is shown.</summary>
    public static UIElement Build(CompanionModel companion)
    {
        var host = new Border { Width = 88, Height = 112, Background = Brushes.Black, ClipToBounds = false };
        var timer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(50) };
        void Draw()
        {
            try
            {
                var centre = host.PointToScreen(new Point(host.ActualWidth / 2, host.ActualHeight / 2));
                companion.Anchor = centre;
            }
            catch { /* not on screen yet */ }
            companion.Step(0.05);
            host.Child = Face(companion, 88, 112);
        }
        timer.Tick += (_, _) => Draw();
        host.Loaded += (_, _) => { Draw(); timer.Start(); };
        host.Unloaded += (_, _) => timer.Stop();
        host.Child = Face(companion, 88, 112);
        return host.Align(HorizontalAlignment.Center, VerticalAlignment.Center);
    }

    static UIElement Face(CompanionModel c, double width, double height)
    {
        var size = Math.Min(width, height);
        var t = c.Time;
        var playing = c.MusicPlaying;
        var sway = playing ? Math.Sin(t * 5) * size * 0.04 : Math.Sin(t * 1.5) * size * 0.012;
        var bob = playing ? Math.Abs(Math.Sin(t * 5)) * size * 0.05 : 0;
        var face = size * 0.72;
        var canvas = new Canvas { Width = width, Height = height };
        var group = new Canvas { Width = face, Height = face };
        group.Children.Add(new Rectangle { Width = face, Height = face, RadiusX = face * 0.3, RadiusY = face * 0.3, Fill = C.Muna, Stroke = C.White(0.25), StrokeThickness = size * 0.015 });
        // eyes
        var eyeY = face / 2 - face * 0.06;
        foreach (var side in new[] { -1, 1 })
        {
            var cx = face / 2 + side * (face * 0.14 + face * 0.11);
            var r = face * (c.Surprised ? 0.13 : 0.1);
            if (c.Asleep || c.Blinking)
            {
                var lid = new Rectangle { Width = r * 2, Height = face * 0.035, RadiusX = face * 0.0175, RadiusY = face * 0.0175, Fill = Ink };
                Canvas.SetLeft(lid, cx - r);
                Canvas.SetTop(lid, eyeY - face * 0.0175);
                group.Children.Add(lid);
            }
            else
            {
                var white = new Ellipse { Width = r * 2, Height = r * 2, Fill = Brushes.White };
                Canvas.SetLeft(white, cx - r);
                Canvas.SetTop(white, eyeY - r);
                group.Children.Add(white);
                var pupil = new Ellipse { Width = r, Height = r, Fill = Ink };
                Canvas.SetLeft(pupil, cx - r / 2 + c.Look.X * r * 0.45);
                Canvas.SetTop(pupil, eyeY - r / 2 + c.Look.Y * r * 0.45);
                group.Children.Add(pupil);
            }
        }
        // mouth
        var mouthY = face / 2 + face * 0.22;
        if (c.Surprised)
        {
            var o = new Ellipse { Width = face * 0.12, Height = face * 0.12, Stroke = Ink, StrokeThickness = face * 0.035 };
            Canvas.SetLeft(o, face / 2 - face * 0.06);
            Canvas.SetTop(o, mouthY - face * 0.06);
            group.Children.Add(o);
        }
        else
        {
            double w = face * 0.24, h = face * 0.08, left = face / 2 - w / 2, top = mouthY - h / 2;
            var smile = new Path
            {
                Stroke = Ink, StrokeThickness = face * 0.035, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
                Data = new PathGeometry(new[] { new PathFigure(new Point(left, top), new[] { new QuadraticBezierSegment(new Point(left + w / 2, top + h * 2), new Point(left + w, top), true) }, false) }),
            };
            group.Children.Add(smile);
        }
        group.RenderTransformOrigin = new Point(0.5, 0.5);
        group.RenderTransform = new RotateTransform(playing ? Math.Sin(t * 5) * 6 : 0);
        Canvas.SetLeft(group, (width - face) / 2 + sway);
        Canvas.SetTop(group, (height - face) / 2 + size * 0.04 - bob);
        canvas.Children.Add(group);
        if (c.Asleep)
        {
            var z = Ui.Bold("z", size * 0.16);
            Canvas.SetLeft(z, width / 2 + face * 0.5);
            Canvas.SetTop(z, height / 2 - face * 0.55 - Math.Sin(t * 2) * size * 0.03 - size * 0.1);
            canvas.Children.Add(z);
        }
        return canvas;
    }
}
