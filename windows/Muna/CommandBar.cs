using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Muna.Core;

namespace Muna;

/// <summary>One line of the Command Bar's list.</summary>
public sealed record CommandResult(string Id, string Glyph, string Title, string Subtitle, Action Run, string? File = null, string? Confirm = null);

/// <summary>The Command Bar, as on Linux (linux/src/commandbar): one field for everything. Type to start
/// an app, to calculate ("12*(3+4)"), to convert units ("5 km to mi"), to find something you copied,
/// or to search the web. Up / Down choose, Enter does it, Esc leaves.</summary>
public sealed class CommandModel : Model
{
    public static readonly string[] Examples = { "12*(3+4)", "5 km to mi", ";snippets", "scratch", "kill …", "ports", "clean" };
    const int MaxApps = 5, MaxClips = 3;

    readonly ClipboardModel _clipboard;
    readonly SnippetsModel _snippets;
    List<(string Name, string Path)> _apps = new();
    int _generation;
    public string Query { get; private set; } = "";
    public List<CommandResult> Results { get; private set; } = new();
    public int Selected { get; private set; }
    /// <summary>The result waiting for its second Enter.</summary>
    public string? Armed { get; private set; }
    /// <summary>Ask to leave (after running something, or Esc).</summary>
    public event Action? Done;
    public event Action? Scratchpad;

    public CommandModel(ClipboardModel clipboard, SnippetsModel snippets)
    {
        _clipboard = clipboard;
        _snippets = snippets;
        Task.Run(FindApps).ContinueWith(t => Ui(() => _apps = t.Result));
    }

