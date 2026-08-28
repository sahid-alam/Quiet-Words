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

- **Launch at login** — done. `SMAppService.mainApp.register()` works even from `build/`
  with the self-signed identity: status goes `.notFound` → `.enabled` and back on
  unregister, verified by `--demo login`. The registration points at wherever the bundle
  sat when it was made, so moving the app to `/Applications` means toggling it again.
- **Sound cues** — done. Tink on start, Pop on finish, Basso on cancel, at 0.25 volume,
  behind a setting.
- **Per-app behaviour overrides — dropped, not deferred.** The plan's own example was
  "always paste in Terminal", but paste is the only injection path there is; the AX route
  was never built because it silently no-ops in Electron. An override needs two behaviours
  to choose between, and there is one. Revisit only if the AX path ever lands.
- Visual identity. The video's design brief — 1980s tape recorder, explicitly not
  synthwave neon — is a good brief. Worth doing once the thing is used every day.

### The Bluetooth microphone problem

Found in real use, 2026-08-28. Dictating while wearing Bluetooth earbuds drops their
output to phone-call quality for the whole machine, because macOS switches the headset
from A2DP to the hands-free profile the moment anything opens its microphone. Measured on
a realme Buds Air6 Pro: output goes 2ch/44100 → 1ch/16000 during capture and recovers
after.

This is not something the app can dodge from inside its own audio graph.
`AVAudioEngine` ignores `kAudioOutputUnitProperty_CurrentDevice` — see trap 9 in
CLAUDE.md — so it always opens whatever macOS has as the default input.

What ships: the app reports which microphone it is recording from, warns in the menu bar
and in Settings when that is a Bluetooth device, and offers a one-click switch of the
system default input to the built-in microphone. Verified: with the system input on the
built-in mic, the headset stays at 2ch/44100 throughout a capture.

What would fix it properly: replacing `AVAudioEngine` with `AVCaptureSession`, which takes
an explicit `AVCaptureDevice` and can genuinely record from a device that is not the
system default. That is a rewrite of the core capture path and wants a person present to
test latency and dropouts, so it is not done yet.

### Languages, and the Hinglish problem

`SpeechTranscriber` does 30 locales and no Hindi. `DictationTranscriber` does 54,
including `hi_IN`. So the app carries both and picks per language, preferring
`SpeechTranscriber` where either can do it. This is the engine abstraction the scope note
below said to add "at that point" — locale coverage proving inadequate is that point, so
it is the condition being met rather than the decision being overruled.

**There is no Hinglish, and no code-switching at any price.** `selectedLocales` is
read-only and neither module has an initialiser taking an array of locales, so nothing
transcribes two languages in one utterance. What exists:

- `en_IN` plus a romanized-Hindi `contextualStrings` pack (`hinglishAssist`). Nudges the
  model toward *yaar*, *matlab*, *theek hai* instead of the English words they sound like.
  A nudge, not a second language.
- `hi_IN` via `DictationTranscriber` for Hindi proper, which returns Devanagari.
- Transliterating Devanagari back to Latin is possible natively
  (`StringTransform("Devanagari-Latin")`) but produces `bha'i, ye koda kama nahim` — which
  is nobody's Hinglish. Not shipped.

How good `hinglishAssist` actually is needs a person speaking Hinglish into it. Same
reason as the `AVCaptureSession` rewrite: no check here can tell a good transcript from a
plausible-looking bad one.

Downloading a language is minutes of work — `hi_IN` ran past fifteen. So `make()` never
downloads: it fails fast with `.notInstalled` and downloading is an explicit action in
Settings with progress. Putting it on the hotkey path would hang the HUD with no
explanation.

### Explicitly out of scope

- Parakeet / Whisper / any downloaded model. Native won on setup cost; revisit only if
  accuracy proves inadequate in real use, and only behind an engine protocol added *at
  that point*, not now.
