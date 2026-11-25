# Muna for macOS

The capsule of Muna on a Mac, drawn like Muna for GNOME: closed it is the date · the butterfly ·
the time (on a Mac with a notch, the date and the time beside it), and it opens under the pointer
or a click into the same panel as on Linux.

| Part | What it does |
|---|---|
| **Muna** | A row of widgets, each some cells wide, on pages when they do not fit: media player (Music, Spotify), calendar, mirror (camera), timer, to-do, notes, shortcuts (apps) |
| **Tray** | Files dropped on the capsule wait here: drag them out, open them, send them with LocalSend |
| **LocalSend** | Send files to several devices at once or to a saved group (Muna on Linux and Mac, the LocalSend apps); receive files (you accept each sending) |
| **Clipboard** | What you copied (text and files), with search; a click copies it again; pinned items stay |
| **Alerts** | What Muna told you lately (macOS lets no app read other apps' notifications) |
| **Command Bar** (⌥Space) | Start apps, calculate, convert units, find what you copied, search the web |
| **Quick panel** (Muna's menu-bar item) | Processor, memory, disk, battery, network with graphs; keep awake; dark mode, screenshot, colour picker, empty trash, screen off, eject |
| **Settings** (the gear) | How the capsule opens and closes, the widgets and their order and width, LocalSend, clipboard, tray, open at login |

While something runs, it takes the sides of the closed capsule (a sending, the timer, the music);
when something ends while the capsule is closed, a short card says it and the Alerts section keeps it.
[`../shared/features.md`](../shared/features.md) lists every feature of Linux and where the Mac stands.

The data files are the same as Muna on Linux ([`../shared/formats`](../shared/formats)), so notes,
to-dos, clipboard and groups can be copied between them.

## Install

Needs macOS 13 or newer and the Xcode command line tools (`xcode-select --install`).

```bash
git clone https://github.com/bekov0004/Muna.git
cd Muna
scripts/install.sh          # builds Muna and puts it in ~/Applications, then starts it
```

`scripts/uninstall.sh` removes it again (your data in `~/Library/Application Support/Muna` stays).

A built app is also attached to every run of the
[macOS workflow](https://github.com/bekov0004/Muna/actions/workflows/macos.yml) (`Muna-macos`). It is
not signed by Apple: after unpacking, run `xattr -dr com.apple.quarantine Muna.app` once, or macOS
will refuse to open it.

**Permissions** (macOS asks once for each):

- *Automation* for Music / Spotify: to show and steer the music. macOS gives other apps no common
  "now playing" any more, so music in a browser does not show.
- *Calendars*: when you click "Show my calendar".
- *Camera*: the first time the Mirror widget is shown.
- *Automation* for System Events and Finder: the dark-mode and empty-trash tools.
- *Local Network*: to find the other devices and to receive files (LocalSend). Receiving is off until
  you switch it on (menu-bar item → Receive files, or "Receiving" on the LocalSend page).

## Inside

```
Package.swift                 Swift package: the app (Muna) and its core (MunaCore)
Sources/MunaCore/             no screen: the data files, LocalSend, groups (builds and is tested on Linux too)
Sources/MunaCore/             (also: HTTP parsing, LocalSend client, receiving, announcements, the sending
                              session for several devices, clipboard history, Tray)
Sources/Muna/                 the app: the capsule's window (CapsuleController), its pages (SwiftUI),
                              music (NowPlaying), LocalSend's HTTPS server and certificate, the menu
Tests/MunaCoreTests/          tests of the core, among them reading files written by Muna on Linux
Resources/                    Info.plist, AppIcon.icns (made from shared/brand/dev.muna.Muna.svg)
scripts/                      build-app.sh, install.sh, uninstall.sh
```

The data files, the LocalSend protocol and the colours follow [`../shared`](../shared).

**Develop:** `swift test` runs the core's tests (on Linux:
`docker run --rm -v "$PWD":/src -w /src swift:6.0-jammy swift test`); `scripts/build-app.sh` builds
`build/Muna.app`. Every push that touches `macos/` or `shared/` is built on a Mac by GitHub Actions.
