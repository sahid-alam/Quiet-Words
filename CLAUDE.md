# Quiet Words

Local push-to-talk dictation for macOS. Hold a key, talk, text lands at the cursor.
Everything runs on-device — no API keys, no subscription. The only network use is a
one-time, checksum-pinned download of the clean-up model (Gemma 4 E2B, 2 GB).

**Resuming? Read [docs/status.md](docs/status.md) first** — what is built, what is open,
and what is next. Full scope, phase order and measurements: [docs/plan.md](docs/plan.md). Source transcript that
seeded the idea: [docs/resource-yt.md](docs/resource-yt.md).

## Verified environment

Checked on this machine, not assumed:

| | |
|---|---|
| macOS | 26.6 (25G70), arm64 |
| Xcode / Swift | 26.6 / 6.3.3 |
| `SpeechTranscriber.isAvailable` | `true` |
| `installedLocales` | `en_US` present (plus 8 other English locales) |
| `AssetInventory.maximumReservedLocales` | 5 |

Re-run the probe any time with `swift scripts/probe-speech.swift`.

## Build shape — decided, do not re-litigate

SwiftPM executable target + `scripts/bundle.sh` that assembles a real `.app`.
No `.xcodeproj` — it is opaque to edit and diff.

```
swift build -c release          # binary → .build/release/QuietWords
./scripts/bundle.sh             # → build/QuietWords.app (Info.plist + codesign)
open build/QuietWords.app
```

The app **must** be a signed bundle with a stable bundle ID. A bare `swift build`
binary cannot hold TCC grants for microphone or accessibility.

- Bundle ID: `com.sahidalam.quietwords` — never change it, TCC grants are keyed to it.
- `LSUIElement = true` (menu-bar app, no Dock icon).
- `Info.plist` needs `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`.

## Speech API — use the macOS 26 surface

**Do not use** `SFSpeechRecognizer`, `SFSpeechAudioBufferRecognitionRequest`,
`SFSpeechRecognitionTask`, or `requestAuthorization(_:)`. Those are the pre-26 API and
every stale training example reaches for them. This project uses `SpeechAnalyzer`.

Signatures pulled from the installed SDK:

```swift
// Module
SpeechTranscriber(locale: Locale, preset: .progressiveTranscription)
SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)
//   ReportingOption: .volatileResults | .alternativeTranscriptions | .fastResults
//   For live HUD text you want .volatileResults (and .fastResults for lower latency).

static var isAvailable: Bool                      // sync
static var supportedLocales: [Locale]             // async
static var installedLocales: [Locale]             // async
var availableCompatibleAudioFormats: [AVAudioFormat]  // async — feed this to the tap
var results: some AsyncSequence<Result, Error>

struct Result { let range: CMTimeRange; var text: AttributedString; let alternatives: [AttributedString] }
extension SpeechModuleResult { var isFinal: Bool }   // finality lives here, not on Result

// Assets — reservation is the gate, not download. Measured on this machine:
//   status .supported  ->  reserve(locale:) == true  ->  status .installed
// The installation request comes back non-nil but with totalUnitCount == 0, i.e. there
// is nothing to download once the locale is in `installedLocales`. Reservations persist
// across launches (release() did not clear one), so branch on status, don't reserve blindly.
AssetInventory.status(forModules:) async -> .unsupported | .supported | .downloading | .installed
AssetInventory.reserve(locale:) async throws -> Bool     // max 5 concurrent
AssetInventory.assetInstallationRequest(supporting:) async throws -> AssetInstallationRequest?
  .downloadAndInstall() async throws         // only needed for a locale not yet installed

// Analyzer (an actor)
SpeechAnalyzer(modules: [...])
prepareToAnalyze(in: AVAudioFormat?) async throws
start(inputSequence:) async throws            // AsyncSequence<AnalyzerInput>
finalizeAndFinishThroughEndOfInput() async throws
cancelAndFinishNow() async

AnalyzerInput(buffer: AVAudioPCMBuffer, bufferStartTime: CMTime?)
```

## Known traps — these are where the time goes

1. **Text injection silently no-ops in Electron apps.** `AXUIElementSetAttributeValue`
   with `kAXSelectedTextAttribute` returns `.success` and does nothing in VS Code, Cursor,
   Slack, Discord. Pasteboard + synthetic `Cmd+V` is the primary path, AX is the
   optimisation. Save and restore the previous pasteboard contents.
2. **Ad-hoc codesign breaks the accessibility grant on every rebuild.** TCC keys ad-hoc
   apps by cdhash. Solved: `scripts/make-signing-cert.sh` creates the self-signed
   `Quiet Words Dev` identity once, and `bundle.sh` picks it up automatically. The grant
   then survives rebuilds.
