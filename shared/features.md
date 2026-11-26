# What each platform has

Muna for GNOME (`linux/`) is the reference: every feature it has is listed here, with where the
other platforms stand. ✅ done · 🟡 partly · ⬜ not yet · ➖ cannot be done there (why in the note).
Change this table together with the code.

## The capsule

| Feature | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Closed capsule: date · butterfly · time | ✅ | ✅ | ✅ | Mac with a notch: at rest just the notch (the menu bar stays free); date and time, or what runs, come out beside it on hover, activity or a card; Windows: in the middle of the top edge of every monitor; hides for full-screen apps (setting) |
| Live activities in the closed capsule (music, timer, sending) | ✅ | ✅ | ✅ | Linux has more (downloads, calendar, files) |
| Cards (a sending ended, time is up …) | ✅ | ✅ | ✅ | |
| Opens on hover / click, delays, collapse when the pointer leaves | ✅ | ✅ | ✅ | |
| Tabs Muna · Tray · LocalSend · Clipboard · Alerts, page dots, gear | ✅ | ✅ | ✅ | |
| Width in cells of 44, pages of widgets | ✅ | ✅ | ✅ | same rules (`PanelLayout`, tested against Linux); Windows: the same `PanelLayout`, tested |
| Files dropped on the capsule | ✅ | ✅ | ✅ | |
| Capsule on several monitors | ✅ | ✅ | ✅ | Mac: every screen, the main one, or the built-in one with the notch (Settings → General → Screens); Windows: every monitor or the main one |
| Command Bar (apps, calculator, converter, clipboard search, snippets …) | ✅ | ✅ | ✅ | Mac: apps, calculator, units, clipboard, web search, ;snippets, kill, ports, clean (~/Library/Caches), scratch (⌥Space); Windows: Start-menu apps, calculator, units, clipboard, web search, ;snippets, kill, ports, clean (Temp), scratch (Alt+Space) |
| Keyboard shortcuts for every section | ✅ | ✅ | ✅ | Mac: ⌥Space Command Bar, ⌃⌥1–5 the sections (can be switched off); Windows: Alt+Space, Ctrl+Alt+Space radial, Ctrl+Alt+1–5 |
| Two-finger pull makes lists taller | ✅ | ➖ | ➖ | Mac: the Clipboard and Alerts sections are tall and scroll; Windows: like the Mac, Clipboard and Alerts are tall and scroll |
| Appearance: size, corner radius, colour, opacity | ✅ | 🟡 | 🟡 | Mac: corner radius, opacity, animation speed; widths per widget; Windows: corner radius, opacity, animation speed; widths per widget |

## Widgets of the Muna section

| Widget | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Media player | ✅ | 🟡 | ✅ | Mac: Music and Spotify only (macOS closed "now playing" to other apps); lyrics from lrclib.net (setting); Windows: any app in the system media overlay (GSMTC), cover, seek, lyrics |
| Calendar | ✅ | ✅ | 🟡 | Mac: EventKit; Windows: an iCalendar (.ics) link from Outlook or Google (Windows gives its own calendar only to Store apps) |
| Mirror (camera) | ✅ | ✅ | ✅ | with the enlarged card |
| Timer | ✅ | ✅ | ✅ | |
| To-do, Notes | ✅ | ✅ | ✅ | same files (`formats/data-files.md`) |
| Shortcuts (apps) | ✅ | ✅ | ✅ | |
| Phone card | ✅ | 🟡 | 🟡 | Mac (quick panel): adb phones, battery, the screen as a picture every second, taps, swipes, keys, typing; not yet: the live picture, pairing over Wi-Fi, the Muna Phone app's link; Windows: the same as the Mac, in the quick panel |
| Companion | ✅ | ✅ | ✅ | |

## Sections

