# Muna for macOS

The capsule of Muna on a Mac: it sits under the camera notch (on a Mac without one, in the middle of
the menu bar) and opens into a panel when the pointer comes to it. In progress; see the
[platforms table](../README.md#platforms).

| Done | Next |
|---|---|
| The capsule under the notch, opening and closing under the pointer | LocalSend and groups (sending to Muna on Linux and other Macs) |
| The time and date; the music of Music and Spotify (title, artist, cover, play/pause, next, previous) | The Tray (files dropped on the capsule) and the clipboard history |
| A menu-bar item (About, Quit) | Calendar, notes and to-dos |

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

**Permissions:** the first time Muna asks Music or Spotify what they play, macOS asks whether Muna
may control them (System Settings → Privacy & Security → Automation). macOS gives other apps no
common "now playing" any more, so music from a browser does not show yet.

## Inside

```
Package.swift                 Swift package: the app (Muna) and its core (MunaCore)
Sources/MunaCore/             no screen: the data files, LocalSend, groups (builds and is tested on Linux too)
Sources/Muna/                 the app: AppKit window of the capsule, SwiftUI views, music
Tests/MunaCoreTests/          tests of the core, among them reading files written by Muna on Linux
Resources/                    Info.plist, AppIcon.icns (made from shared/brand/dev.muna.Muna.svg)
scripts/                      build-app.sh, install.sh, uninstall.sh
```

The data files, the LocalSend protocol and the colours follow [`../shared`](../shared).

**Develop:** `swift test` runs the core's tests (on Linux:
`docker run --rm -v "$PWD":/src -w /src swift:6.0-jammy swift test`); `scripts/build-app.sh` builds
`build/Muna.app`. Every push that touches `macos/` or `shared/` is built on a Mac by GitHub Actions.
