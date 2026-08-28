---
name: build-run
description: Build, bundle, sign, launch Quiet Words and tail its log. Use whenever the app needs to be run, restarted, or observed after a code change — and before claiming any change works.
---

# Build and run Quiet Words

One loop. Run it after every change that touches app code.

```bash
pkill -x QuietWords 2>/dev/null
swift build -c release 2>&1 | tail -20 || exit 1
./scripts/bundle.sh || exit 1
open build/QuietWords.app
```

Then watch what it actually did — the app is a background agent with no stdout:

```bash
log stream --predicate 'subsystem == "com.sahidalam.quietwords"' --level debug --style compact
```

Run the tail in the background, exercise the app, read the output. `log show --last 2m
--predicate '...'` retrieves what you missed.

## When it launches but does nothing

Check permissions before debugging code — a missing TCC grant looks exactly like a
logic bug:

```bash
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "select service, auth_value from access where client='com.sahidalam.quietwords'" 2>/dev/null \
  || echo "TCC.db unreadable (needs Full Disk Access) — check System Settings manually"
```

`auth_value` 2 = granted. Missing row = never prompted. If accessibility dropped after a
rebuild, that is the ad-hoc codesign cdhash problem — see docs/plan.md Phase 0.

```bash
tccutil reset Accessibility com.sahidalam.quietwords
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

## Verifying the bundle itself

```bash
codesign -dv --verbose=2 build/QuietWords.app   # identifier must be com.sahidalam.quietwords
plutil -p build/QuietWords.app/Contents/Info.plist
```

## Speech stack sanity check

Independent of the app, confirms the OS side is healthy:

```bash
swift scripts/probe-speech.swift
```

Expect `isAvailable: true` and `en_US` in `installedLocales`.