| Feature | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Tray | ✅ | ✅ | ✅ | |
| LocalSend: send, several devices, groups, receive | ✅ | ✅ | ✅ | Mac ↔ Linux to be tried on real machines; Windows ↔ Linux/Mac to be tried on real machines; Windows asks once to allow the network |
| Clipboard history, pin, notes, search, clean links, private items, drag out | ✅ | ✅ | ✅ | Windows: private items behind Windows Hello |
| Alerts | ✅ | 🟡 | 🟡 | macOS lets no app read other apps' notifications: Muna's own events only; Windows: Muna's own events (reading other apps' notifications needs a Store app) |

## The top-bar window (quick panel) and tools

| Feature | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Top-bar readings (CPU, temperature, memory, network …) | ✅ | 🟡 | 🟡 | Mac: CPU and memory next to Muna's menu-bar item (setting); no temperature (macOS hides the sensors); Windows: CPU and memory in the tray icon's tooltip (setting) |
| System, Network, Disks, Power, Sound widgets | ✅ | ✅ | ✅ | Mac quick panel: processor and memory with graphs, disk, battery, uptime, network; sound (volume, mute, output, microphone); Windows quick panel: processor, memory (graphs), disk, battery, uptime, network; sound: volume, mute, microphone, output device |
| Displays (brightness, arrangement) | ✅ | ✅ | ✅ | Mac: built-in screen's own brightness, other screens dimmed by Muna, the arrangement drawn; no Night Shift switch; Windows: laptop screen (WMI), monitors over DDC/CI, else dimmed by Muna; arrangement; night light opens Windows' setting |
| Keep awake | ✅ | ✅ | ✅ | Mac: IOPMAssertion, for a while or until off, screen on or not (no "lid closed": needs admin rights); Windows: for a while or until off, screen on or not |
| Quick toggles, Utilities, Controls | ✅ | 🟡 | 🟡 | Mac: dark mode, screenshot, colour picker, empty trash, screen off, eject disks; Windows: dark mode, screenshot, colour picker, empty the bin, screen off, lock |
| Focus (Pomodoro, stopwatch) | ✅ | ✅ | ✅ | same focus.json; same focus.json (MunaCore, tested) |
| Downloads | ✅ | ✅ | ✅ | |
| Windows (snapping), Desktops | ✅ | 🟡 | 🟡 | Mac: halves, quarters, thirds, maximize, centre, next screen (Accessibility permission); desktops are macOS's own Spaces; Windows: halves, quarters, thirds, maximise, centre, next screen, minimise; task view and a new desktop |
| Reminders (the butterfly) | ✅ | ✅ | ✅ | a card in the capsule and a sound |
| AI agents (Claude Code, Codex) | ✅ | 🟡 | 🟡 | Mac: Claude Code tasks, questions in the capsule, agents window, plan limits, Claude Code and Codex sessions in terminals; not yet: starting Codex, token counts of the logs; Windows: as the Mac |
| Radial menu, colour picker, cleaning mode, scratchpad | ✅ | ✅ | ✅ | Mac: radial menu on ⌃⌥Space; Windows: radial menu on Ctrl+Alt+Space |

## The system

| Feature | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Settings window | ✅ | 🟡 | 🟡 | Mac: general, appearance, screens, shortcuts, widgets, LocalSend, clipboard, tray, snippets; Windows: general, appearance, screens, keys, widgets, calendar, LocalSend, clipboard, tray, snippets |
| Touchpad gestures (3/4 fingers, edges, taps) | ✅ | ➖ | ➖ | macOS keeps its own gestures; edge swipes maybe later; Windows keeps its own touchpad gestures |
| Fingerprint (private notes, confirm) | ✅ | ✅ | ✅ | Mac: Touch ID or the password opens private notes and clipboard items for 5 minutes; Windows: Windows Hello (face, finger or PIN) for 5 minutes |
| Muna bar, hiding the top bar, desktops per monitor | ✅ | ➖ | ➖ | GNOME-only ideas |
| Open at login | ✅ | ✅ | ✅ | |
