# What each platform has

Muna for GNOME (`linux/`) is the reference: every feature it has is listed here, with where the
other platforms stand. ✅ done · 🟡 partly · ⬜ not yet · ➖ cannot be done there (why in the note).
Change this table together with the code.

## The capsule

| Feature | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Closed capsule: date · butterfly · time | ✅ | ✅ | ⬜ | Mac with a notch: date and time beside the notch |
| Live activities in the closed capsule (music, timer, sending) | ✅ | ✅ | ⬜ | Linux has more (downloads, calendar, files) |
| Cards (a sending ended, time is up …) | ✅ | ✅ | ⬜ | |
| Opens on hover / click, delays, collapse when the pointer leaves | ✅ | ✅ | ⬜ | |
| Tabs Muna · Tray · LocalSend · Clipboard · Alerts, page dots, gear | ✅ | ✅ | ⬜ | |
| Width in cells of 44, pages of widgets | ✅ | ✅ | ⬜ | same rules (`PanelLayout`, tested against Linux) |
| Files dropped on the capsule | ✅ | ✅ | ⬜ | |
| Capsule on several monitors | ✅ | ⬜ | ⬜ | |
| Command Bar (apps, calculator, converter, clipboard search, snippets …) | ✅ | ⬜ | ⬜ | |
| Keyboard shortcuts for every section | ✅ | ⬜ | ⬜ | needs a global hot-key (Carbon RegisterEventHotKey) |
| Two-finger pull makes lists taller | ✅ | ⬜ | ⬜ | |
| Appearance: size, corner radius, colour, opacity | ✅ | ⬜ | ⬜ | |

## Widgets of the Muna section

| Widget | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Media player | ✅ | 🟡 | ⬜ | Mac: Music and Spotify only (macOS closed "now playing" to other apps); no lyrics yet |
| Calendar | ✅ | ✅ | ⬜ | Mac: EventKit |
| Mirror (camera) | ✅ | ✅ | ⬜ | enlarged card not yet |
| Timer | ✅ | ✅ | ⬜ | |
| To-do, Notes | ✅ | ✅ | ⬜ | same files (`formats/data-files.md`) |
| Shortcuts (apps) | ✅ | ✅ | ⬜ | |
| Phone card | ✅ | ⬜ | ⬜ | adb works on a Mac too |
| Companion | ✅ | ⬜ | ⬜ | |

## Sections

| Feature | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Tray | ✅ | ✅ | ⬜ | |
| LocalSend: send, several devices, groups, receive | ✅ | ✅ | ⬜ | Mac ↔ Linux to be tried on real machines |
| Clipboard history, pin, search | ✅ | ✅ | ⬜ | Linux also: notes on items, drag an item out, clean links |
| Alerts | ✅ | 🟡 | ⬜ | macOS lets no app read other apps' notifications: Muna's own events only |

## The top-bar window (quick panel) and tools

| Feature | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Top-bar readings (CPU, temperature, memory, network …) | ✅ | ⬜ | ⬜ | |
| System, Network, Disks, Power, Sound widgets | ✅ | ⬜ | ⬜ | |
| Displays (brightness, arrangement) | ✅ | ⬜ | ⬜ | |
| Keep awake | ✅ | ⬜ | ⬜ | Mac: IOPMAssertion |
| Quick toggles, Utilities, Controls | ✅ | ⬜ | ⬜ | |
| Focus (Pomodoro, stopwatch) | ✅ | ⬜ | ⬜ | |
| Downloads | ✅ | ⬜ | ⬜ | |
| Windows (snapping), Desktops | ✅ | ⬜ | ⬜ | Mac: Accessibility permission |
| Reminders (the butterfly) | ✅ | ⬜ | ⬜ | |
| AI agents (Claude Code, Codex) | ✅ | ⬜ | ⬜ | |
| Radial menu, colour picker, cleaning mode, scratchpad | ✅ | ⬜ | ⬜ | |

## The system

| Feature | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Settings window | ✅ | 🟡 | ⬜ | Mac: general, widgets, LocalSend, clipboard, tray |
| Touchpad gestures (3/4 fingers, edges, taps) | ✅ | ➖ | ⬜ | macOS keeps its own gestures; edge swipes maybe later |
| Fingerprint (private notes, confirm) | ✅ | ⬜ | ⬜ | Mac: Touch ID (LocalAuthentication) |
| Muna bar, hiding the top bar, desktops per monitor | ✅ | ➖ | ⬜ | GNOME-only ideas |
| Open at login | ✅ | ✅ | ⬜ | |
