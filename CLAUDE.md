# Quiet Words

Local push-to-talk dictation for macOS. Hold a key, talk, text lands at the cursor.
Everything runs on-device — no network, no API keys, no subscription.

Full scope and phase order: [docs/plan.md](docs/plan.md). Source transcript that
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

## Conventions

- Swift 6 strict concurrency. The analyzer is an actor; keep audio off the main actor.
- Persistence is JSON in `~/Library/Application Support/QuietWords/`. No SwiftData, no
  Core Data, until a JSON file measurably hurts.
- One runnable check per non-trivial phase, all in `Demo.swift`, run from inside the
  bundle so TCC attributes the grants to the app:
  `build/QuietWords.app/Contents/MacOS/QuietWords --demo audio|transcribe|inject`.
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
