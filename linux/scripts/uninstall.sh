#!/usr/bin/env bash
# Removes what linux/scripts/install.sh installed. Your data (~/.local/share/muna: notes, tray, clipboard,
# ...) and settings are left alone.
set -euo pipefail

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
gnome-extensions disable muna@muna.dev 2>/dev/null || true
gnome-extensions disable muna@bekov0004.github.io 2>/dev/null || true
rm -rf "$DATA/gnome-shell/extensions/muna@muna.dev" "$DATA/applications/dev.muna.Muna.desktop" "$DATA/icons/hicolor/scalable/apps/dev.muna.Muna.svg" \
       "$DATA/gnome-shell/extensions/muna@bekov0004.github.io" "$DATA/applications/io.github.bekov0004.Muna.desktop" \
       "$DATA/muna-service" "$DATA/dbus-1/services/io.github.bekov0004.Muna.service"
# (and the leftovers of the old name)
rm -rf "$DATA/gnome-shell/extensions/nook@bekov0004.github.io" "$DATA/nook-service" \
       "$DATA/dbus-1/services/io.github.bekov0004.Nook.service" "$DATA/applications/io.github.bekov0004.Nook.desktop"
echo "Muna is removed (your data in $DATA/muna is kept)."
