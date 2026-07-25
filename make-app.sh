#!/bin/sh
# Bundle the renderer into a double-clickable "Black Hole.app" in dist/.
# (swift run works fine too — this is just for keeping it in the Dock.)
set -e
cd "$(dirname "$0")"

swift build -c release

# Sparkle compares CFBundleVersion, so it has to increase with every release or
# an update will not be offered. The commit count does that for free and cannot
# be forgotten; the human-readable version comes from the latest tag.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-1.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# Where the app looks for updates, and the key it insists they be signed with.
# Overridable so a fork does not silently point at this repo's releases.
FEED_URL="${FEED_URL:-https://github.com/ZGhey/blackhole-mac/releases/latest/download/appcast.xml}"
PUBLIC_ED_KEY="${PUBLIC_ED_KEY:-GuGfm0TfgxLQZULclHPLhQZkbCPkIoH6/i4QZGSBHek=}"

APP="dist/Black Hole.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp .build/release/BlackHoleApp "$APP/Contents/MacOS/"
# Sparkle is an XCFramework, so it travels inside the bundle and the executable
# finds it by the @executable_path/../Frameworks rpath set in Package.swift.
cp -R .build/release/Sparkle.framework "$APP/Contents/Frameworks/"
# BlackHole.metal is compiled at launch out of the SwiftPM resource bundle, so
# the bundle has to travel with the binary. Bundle.module finds it next to
# Bundle.main.resourceURL.
cp -R .build/release/BlackHoleApp_BlackHoleApp.bundle "$APP/Contents/Resources/"
# The icon has to sit at Contents/Resources/AppIcon.icns for CFBundleIconFile;
# inside the SwiftPM resource bundle is where the app finds it, not the Finder.
cp Sources/BlackHoleApp/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>      <string>BlackHoleApp</string>
    <key>CFBundleIdentifier</key>      <string>dev.s13k.blackhole-app</string>
    <key>CFBundleName</key>            <string>Black Hole</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <!-- LaunchServices and SMAppService (launch at login) both key off this,
         and Sparkle compares it to decide whether an update is newer. -->
    <key>CFBundleVersion</key>         <string>${BUILD}</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <!-- Lives on the desktop and in the menu bar; no Dock icon, no windows. -->
    <key>LSUIElement</key>             <true/>

    <!-- Updates. SUPublicEDKey is the whole trust story: the app is signed with
         a local identity and is not notarized, so nothing about the download
         vouches for itself — Sparkle installs an update only if its EdDSA
         signature matches this key. The private half lives in the login
         keychain of whoever publishes; see make-release.sh. -->
    <key>SUFeedURL</key>               <string>${FEED_URL}</string>
    <key>SUPublicEDKey</key>           <string>${PUBLIC_ED_KEY}</string>
    <!-- Check on its own, and install what it finds. Set both false to make it
         a purely manual "Check for Updates…". -->
    <key>SUEnableAutomaticChecks</key> <true/>
    <key>SUAutomaticallyUpdate</key>   <true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
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
# Inside-out, because codesign seals what it finds: the app's signature covers
# the framework's, which covers the helpers' inside it. Signing the outside
# first would seal unsigned nested code and the whole thing would be rejected.
# (`--deep` looks like it does this and is discouraged by Apple for exactly the
# reason it hides which piece failed.)
for nested in \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
do
    [ -e "$nested" ] || continue
    codesign --force --sign "$IDENTITY" --timestamp=none --options runtime "$nested" >/dev/null 2>&1 \
        || echo "warning: could not sign $(basename "$nested"); updates will not install"
done
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
