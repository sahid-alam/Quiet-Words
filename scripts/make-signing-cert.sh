#!/bin/bash
# One-time: create a self-signed code-signing identity so TCC grants survive rebuilds.
#
# Ad-hoc signing keys the accessibility grant to the binary's cdhash, which changes on
# every build — the grant silently stops applying and the app looks broken. A stable
# signing identity fixes that. See docs/plan.md Phase 0.
set -euo pipefail

NAME="Quiet Words Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "'$NAME' already exists — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# Legacy PBE — macOS Security.framework does not read OpenSSL 3's modern PKCS#12 defaults.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
    -name "$NAME" -passout pass:quietwords \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

security import "$TMP/id.p12" -k "$KEYCHAIN" -P quietwords -T /usr/bin/codesign -A
# Self-signed certs are not valid for codesign until trusted. User trust settings only —
# this does not touch the system trust store and needs no sudo.
security add-trusted-cert -r trustRoot -p codeSign "$TMP/cert.pem"

security find-identity -v -p codesigning | grep "$NAME"
echo
echo "Now: SIGN_ID=\"$NAME\" ./scripts/bundle.sh"
