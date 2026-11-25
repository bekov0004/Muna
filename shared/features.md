# What each platform has

Muna for GNOME (`linux/`) is the reference: every feature it has is listed here, with where the
other platforms stand. ✅ done · 🟡 partly · ⬜ not yet · ➖ cannot be done there (why in the note).
Change this table together with the code.

## The capsule

| Feature | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Closed capsule: date · butterfly · time | ✅ | ✅ | ⬜ | Mac with a notch: at rest just the notch (the menu bar stays free); date and time, or what runs, come out beside it on hover, activity or a card |
| Live activities in the closed capsule (music, timer, sending) | ✅ | ✅ | ⬜ | Linux has more (downloads, calendar, files) |
| Cards (a sending ended, time is up …) | ✅ | ✅ | ⬜ | |
| Opens on hover / click, delays, collapse when the pointer leaves | ✅ | ✅ | ⬜ | |
| Tabs Muna · Tray · LocalSend · Clipboard · Alerts, page dots, gear | ✅ | ✅ | ⬜ | |
| Width in cells of 44, pages of widgets | ✅ | ✅ | ⬜ | same rules (`PanelLayout`, tested against Linux) |
| Files dropped on the capsule | ✅ | ✅ | ⬜ | |
| Capsule on several monitors | ✅ | ✅ | ⬜ | Mac: every screen, the main one, or the built-in one with the notch (Settings → General → Screens) |
| Command Bar (apps, calculator, converter, clipboard search, snippets …) | ✅ | ✅ | ⬜ | Mac: apps, calculator, units, clipboard, web search, ;snippets, kill, ports, clean (~/Library/Caches), scratch (⌥Space) |
| Keyboard shortcuts for every section | ✅ | ✅ | ⬜ | Mac: ⌥Space Command Bar, ⌃⌥1–5 the sections (can be switched off) |
| Two-finger pull makes lists taller | ✅ | ➖ | ⬜ | Mac: the Clipboard and Alerts sections are tall and scroll |
| Appearance: size, corner radius, colour, opacity | ✅ | 🟡 | ⬜ | Mac: corner radius, opacity, animation speed; widths per widget |

## Widgets of the Muna section

| Widget | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Media player | ✅ | 🟡 | ⬜ | Mac: Music and Spotify only (macOS closed "now playing" to other apps); lyrics from lrclib.net (setting) |
| Calendar | ✅ | ✅ | ⬜ | Mac: EventKit |
| Mirror (camera) | ✅ | ✅ | ⬜ | with the enlarged card |
| Timer | ✅ | ✅ | ⬜ | |
| To-do, Notes | ✅ | ✅ | ⬜ | same files (`formats/data-files.md`) |
| Shortcuts (apps) | ✅ | ✅ | ⬜ | |
| Phone card | ✅ | ⬜ | ⬜ | adb works on a Mac too |
| Companion | ✅ | ✅ | ⬜ | |

## Sections

| Feature | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Tray | ✅ | ✅ | ⬜ | |
| LocalSend: send, several devices, groups, receive | ✅ | ✅ | ⬜ | Mac ↔ Linux to be tried on real machines |
| Clipboard history, pin, notes, search, clean links, private items, drag out | ✅ | ✅ | ⬜ | |
| Alerts | ✅ | 🟡 | ⬜ | macOS lets no app read other apps' notifications: Muna's own events only |

## The top-bar window (quick panel) and tools

| Feature | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Top-bar readings (CPU, temperature, memory, network …) | ✅ | 🟡 | ⬜ | Mac: CPU and memory next to Muna's menu-bar item (setting); no temperature (macOS hides the sensors) |
| System, Network, Disks, Power, Sound widgets | ✅ | ✅ | ⬜ | Mac quick panel: processor and memory with graphs, disk, battery, uptime, network; sound (volume, mute, output, microphone) |
| Displays (brightness, arrangement) | ✅ | ⬜ | ⬜ | |
| Keep awake | ✅ | ✅ | ⬜ | Mac: IOPMAssertion, for a while or until off, screen on or not (no "lid closed": needs admin rights) |
| Quick toggles, Utilities, Controls | ✅ | 🟡 | ⬜ | Mac: dark mode, screenshot, colour picker, empty trash, screen off, eject disks |
| Focus (Pomodoro, stopwatch) | ✅ | ✅ | ⬜ | same focus.json |
| Downloads | ✅ | ✅ | ⬜ | |
| Windows (snapping), Desktops | ✅ | 🟡 | ⬜ | Mac: halves, quarters, thirds, maximize, centre, next screen (Accessibility permission); desktops are macOS's own Spaces |
| Reminders (the butterfly) | ✅ | ✅ | ⬜ | a card in the capsule and a sound |
| AI agents (Claude Code, Codex) | ✅ | 🟡 | ⬜ | Mac: Claude Code tasks, questions in the capsule, agents window, plan limits; not yet: Codex, sessions run in a terminal |
| Radial menu, colour picker, cleaning mode, scratchpad | ✅ | 🟡 | ⬜ | Mac: colour picker, cleaning mode, scratchpad; no radial menu yet |

## The system

| Feature | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Settings window | ✅ | 🟡 | ⬜ | Mac: general, appearance, screens, shortcuts, widgets, LocalSend, clipboard, tray, snippets |
| Touchpad gestures (3/4 fingers, edges, taps) | ✅ | ➖ | ⬜ | macOS keeps its own gestures; edge swipes maybe later |
| Fingerprint (private notes, confirm) | ✅ | ✅ | ⬜ | Mac: Touch ID or the password opens private notes and clipboard items for 5 minutes |
| Muna bar, hiding the top bar, desktops per monitor | ✅ | ➖ | ⬜ | GNOME-only ideas |
| Open at login | ✅ | ✅ | ⬜ | |
