using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Text;
using System.Linq;
using Forms = System.Windows.Forms;

namespace Muna;

/// <summary>Linux's top-bar readings (linux/src/ui/barReadings.js): what each one is called, its short
/// value for the bar and its line for the tooltip.</summary>
public sealed record Reading(string Id, string Label, string Title, string Page, Func<SystemMonitor, string?> Short, Func<SystemMonitor, string?> Long)
{
    static string Rate(double bytes) => bytes < 1000 ? $"{bytes:0}B" : bytes < 1_000_000 ? $"{bytes / 1000:0}K" : $"{bytes / 1_000_000:0.#}M";

    static string? Temp(SystemMonitor m)
    {
        if (m.Temperature is not { } c) return null;
        return Preferences.Shared.TemperatureUnit == "F" ? $"{c * 9 / 5 + 32:0}°" : $"{c:0}°";
    }

    public static readonly Reading[] All =
    {
        new("cpu", "CPU", "Processor", "system", m => $"{(int)(m.Cpu * 100)}%", m => $"Processor {(int)(m.Cpu * 100)}%"),
        new("cputemp", "TMP", "Temperature", "system", Temp, m => m.Temperature is { } c ? $"Temperature {SystemMonitor.TemperatureText(c)}" : null),
        new("gpu", "GPU", "Graphics", "system", m => m.Gpu is { } g ? $"{(int)(g * 100)}%" : null, m => m.Gpu is { } g ? $"Graphics {(int)(g * 100)}%" : null),
        new("mem", "RAM", "Memory", "system", m => $"{m.MemoryPercent}%", m => $"Memory {m.MemoryPercent}% · {Ui.SizeText((long)m.MemoryUsed)} of {Ui.SizeText((long)m.MemoryTotal)}"),
        new("battery", "BAT", "Battery", "system", _ => SystemMonitor.Battery() is { HasBattery: true } b ? $"{b.Percent}%" : null,
            _ => SystemMonitor.Battery() is { HasBattery: true } b ? $"Battery {b.Percent}%{(b.Charging ? ", charging" : "")}" : null),
        new("net", "NET", "Network", "network", m => $"↓{Rate(m.DownPerSecond)}", m => $"Network ↓ {Rate(m.DownPerSecond)}/s ↑ {Rate(m.UpPerSecond)}/s"),
        new("disk", "DSK", "Disk", "system", _ => SystemMonitor.SystemDisk() is { Total: > 0 } d ? $"{(int)(100 - 100.0 * d.Free / d.Total)}%" : null,
            _ => SystemMonitor.SystemDisk() is { Total: > 0 } d ? $"Disk {Ui.SizeText(d.Free)} free" : null),
        new("diskio", "I/O", "Disk activity", "system", m => m.DiskBytesPerSecond is { } b ? Rate(b) : null, m => m.DiskBytesPerSecond is { } b ? $"Disk activity {Rate(b)}/s" : null),
        new("power", "PWR", "Power use", "system", m => m.PowerWatts is { } w ? $"{w:0.#}W" : null, m => m.PowerWatts is { } w ? $"Power {w:0.0} W" : null),
    };

    public static Reading? Find(string id) => All.FirstOrDefault(r => r.Id == id);

    /// <summary>The chosen readings with a value now.</summary>
    public static List<(Reading Reading, string Value)> Chosen(SystemMonitor monitor) =>
        Preferences.Shared.BarMetrics.Select(Find).OfType<Reading>()
            .Select(r => (r, r.Short(monitor))).Where(p => p.Item2 is not null).Select(p => (p.r, p.Item2!)).ToList();
}

/// <summary>The readings in the notification area: Windows has no top bar, so each chosen reading is
/// a small icon of its own that shows its value (the way the top bar shows it on Linux). A click opens
/// the quick panel on its page.</summary>
public sealed class ReadingIcons : IDisposable
{
    readonly AppState _app;
    readonly Dictionary<string, (Forms.NotifyIcon Icon, string Text, IntPtr Handle)> _icons = new();

    public ReadingIcons(AppState app) => _app = app;

    public void Update()
    {
        var wanted = Preferences.Shared.BarMetrics.Select(Reading.Find).OfType<Reading>().ToList();
        foreach (var id in _icons.Keys.Where(id => wanted.All(r => r.Id != id)).ToList()) Remove(id);
        foreach (var reading in wanted)
        {
            var value = reading.Short(_app.Monitor) ?? "–";
            var tip = reading.Long(_app.Monitor) ?? $"{reading.Title}: not available";
            if (!_icons.TryGetValue(reading.Id, out var entry))
            {
                var icon = new Forms.NotifyIcon { Visible = true };
                var page = reading.Page;
                icon.MouseUp += (_, e) => { if (e.Button == Forms.MouseButtons.Left) _app.ShowQuickPanel(page); };
                entry = (icon, "", IntPtr.Zero);
            }
            if (entry.Text != value)
            {
                var handle = Draw(reading.Label, value);
                entry.Icon.Icon = Icon.FromHandle(handle);
                if (entry.Handle != IntPtr.Zero) Native.DestroyIcon(entry.Handle);
                entry = (entry.Icon, value, handle);
            }
            var text = tip.Length > 63 ? tip[..63] : tip;
            if (entry.Icon.Text != text) entry.Icon.Text = text;
            _icons[reading.Id] = entry;
        }
    }

    /// <summary>The label small on top, the value below (without "%", which does not fit).</summary>
    static IntPtr Draw(string label, string value)
    {
        var size = Forms.SystemInformation.SmallIconSize.Width;
        using var bitmap = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            g.Clear(Color.Transparent);
            var shown = value.TrimEnd('%');
            using var small = new Font("Segoe UI", size * 0.30f, FontStyle.Bold, GraphicsUnit.Pixel);
            using var big = new Font("Segoe UI", size * (shown.Length > 3 ? 0.40f : 0.52f), FontStyle.Bold, GraphicsUnit.Pixel);
            using var grey = new SolidBrush(Color.FromArgb(200, 180, 180, 190));
            var center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Near };
            g.DrawString(label, small, grey, new RectangleF(-2, -size * 0.06f, size + 4, size * 0.4f), center);
            g.DrawString(shown, big, Brushes.White, new RectangleF(-3, size * 0.30f, size + 6, size * 0.7f), center);
        }
        return bitmap.GetHicon();
    }

    void Remove(string id)
    {
        if (!_icons.Remove(id, out var entry)) return;
        entry.Icon.Visible = false;
        entry.Icon.Dispose();
        if (entry.Handle != IntPtr.Zero) Native.DestroyIcon(entry.Handle);
    }

    public void Dispose()
    {
        foreach (var id in _icons.Keys.ToList()) Remove(id);
    }
}
