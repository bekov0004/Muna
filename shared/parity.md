# One to one: every part of Muna for GNOME, on macOS and Windows

Muna for GNOME (`linux/`) is the reference. macOS and Windows must have the same functions, the same
settings (same names, same pages) and the same wording; each may use its own system's tools to do
them and to look better. This list is taken from the Linux code (`src/utils/widgetInfo.js`,
`prefsWindow.js`, `prefsUtilities.js`, `prefsGestures.js`, `src/widgets/*`). Go through it after
every change to a port.

✅ same as Linux · 🟡 there, but something of it is missing (said in the note) · ⬜ not yet · ➖ the
system does not allow it (the note says why and what is done instead)

## The capsule's widgets (Muna section)

| Widget (Linux id) | What it has on Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Media Player (`media`) | any player, cover, seek, lyrics, spectrum or waves effect in the album's colour, sideways swipe skips | 🟡 | 🟡 | Mac: Music and Spotify only (macOS closed "now playing" to other apps); effect colours not yet on either |
| Calendar (`calendar`) | days around today, events, next meeting card | ✅ | ✅ | |
| Mirror (`mirror`) | camera preview, the enlarged card | ✅ | ✅ | |
| Phone (`phonecard`) | the phone's screen in the capsule, as tall as the phone, QR to connect, out into a window | ⬜ | 🟡 | Windows: in the capsule, no taller card or window yet |
| Timer (`timer`) | countdown in the capsule | ✅ | ✅ | |
| Companion (`companion`) | eyes follow the pointer, sways to music, surprised by cards, sleeps | ✅ | ✅ | |
| Shortcuts (`shortcuts`) | favourite apps, 1 or 2 columns | ✅ | ✅ | |
| To-do (`todo`), Notes (`notes`) | same files | ✅ | ✅ | |

## The window of the menu-bar / tray icon (Linux: the top-bar button), its tabs

| Tab (Linux id) | What it has on Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Focus (`focus`) | Pomodoro and stopwatch with laps | ✅ | ✅ | |
| System (`system`) | processor, memory, temperature, graphics, uptime, graphs, alerts | 🟡 | 🟡 | |
| Network (`network`) | speeds with one graph of both, this session's traffic, address, speed test | 🟡 | 🟡 | no speed test, no session traffic on Windows |
| Disks (`disks`) | each disk: fullness, live read/write with graph, read/written since start, temperature, eject, open | ⬜ | ⬜ | |
| Power (`power`) | charge and history, busy programs, heat, power draw, adapter, battery health, devices' batteries | ⬜ | ⬜ | |
| Sound (`sound`) | output volume, system sounds, microphone, every app's volume and device | 🟡 | 🟡 | Mac: macOS has no per-app volume without an audio driver ➖; Windows: per-app volume not yet |
| Downloads (`downloads`) | files arriving with progress | ✅ | ✅ | |
| Input (`input`) | mouse and keyboard switches | ⬜ | 🟡 | Windows: in Controls |
| Windows (`windows`) | a picture of each screen and desktop: drag windows, zones, columns, rows, grid | 🟡 | ✅ | Mac: snapping only |
| Desktops (`workspaces`) | list, switch, new, send window to a new desktop, dynamic desktops, per monitor | ⬜ | 🟡 | Windows: inside the Windows tab |
| Reminders (`reminders`) | once, every day, weekdays | 🟡 | 🟡 | repeats not yet |
| AI Agents (`agents`) | working now, tokens 5 h and week, cards | 🟡 | ✅ | Mac: no Codex start, no tokens |
| Phone (`phone`) | screen, control, QR pairing, Muna Phone link | 🟡 | ✅ | Mac: picture once a second, no pairing, no link |
| Keep awake (`awake`) | for a while or until off, lid closed, icon and colour | 🟡 | 🟡 | lid closed needs admin rights on both |
| Displays (`displays`) | brightness of every monitor and keyboard light, night light, auto brightness, arrangement (drag, main, mirror, only one) | 🟡 | 🟡 | arranging by dragging not yet |
| Utilities (`utilities`) | every tool in one list, can be reordered and hidden | ⬜ | ⬜ | |
| Controls (`controls`) | switches for windows, mouse, keyboard, files, with counters | ⬜ | ✅ | |
| Quick toggles (`toggles`) | dark mode, keyboard light, microphone, trash, disks, hidden files, lock, screen | 🟡 | 🟡 | in Tools |

## The settings window

The same sections and pages in the same order: Essentials (General, Menu bar, Touchpad gestures,
Fingerprint, Monitor), Features (Overview, Music and media, System, Windows and desktops, Work, Files
and sharing, Capsule), Utilities (Command Bar, Quick panel, Quick toggles, Cleaning Mode,
Screenshot, Phone, Camera preview, Scratchpad, Color picker, Radial menu), Sound (Volume mixer,
Output switcher, Mute microphone), Dynamic Island (Widgets, Appearance, Gestures, Live Activities),
Tabs (Tray, Clipboard), Muna (About); a search, back and forward, a "Try it" button.

| | macOS | Windows |
|---|---|---|
| Sections, pages, search, Try it | ✅ | ⬜ (other pages) |
| Shortcuts set by pressing keys (Linux: shortcut-* keys) | ⬜ | ⬜ |
