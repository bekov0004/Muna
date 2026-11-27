# What each platform has

Muna for GNOME (`linux/`) is the reference: every feature it has is listed here, with where the
other platforms stand. ✅ done · 🟡 partly · ⬜ not yet · ➖ cannot be done there (why in the note).
Change this table together with the code. `parity.md` goes into every part of Linux in detail.

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
| Two-finger pull makes lists taller | ✅ | ➖ | ✅ | Mac: the Clipboard and Alerts sections are tall and scroll; Windows: a two-finger swipe (or the wheel) past the top of the list makes Clipboard and Alerts taller, up to 40% of the screen; back past the end |
| Appearance: size, corner radius, colour, opacity | ✅ | ✅ | ✅ | Mac: widget size, height, padding, spacing, dividers, width, corner radius, transparency, shadow, butterfly; Mac: corner radius, opacity, animation speed; widths per widget; Windows: widget size, height, padding, spacing, dividers, auto or fixed width, corner radius, transparency, shadow, capsule colour, animation speed; the Muna bar's colour and opacity (Linux's top-bar colour) |

## Widgets of the Muna section

| Widget | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Media player | ✅ | 🟡 | ✅ | Mac: Music and Spotify only (macOS closed "now playing" to other apps); lyrics from lrclib.net (setting); Windows: any app in the system media overlay (GSMTC), cover, seek, lyrics |
| Calendar | ✅ | ✅ | ✅ | Mac: EventKit; Windows: Outlook's own calendar (the desktop app) and any number of iCalendar (.ics) links (Outlook on the web, Google) |
| Mirror (camera) | ✅ | ✅ | ✅ | with the enlarged card |
| Timer | ✅ | ✅ | ✅ | |
| To-do, Notes | ✅ | ✅ | ✅ | same files (`formats/data-files.md`) |
| Shortcuts (apps) | ✅ | ✅ | ✅ | |
| Phone card | ✅ | ✅ | ✅ | Mac: the Phone widget and the quick panel: live picture (VideoToolbox), pairing over Wi-Fi with a QR code, Muna Phone's link; Mac (quick panel): adb phones, battery, the screen as a picture every second, taps, swipes, keys, typing; not yet: the live picture, pairing over Wi-Fi, the Muna Phone app's link; Windows: a Phone widget in the capsule and the quick panel's page: the live picture (screenrecord through adb, decoded by Windows' own H.264 decoder), pairing over Wi-Fi with a QR code, Muna Phone's link (picture and touches over the network, dark phone screen), taps, swipes, keys, typing |
| Companion | ✅ | ✅ | ✅ | |

## Sections

| Feature | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Tray | ✅ | ✅ | ✅ | |
| LocalSend: send, several devices, groups, receive | ✅ | ✅ | ✅ | Mac ↔ Linux to be tried on real machines; Windows ↔ Linux/Mac to be tried on real machines; Windows asks once to allow the network |
| LocalSend: send and receive texts (Text, the text chip, the received-text card with Copy and Open) | ✅ | 🟡 | 🟡 | Mac and Windows: core tested against Muna and a fake LocalSend; the views not yet seen running |
| Clipboard history, pin, notes, search, clean links, private items, drag out | ✅ | ✅ | ✅ | Windows: private items behind Windows Hello |
| Alerts | ✅ | ✅ | ✅ | Mac: other apps' notifications from macOS's own list (Full Disk Access); macOS lets no app read other apps' notifications: Muna's own events only; Windows: other apps' notifications (read from Windows' own notification list, with the app's name and icon, a click opens the app), Muna's own events, system alerts |

## The top-bar window (quick panel) and tools

