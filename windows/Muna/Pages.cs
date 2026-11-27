using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Muna.Core;

namespace Muna;

/// <summary>LocalSend: the files to send, the devices and groups to send them to, the transfers; and
/// what another device wants to send here. Works with Muna on Linux and Mac and with the LocalSend apps.</summary>
public static class LocalSendPage
{
    public static void Wire(CapsuleWindow w)
    {
        w.State.GroupName.Submitted += () => SaveGroup(w);
        w.State.LocalSendText.Submitted += () => KeepText(w, true);
    }

    /// <summary>Ends writing the text; <paramref name="keep"/>: it becomes the message to send.</summary>
    static void KeepText(CapsuleWindow w, bool keep)
    {
        w.State.WritingText = false;
        if (keep) w.App.LocalSend.Session.SetText(w.State.LocalSendText.Text);
        w.Invalidate();
    }

    public static UIElement Build(CapsuleWindow w)
    {
        var localSend = w.App.LocalSend;
        if (localSend.Incoming is { } incoming) return IncomingCard(w, incoming);
        if (localSend.Message is { } message) return MessageCard(w, message.From, message.Text);
        return Ui.Column(12, Basket(w), Devices(w));
    }

    // --- what comes in ---------------------------------------------------------------------------

    /// <summary>A text someone sent: who, the text, Copy, and Open when it is one link.</summary>
    static UIElement MessageCard(CapsuleWindow w, string from, string text)
    {
        var localSend = w.App.LocalSend;
        var words = Ui.Text(text, 13, wrap: true);
        words.MaxHeight = 90;
        words.TextTrimming = TextTrimming.CharacterEllipsis;
        var card = Ui.Box(Ui.Row(14, Ui.Box(Ui.Icon(Glyph.Edit, 22, C.Accent), C.Tile, 28).Size(56, 56),
            Ui.Column(4, Ui.Semi($"{from} sent a text", 15), words).Grow()), C.Tile, 18, 14, 14);
        var buttons = Ui.Row(8, Ui.Spacer());
        var link = text.Trim();
        if (Uri.TryCreate(link, UriKind.Absolute, out var uri) && (uri.Scheme == "http" || uri.Scheme == "https") && !link.Contains(' '))
            buttons.Children.Add(Ui.Pill("Open", () => { CapsuleViews.Launch(link); localSend.DismissMessage(); }));
        buttons.Children.Add(Ui.Pill("Copy", () => { ClipboardModel.SetText(text); localSend.DismissMessage(); }, accent: true));
        buttons.Children.Add(Ui.Pill("OK", localSend.DismissMessage));
        return Ui.Column(10, Ui.Caption($"From {from}"), card, buttons);
    }

    static UIElement IncomingCard(CapsuleWindow w, IncomingTransfer incoming)
    {
        var localSend = w.App.LocalSend;
        var count = incoming.Files.Count;
        var files = $"{count} file{(count == 1 ? "" : "s")}";
        var (title, glyph, tint) = incoming.State switch
        {
            IncomingState.Asking => ($"{incoming.Sender.Alias} wants to send {files} ({Ui.SizeText(incoming.Total)})", Glyph.Download, C.Accent),
            IncomingState.Receiving => ($"Receiving {files}…", Glyph.Download, C.Accent),
            IncomingState.Done => ($"Received {files} · in {System.IO.Path.GetFileName(incoming.Folder)}", Glyph.CheckCircle, C.Ok),
            IncomingState.Declined => ("Declined", Glyph.Close, C.Warning),
            _ => (incoming.Error ?? "The transfer stopped", Glyph.Close, C.Warning),
        };
        var names = string.Join(", ", incoming.Files.Take(4).Select(f => f.Name)) + (count > 4 ? " …" : "");
        var text = Ui.Column(4, Ui.Semi(title, 15), Ui.Text(names, 12, color: C.Secondary, lines: 2));
        if (incoming.State == IncomingState.Receiving)
        {
            text.Children.Add(new Live(() => ProgressBar(incoming.Received, incoming.Total, 0), TimeSpan.FromMilliseconds(200)));
            text.Children.Add(new Live(() => Ui.Text($"{Ui.SizeText(incoming.Received)} of {Ui.SizeText(incoming.Total)}", 11, color: C.Secondary), TimeSpan.FromMilliseconds(250)));
        }
        var card = Ui.Box(Ui.Row(14, Ui.Box(Ui.Icon(glyph, 24, tint), C.Tile, 28).Size(56, 56), text.Grow()), C.Tile, 18, 14, 14);
        var buttons = Ui.Row(8, Ui.Spacer());
        switch (incoming.State)
        {
            case IncomingState.Asking:
                buttons.Children.Add(Ui.Pill("Decline", localSend.Decline));
                buttons.Children.Add(Ui.Pill("Accept", localSend.Accept, accent: true));
                break;
            case IncomingState.Done:
                buttons.Children.Add(Ui.Pill("Show in Explorer", localSend.ShowReceived, accent: true));
                buttons.Children.Add(Ui.Pill("OK", localSend.DismissIncoming));
                break;
            case IncomingState.Failed or IncomingState.Declined:
                buttons.Children.Add(Ui.Pill("OK", localSend.DismissIncoming));
                break;
        }
        return Ui.Column(10, Ui.Caption($"From {incoming.Sender.Alias}"), card, buttons);
    }