    /// <summary>The Start menu's programs (shortcuts of every user and of this one).</summary>
    static List<(string, string)> FindApps()
    {
        var folders = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu),
            Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),
        };
        var result = new List<(string, string)>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var folder in folders.Where(Directory.Exists))
        {
            IEnumerable<string> files;
            try { files = Directory.EnumerateFiles(folder, "*.*", SearchOption.AllDirectories).ToList(); }
            catch { continue; }
            foreach (var file in files)
            {
                var ext = Path.GetExtension(file).ToLowerInvariant();
                if (ext is not (".lnk" or ".url" or ".appref-ms")) continue;
                var name = Path.GetFileNameWithoutExtension(file);
                var lower = name.ToLowerInvariant();
                if (lower.Contains("uninstall") || lower.Contains("readme") || lower.Contains("help") && lower.Length < 12) continue;
                if (seen.Add(name)) result.Add((name, file));
            }
        }
        return result.OrderBy(a => a.Item1, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    public void Reset()
    {
        Query = "";
        Selected = 0;
        Results = new();
        Armed = null;
        Notify();
    }

    public void SetQuery(string query)
    {
        if (query == Query) return;
        Query = query;
        Update();
    }

    public void Move(int step)
    {
        if (Results.Count == 0) return;
        Selected = (Selected + step + Results.Count) % Results.Count;
        Notify();
    }

    public void Select(int index)
    {
        Selected = index;
        RunSelected();
    }

    public void RunSelected()
    {
        if (Selected < 0 || Selected >= Results.Count) return;
        var result = Results[Selected];
        if (result.Confirm is not null && Armed != result.Id)
        {
            Armed = result.Id;
            Notify();
            return;
        }
        Armed = null;
        result.Run();
    }

    void Finish() => Done?.Invoke();

    /// <summary>Results that take a moment (processes, ports, folder sizes): worked out in the background.</summary>
    void Later(Func<List<CommandResult>> work)
    {
        var mine = _generation;
        Results = new() { new("busy", Glyph.Clock, "Looking…", "", () => { }) };
        Notify();
        Task.Run(work).ContinueWith(t => Ui(() =>
        {
            if (_generation != mine) return;
            Results = t.Result.Count == 0 ? new() { new("none", Glyph.Info, "Nothing found", "", () => { }) } : t.Result;
            Notify();
        }));
    }

    static CommandResult StopRow(int pid, string title, string subtitle) => new($"pid:{pid}", Glyph.Close, title, subtitle, () =>
    {
        try { Process.GetProcessById(pid).Kill(); } catch { /* gone, or not ours */ }
    }, Confirm: "Enter again to stop it");

    /// <summary>"kill &lt;name&gt;": the processes whose name has it.</summary>
    static List<CommandResult> Processes(string name)
    {
        var own = Environment.ProcessId;
        var rows = new List<CommandResult>();
        foreach (var p in Process.GetProcesses().OrderBy(p => p.ProcessName))
        {
            if (p.Id == own || !p.ProcessName.Contains(name, StringComparison.OrdinalIgnoreCase)) continue;
            string memory = "";
            try { memory = " · " + Muna.Ui.SizeText(p.WorkingSet64); } catch { /* not ours */ }
            rows.Add(StopRow(p.Id, p.ProcessName, $"Process {p.Id}{memory}"));
            if (rows.Count >= 8) break;
        }
        return rows;
    }

    static string Output(string program, string arguments)
    {
        try
        {
            var info = new ProcessStartInfo(program, arguments) { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
            using var process = Process.Start(info)!;
            var text = process.StandardOutput.ReadToEnd();
            process.WaitForExit(5000);
            return text;
        }
        catch { return ""; }
    }

    /// <summary>"ports": what listens on which TCP port.</summary>
    static List<CommandResult> ListeningPorts()
    {
        var rows = new List<CommandResult>();
        var seen = new HashSet<string>();
        var names = new Dictionary<int, string>();
        foreach (var line in Output("netstat", "-ano -p TCP").Split('\n'))
        {
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 5 || parts[0] != "TCP" || parts[3] != "LISTENING" || !int.TryParse(parts[4], out var pid) || pid <= 4) continue;
            var port = parts[1].Split(':').Last();
            if (!seen.Add($"{pid}:{port}")) continue;
            if (!names.TryGetValue(pid, out var program))
            {
                try { program = Process.GetProcessById(pid).ProcessName; } catch { program = "?"; }
                names[pid] = program;
            }
            rows.Add(StopRow(pid, $"Port {port} · {program}", $"TCP · process {pid}"));
        }
        return rows.OrderBy(r => int.TryParse(r.Title.Split(' ')[1], out var n) ? n : 0).ToList();
    }

    /// <summary>"clean": the biggest folders of the temporary folder; Enter twice empties one.</summary>
    static List<CommandResult> TempFolders()
    {
        var temp = Path.GetTempPath();
        var rows = new List<(string Path, long Size)>();
        long Size(string folder)
        {
            long total = 0;
            try
            {
                foreach (var f in Directory.EnumerateFiles(folder, "*", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true }))
                    try { total += new FileInfo(f).Length; } catch { }
            }
            catch { }
            return total;
        }
        long loose = 0;
        try
        {
            foreach (var f in Directory.EnumerateFiles(temp)) try { loose += new FileInfo(f).Length; } catch { }
            foreach (var d in Directory.EnumerateDirectories(temp))
            {
                var size = Size(d);
                if (size > 1_000_000) rows.Add((d, size));
            }
        }
        catch { }
        var result = new List<CommandResult>();
        if (loose > 1_000_000)
            result.Add(new("clean:loose", Glyph.Delete, $"Loose files in Temp · {Muna.Ui.SizeText(loose)}", "Programs left them; the ones in use stay", () =>
            {
                foreach (var f in Directory.EnumerateFiles(temp)) try { File.Delete(f); } catch { }
            }, Confirm: "Enter again to empty it"));
        foreach (var (path, size) in rows.OrderByDescending(r => r.Size).Take(8))
            result.Add(new($"clean:{path}", Glyph.Delete, $"{Path.GetFileName(path)} · {Muna.Ui.SizeText(size)}", "Temporary: the program makes it again", () =>
            {
                try { Directory.Delete(path, true); } catch { /* in use */ }
            }, Confirm: "Enter again to empty it"));
        return result;
    }

    void Update()
    {
        var text = Query.Trim();
        Selected = 0;
        Armed = null;
        _generation++;
        var lowered = text.ToLowerInvariant();
        var words = lowered.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 2 && words[0] is "kill" or "stop" or "quit") { var name = words[1]; Later(() => Processes(name)); return; }
        if (lowered is "ports" or "port") { Later(ListeningPorts); return; }
        if (lowered is "clean" or "cleaner" or "cache" or "temp") { Later(TempFolders); return; }
        if (text.Length == 0) { Results = new(); Notify(); return; }
        var list = new List<CommandResult>();
        // ";trigger": the snippets (";" alone: all of them); Enter copies the text, {date} and {time} filled in
        if (text.StartsWith(';'))
        {
            var wanted = text[1..].ToLowerInvariant();
            foreach (var snippet in _snippets.Snippets.Where(s => wanted.Length == 0 || s.Trigger.TrimStart(';').ToLowerInvariant().StartsWith(wanted)).Take(8))
            {
                var body = snippet.Text;
                list.Add(new($"snippet:{snippet.Trigger}", Glyph.Edit, snippet.Trigger.StartsWith(';') ? snippet.Trigger : ";" + snippet.Trigger,
                             body.Replace("\n", " "), () => { ClipboardModel.SetText(SnippetsStore.Expand(body)); Finish(); }));
            }
            if (list.Count == 0) list.Add(new("snippets-none", Glyph.Edit, "No snippet like that", "Add snippets in Settings → Snippets", Finish));
            Results = list;
            Notify();
            return;
        }
        if ("scratchpad".StartsWith(lowered) && text.Length >= 3)
            list.Add(new("scratchpad", Glyph.Note, "Scratchpad", "A window for long notes", () => { Finish(); Scratchpad?.Invoke(); }));
        if (CommandEngine.Calculate(text) is { } value)
        {
            var answer = CommandEngine.Format(value);
            list.Add(new("calc", Glyph.Calculator, answer, $"{text} · Enter copies it", () => { ClipboardModel.SetText(answer); Finish(); }));
        }
        if (CommandEngine.Convert(text) is { } conversion)
        {
            var answer = CommandEngine.Format(Math.Round(conversion.Value * 1e6) / 1e6);
            list.Add(new("convert", Glyph.Ruler, conversion.Text, $"Enter copies {answer}", () => { ClipboardModel.SetText(answer); Finish(); }));
        }
        foreach (var (name, path) in _apps.Select(a => (a, score: CommandEngine.MatchScore(a.Name, text))).Where(x => x.score > 0)
                     .OrderByDescending(x => x.score).Take(MaxApps).Select(x => x.a))
            list.Add(new($"app:{path}", Glyph.Apps, name, "Application", () => { CapsuleViews.Launch(path); Finish(); }, File: path));
        foreach (var item in _clipboard.Items.Where(i => !i.IsPrivate && i.SearchText.Contains(lowered, StringComparison.OrdinalIgnoreCase)).Take(MaxClips))
        {
            var title = (item.Text ?? item.Files?.Select(TrayStore.PathOf).FirstOrDefault(p => p is not null)?.Split('\\').Last() ?? "").Replace("\n", " ");
            list.Add(new($"clip:{item.Id}", Glyph.Clipboard, title, "Copied before · Enter copies it again", () => { _clipboard.Copy(item); Finish(); }));
        }
        var encoded = Uri.EscapeDataString(text);
        list.Add(new("web", Glyph.Search, $"Search the web for “{text}”", "In your browser", () =>
        {
            CapsuleViews.Launch($"https://www.google.com/search?q={encoded}");
            Finish();
        }));
        Results = list;
        Notify();
    }
}

