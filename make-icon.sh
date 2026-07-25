#!/bin/sh
# Regenerate the app's icons — from the app's own renderer.
#
# There is no icon art in this repo and there does not need to be: the thing the
# app draws is the thing the icon should be. Only needs rerunning when the look
# changes; the results are committed.
set -e
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swift run render-icon Sources/BlackHoleApp/BlackHole.metal "$TMP"
iconutil -c icns "$TMP/AppIcon.iconset" -o Sources/BlackHoleApp/AppIcon.icns
cp "$TMP/MenuIcon.png" Sources/BlackHoleApp/MenuIcon.png

echo "wrote Sources/BlackHoleApp/AppIcon.icns and MenuIcon.png"
