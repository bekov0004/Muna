#!/usr/bin/env bash
# Removes Muna from this computer (your notes, tray, clipboard ... are kept).
# Linux (GNOME): linux/scripts/uninstall.sh   ·   macOS: macos/scripts/uninstall.sh
# Windows (Git Bash): windows/scripts/uninstall.ps1
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$(uname -s)" in
    Linux)  exec "$ROOT/linux/scripts/uninstall.sh" "$@" ;;
    Darwin) exec "$ROOT/macos/scripts/uninstall.sh" "$@" ;;
    MINGW*|MSYS*|CYGWIN*) exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$ROOT/windows/scripts/uninstall.ps1")" "$@" ;;
    *)      echo "Muna has no uninstaller for $(uname -s)." >&2; exit 1 ;;
esac