    public static UIElement ProgressBar(long done, long total, double width)
    {
        var share = total > 0 ? Math.Clamp((double)done / total, 0, 1) : 0;
        var grid = new Grid { Height = 4 };
        if (width > 0) grid.Width = width;
        grid.Children.Add(new Rectangle { RadiusX = 2, RadiusY = 2, Fill = C.White(0.14) });
        var fill = new Rectangle { RadiusX = 2, RadiusY = 2, Fill = C.Accent, HorizontalAlignment = HorizontalAlignment.Left };
        grid.Children.Add(fill);
        grid.SizeChanged += (_, _) => fill.Width = grid.ActualWidth * share;
        return grid;
    }

    // --- the files to send ---------------------------------------------------------------------------

    static long SizeOf(string path)
    {
        try { return File.Exists(path) ? new FileInfo(path).Length : 0; } catch { return 0; }
    }

    static UIElement Basket(CapsuleWindow w)
    {
        var session = w.App.LocalSend.Session;
        var ui = w.State;
        if (ui.WritingText)
        {
            // writing the text message: Enter keeps it, Esc or Cancel leaves it as it was
            return Ui.Column(6,
                Ui.Caption("Text", Ui.Pill("Cancel", () => KeepText(w, false)), Ui.Pill("Done", () => KeepText(w, true), accent: true)),
                ui.LocalSendText,
                Ui.Text("Enter keeps it; then choose who gets it. Muna and LocalSend show it at once.", 11, color: C.Secondary));
        }
        var basket = session.Basket;
        var total = basket.Sum(SizeOf);
        var text = session.Text.Trim();
        var caption = Ui.Caption(basket.Count == 0 ? (text.Length > 0 ? "Text" : "Files") : $"Files · {basket.Count} · {Ui.SizeText(total)}{(text.Length > 0 ? " · Text" : "")}",
            Ui.Pill("Text", () => { ui.LocalSendText.Text = session.Text; ui.WritingText = true; w.Invalidate(); }),
            w.App.Tray.Files.Count > 0 ? Ui.Pill("Add from Tray", () => session.Offer(w.App.Tray.Files.ToList())) : null,
            Ui.Pill("Choose…", () => Choose(session)),
            basket.Count > 0 || text.Length > 0 ? Ui.Pill("Clear", () => { session.SetText(""); session.ClearBasket(); }) : null);
        UIElement content;
        if (basket.Count == 0 && text.Length == 0)
        {
            content = Ui.Text("Drop files on the capsule while this page is open, choose them, or write a text", 11, color: C.Secondary).Size(height: 28);
        }
        else
        {
            var row = Ui.Row(6);
            if (text.Length > 0)
            {
                var words = Ui.Semi($"“{string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))}”", 11);
                words.MaxWidth = 180;
                words.TextTrimming = TextTrimming.CharacterEllipsis;
                var chip = Ui.Row(6, Ui.Icon(Glyph.Edit, 12, C.Secondary), words, Ui.Text("Text", 10, color: C.Secondary),
                                  Ui.IconButton(Glyph.Close, () => session.SetText("")));
                row.Children.Add(Ui.Box(chip, C.Tile, 12).Size(height: 24).WithPadding(8, 0, 4, 0).OnClick(() => { ui.LocalSendText.Text = session.Text; ui.WritingText = true; w.Invalidate(); }));
            }
            foreach (var file in basket)
            {
                var name = Ui.Semi(System.IO.Path.GetFileName(file), 11);
                name.MaxWidth = 140;
                var chip = Ui.Row(6, Ui.FileIconView(file, 16), name, Ui.Text(Ui.SizeText(SizeOf(file)), 10, color: C.Secondary),
                                  Ui.IconButton(Glyph.Close, () => session.Remove(file)));
                row.Children.Add(Ui.Box(chip, C.Tile, 12).Margin(0, 0, 0, 0).Size(height: 24).WithPadding(8, 0, 4, 0));
            }
            content = Ui.Scroll(row, horizontal: true).Size(height: 28);
        }
        return Ui.Column(6, caption, content);
    }

