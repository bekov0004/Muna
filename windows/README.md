# Muna for Windows

The capsule of Muna on Windows, drawn like Muna for GNOME. When closed, it shows the date · the
butterfly · the time in the middle of the top edge of each monitor. It opens under the pointer, or
with a click, into the same panel as on Linux.

| Part | What it does |
|---|---|
| **Muna** | A row of widgets, each some cells wide, on pages when they do not fit: media player (any app that shows in Windows' media overlay: Spotify, browsers, Media Player …; lyrics from lrclib.net as an option), calendar (Outlook's own calendar, and iCalendar links from Outlook on the web or Google), mirror (camera), timer, to-do, notes, shortcuts (apps), phone, companion |
| **Tray** | Files dropped on the capsule wait here: drag them out, open them, send them with LocalSend |
| **LocalSend** | Send files to several devices at once or to a saved group (Muna on Linux, Mac and Windows, the LocalSend apps); receive files (you accept each sending) |
| **Clipboard** | What you copied (text and files), with search, pins, notes, private items (Windows Hello), cleaned links; a click copies it again, files can be dragged out. A swipe past the top of the list makes it taller |
| **Alerts** | Other apps' notifications (a click opens the app), what Muna told you (sendings, received files, the timer, reminders, downloads, agents), warnings (busy processor, heat, full disk or memory, low battery) |
| **Command Bar** (Alt+Space) | Start apps, calculate, convert units, find what you copied, ;snippets, kill a process, ports, clean temporary files, search the web |
| **Quick panel** (Muna's tray icon) | Processor, memory, disk, battery and network with graphs; sound; displays (brightness, night light, the arrangement); an Android phone (live picture, touches, typing; pairing over Wi-Fi with a QR code; Muna Phone's link); keep awake; focus timer and stopwatch; reminders; downloads; windows (a map of the screen with live pictures, all windows in columns, rows, a grid or main + side, one window snapped; desktops); AI agents (Claude Code and Codex, token counts); controls (focus follows the mouse, snapping, animations, mouse acceleration, hidden files …); tools (Wi-Fi, Bluetooth, night light, airplane mode, microphone, dark mode, screenshot, colour picker, empty the bin, eject disks, screen off, lock, scratchpad, cleaning mode) |
| **Readings and the Muna bar** | Each chosen reading (processor, temperature, graphics, memory, battery, network, disks, power) as an icon with its value in the notification area; the Muna bar across the top of other or all monitors (desktops, readings, sound, battery; hides never, when a window touches it, or always); hiding the taskbar; separate desktops for every monitor (Ctrl+Win+arrows follow the pointer) |
| **Touchpad gestures** | Three and four fingers (the live app switcher is Windows' own Alt+Tab), pinches, resting the fingers, one finger along the edges (brightness, volume), double taps and holds at the edges; each does what you choose. Set Windows' own three- and four-finger gestures to "Nothing" first |
| **Keys** | Alt+Space Command Bar, Ctrl+Alt+Space radial menu, Ctrl+Alt+1 … 5 the sections |
| **Settings** (the gear) | Linux's pages, grouped, with a search: general, appearance (size, height, spacing, colour, shadow …), live activities, widgets, touchpad gestures, calendar, phone, readings and bars, keys and radial menu, tools, AI agents, Windows Hello, LocalSend, clipboard and tray, snippets |

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

The first time Muna receives files (or Muna Phone connects), Windows asks whether it may use the
network: allow it on private networks, or other computers and the phone cannot reach you.
`install.ps1 -Firewall` adds those rules itself; it asks for administrator rights once.

To remove Muna, use Settings → Apps, or `windows\scripts\uninstall.cmd`. Your data stays unless you
add `-Purge`.

## Development

- `MunaCore/`: the logic, with no screen and no Windows-only code. It covers the data files,
  LocalSend (HTTP, HTTPS server and client, multicast, the sending session, groups), the layout,
  the Command Bar engine, link cleaning, snippets, lyrics, iCalendar, Claude Code tasks, terminal
  sessions, token counts, adb parsing, the QR code, Muna Phone's handshake, the H.264 stream cut into
  pictures, touchpad gestures, tiling, toasts and night light. Tests are in `MunaCore.Tests/` and run on Linux: `scripts/build.sh test`.
- `Muna/`: the WPF app, written as code rather than XAML (pages are drawn again when their model
  changes, like SwiftUI views). It compiles on Linux (`scripts/build.sh build`), but runs only on
  Windows.
- `scripts/build.sh publish` makes `publish/Muna.exe` on Linux.
