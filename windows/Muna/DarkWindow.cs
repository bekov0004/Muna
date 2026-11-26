using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;

namespace Muna;

/// <summary>Muna's ordinary windows (settings, agents, scratchpad): dark, with Windows' dark title bar;
/// closing hides them, so they come back as they were.</summary>
public class DarkWindow : Window
{
    public DarkWindow()
    {
        Background = C.WinBackground;
        Foreground = C.WinText;
        FontFamily = Ui.Font;
        FontSize = 13;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            var on = 1;
            Native.DwmSetWindowAttribute(hwnd, 20, ref on, 4);   // dark title bar
            var round = 2;
            Native.DwmSetWindowAttribute(hwnd, 33, ref round, 4); // round corners (Windows 11)
        };
        try { Icon = Ui.LoadResource("Assets/Muna.ico"); } catch { /* no icon */ }
    }

    public bool Quitting { get; set; }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        if (!Quitting)
        {
            e.Cancel = true;
            Hide();
        }
        base.OnClosing(e);
    }

    protected virtual void OnShown() { }

    /// <summary>Shows the window in front (it may be hidden, minimised or behind others).</summary>
    public void ShowFront()
    {
        if (!IsVisible) Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        Topmost = true;
        Topmost = false;
        Focus();
        OnShown();
    }

    // --- controls in the windows' style ------------------------------------------------------------

    public static TextBox Input(bool multiline = false)
    {
        var box = new TextBox
        {
            Background = C.WinControl, Foreground = C.WinText, CaretBrush = C.WinText, BorderBrush = C.WinBorder, BorderThickness = new Thickness(1),
            Padding = new Thickness(8, 6, 8, 6), FontFamily = Ui.Font, FontSize = 13, SelectionBrush = C.WinAccent,
            AcceptsReturn = multiline, TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
            VerticalScrollBarVisibility = multiline ? ScrollBarVisibility.Auto : ScrollBarVisibility.Disabled,
        };
        box.Resources[SystemParameters.VerticalScrollBarWidthKey] = 8.0;
        return box;
    }

    public static Border Button(string label, Action action, bool accent = false, bool disabled = false)
    {
        var button = Ui.Box(Ui.Semi(label, 12, accent ? Brushes.White : C.WinText), accent ? C.WinAccent : C.WinControl, 7, 12, 6);
        if (disabled) { button.Opacity = 0.45; return button; }
        return button.OnClick(action, accent ? C.Rgb(0x2a, 0x93, 0xff) : C.Rgb(0x35, 0x35, 0x38));
    }

    /// <summary>A switch (on: blue).</summary>
    public static Border Toggle(bool on, Action<bool> changed)
    {
        var knob = new Border { Width = 16, Height = 16, CornerRadius = new CornerRadius(8), Background = Brushes.White, HorizontalAlignment = on ? HorizontalAlignment.Right : HorizontalAlignment.Left, Margin = new Thickness(2) };
        var track = new Border { Width = 38, Height = 20, CornerRadius = new CornerRadius(10), Background = on ? C.WinAccent : C.Rgb(0x48, 0x48, 0x4c), Child = knob };
        return track.OnClick(() => changed(!on));
    }

    /// <summary>A slider in the windows' colours.</summary>
    public static Slider Slider(double min, double max, double value, Action<double> changed, double step = 0)
    {
        var slider = new Slider { Minimum = min, Maximum = max, Value = value, Width = 200, VerticalAlignment = VerticalAlignment.Center, IsMoveToPointEnabled = true };
        if (step > 0) { slider.TickFrequency = step; slider.IsSnapToTickEnabled = true; }
        slider.ValueChanged += (_, e) => changed(e.NewValue);
        return slider;
    }

    /// <summary>A choice of a few values (segmented buttons).</summary>
    public static UIElement Choice(string[] labels, int selected, Action<int> changed)
    {
        var row = Ui.Row(2);
        for (var i = 0; i < labels.Length; i++)
        {
            var index = i;
            var on = i == selected;
            row.Children.Add(Ui.Box(Ui.Semi(labels[i], 12, on ? Brushes.White : C.WinSecondary), on ? C.WinAccent : C.Clear, 6, 10, 4).OnClick(() => changed(index)));
        }
        return Ui.Box(row, C.WinControl, 8, 2, 2);
    }

    /// <summary>A setting: its name and description on the left, the control on the right.</summary>
    public static UIElement Setting(string title, string? subtitle, UIElement control)
    {
        var text = Ui.Column(2, Ui.Text(title, 13, color: C.WinText));
        if (subtitle is not null) text.Children.Add(Ui.Text(subtitle, 11, color: C.WinSecondary, wrap: true));
        var row = Ui.Row(16, text.Grow(), Ui.Detach(control));
        return new Border { Child = row, Padding = new Thickness(14, 10, 14, 10) };
    }

    /// <summary>A group of settings on a card, lines between them.</summary>
    public static UIElement Card(string? heading, params UIElement?[] rows)
    {
        var column = Ui.Column(0);
        var first = true;
        foreach (var row in rows)
        {
            if (row is null) continue;
            if (!first) column.Children.Add(Ui.Line(color: C.WinBorder).Margin(14, 0, 14, 0));
            column.Children.Add(Ui.Detach(row));
            first = false;
        }
        var card = new Border { Child = column, Background = C.WinCard, CornerRadius = new CornerRadius(12), BorderBrush = C.WinBorder, BorderThickness = new Thickness(1) };
        if (heading is null) return card;
        return Ui.Column(8, Ui.Text(heading.ToUpperInvariant(), 11, FontWeights.Bold, C.WinSecondary).Margin(4, 0, 0, 0), card);
    }
}
