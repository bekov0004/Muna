#!/usr/bin/env bash
# Installs Muna for this computer: picks the part of the repository for this system.
#   scripts/install.sh [options]     (the options go to the system's own installer)
# Linux (GNOME): linux/scripts/install.sh   ·   macOS: macos/scripts/install.sh
# Windows (Git Bash): windows/scripts/install.ps1
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$(uname -s)" in
    Linux)  exec "$ROOT/linux/scripts/install.sh" "$@" ;;
    Darwin) exec "$ROOT/macos/scripts/install.sh" "$@" ;;
    MINGW*|MSYS*|CYGWIN*) exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$ROOT/windows/scripts/install.ps1")" "$@" ;;
    *)      echo "Muna has no installer for $(uname -s)." >&2; exit 1 ;;
esac