    static Border WithPadding(this Border border, double l, double t, double r, double b)
    {
        border.Padding = new Thickness(l, t, r, b);
        return border;
    }

    static void Choose(SendSession session)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Multiselect = true, Title = "Files to send" };
        if (dialog.ShowDialog() == true) session.Offer(dialog.FileNames);
    }

    // --- devices, groups, transfers ------------------------------------------------------------------

    static UIElement Devices(CapsuleWindow w)
    {
        var session = w.App.LocalSend.Session;
        if (session.Phase is SessionPhase.Sending or SessionPhase.Done) return Transfers(w);
        if (w.State.NamingGroup) return Naming(w);
        return Ui.Column(6, DevicesCaption(w), DeviceList(w));
    }

    static UIElement DevicesCaption(CapsuleWindow w)
    {
        var localSend = w.App.LocalSend;
        var session = localSend.Session;
        var ui = w.State;
        var chosen = session.SelectedDevices.Count;
        if (chosen > 0)
        {
            var group = session.ActiveGroup;
            UIElement groupPill;
            if (group is not null)
            {
                var confirming = ui.ConfirmDeleteGroup == group.Id;
                groupPill = Ui.Pill(confirming ? "Delete it?" : "Delete group", () =>
                {
                    if (confirming) { ui.ConfirmDeleteGroup = null; session.DeleteGroup(group.Id); }
                    else { ui.ConfirmDeleteGroup = group.Id; w.Invalidate(); }
                }, active: confirming);
            }
            else
            {
                groupPill = Ui.Pill("Save as group", () =>
                {
                    ui.GroupName.Text = "";
                    ui.GroupNameError = "";
                    ui.NamingGroup = true;
                    w.Invalidate();
                });
            }
            return Ui.Caption(group is not null ? $"{group.Name} · {chosen} of {group.Members.Count} here" : $"Send to · {chosen} chosen",
                Ui.Pill("Clear", session.ClearSelection), groupPill,
                Ui.Pill(!session.HasContent ? "Add files or a text" : $"Send to {chosen}", () => session.Send(), accent: session.HasContent, disabled: !session.HasContent));
        }
        return Ui.Caption(session.Phase == SessionPhase.Scan ? "Looking for devices…" : "Send to",
            session.Devices.Count >= 2 ? Ui.Pill("All", session.SelectAll) : null,
            Ui.Pill("Refresh", () => session.Refresh(true)),
            Ui.Pill(localSend.Receiving ? "Receiving: on" : "Receiving: off", () => localSend.SetReceiving(!localSend.Receiving), active: localSend.Receiving));
    }

    static UIElement DeviceList(CapsuleWindow w)
    {
        var localSend = w.App.LocalSend;
        var session = localSend.Session;
        var ui = w.State;
        if (session.Devices.Count == 0)
        {
            var column = Ui.Column(2, Ui.Text(session.Phase == SessionPhase.Scan
                ? "Looking on this network… (on the other side: Muna or LocalSend, with receiving on)"
                : "No devices found. The others need receiving on and the same network", 11, color: C.Secondary, lines: 2).Size(height: 30));
            if (localSend.ReceiveProblem is { } problem)
                column.Children.Add(Ui.Text($"Receiving here: {problem}", 11, color: C.Warning));
            return column;
        }
        var row = Ui.Row(8);
        foreach (var group in session.Groups)
        {
            var here = group.Presence(session.Devices).Found.Count;
            var active = session.ActiveGroupId == group.Id;
            row.Children.Add(Tile(active ? Glyph.Check : Glyph.Network, group.Name, $"{here} of {group.Members.Count} here", active, false, true,
                () => { ui.ConfirmDeleteGroup = null; session.SelectGroup(group); }));
        }
        foreach (var device in session.Devices)
        {
            var selected = session.IsSelected(device);
            row.Children.Add(Tile(selected ? Glyph.Check : DeviceGlyph(device), device.Alias, device.DeviceModel.Length == 0 ? "LocalSend" : device.DeviceModel,
                selected, device.IsMuna, false, () => { ui.ConfirmDeleteGroup = null; session.Toggle(device); }));
        }
        return Ui.Scroll(row, horizontal: true).Size(height: 44);
    }

    static string DeviceGlyph(Device device) => device.DeviceType switch
    {
        "mobile" => Glyph.Phone,
        "web" => Glyph.Globe,
        "headless" or "server" => Glyph.Disk,
        _ => Glyph.Monitor,
    };

    /// <summary>A device or a group to choose.</summary>
    static UIElement Tile(string glyph, string name, string detail, bool selected, bool muna, bool dashed, Action action)
    {
        var color = muna ? C.Muna : C.Accent;
        var circle = Ui.Box(Ui.Icon(glyph, 11, selected ? Brushes.White : color), selected ? C.Accent : muna ? C.Rgb(179, 154, 255, 0.22) : C.Rgb(77, 141, 255, 0.22), 13).Size(26, 26);
        var text = Ui.Column(0, Ui.Semi(name, 12), Ui.Text(detail, 10, color: muna ? C.Muna : C.Secondary));
        text.MinWidth = 60;
        var tile = Ui.Box(Ui.Row(7, circle, text), selected ? C.Rgb(77, 141, 255, 0.34) : C.Tile, 18).WithPadding(5, 4, 12, 4);
        if (dashed)
        {
            tile.BorderBrush = C.White(0.18);
            tile.BorderThickness = new Thickness(1);
        }
        return tile.OnClick(action);
    }

    static UIElement Naming(CapsuleWindow w)
    {
        var session = w.App.LocalSend.Session;
        var ui = w.State;
        var names = session.SelectedDevices.Select(d => d.Alias).ToList();
        ui.GroupName.Placeholder = "Name, for example: Office";
        var column = Ui.Column(6,
            Ui.Caption($"New group · {names.Count} device{(names.Count == 1 ? "" : "s")}",
                Ui.Pill("Cancel", () => { ui.NamingGroup = false; w.Invalidate(); }),
                Ui.Pill("Save", () => SaveGroup(w), accent: true)),
            ui.GroupName,
            Ui.Text(string.Join(", ", names), 11, color: C.Secondary));
        if (ui.GroupNameError.Length > 0) column.Children.Add(Ui.Text(ui.GroupNameError, 11, color: C.Warning));
        return column;
    }

    static void SaveGroup(CapsuleWindow w)
    {
        var ui = w.State;
        var name = ui.GroupName.Text.Trim();
        if (name.Length == 0)
        {
            ui.GroupNameError = "Write a name first";
        }
        else
        {
            try
            {
                w.App.LocalSend.Session.SaveGroup(name);
                ui.NamingGroup = false;
            }
            catch (GroupException e)
            {
                ui.GroupNameError = e.Message;
            }
        }
        w.Invalidate();
    }

    static UIElement Transfers(CapsuleWindow w)
    {
        var session = w.App.LocalSend.Session;
        var all = session.Transfers;
        var counted = all.Where(t => t.Phase != TransferPhase.Missing).ToList();
        var finished = counted.Count(t => t.Phase is not (TransferPhase.Waiting or TransferPhase.Sending));
        var left = all.Count(t => t.Phase is TransferPhase.Failed or TransferPhase.Missing);
        UIElement caption = session.Phase == SessionPhase.Sending
            ? Ui.Caption(all.Count == 1 ? $"Sending to {all[0].Name}" : $"Sending · {finished} of {counted.Count} done", Ui.Pill("Cancel", session.Cancel))
            : Ui.Caption(session.Message,
                left > 0 ? Ui.Pill(all.Count == 1 ? "Try again" : $"Try again ({left})", () => session.RetryFailed(), accent: true) : null,
                Ui.Pill("OK", session.Dismiss));
        var row = Ui.Row(8);
        foreach (var transfer in all) row.Children.Add(TransferTile(transfer));
        return Ui.Column(6, caption, Ui.Scroll(row, horizontal: true).Size(height: 52));
    }

    /// <summary>How far a sending to one device got.</summary>
    static UIElement TransferTile(Transfer transfer)
    {
        var (glyph, tint) = transfer.Phase switch
        {
            TransferPhase.Waiting => (Glyph.More, C.Accent),
            TransferPhase.Sending => (Glyph.Up, C.Accent),
            TransferPhase.Done => (Glyph.Check, C.Ok),
            TransferPhase.Failed => (Glyph.Warning, C.Warning),
            _ => (Glyph.Wifi, C.Warning),
        };
        var detail = transfer.Phase switch
        {
            TransferPhase.Waiting => "Waiting to accept…",
            TransferPhase.Sending => $"{(transfer.Total > 0 ? 100 * transfer.Sent / transfer.Total : 0)}% · {Ui.SizeText(transfer.Sent)}",
            TransferPhase.Done => "Received",
            TransferPhase.Failed => transfer.Message,
            _ => "Not on the network",
        };
        var text = Ui.Column(2, Ui.Semi(transfer.Name, 12), Ui.Text(detail, 10, color: C.Secondary));
        if (transfer.Phase is TransferPhase.Waiting or TransferPhase.Sending) text.Children.Add(ProgressBar(transfer.Sent, transfer.Total, 90));
        var tintSoft = new SolidColorBrush(((SolidColorBrush)tint).Color) { Opacity = 0.2 };
        var circle = Ui.Box(Ui.Icon(glyph, 11, tint), tintSoft, 13).Size(26, 26);
        return Ui.Box(Ui.Row(7, circle, text), C.Tile, 22).WithPadding(5, 4, 14, 4);
    }
}

