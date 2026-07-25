#!/bin/sh
# Wrap dist/Black Hole.app in a drag-to-install dmg.
#
# The app is signed with the local self-signed identity (see make-signing-cert.sh),
# not notarized — which is fine on the machine that built it, and is *not* fine
# anywhere else: Gatekeeper refuses the first launch of an unnotarized app that
# arrived with a quarantine flag, and the way past it is right-click ▸ Open.
set -e
cd "$(dirname "$0")"

./make-app.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "dist/Black Hole.app" "$STAGE/"
# The symlink is the whole of the drag-to-install idiom: the window shows the
# app and a shortcut to /Applications, and you drag one onto the other.
ln -s /Applications "$STAGE/Applications"

DMG="dist/Black Hole.dmg"
rm -f "$DMG"
# UDZO: compressed and read-only, which is what a distributed dmg should be.
hdiutil create -volname "Black Hole" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null

echo "built: $PWD/$DMG ($(du -h "$DMG" | cut -f1))"
