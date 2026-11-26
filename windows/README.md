# Muna for Windows

The capsule of Muna on Windows, drawn like Muna for GNOME. When closed, it shows the date · the
butterfly · the time in the middle of the top edge of each monitor. It opens under the pointer, or
with a click, into the same panel as on Linux.

| Part | What it does |
|---|---|
| **Muna** | A row of widgets, each some cells wide, on pages when they do not fit: media player (any app that shows in Windows' media overlay: Spotify, browsers, Media Player …; lyrics from lrclib.net as an option), calendar (an iCalendar link from Outlook or Google), mirror (camera), timer, to-do, notes, shortcuts (apps), companion |
| **Tray** | Files dropped on the capsule wait here: drag them out, open them, send them with LocalSend |
| **LocalSend** | Send files to several devices at once or to a saved group (Muna on Linux, Mac and Windows, the LocalSend apps); receive files (you accept each sending) |
| **Clipboard** | What you copied (text and files), with search, pins, notes, private items (Windows Hello), cleaned links; a click copies it again, files can be dragged out |
| **Alerts** | What Muna told you lately (sendings, received files, the timer, reminders, downloads, agents) |
| **Command Bar** (Alt+Space) | Start apps, calculate, convert units, find what you copied, ;snippets, kill a process, ports, clean temporary files, search the web |
| **Quick panel** (Muna's tray icon) | Processor, memory, disk, battery and network with graphs; sound (volume, microphone, output); displays (brightness, the arrangement); an Android phone over adb; keep awake; focus timer and stopwatch; reminders; downloads; window snapping; AI agents; tools (dark mode, screenshot, colour picker, empty the bin, screen off, lock, scratchpad, cleaning mode) |
| **Keys** | Alt+Space Command Bar, Ctrl+Alt+Space radial menu, Ctrl+Alt+1 … 5 the sections |
| **Settings** (the gear) | How the capsule opens and closes, its look, the widgets and their order and width, the calendar link, LocalSend, clipboard, tray, snippets, keys, open at login |

While something runs, it takes the sides of the closed capsule (a sending, the timer, the music).
When something ends while the capsule is closed, a short card says so and the Alerts section keeps
it. [`../shared/features.md`](../shared/features.md) lists every Linux feature and how far Windows
has got with each.

The data files are the same as Muna on Linux and macOS ([`../shared/formats`](../shared/formats)).
They live in `%APPDATA%\Muna`.

## Install

Needs Windows 10 (2004) or 11, and the .NET 10 SDK to build:

```powershell
winget install Microsoft.DotNet.SDK.10        # once; then open a new terminal
git clone https://github.com/bekov0004/Muna.git
cd Muna
windows\scripts\install.cmd                   # or: scripts/install.sh from Git Bash
```

It builds `Muna.exe` (one file, nothing else to install), puts it in
`%LOCALAPPDATA%\Programs\Muna`, adds it to the Start menu and to the apps that open at sign-in,
then starts it. It needs no administrator rights.

The first time Muna receives files, Windows asks whether it may use the network: allow it on
private networks, or other computers cannot send to you. `install.ps1 -Firewall` adds that rule
itself; it asks for administrator rights once.

To remove Muna, use Settings → Apps, or `windows\scripts\uninstall.cmd`. Your data stays unless you
add `-Purge`.

## Development

- `MunaCore/`: the logic, with no screen and no Windows-only code. It covers the data files,
  LocalSend (HTTP, HTTPS server and client, multicast, the sending session, groups), the layout,
  the Command Bar engine, link cleaning, snippets, lyrics, iCalendar, Claude Code tasks, terminal
  sessions and adb parsing. Tests are in `MunaCore.Tests/` and run on Linux: `scripts/build.sh test`.
- `Muna/`: the WPF app, written as code rather than XAML (pages are drawn again when their model
  changes, like SwiftUI views). It compiles on Linux (`scripts/build.sh build`), but runs only on
  Windows.
- `scripts/build.sh publish` makes `publish/Muna.exe` on Linux.
