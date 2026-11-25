#!/usr/bin/env bash
# Builds Muna and puts it in ~/Applications, then starts it. No admin rights needed.
#   macos/scripts/install.sh      (scripts/install.sh at the top of the repository comes here on a Mac)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # macos/
if ! command -v swift >/dev/null; then
    echo "Swift is missing: install the Xcode command line tools first:  xcode-select --install" >&2
    exit 1
fi
scripts/build-app.sh
DEST="$HOME/Applications/Muna.app"
pkill -x Muna 2>/dev/null && sleep 1 || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/Muna.app "$DEST"
open "$DEST"
echo
echo "Muna is in $DEST and running: the capsule is at the top of the screen (under the notch),"
echo "its menu is the item in the menu bar. macOS asks once before Muna may see Music or Spotify."