| Feature | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Top-bar readings (CPU, temperature, memory, network …) | ✅ | ✅ | ✅ | Mac: the chosen readings next to Muna's menu-bar item, temperature and graphics from IOKit; Mac: CPU and memory next to Muna's menu-bar item (setting); no temperature (macOS hides the sensors); Windows: each chosen reading (processor, temperature, graphics, memory, battery, network, disk, disk activity, power) as an icon with its value in the notification area and in the Muna bar; warnings with Linux's thresholds |
| System, Network, Disks, Power, Sound widgets | ✅ | ✅ | ✅ | Mac quick panel: processor and memory with graphs, disk, battery, uptime, network; sound (volume, mute, output, microphone); Windows quick panel: processor, memory (graphs), disk, battery, uptime, network; sound: volume, mute, microphone, output device |
| Displays (brightness, arrangement) | ✅ | ✅ | ✅ | Mac: built-in screen's own brightness, other screens dimmed by Muna, the arrangement drawn; no Night Shift switch; Windows: laptop screen (WMI), monitors over DDC/CI, else dimmed by Muna; arrangement; night light switch |
| Keep awake | ✅ | ✅ | ✅ | Mac: IOPMAssertion, for a while or until off, screen on or not (no "lid closed": needs admin rights); Windows: for a while or until off, screen on or not |
| Quick toggles, Utilities, Controls | ✅ | ✅ | ✅ | Mac: dark mode, Night Shift, microphone, keyboard light, hidden files, trash, eject, lock, screen off, and the Controls switches; Mac: dark mode, screenshot, colour picker, empty trash, screen off, eject disks; Windows: Wi-Fi, Bluetooth, night light, airplane mode, microphone, keep awake, dark mode, screenshot, colour picker, empty the bin, eject disks, screen off, lock; Controls: focus follows the mouse, snapping, animations, mouse acceleration, the Caps Lock sound, hidden files, extensions, clipboard, separate desktops |
| Focus (Pomodoro, stopwatch) | ✅ | ✅ | ✅ | same focus.json; same focus.json (MunaCore, tested) |
| Downloads | ✅ | ✅ | ✅ | |
| Windows (snapping), Desktops | ✅ | ✅ | ✅ | Mac: the window map with live pictures (ScreenCaptureKit), all windows at once, snapping, Spaces; Mac: halves, quarters, thirds, maximize, centre, next screen (Accessibility permission); desktops are macOS's own Spaces; Windows: the window map (live pictures; drag, edge zones, bring forward, close), all windows at once (columns, rows, grid, main + side, undo), one window (halves, quarters, thirds, maximise, centre, next screen, minimise); desktop tabs, task view, new desktop |
| Reminders (the butterfly) | ✅ | ✅ | ✅ | a card in the capsule and a sound |
| AI agents (Claude Code, Codex) | ✅ | ✅ | ✅ | Mac: also Codex in Terminal and the token counts; Mac: Claude Code tasks, questions in the capsule, agents window, plan limits, Claude Code and Codex sessions in terminals; not yet: starting Codex, token counts of the logs; Windows: Claude Code tasks (background or terminal, model), Codex tasks in a terminal, questions in the capsule, agents window, plan limits, sessions in terminals, token counts of the last 5 hours and week |
| Radial menu, colour picker, cleaning mode, scratchpad | ✅ | ✅ | ✅ | Mac: radial menu on ⌃⌥Space; Windows: radial menu on Ctrl+Alt+Space |

## The system

| Feature | Linux | macOS | Windows | Note |
|---|---|---|---|---|
| Settings window | ✅ | ✅ | ✅ | Mac and Windows: Linux's pages, search, Try it, shortcuts by pressing keys; Mac: general, appearance, screens, shortcuts, widgets, LocalSend, clipboard, tray, snippets; Windows: Linux's grouped pages with a search: general, appearance, live activities, widgets, touchpad gestures, calendar, phone, readings and bars, keys and radial menu, tools, AI agents, Windows Hello, LocalSend, clipboard and tray, snippets, about |
| Touchpad gestures (3/4 fingers, edges, taps) | ✅ | ✅ | ✅ | Mac: Muna reads the trackpad itself (MultitouchSupport); macOS keeps its own gestures; edge swipes maybe later; Windows: Muna reads the precision touchpad itself (Raw Input): 3/4-finger swipes (the live app switcher is Windows' Alt+Tab), pinches, holds, one finger along the edges, double taps and holds at them, any action of Linux's list; Windows' own 3/4-finger gestures must be set to "Nothing" |
| Fingerprint (private notes, confirm) | ✅ | ✅ | ✅ | Mac: Touch ID or the password opens private notes and clipboard items for 5 minutes; Windows: Windows Hello (face, finger or PIN) for 5 minutes |
| Muna bar, hiding the top bar, desktops per monitor | ✅ | ✅ | ✅ | Mac: macOS's own menu bar on every screen, hiding it, "Displays have separate Spaces"; GNOME-only ideas on the Mac; Windows: the Muna bar on other or all monitors (desktops, capsule, readings, network, sound, battery; hides never, intellihide, always), hiding the taskbar, separate desktops for every monitor kept by Muna (Ctrl+Win+arrows follow the pointer) |
| Open at login | ✅ | ✅ | ✅ | |
