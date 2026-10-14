#!/bin/bash
# Fetch LiteRT-LM's runtime (liblitert-lm.dylib, Apache-2.0) into vendor/, once.
# It is 63 MB, so it is not committed; bundle.sh copies it into the app.
# The library is what runs Gemma for the clean-up pass — see Sources/QuietWords/Cleanup.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="vendor/liblitert-lm.dylib"
[ -f "$OUT" ] && exit 0

# Pinned: the C API has no stability promise, and Cleanup.swift binds to this version's symbols.
URL="https://files.pythonhosted.org/packages/cc/df/147e5fa60cf8964bdcbc022cbd38502f91ea415bf82bed2c9335fcf9be9d/litert_lm_api-0.18.0-py3-none-macosx_12_0_arm64.whl"
SHA="9fd0c55835e469a035c1b75cde4797b26292963c2c36d9fcdfceb965ffa08a37"

mkdir -p vendor
WHEEL="$(mktemp -d)/litert.whl"
curl -sfL -o "$WHEEL" "$URL"
echo "$SHA  $WHEEL" | shasum -a 256 -c - >/dev/null
unzip -q -j -o "$WHEEL" "litert_lm/liblitert-lm.dylib" -d vendor
rm -rf "$(dirname "$WHEEL")"
echo "fetched $OUT"
