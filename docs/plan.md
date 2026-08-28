# Quiet Words — full scope

A local push-to-talk dictation app for macOS. Hold a key, speak, the text appears where
your cursor is. On-device, no network, no subscription. Functionally a WhisperFlow
replacement; see [resource-yt.md](resource-yt.md) for the transcript that seeded it.

## Calibration first

The source video frames this as a 20-minute, two-prompt build. That is a demo artifact —
the cut skips the three things that actually consume the time, all of them
environment-dependent and none of them visible on screen:

1. **TCC permissions.** Microphone and accessibility grants, and keeping them across
   rebuilds.
2. **The Fn-key event tap.** Push-to-talk means tracking key-down and key-up on a
   modifier that is not an ordinary modifier.
3. **Text injection into Electron apps.** The accessibility API reports success and
   does nothing. The video hits this on camera and moves past it in ten seconds.

Everything else — audio capture, transcription, the HUD, the history window — is
genuinely fast, because macOS 26 does the hard part. Budget accordingly: the risky
third of this project is phases 0, 3 and 4.

## Decisions already made

| Decision | Choice | Why |
|---|---|---|
| Build system | SwiftPM executable + `scripts/bundle.sh` | `.xcodeproj` is opaque to edit and diff; a bare binary can't hold TCC grants |
| Speech engine | `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26) | Built in, on-device, no download, no API. Verified available on this machine |
| Parakeet / Whisper | Out of scope by default | The video's own benchmark: native lost by ~0.2s and won decisively on setup cost |
| Injection | Pasteboard + synthetic `Cmd+V` primary, AX opportunistic | AX silently fails in Electron. Designing AX-first and bolting on a fallback is the bug |
| Persistence | JSON in `~/Library/Application Support/QuietWords/` | Hundreds of rows. SwiftData when it hurts, not before |
| App shape | `LSUIElement` menu-bar agent + optional main window | Dictation is invoked by hotkey, not by clicking a Dock icon |
| Bundle ID | `com.sahidalam.quietwords` | Fixed forever — TCC grants key off it |

## Phase order — by risk, not by feature

Each phase ends with one runnable check. A phase is not done until its check passes.

---

### Phase 0 — Bundle, signing, permissions

No audio, no transcription. Prove the container works before putting anything in it.

- `Package.swift`, executable target `QuietWords`, macOS 26 platform, Swift 6 tools.
- `scripts/bundle.sh` — **already written.** Assembles
  `build/QuietWords.app/Contents/{MacOS,Resources}`, writes `Info.plist`, ad-hoc
  codesigns with a fixed identifier. It currently exits 1 with
  `missing .build/release/QuietWords`; that error going away is the first sign of life.
- `Info.plist`: `CFBundleIdentifier`, `LSUIElement=true`, `NSMicrophoneUsageDescription`,
  `NSSpeechRecognitionUsageDescription`, `LSMinimumSystemVersion=26.0`.
- `AppDelegate` that logs, at launch: mic authorization state
  (`AVCaptureDevice.authorizationStatus(for: .audio)`) and accessibility trust
  (`AXIsProcessTrustedWithOptions` with the prompt option set).
- Menu-bar `NSStatusItem` with a Quit item. That is the entire UI for now.

**The codesign trap.** Ad-hoc signing (`-s -`) means TCC keys the accessibility grant to
the binary's cdhash, which changes on every rebuild — the grant silently stops applying
and the app looks broken. Start ad-hoc and measure how often it bites. If it bites,
create a self-signed code-signing certificate once in Keychain Access
(Certificate Assistant → Create a Certificate → Code Signing, self-signed), then sign
with `-s "Quiet Words Dev"` instead. The grant then survives rebuilds.

> **Check:** `open build/QuietWords.app`, then
> `log show --last 1m --predicate 'subsystem == "com.sahidalam.quietwords"'` prints both
> permission states. `codesign -dv build/QuietWords.app` reports the right identifier.

---

### Phase 1 — Audio capture

- `AVAudioEngine`, tap on `inputNode`.
- Ask the transcriber for `availableCompatibleAudioFormats` and convert the tap buffer to
  the chosen format with `AVAudioConverter`. A mismatch here produces silence, not an
  error — this is the single most common silent failure in the stack.
- Bridge the tap into an `AsyncStream<AnalyzerInput>` via a continuation.
- Compute a cheap RMS per buffer and publish it; the HUD waveform reads this later.
- Start the engine on key-down, stop and finish the stream on key-up.

> **Check:** a `demo()` that records 2 seconds, asserts it received buffers in the target
> format and that peak RMS is non-zero while speaking.

---

### Phase 2 — Transcription

- `SpeechTranscriber(locale: .current, preset: .progressiveTranscription)` — progressive
  gives volatile partials for the HUD plus finalized text for injection.
- **Gate first use on assets — but the gate is reservation, not download.** Measured
  here: `status(forModules:)` reports `.supported`, `reserve(locale:)` returns `true`,
  and status then reads `.installed`, with the installation request carrying zero units
  to download. So for a locale already in `installedLocales` the whole cost is one
  `reserve` call. Reservations persist across launches, so branch on status rather than
  reserving every launch; the cap is 5 concurrent locales.
- Keep `downloadAndInstall()` on the error path only — it is what runs for a locale the
  user picks that is *not* already installed, and it is the one place a progress UI is
  warranted. Do it at launch (Phase 0's check), not on the first hotkey press.
- `SpeechAnalyzer(modules: [transcriber])`, `prepareToAnalyze(in: format)`,
  `start(inputSequence:)` with the Phase 1 stream.
- Consume `transcriber.results`. `result.isFinal` (from the `SpeechModuleResult`
  extension, not the struct) separates volatile partials from committed text. Accumulate
  finals; the volatile tail is display-only.
- On key-up: `finalizeAndFinishThroughEndOfInput()`, then emit the assembled string.
  On cancel: `cancelAndFinishNow()`.

> **Check:** `demo()` transcribes a short bundled `.wav` through the same analyzer path
> and asserts the text is non-empty and contains an expected word.

---

### Phase 3 — Push-to-talk hotkey

- Default key: **Right Option** — a deliberate deviation from the source video, which
  uses Fn. Fn works, but on many keyboards it is already bound to emoji picker or system
  dictation, and intercepting it fights the OS. Make the binding configurable and offer
  Fn as a choice.
- `CGEventTap` at `.cgSessionEventTap` on `.flagsChanged` (plus `.keyDown`/`.keyUp` if a
  non-modifier key is bound). Requires accessibility permission — hence Phase 0 first.
- Push-to-talk is a state machine, not an event: modifier-down starts capture,
  modifier-up finalizes, and a tap-and-release under ~200ms should cancel rather than
  transcribe silence.
- Handle `kCGEventTapDisabledByTimeout` by re-enabling the tap. It will happen.
- Escape while recording cancels and discards.

> **Check:** log line pairs `hotkey.down` / `hotkey.up` with the held duration, observed
> live in `log stream` while holding the key.

---

### Phase 4 — Text injection

The known-hard one. Order matters.

1. Snapshot `NSPasteboard.general` contents (all types, all items) and the change count.
2. Write the transcript, synthesise `Cmd+V` via `CGEvent` posted to
   `.cghidEventTap`, with the correct flags on both key-down and key-up.
3. Restore the pasteboard after a short delay (~150ms — the target app needs to read it
   first). Restoring too fast pastes the old contents.
4. *Optional, later:* try `AXUIElementSetAttributeValue(kAXSelectedTextAttribute)` on the
   focused element first and fall back to paste — but only after verifying per-app,
   because it returns `.success` while doing nothing in every Chromium/Electron app.

Also: the frontmost app must not change between capture and injection. Capture
`NSWorkspace.shared.frontmostApplication` at key-down and inject there.

> **Check:** a manual matrix, recorded in this file — TextEdit, Notes, Safari address
> bar, VS Code / Cursor, Slack, Terminal. Each either works or is a documented
> known-failure. Plus an automated check that the pasteboard is byte-identical before
> and after an injection.

| Target | Result | Measured |
|---|---|---|
| Antigravity IDE (`com.google.antigravity-ide`) — Electron | works | 2026-08-28, 47 and 202 chars |
| TextEdit | untested | |
| Notes | untested | |
| Safari address bar | untested | |
| Cursor / VS Code | untested | |
| Slack | untested | |
| Terminal | untested | |

Electron was the one expected to fail, and paste carries it. The pasteboard round-trip is
`--demo inject`; note that check cannot prove the paste itself, because a binary launched
from a shell inherits the terminal's TCC identity and `CGEvent.post` silently no-ops.

---

### Phase 5 — HUD

- Borderless `NSPanel`, `.nonactivatingPanel` style, `.floating` level,
  `collectionBehavior` including `.canJoinAllSpaces` and `.stationary`,
  `ignoresMouseEvents = true`, `hidesOnDeactivate = false`.
- **It must never become key.** If it activates, the frontmost app changes and Phase 4
  injects into the wrong place.
- Content: a waveform driven by the Phase 1 RMS values, and the volatile transcript tail.
- Positioned bottom-centre of the screen with the mouse, fading in on key-down.

> **Check:** with the HUD visible, `NSWorkspace.shared.frontmostApplication` is still the
> editor, and an injection still lands correctly.

---

### Phase 6 — Main window

- History: every transcript with timestamp, duration, and the target app. JSON-backed,
  searchable, copy and delete. Cap at a few thousand entries with trimming.
- Dictionary: user terms that get corrected in post-processing — `claude code`,
  `Xcode`, proper nouns. The video demonstrates this working and it is the single
  highest-value feature after transcription itself.
  - Implement as `AssetInventory`-independent post-processing: case-insensitive
    whole-word replacement over the final text, applied before injection.
  - Feed the same terms to the transcriber as `contextualStrings` via `AnalysisContext`
    so the model biases toward them up front rather than only correcting after.
- Settings: hotkey binding, locale, launch-at-login, auto-punctuation toggle.
  - **Auto-punctuation cannot be a setting.** `SpeechTranscriber.TranscriptionOption` has
    exactly one case, `.etiquetteReplacements` (profanity masking). `.punctuation` lives on
    `DictationTranscriber`, a different module. `SpeechTranscriber` always punctuates.
  - Hotkey binding and locale are still open; launch-at-login is Phase 7.

> **Check:** a dictionary entry `claude code` corrects a transcript containing
> "clawed code", asserted in a unit test over the post-processing function alone.

---

### Phase 7 — Polish (optional, only if used daily)

- Launch at login (`SMAppService.mainApp.register()`).
- Sound cues on start/stop.
- Per-app behaviour overrides (e.g. always paste in Terminal).
- Visual identity. The video's design brief — 1980s tape recorder, explicitly not
  synthwave neon — is a good brief. Worth doing once the thing is used every day.

### Explicitly out of scope

- Parakeet / Whisper / any downloaded model. Native won on setup cost; revisit only if
  accuracy proves inadequate in real use, and only behind an engine protocol added *at
  that point*, not now.
- An LLM cleanup pass for filler words and punctuation. `SpeechTranscriber` already
  punctuates. Adding a second local model triples the install story for a marginal gain.
- Windows or Linux. The whole design is `Speech.framework` and `CGEventTap`.
- iCloud sync, teams, accounts, telemetry.

## Working agreement

- One phase at a time, check passing before the next.
- Phases 0–4 are the product. 5 and 6 are what make it pleasant. 7 is optional.
- If a phase's check cannot be made to pass, say so and stop rather than building the
  next phase on top of it.
