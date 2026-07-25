#!/bin/sh
# Bundle the renderer into a double-clickable "Black Hole.app" in macapp/dist.
# (swift run works fine too — this is just for keeping it in the Dock.)
set -e
cd "$(dirname "$0")"

swift build -c release

APP="dist/Black Hole.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/BlackHoleApp "$APP/Contents/MacOS/"
# BlackHole.metal is compiled at launch out of the SwiftPM resource bundle, so
# the bundle has to travel with the binary. Bundle.module finds it next to
# Bundle.main.resourceURL.
cp -R .build/release/BlackHoleApp_BlackHoleApp.bundle "$APP/Contents/Resources/"
# The icon has to sit at Contents/Resources/AppIcon.icns for CFBundleIconFile;
# inside the SwiftPM resource bundle is where the app finds it, not the Finder.
cp Sources/BlackHoleApp/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>      <string>BlackHoleApp</string>
    <key>CFBundleIdentifier</key>      <string>dev.s13k.blackhole-app</string>
    <key>CFBundleName</key>            <string>Black Hole</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <!-- LaunchServices and SMAppService (launch at login) both key off this. -->
    <key>CFBundleVersion</key>         <string>1</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <!-- Lives on the desktop and in the menu bar; no Dock icon, no windows. -->
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
EOF

# TCC keys Screen Recording and Accessibility grants to the code signature.
# An ad-hoc signature is content-derived, so *every rebuild* produces a new one
# and macOS silently revokes the grant. Signing with a stable self-signed
# identity fixes that for good; set CODESIGN_IDENTITY to its name.
#
#   Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…
#     name: Black Hole Dev,  type: Code Signing,  self-signed
#   export CODESIGN_IDENTITY="Black Hole Dev"
#
# Without one this falls back to ad-hoc, and the app's Controls panel has an
# "Ask again" button to re-request the permission after each rebuild.
# Prefer a stable identity automatically: ad-hoc is a footgun here, and having
# to remember an env var is how you end up re-granting permissions forever.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "Black Hole Dev"; then
    IDENTITY="Black Hole Dev"
fi
IDENTITY="${IDENTITY:--}"
if codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null 2>&1; then
    if [ "$IDENTITY" = "-" ]; then
        echo "note: ad-hoc signed — Screen Recording must be re-granted after each rebuild."
        echo "      Run ./make-signing-cert.sh once to fix that permanently."
    else
        echo "signed with: $IDENTITY"
    fi
else
    echo "warning: codesign failed; Screen Recording permission will not persist"
fi

echo "built: $PWD/$APP"