/// <summary>The clipboard history: a click copies an item again (then Ctrl+V pastes it); pinned items stay.</summary>
public static class ClipboardPage
{
    public static void Wire(CapsuleWindow w)
    {
        var ui = w.State;
        ui.ClipboardSearch.Box.TextChanged += (_, _) => w.Invalidate();
        ui.ClipNote.Submitted += () =>
        {
            var item = w.App.Clipboard.Items.FirstOrDefault(i => i.Id == ui.NoteForClip);
            if (item is not null) w.App.Clipboard.SetNote(item, ui.ClipNote.Text);
            ui.NoteForClip = null;
            w.Invalidate();
        };
    }

    public static UIElement Build(CapsuleWindow w)
    {
        var clipboard = w.App.Clipboard;
        var ui = w.State;
        ui.ClipboardSearch.Placeholder = "Search what you copied";
        var words = ui.ClipboardSearch.Text.ToLowerInvariant().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var shown = words.Length == 0 ? clipboard.Items : clipboard.Items.Where(i => words.All(i.SearchText.ToLowerInvariant().Contains)).ToList();
        var top = Ui.Row(8, ui.ClipboardSearch.Grow());
        if (clipboard.Items.Any(i => !i.Saved)) top.Children.Add(Ui.Pill("Clear", clipboard.Clear));
        UIElement body;
        if (shown.Count == 0)
        {
            body = Ui.Text(clipboard.Items.Count == 0 ? "What you copy shows up here" : "Nothing matches", 12, color: C.Secondary)
                .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        }
        else
        {
            var list = new VirtualizingStackPanel();
            foreach (var item in shown.Take(200)) list.Children.Add(Row(w, item));
            body = Ui.Scroll(list);
        }
        return Ui.Column(8, top, body.Grow());
    }

