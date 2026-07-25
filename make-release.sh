#!/bin/sh
# Cut a release: build the dmg, sign it for Sparkle, write the appcast, and put
# all of it on GitHub.
#
#   ./make-release.sh 1.1
#
# The appcast is uploaded as an asset of every release, which is what makes
# .../releases/latest/download/appcast.xml — the SUFeedURL baked into the app —
# always resolve to the newest one.
#
# Signing uses the EdDSA private key in your login keychain, put there by
# Sparkle's generate_keys. Nothing else can produce an update this app will
# install, so back it up:
#
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
#
# and keep that file somewhere that is not this repository.
set -e
cd "$(dirname "$0")"

VERSION="$1"
if [ -z "$VERSION" ]; then
    echo "usage: ./make-release.sh <version>   e.g. ./make-release.sh 1.1" >&2
    exit 1
fi
TAG="v$VERSION"

if ! git remote get-url origin >/dev/null 2>&1; then
    echo "no 'origin' remote — a release has nowhere to go." >&2
    echo "create the repo first:  gh repo create blackhole-mac --public --source=. --push" >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "working tree is dirty; commit before releasing." >&2
    exit 1
fi

BIN=".build/artifacts/sparkle/Sparkle/bin"
if [ ! -x "$BIN/generate_appcast" ]; then
    swift build -c release >/dev/null      # resolves the Sparkle artifact
fi

# The tag is what the download URLs are built from, so it has to exist before
# the appcast is generated, and point at what is being shipped.
git tag "$TAG" 2>/dev/null || true

VERSION="$VERSION" ./make-dmg.sh

# generate_appcast reads every archive in this directory and writes one appcast
# describing them. Hyphens rather than spaces: this file name becomes a URL.
STAGE="dist/release"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "dist/Black Hole.dmg" "$STAGE/Black-Hole-$VERSION.dmg"

REPO_URL="$(git remote get-url origin | sed -e 's|git@github.com:|https://github.com/|' -e 's|\.git$||')"
"$BIN/generate_appcast" \
    --download-url-prefix "$REPO_URL/releases/download/$TAG/" \
    "$STAGE"

echo
echo "appcast:"
grep -E "sparkle:version|sparkle:edSignature|url=" "$STAGE/appcast.xml" | sed 's/^/  /'
echo

git push origin HEAD "$TAG"
gh release create "$TAG" \
    --title "$TAG" \
    --notes "Black Hole $VERSION" \
    "$STAGE/Black-Hole-$VERSION.dmg" \
    "$STAGE/appcast.xml"

echo "released: $REPO_URL/releases/tag/$TAG"
