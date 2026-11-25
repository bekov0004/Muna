#!/usr/bin/env bash
# Builds muna@muna.dev.shell-extension.zip: the extension with its service inside, for
# `gnome-extensions install --force <zip>` (or for uploading to extensions.gnome.org).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # linux/
# The extension wants its icons and the licence next to it: put them in a copy of linux/ first.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -r . "$STAGE/muna"
rm -rf "$STAGE/muna/scripts" "$STAGE/muna/airdrop"
cp -r ../shared/brand "$STAGE/muna/icons"
cp ../LICENSE "$STAGE/muna/LICENSE"
gnome-extensions pack --force \
    --extra-source=phone-helper --extra-source=icons --extra-source=prefsWindow.js --extra-source=prefsText.js --extra-source=theme.js --extra-source=prefsUtilities.js --extra-source=prefsGestures.js --extra-source=src --extra-source=service --extra-source=LICENSE \
    --schema=schemas/org.gnome.shell.extensions.muna.gschema.xml \
    --out-dir=. "$STAGE/muna"
VERSION="$(grep -oP '"version-name":\s*"\K[^"]+' metadata.json)"
mv -f muna@muna.dev.shell-extension.zip "Muna-$VERSION.zip"
echo "Built: linux/Muna-$VERSION.zip"
