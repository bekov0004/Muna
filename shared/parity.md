# One to one: every part of Muna for GNOME, on macOS and Windows

Muna for GNOME (`linux/`) is the reference. macOS and Windows must have the same functions, the same
settings (same names, same pages) and the same wording; each may use its own system's tools to do
them and to look better. This list is taken from the Linux code (`src/utils/widgetInfo.js`,
`prefsWindow.js`, `prefsUtilities.js`, `prefsGestures.js`, `src/widgets/*`). Go through it after
every change to a port.

✅ same as Linux · 🟡 there, but something of it is missing (said in the note) · ⬜ not yet · ➖ the
system does not allow it (the note says why and what is done instead)

Neither port has been run on its system yet: ✅ means built (Windows) or written and syntax-checked
(macOS app), with the logic tested in MunaCore; the user's runs decide.

## The capsule's widgets (Muna section)

| Widget (Linux id) | What it has on Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Media Player (`media`) | any player, cover, seek, lyrics, spectrum or waves in the album's colour, sideways swipe skips | 🟡 | ✅ | macOS gives "now playing" of other players to Apple's apps only: Music and Spotify ➖ |
| Calendar (`calendar`) | days around today, events, next meeting card | ✅ | ✅ | Windows: Outlook and .ics links |
| Mirror (`mirror`) | camera preview, the enlarged card | ✅ | ✅ | |
| Phone (`phonecard`) | the phone's screen in the capsule, as tall as the phone, QR to connect, out into a window | 🟡 | 🟡 | in the capsule with control; the taller card and the window not yet |
| Timer (`timer`) | countdown in the capsule | ✅ | ✅ | |
| Companion (`companion`) | eyes follow the pointer, sways to music, surprised by cards, sleeps | ✅ | ✅ | |
| Shortcuts (`shortcuts`) | favourite apps | ✅ | ✅ | |
| To-do (`todo`), Notes (`notes`) | same files | ✅ | ✅ | |

## The window of the menu-bar / tray icon (Linux: the top-bar button), its tabs

All eighteen tabs, in Linux's order, chosen, hidden and ordered in Settings → Menu bar.

| Tab (Linux id) | What it has on Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Focus (`focus`) | Pomodoro and stopwatch with laps | ✅ | ✅ | |
| System (`system`) | processor, memory, temperature, graphics, uptime, graphs, chosen blocks | ✅ | ✅ | Mac: temperatures of Apple silicon (IOKit HID), graphics (IOAccelerator) |
| Network (`network`) | speeds and graph, this session's traffic, address, speed test | ✅ | ✅ | |
| Disks (`disks`) | each disk: fullness, live read/write, since start, temperature, eject, open | 🟡 | 🟡 | no disk temperature |
| Power (`power`) | charge and history, busy programs, heat, power draw, adapter, health, devices' batteries | ✅ | 🟡 | Windows: no batteries of Bluetooth devices yet |
| Sound (`sound`) | output volume, system sounds, microphone, every app's volume | 🟡 | ✅ | macOS has no per-app volume without an audio driver ➖ |
| Downloads (`downloads`) | files arriving with progress | ✅ | ✅ | |
| Input (`input`) | mouse and keyboard switches | ✅ | ✅ | Mac: some take effect at the next login (macOS) |
| Windows (`windows`) | a picture of each screen with its windows: drag, zones, columns, rows, grid, main + side | ✅ | ✅ | Mac: pictures need Screen Recording |
| Desktops (`workspaces`) | list, switch, new, send a window to a new desktop, per monitor | 🟡 | ✅ | macOS lets no app create a desktop or move a window to one ➖ (Mission Control does) |
| Reminders (`reminders`) | the butterfly's reminders: once, every day, weekdays | ✅ | ✅ | |
| AI Agents (`agents`) | working now, tokens 5 h and week, cards, Codex | ✅ | ✅ | |
| Phone (`phone`) | live screen, control, QR pairing, Muna Phone link, dark screen | ✅ | ✅ | |
| Keep awake (`awake`) | for a while or until off, lid closed, icon and colour | 🟡 | 🟡 | lid closed needs administrator rights ➖; the icon in the menu bar / tray not yet |
| Displays (`displays`) | brightness of every monitor and keyboard light, night light, arrangement (drag, main, mirror, only one) | 🟡 | 🟡 | arranging by dragging, main, mirror not yet; Windows has no keyboard light API ➖ |
| Utilities (`utilities`) | every tool in one list, reordered and hidden | 🟡 | 🟡 | the list; reordering and hiding not yet |
| Controls (`controls`) | switches for windows, mouse, keyboard, files, with counters | ✅ | ✅ | |
| Quick toggles (`toggles`) | dark mode, keyboard light, microphone, trash, disks, hidden files, lock, screen | ✅ | ✅ | also Wi-Fi, Bluetooth, night light, airplane on Windows |

## The capsule itself

| | macOS | Windows | Note |
|---|---|---|---|
| Live Activities and their cards (music, timer, meeting, tray, downloads, how long) | ✅ | ✅ | |
| Capsule gestures (swipe down opens, up closes, invert, sideways skips, middle click) | ✅ | ✅ | |
| Appearance (size, height, padding, spacing, dividers, width, radius, transparency, shadow, butterfly flapping) | ✅ | ✅ | |
| Cards: keyboard layout, Caps Lock, system alerts with thresholds, agents | ✅ | ✅ | |
| Alerts: other apps' notifications | ✅ | ✅ | Mac: Full Disk Access |
| Two-finger pull makes lists taller | ➖ | ✅ | Mac: the lists are tall and scroll |
| Touchpad gestures everywhere (3/4 fingers, pinches, holds, edges) | ✅ | ✅ | the system's own 3/4-finger gestures must be turned off |
| Muna bar, hiding the top bar, desktops per monitor | ✅ | ✅ | Mac: macOS's own menu bar on every screen; hiding it; "Displays have separate Spaces" |

## The settings window

| | macOS | Windows |
|---|---|---|
| Linux's sections and pages, search, back and forward, Try it | ✅ | ✅ |
| Shortcuts set by pressing keys (Linux's shortcut-* keys) | ✅ | ✅ |
| Feature overview with bundles and topics | ✅ | ✅ |
| Light, dark or the system's look for the window | ✅ | ⬜ (dark only) |
