#!/bin/sh
# Create a stable self-signed code-signing identity for the app, once.
#
# Why this exists: macOS keys TCC grants (Screen Recording, Accessibility) to a
# binary's code signature. An ad-hoc signature is derived from the binary's
# contents, so its designated requirement is `cdhash H"..."` — every rebuild is
# a different app as far as TCC is concerned, and the permission is silently
# revoked. Signing with a certificate instead produces a requirement anchored to
# the *certificate*, which does not change when the code does.
#
# Run once, then build with:
#   CODESIGN_IDENTITY="Black Hole Dev" ./make-app.sh
#
# The certificate is self-signed and lives only in your login keychain. To undo:
#   security delete-certificate -c "Black Hole Dev"
set -e

NAME="${1:-Black Hole Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "identity already present: $NAME"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# codeSigning EKU is the part that matters — without it `codesign` will not
# accept the identity, and `security find-identity -p codesigning` skips it.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# Security.framework rejects a PKCS#12 bundle with an empty password ("MAC
# verification failed"), so the transfer gets a throwaway one. It never leaves
# this script — the file is deleted on exit.
PASS="transfer-$$"
openssl pkcs12 -export \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout "pass:$PASS"

# -T /usr/bin/codesign puts codesign on the private key's ACL, so signing does
# not pop a keychain prompt every single time.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" \
    -T /usr/bin/codesign -T /usr/bin/security

# A self-signed certificate has no chain to a trusted root, so it has to be
# trusted explicitly for the code-signing policy. User trust domain — no sudo.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" \
  || echo "note: could not set trust automatically; open Keychain Access, find" \
          "\"$NAME\", and set Code Signing to \"Always Trust\""

echo
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "created signing identity: $NAME"
    echo
    echo "Build with it:"
    echo "  CODESIGN_IDENTITY=\"$NAME\" ./make-app.sh"
else
    echo "identity was imported but is not valid for code signing yet."
    echo "Open Keychain Access ▸ login ▸ Certificates, double-click \"$NAME\","
    echo "expand Trust, and set Code Signing to \"Always Trust\"."
    exit 1
fi
