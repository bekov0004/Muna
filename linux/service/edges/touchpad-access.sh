#!/usr/bin/env bash
# Gives the person at the computer (the active seat) read access to touchpads only, for Muna's one-finger edge
# swipes (service/edges/muna-edges.py). Keyboards and mice stay closed: unlike joining the "input" group, no program
# of yours can read what you type through this.
# Run once:  sudo bash touchpad-access.sh        Undo:  sudo bash touchpad-access.sh --remove
set -euo pipefail
RULE=/etc/udev/rules.d/70-muna-touchpad.rules
if [[ $EUID -ne 0 ]]; then
    echo "Run it with sudo: sudo $0 $*" >&2
    exit 1
fi
if [[ "${1:-}" == "--remove" ]]; then
    rm -f "$RULE"
    echo "Removed $RULE"
else
    cat > "$RULE" <<'RULE'
# Muna: the person at the computer may read the touchpad (one-finger swipes along its edges). Touchpads only.
SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_TOUCHPAD}=="1", TAG+="uaccess"
RULE
    echo "Wrote $RULE"
fi
udevadm control --reload-rules
udevadm trigger --subsystem-match=input --action=change
echo "Done. Muna starts the edge swipes by itself within 20 seconds (no need to log out)."
