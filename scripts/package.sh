#!/usr/bin/env bash
# Builds muna@muna.dev.shell-extension.zip: the extension with its service inside, for
# `gnome-extensions install --force <zip>` (or for uploading to extensions.gnome.org).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
gnome-extensions pack --force \
    --extra-source=phone-helper --extra-source=icons --extra-source=prefsWindow.js --extra-source=prefsText.js --extra-source=prefsUtilities.js --extra-source=prefsGestures.js --extra-source=src --extra-source=service --extra-source=LICENSE \
    --schema=schemas/org.gnome.shell.extensions.muna.gschema.xml \
    --out-dir=. .
VERSION="$(grep -oP '"version-name":\s*"\K[^"]+' metadata.json)"
mv -f muna@muna.dev.shell-extension.zip "Muna-$VERSION.zip"
echo "Built: Muna-$VERSION.zip"
