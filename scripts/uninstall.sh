#!/usr/bin/env bash
# Removes what scripts/install-dev.sh installed: the extension, the Muna service and its D-Bus file.
# Your data (~/.local/share/muna: notes, tray, clipboard, ...) is left alone.
set -euo pipefail

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
gnome-extensions disable muna@bekov0004.github.io 2>/dev/null || true
rm -rf "$DATA/gnome-shell/extensions/muna@bekov0004.github.io" \
       "$DATA/muna-service" \
       "$DATA/dbus-1/services/io.github.bekov0004.Muna.service"
echo "Muna is removed (your data in $DATA/muna is kept)."
