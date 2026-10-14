# Quiet Words

Push-to-talk dictation for macOS that runs entirely on your Mac. Hold a key, talk, and the
text lands at the cursor in any app. No account, no API keys, no subscription.

- Hold **Right Option** to dictate; double-tap to keep listening hands-free; **Esc** cancels.
- Transcription by Apple's on-device speech models (`SpeechAnalyzer`), 54 languages.
- Hinglish (romanized Hindi mixed with English) through a custom language model.
- Smart clean-up by Gemma 4 E2B running locally: removes fillers and stutters, applies
  self-corrections ("friday, no wait, thursday" → "Thursday"), fixes grammar lightly, and
  keeps Hinglish in Hinglish. Each phrase is cleaned while you are still talking. Any
  output that adds or loses meaning is discarded in favour of the original words.
- Dictionary of names and jargon, learned corrections, and a searchable history.

## Requirements

| | |
|---|---|
| macOS | 26 or later |
| Mac | Apple Silicon (the clean-up runtime is arm64 only). Developed and measured on an M1 with 16 GB |
| Build tools | Xcode 26 / Swift 6 toolchain |
| Disk | ~3.4 GB in `~/Library/Application Support/QuietWords/` for the clean-up model and its compiled cache, plus ~65 MB for the runtime in the app bundle |
| Memory | ~480 MB while running with clean-up loaded |
| Network | Only once: the build fetches the LiteRT-LM runtime (21 MB, from PyPI) and the app downloads the model on first launch (2.6 GB, from Hugging Face). Both are pinned and checksum-verified. Dictation itself never uses the network |
| Permissions | Microphone and Accessibility (to type into other apps). macOS asks on first launch |
| Speech languages | English is usually installed already. Others are added from the app's Settings, or System Settings → Keyboard → Dictation |

Smart clean-up can be turned off in Settings; the app then uses rule-based filler removal
only, and the model is not downloaded or loaded.

## Build and run

```bash
./scripts/make-signing-cert.sh   # once: a stable signing identity, so permissions survive rebuilds
swift build -c release
./scripts/bundle.sh              # → build/QuietWords.app (also fetches the runtime into vendor/)
open build/QuietWords.app
```

The app must run as the signed bundle: macOS ties the microphone and accessibility grants
to its bundle ID, and a bare `swift build` binary cannot hold them.

## Checks

Each feature has a runnable check, run from inside the bundle:

```bash
build/QuietWords.app/Contents/MacOS/QuietWords --demo cleanup   # or: audio, transcribe, dictionary,
                                                                #  hud, window, inject, devices, login,
                                                                #  languages, learning, hinglish, ui
```

## Third-party components

- [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) runtime, Apache-2.0 — fetched at
  build time by `scripts/fetch-litert.sh`, not committed.
- [Gemma 4 E2B](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm),
  Apache-2.0 — downloaded by the app on first launch.

Developer notes — architecture, measurements and known traps — are in
[CLAUDE.md](CLAUDE.md), [docs/status.md](docs/status.md) and [docs/plan.md](docs/plan.md).