public static class CommandView
{
    public static void Wire(CapsuleWindow w)
    {
        var field = w.State.CommandField;
        var command = w.App.Command;
        field.Box.TextChanged += (_, _) => command.SetQuery(field.Text);
        field.Submitted += command.RunSelected;
        field.Box.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Down) { command.Move(1); e.Handled = true; }
            if (e.Key == Key.Up) { command.Move(-1); e.Handled = true; }
            if (e.Key == Key.Escape && w.Tab == PanelTab.Command) { e.Handled = true; w.Close_(); }
        };
    }

    public static UIElement Build(CapsuleWindow w)
    {
        var command = w.App.Command;
        var field = w.State.CommandField;
        field.CornerRadius = new CornerRadius(20);
        field.Padding = new Thickness(14, 0, 14, 0);
        var top = Ui.Row(10, Ui.Icon(Glyph.Search, 16, C.Secondary), field.Grow());
        var column = Ui.Column(8, top);
        if (command.Query.Trim().Length == 0)
        {
            var examples = new WrapPanel();
            foreach (var example in CommandModel.Examples)
            {
                var pill = Ui.Pill(example, () =>
                {
                    field.Text = example == "kill …" ? "kill " : example;
                    field.Box.CaretIndex = field.Text.Length;
                    CapsuleWindow.TakeKeyboard(field);
                });
                pill.Margin = new Thickness(0, 0, 6, 6);
                examples.Children.Add(pill);
            }
            column.Children.Add(examples);
            column.Children.Add(Ui.Text("Type an app's name, a calculation, a conversion, or something you copied. Enter does it, Esc leaves.", 11, color: C.Secondary, wrap: true));
        }
        else
        {
            var list = Ui.Column(2);
            for (var i = 0; i < command.Results.Count; i++)
            {
                var result = command.Results[i];
                var index = i;
                var armed = command.Armed == result.Id;
                UIElement icon = result.File is not null ? Ui.FileIconView(result.File, 24) : Ui.Icon(result.Glyph, 15).Size(24, 24);
                var text = Ui.Column(1, Ui.Semi(result.Title, 13),
                    Ui.Text(armed ? result.Confirm ?? result.Subtitle : result.Subtitle, 11, armed ? FontWeights.SemiBold : FontWeights.Normal, armed ? C.Amber : C.Secondary));
                var row = Ui.Box(Ui.Row(10, icon, text.Grow()), index == command.Selected ? C.Rgb(77, 141, 255, 0.5) : C.Clear, 10, 10, 5);
                list.Children.Add(row.OnClick(() => command.Select(index)));
            }
            var scroller = Ui.Scroll(list);
            column.Children.Add(scroller.Grow());
            // the chosen line stays in sight
            scroller.Loaded += (_, _) =>
            {
                if (command.Selected < list.Children.Count && list.Children[command.Selected] is FrameworkElement chosen) chosen.BringIntoView();
            };
        }
        return column;
    }
}
