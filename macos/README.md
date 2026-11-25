# Muna for macOS

The capsule of Muna on a Mac: it sits under the camera notch (on a Mac without one, in the middle of
the menu bar) and opens into a panel when the pointer comes to it.

| Page | What it does |
|---|---|
| **Muna** | The time and date; the music of Music and Spotify (cover, progress, play/pause, next, previous); today's and tomorrow's events; the open to-dos |
| **Tray** | Files dropped on the capsule wait here: drag them out somewhere else, open them, or send them with LocalSend |
| **LocalSend** | Send files to several devices at once or to a saved group (Muna on Linux and Mac, the LocalSend apps); receive files (you accept each sending) |
| **Clipboard** | What you copied (text and files), with search; a click copies it again; pinned items stay |
| **Notes** | Quick notes and the to-do list |

While music plays, the closed capsule shows the cover and moving bars beside the notch; when a sending
ends while it is closed, a short card says how it went. The menu-bar item opens any page and holds
the settings: receiving files, keeping the clipboard history and the Tray, opening at login.

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
