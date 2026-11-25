#!/usr/bin/env bash
# Quits Muna and removes the app. Your data (~/Library/Application Support/Muna) is kept.
set -euo pipefail
pkill -x Muna 2>/dev/null || true
rm -rf "$HOME/Applications/Muna.app"
echo "Muna is removed (your data in ~/Library/Application Support/Muna is kept)."
