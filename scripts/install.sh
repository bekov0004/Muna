#!/usr/bin/env bash
# Installs Muna for your user: the GNOME Shell extension (which carries its own background service)
# and a launcher for the Muna app window. No root needed. Run it from the folder you cloned.
#   scripts/install.sh            install / update
#   scripts/install.sh --nested   ...then start a nested GNOME Shell with Muna enabled (to try it)
#   scripts/uninstall.sh          remove everything again
set -euo pipefail

UUID="muna@muna.dev"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
DEST="$DATA/gnome-shell/extensions/$UUID"

# --- what Muna needs -----------------------------------------------------------------------
missing=()
for tool in gjs glib-compile-schemas; do
    command -v "$tool" >/dev/null || missing+=("$tool")
done
if ((${#missing[@]})); then
    echo "Missing: ${missing[*]}"
    echo "On Ubuntu / Debian: sudo apt install gjs libglib2.0-bin"
    echo "On Fedora:          sudo dnf install gjs glib2"
    exit 1
fi
if command -v gnome-shell >/dev/null; then
    version="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
    if [[ -n "$version" && "$version" != "50" ]]; then
        echo "Warning: this Muna is made for GNOME Shell 50; you have $version. It may not load."
    fi
fi

# --- the project used to have another name: take its leftovers away and bring the data over ----
OLD_UUID="nook@bekov0004.github.io"
if [[ -d "$DATA/gnome-shell/extensions/$OLD_UUID" || -d "$DATA/nook" ]]; then
    gnome-extensions disable "$OLD_UUID" 2>/dev/null || true
    rm -rf "$DATA/gnome-shell/extensions/$OLD_UUID" "$DATA/nook-service" \
           "$DATA/dbus-1/services/io.github.bekov0004.Nook.service" "$DATA/applications/io.github.bekov0004.Nook.desktop"
    if [[ -d "$DATA/nook" && ! -e "$DATA/muna" ]]; then
        mv "$DATA/nook" "$DATA/muna"
        echo "Moved your data from $DATA/nook to $DATA/muna"
    fi
    if command -v dconf >/dev/null && [[ -n "$(dconf list /org/gnome/shell/extensions/nook/ 2>/dev/null)" ]] &&
       [[ -z "$(dconf list /org/gnome/shell/extensions/muna/ 2>/dev/null)" ]]; then
        dconf dump /org/gnome/shell/extensions/nook/ | dconf load /org/gnome/shell/extensions/muna/ && echo "Copied your settings"
        old_shortcut="$(dconf read /org/gnome/shell/extensions/nook/shortcut-nook 2>/dev/null || true)"
        [[ -n "$old_shortcut" ]] && dconf write /org/gnome/shell/extensions/muna/shortcut-muna "$old_shortcut" || true
    fi
fi
# an earlier layout had the service in a folder of its own
rm -rf "$DATA/muna-service" "$DATA/dbus-1/services/io.github.bekov0004.Muna.service"
# ...and the first UUID / launcher name Muna had
gnome-extensions disable "muna@bekov0004.github.io" 2>/dev/null || true
rm -rf "$DATA/gnome-shell/extensions/muna@bekov0004.github.io" "$DATA/applications/io.github.bekov0004.Muna.desktop"

# --- install ----------------------------------------------------------------------------------
rm -rf "$DEST"
mkdir -p "$DEST"
cp -r "$SRC/extension.js" "$SRC/prefs.js" "$SRC/prefsUtilities.js" "$SRC/metadata.json" "$SRC/stylesheet.css" \
      "$SRC/src" "$SRC/service" "$SRC/schemas" "$DEST/"
glib-compile-schemas "$DEST/schemas"
echo "Installed to $DEST"

# A launcher for the Muna app window (status, Scratchpad). It also works with the extension off.
mkdir -p "$DATA/applications"
cat > "$DATA/applications/dev.muna.Muna.desktop" <<UNIT
[Desktop Entry]
Type=Application
Name=Muna
Comment=Status of the Muna service and the Scratchpad (the capsule is a GNOME Shell extension)
Icon=view-grid-symbolic
Exec=$(command -v gjs) -m $DEST/service/main.js
Categories=Utility;
UNIT

if [[ "${1:-}" == "--nested" ]]; then
    exec dbus-run-session -- bash -c \
        "gnome-shell --devkit --wayland & sleep 6; gnome-extensions enable $UUID; wait"
fi
echo
echo "Log out and in again (Wayland cannot load a new extension in place), then:"
echo "    gnome-extensions enable $UUID"
