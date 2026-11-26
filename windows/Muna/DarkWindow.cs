using System.Collections.Generic;
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
            ApplyScheme();
            var round = 2;
            Native.DwmSetWindowAttribute(new WindowInteropHelper(this).Handle, 33, ref round, 4); // round corners (Windows 11)
        };
        Preferences.Shared.Changed += key => { if (key is "color-scheme" or "*") Dispatcher.BeginInvoke(ApplyScheme); };
        try { Icon = Ui.LoadResource("Assets/Muna.ico"); } catch { /* no icon */ }
        Resources.Add(typeof(ScrollBar), ThinScrollBar.Value);
    }

    /// <summary>Thin rounded scroll bars in grey, readable on light and dark (Windows' own are white boxes).</summary>
    static readonly Lazy<Style> ThinScrollBar = new(() => (Style)System.Windows.Markup.XamlReader.Parse("""
        <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="ScrollBar">
          <Setter Property="Background" Value="Transparent"/>
          <Setter Property="Width" Value="10"/>
          <Setter Property="MinWidth" Value="10"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Track x:Name="PART_Track" IsDirectionReversed="True">
                  <Track.Thumb>
                    <Thumb>
                      <Thumb.Template>
                        <ControlTemplate TargetType="Thumb"><Border CornerRadius="3" Background="#7F8A8A90" Margin="3,2,3,2"/></ControlTemplate>
                      </Thumb.Template>
                    </Thumb>
                  </Track.Thumb>
                </Track>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
          <Style.Triggers>
            <Trigger Property="Orientation" Value="Horizontal">
              <Setter Property="Width" Value="Auto"/>
              <Setter Property="MinWidth" Value="0"/>
              <Setter Property="Height" Value="10"/>
              <Setter Property="Template">
                <Setter.Value>
                  <ControlTemplate TargetType="ScrollBar">
                    <Track x:Name="PART_Track" IsDirectionReversed="False">
                      <Track.Thumb>
                        <Thumb>
                          <Thumb.Template>
                            <ControlTemplate TargetType="Thumb"><Border CornerRadius="3" Background="#7F8A8A90" Margin="2,3,2,3"/></ControlTemplate>
                          </Thumb.Template>
                        </Thumb>
                      </Track.Thumb>
                    </Track>
                  </ControlTemplate>
                </Setter.Value>
              </Setter>
            </Trigger>
          </Style.Triggers>
        </Style>
        """));

    /// The window's colours and title bar follow Settings → General → Appearance.
    void ApplyScheme()
    {
        Background = C.WinBackground;
        Foreground = C.WinText;
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        var dark = C.Light ? 0 : 1;
        Native.DwmSetWindowAttribute(hwnd, 20, ref dark, 4);
        OnShown();
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

    /// <summary>Linux's dropdown in the window's colours (light or dark): a rounded box with a chevron,
    /// its list on a card; Windows' own is a white box in both.</summary>
    static Style DropdownStyle()
    {
        string Hex(SolidColorBrush b) => b.Color.ToString();
        var xaml = """
            <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="ComboBox">
              <Setter Property="Template">
                <Setter.Value>
                  <ControlTemplate TargetType="ComboBox">
                    <Grid>
                      <ToggleButton Focusable="False" ClickMode="Press" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                        <ToggleButton.Template>
                          <ControlTemplate TargetType="ToggleButton">
                            <Border x:Name="Box" Background="CONTROL" BorderBrush="BORDER" BorderThickness="1" CornerRadius="7">
                              <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,11,0" Data="M0,0 L4,4 L8,0" Stroke="SECONDARY" StrokeThickness="1.5"/>
                            </Border>
                            <ControlTemplate.Triggers>
                              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="ACCENT"/></Trigger>
                            </ControlTemplate.Triggers>
                          </ControlTemplate>
                        </ToggleButton.Template>
                      </ToggleButton>
                      <ContentPresenter IsHitTestVisible="False" Margin="10,6,30,6" VerticalAlignment="Center" HorizontalAlignment="Left"
                                        Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
                      <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                        <Border Background="CARD" BorderBrush="BORDER" BorderThickness="1" CornerRadius="8" Padding="4" Margin="0,4,0,0"
                                MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                          <ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer>
                        </Border>
                      </Popup>
                    </Grid>
                  </ControlTemplate>
                </Setter.Value>
              </Setter>
              <Setter Property="ItemContainerStyle">
                <Setter.Value>
                  <Style TargetType="ComboBoxItem">
                    <Setter Property="Foreground" Value="TEXT"/>
                    <Setter Property="Template">
                      <Setter.Value>
                        <ControlTemplate TargetType="ComboBoxItem">
                          <Border x:Name="Row" Background="Transparent" CornerRadius="5" Padding="8,5,8,5"><ContentPresenter/></Border>
                          <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Row" Property="Background" Value="HOVER"/></Trigger>
                            <Trigger Property="IsSelected" Value="True"><Setter Property="Foreground" Value="ACCENT"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="SECONDARY"/></Trigger>
                          </ControlTemplate.Triggers>
                        </ControlTemplate>
                      </Setter.Value>
                    </Setter>
                  </Style>
                </Setter.Value>
              </Setter>
            </Style>
            """;
        xaml = xaml.Replace("CONTROL", Hex(C.WinControl)).Replace("BORDER", Hex(C.WinBorder)).Replace("SECONDARY", Hex(C.WinSecondary))
                   .Replace("ACCENT", Hex(C.WinAccent)).Replace("CARD", Hex(C.WinCard)).Replace("TEXT", Hex(C.WinText))
                   .Replace("HOVER", C.Light ? "#14000000" : "#1FFFFFFF");
        return (Style)System.Windows.Markup.XamlReader.Parse(xaml);
    }

    /// <summary>A setting: its name and description on the left, the control on the right.</summary>
    /// <summary>A list to choose from (long lists, as the gestures' actions), with group headings.</summary>
    public static ComboBox Dropdown(IReadOnlyList<(string Label, string? Group)> items, int selected, Action<int> changed)
    {
        var box = new ComboBox { MinWidth = 230, FontFamily = Ui.Font, FontSize = 12, MaxDropDownHeight = 420, Style = DropdownStyle(), Foreground = C.WinText };
        string? group = null;
        var indexes = new List<int>();
        for (var i = 0; i < items.Count; i++)
        {
            var (label, g) = items[i];
            if (!string.IsNullOrEmpty(g) && g != group)
            {
                group = g;
                box.Items.Add(new ComboBoxItem { Content = g.ToUpperInvariant(), IsEnabled = false, FontSize = 10, FontWeight = FontWeights.Bold });
                indexes.Add(-1);
            }
            box.Items.Add(new ComboBoxItem { Content = label });
            indexes.Add(i);
        }
        box.SelectedIndex = Math.Max(0, indexes.IndexOf(selected));
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedIndex >= 0 && indexes[box.SelectedIndex] is var index and >= 0) changed(index);
        };
        return box;
    }

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