3. **The HUD must not steal focus.** A panel that activates changes the frontmost app,
   so the text injects into the HUD instead of the user's editor. Non-activating panel,
   `ignoresMouseEvents`.
4. **Fn is not an ordinary modifier.** It arrives as `.flagsChanged` with `.function`.
   A global `NSEvent` monitor can observe it but cannot suppress it; a `CGEventTap`
   can, and needs accessibility permission already granted.
5. **Audio format mismatch fails silently.** Take the format from
   `availableCompatibleAudioFormats`, convert the tap buffer to it, pass the same format
   to `prepareToAnalyze(in:)`.
6. **`availableCompatibleAudioFormats` is unordered.** It returns 16kHz *and* 8kHz, and
   which one is `.first` changes between runs. Take `max(by: sampleRate)`.
7. **`AVAudioFile.read(into:)` throws at EOF** rather than returning zero frames — and it
   throws `_GenericObjCError.nilError`, which names nothing. Loop on
   `framePosition < length`.
8. **`assert` is compiled out of release builds**, and the app only runs as a release
   bundle. Demo checks use `precondition`.
9. **`AVAudioEngine` cannot record from a non-default input device.** Setting
   `kAudioOutputUnitProperty_CurrentDevice` on `inputNode.audioUnit` returns `noErr` and
   does nothing — the engine still opens the system default. Measured: with the property
   set to the built-in mic, the Bluetooth headset *still* dropped into hands-free mode,
   and the tap died after ~0.3s because it was built for the built-in mic's 48kHz while
   the hardware ran at the headset's 16kHz. Uninitialize/set/initialize does not help.
   The only reliable options are changing the system default input, or `AVCaptureSession`,
   which takes an explicit `AVCaptureDevice`. Do not re-attempt the AU property.
10. **Opening a Bluetooth mic wrecks that headset's output for the whole machine.** macOS
   switches it from A2DP to the hands-free profile: output goes from 2ch/44.1kHz to
   1ch/16kHz — "phone speaker" — for as long as the mic is held, and recovers on release.
   Nothing the app does to its own audio graph avoids this. Verify with
   `system_profiler SPAudioDataType` during a capture.
11. **`inputNode.outputFormat(forBus:)` can go stale**; `inputFormat(forBus:)` reports the
   hardware's real format. Use the latter for the tap.
12. **SwiftUI chrome cannot be captured offscreen, and `CGWindowListCreateImage` is
   unavailable in the macOS 26 SDK.** The symbol still exists at runtime, though, and an
   app may capture its own windows without a Screen Recording grant — `--demo ui` looks it
   up with `dlsym`. Review the PNGs in a subagent: one image over 2000px anywhere in a
   conversation makes every later image read fail.
13. **Do not keep window panes built by stacking them in a ZStack.** It removed Settings'
   100–220ms rebuild, but the title bar latched onto the hidden Settings form's scroll view
   (the one pane taller than the window) and the sidebar jumped 11px for good.
   `scrollEdgeEffectHidden` does not help. `--demo ui` fails if this comes back.
14. **Clean-up runs on LiteRT-LM via `dlopen`, not a link.** `scripts/fetch-litert.sh`
   pulls `liblitert-lm.dylib` (63 MB, pinned 0.18.0) into gitignored `vendor/`; `bundle.sh`
   signs it into `Contents/Frameworks`. Its C API has no stability promise — the signatures
   in `Cleanup.swift` were copied from that wheel's `litert_lm/_ffi.py`. Bump both together.
   Every output must pass `cleanupIsSafe`, and a segment starting with "no / wait / actually"
   is cleaned together with the one before — cleaned apart, neither half can apply it.

## Conventions

- Swift 6 strict concurrency. The analyzer is an actor; keep audio off the main actor.
- Persistence is JSON in `~/Library/Application Support/QuietWords/`. No SwiftData, no
  Core Data, until a JSON file measurably hurts.
- One runnable check per non-trivial phase, all in `Demo.swift`, run from inside the
  bundle so TCC attributes the grants to the app:
  `build/QuietWords.app/Contents/MacOS/QuietWords --demo <name>` — the full list is in
  [docs/status.md](docs/status.md); `ui` drives the real window.
  No committed fixtures — the transcription check renders its own audio with `say`.
- Log with `os.Logger(subsystem: "com.sahidalam.quietwords", category: ...)`.
  Tail it with `log stream --predicate 'subsystem == "com.sahidalam.quietwords"'`.
- Mark deliberate shortcuts with a `// ponytail:` comment naming the ceiling.

## Permissions

```bash
tccutil reset Microphone com.sahidalam.quietwords
tccutil reset Accessibility com.sahidalam.quietwords
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```
