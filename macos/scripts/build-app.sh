#!/usr/bin/env bash
# Builds Muna.app into macos/build/Muna.app (needs the Xcode command line tools: xcode-select --install).
#   macos/scripts/build-app.sh             for this Mac
#   UNIVERSAL=1 macos/scripts/build-app.sh for Apple silicon and Intel Macs at once (needs Xcode)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # macos/
ARGS=(-c release --product Muna)
[[ "${UNIVERSAL:-}" == 1 ]] && ARGS+=(--arch arm64 --arch x86_64)
swift build "${ARGS[@]}"
BIN="$(swift build "${ARGS[@]}" --show-bin-path)/Muna"
APP=build/Muna.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Muna"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/butterfly.png "$APP/Contents/Resources/butterfly.png"
# What any player plays (MediaRemote, read through /usr/bin/perl: see Helpers/NowPlayingHelper.m)
HELPER_ARCHS=(-arch "$(uname -m)")
[[ "${UNIVERSAL:-}" == 1 ]] && HELPER_ARCHS=(-arch arm64 -arch x86_64)
if clang "${HELPER_ARCHS[@]}" -dynamiclib -fobjc-arc -mmacosx-version-min=13.0 -framework Foundation \
     -o "$APP/Contents/Resources/MunaNowPlaying.dylib" Helpers/NowPlayingHelper.m; then
  codesign --force --sign - "$APP/Contents/Resources/MunaNowPlaying.dylib"
else
  echo "warning: the now-playing helper did not build; Muna sees Music and Spotify only" >&2
fi
# An ad-hoc signature: enough to run on this Mac (Apple silicon runs nothing unsigned).
codesign --force --sign - "$APP"
echo "Built macos/$APP"
