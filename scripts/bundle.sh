#!/bin/bash
# Assemble build/QuietWords.app from the SwiftPM release binary.
# A signed bundle with a stable bundle ID is required — TCC grants can't attach to a
# bare executable. See CLAUDE.md.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.sahidalam.quietwords"
APP="build/QuietWords.app"
BIN=".build/release/QuietWords"
# Prefer the stable self-signed identity; TCC keys ad-hoc apps by cdhash, so under ad-hoc
# the accessibility grant dies on every rebuild. Create it with scripts/make-signing-cert.sh.
if [ -z "${SIGN_ID:-}" ]; then
    if security find-identity -v -p codesigning | grep -q "Quiet Words Dev"; then
        SIGN_ID="Quiet Words Dev"
    else
        SIGN_ID="-"
        echo "warning: signing ad-hoc — accessibility will need re-granting after every" >&2
        echo "         build. Run ./scripts/make-signing-cert.sh once to stop that." >&2
    fi
fi

[ -x "$BIN" ] || { echo "missing $BIN — run: swift build -c release" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QuietWords"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Quiet Words</string>
  <key>CFBundleDisplayName</key><string>Quiet Words</string>
  <key>CFBundleExecutable</key><string>QuietWords</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Quiet Words listens while you hold the dictation key, and transcribes on this device.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Quiet Words transcribes your speech on this device. Nothing is sent anywhere.</string>
</dict>
</plist>
PLIST

plutil -lint -s "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature'
echo "built $APP"