- **An automatic LLM cleanup pass over every dictation.** Reaffirmed 2026-08-28, on
  evidence rather than the original reasoning. The install-story objection has actually
  dissolved — `FoundationModels` ships in macOS 26, `SystemLanguageModel.default`
  reports `.available` on this machine, and there is nothing to download. The model is
  simply not trustworthy in this position:

  | Prompt style | "hey can you check the the logs for me" | "write me a poem about cats" |
  |---|---|---|
  | Plain instructions | `Sure, I can check the logs for you.` | — |
  | Transcript in `<t>` delimiters | `<t>hey can you check the logs for me</t>` | `<t>cats are cute</t>` ×3 |

  Three configurations were measured against the same samples:

  | Configuration | Safe outputs | Actually cleaned? | Latency |
  |---|---|---|---|
  | Plain instructions | 0 / 6 | answered the dictation instead | 0.5–7.7s |
  | Transcript in `<t>` delimiters | 3 / 5 | barely | 3.8–7.7s |
  | `@Generable` structured output | 4 / 5 | **no — returned input unchanged** | 6.7–13s |

  Constrained decoding is what stops it answering; nothing stops it being useless. In the
  only safe configuration it left "so um the the build is is failing on on main again"
  entirely untouched and took seven seconds to do it. Loose prompting is worse: it
  invented a meeting time ("The meeting tomorrow is scheduled for 10:00 AM") and wrote a
  full poem when asked to clean "write me a poem about cats".

  **A subsequence verifier caught 100% of the bad outputs** and is worth keeping in mind
  if an LLM is ever wired in: require every word of the output to appear in the input in
  order, allowing punctuation and capitalisation to change, and fall back to the raw
  transcript otherwise. Ten lines, deterministic, and it turns an untrustworthy model
  into a safe one — it just cannot make an incapable one useful.

  **How Wispr Flow appears to have no latency**, since it comes up: it overlaps the pass
  with speech — audio streams to their servers while you talk, ASR finalises segments
  continuously, and cleanup runs per segment, so only the tail is outstanding at key-up.
  That technique is copyable here; `SpeechTranscriber` already emits final segments
  progressively. What is not copyable is a 7B–70B model on a server GPU, most likely
  fine-tuned for this one task and therefore never trained to answer anything. Latency
  was never the blocker.

  Where the model *does* belong is explicit, user-invoked transforms — select text, ask
  for "more formal" or "as bullets". There a rephrase is the point, the latency is one
  the user chose to wait for, and a bad result is visible rather than silently pasted.

- **Training our own model — not yet, and most of the reason is that the task is
  smaller than it looks.** Apple's model, in its only safe configuration, returned
  "so um the the build is is failing on on main again" unchanged after seven seconds.
  A regex collapsing immediate word repetition does it in **37 microseconds**, and now
  ships. Filler words were already a word list. What actually remains for a model is
  narrow: false starts and self-corrections ("use Postgres — actually no, SQLite"),
  telling "code like this" from "it was like really slow", and reflowing run-on speech
  into sentences.

  If that residue turns out to be worth it after real daily use, the order is:

  | Approach | Feasible? | Catch |
  |---|---|---|
  | From scratch | No | Millions of dollars for something worse than free |
  | LoRA on an open 1–3B via MLX | Yes, hours on this Mac | Needs data — solvable by inversion: take clean text and *inject* fillers and stutters, generating (messy, clean) pairs by construction |
  | `.fmadapter` for Apple's model | Yes — `SystemLanguageModel.Adapter` and `SystemLanguageModel(adapter:)` exist | Adapters pin to a base-model version. `compatibleAdapterIdentifiers` and `removeObsoleteAdapters()` exist precisely because Apple's model updates break them — retraining every macOS release, forever |

  Fine-tuning is also the thing that fixes the failure measured above: a model trained
  only to clean transcripts was never trained to answer them, so it cannot helpfully
  reply "The meeting tomorrow is scheduled for 10:00 AM" to your dictation.

  Do not start this until the rule-based cleanup has been used daily for weeks and the
  residue can be named from real transcripts. `history.json` is the corpus for that.

- **Cloud LLM APIs, free tiers included.** Every dictated word would leave the machine,
  the app would stop working offline, and network latency lands in the hot path — to buy
  something an on-device model already does. It also costs the only structural advantage
  this app has over Wispr Flow.
- Windows or Linux. The whole design is `Speech.framework` and `CGEventTap`.
- iCloud sync, teams, accounts, telemetry.

## Working agreement

- One phase at a time, check passing before the next.
- Phases 0–4 are the product. 5 and 6 are what make it pleasant. 7 is optional.
- If a phase's check cannot be made to pass, say so and stop rather than building the
  next phase on top of it.