    static UIElement Row(CapsuleWindow w, ClipItem item)
    {
        var clipboard = w.App.Clipboard;
        var privacy = w.App.Privacy;
        var ui = w.State;
        var hidden = item.IsPrivate && !privacy.Unlocked;
        UIElement icon, text;
        if (item.Files is { Count: > 0 } files)
        {
            var first = TrayStore.PathOf(files[0]) ?? files[0];
            icon = Ui.FileIconView(first, 18);
            var name = System.IO.Path.GetFileName(first);
            text = Ui.Text(files.Count == 1 ? name : $"{name} and {files.Count - 1} more", 12);
        }
        else
        {
            icon = Ui.Icon(Glyph.Document, 11, C.Secondary).Size(18);
            text = Ui.Text(hidden ? "Private · Windows Hello" : (item.Text ?? "").Replace("\r", " ").Replace("\n", " "), 12);
        }
        var row = Ui.Row(8, icon, text.Grow());
        if (ui.CopiedClip == item.Id) row.Children.Add(Ui.Semi("Copied", 10, C.Ok));
        row.Children.Add(Ui.IconButton(Glyph.Note, () =>
        {
            ui.ClipNote.Text = item.Note;
            ui.NoteForClip = ui.NoteForClip == item.Id ? null : item.Id;
            w.Invalidate();
        }, item.Note.Length == 0 ? C.Secondary : C.Accent, "Note"));
        row.Children.Add(Ui.IconButton(item.IsPrivate ? Glyph.Lock : Glyph.Unlock, () => { if (hidden) privacy.Unlock(); else clipboard.TogglePrivate(item); },
                                       item.IsPrivate ? C.Amber : C.Secondary, item.IsPrivate ? "Private" : "Make private"));
        row.Children.Add(Ui.IconButton(item.Saved ? Glyph.Unpin : Glyph.Pin, () => clipboard.TogglePinned(item), item.Saved ? C.Accent : C.Secondary, item.Saved ? "Unpin" : "Pin"));
        row.Children.Add(Ui.IconButton(Glyph.Close, () => clipboard.Remove(item)));
        var column = Ui.Column(4, row);
        if (ui.NoteForClip == item.Id)
        {
            ui.ClipNote.Placeholder = "A note for this item (Enter keeps it)";
            column.Children.Add(Ui.Detach(ui.ClipNote).Margin(26, 0, 0, 0));
        }
        else if (item.Note.Length > 0)
        {
            column.Children.Add(Ui.Text(item.Note, 11, color: C.Accent).Margin(26, 0, 0, 0));
        }
        var box = Ui.Box(column, C.Tile, 10, 10, 6).Margin(0, 0, 0, 4);
        void Copy()
        {
            if (hidden) { privacy.Unlock(); return; }
            clipboard.Copy(item);
            ui.CopiedClip = clipboard.Items.FirstOrDefault()?.Id;
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.2) };
            timer.Tick += (_, _) => { timer.Stop(); ui.CopiedClip = null; w.Invalidate(); };
            timer.Start();
        }
        if (item.Files is { Count: > 0 } && !hidden)
            DragOut.Attach(box, () => item.Files!.Select(TrayStore.PathOf).OfType<string>().ToArray(), Copy);
        else
            box.OnClick(Copy, C.White(0.1));
        return box;
    }
}
