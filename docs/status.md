# Status — where things stand

Snapshot as of 2026-09-11. Read this first when resuming; [plan.md](plan.md) holds the
reasoning and measurements, this file holds the state.

## Built and verified

| Area | State | Check |
|---|---|---|
| Bundle, signing, TCC | Self-signed `Quiet Words Dev` identity, grants survive rebuilds | launch log |
| Push-to-talk | Right Option hold, double-tap hands-free, Esc cancels, <200ms tap discarded | live |
| Capture → transcript | `SpeechTranscriber`, 16kHz Int16 conversion, warm session | `--demo audio`, `transcribe` |
| Injection | Pasteboard + Cmd+V, clipboard restored byte-identical; works in Electron | `--demo inject` + manual |
| HUD | Non-activating bottom-centre panel, waveform + live caption | `--demo hud` |
| History | JSONL, append-only, **never trimmed** — it is the corpus for any future model | `--demo window` |
| Dictionary | (heard → meant), fed as contextual strings and applied after | `--demo dictionary` |
| Learned corrections | Watches the field after injection; waits for typing to settle; suggestions need a yes | `--demo learning` |
| Clean-up | Filler words, optional hedges, stutter collapse (37µs regex) | `--demo dictionary` |
| Languages | 54 via two engines (`SpeechTranscriber` preferred, `DictationTranscriber` for the rest) | `--demo languages` |
| Hinglish | Custom language model on `en_IN`; 2 → 8 Hinglish words recognised | `--demo hinglish` |
| Mic choice, launch at login, sound cues, recordings | Shipped | `--demo devices`, `login` |

Run every check: `for d in audio transcribe dictionary hud window inject devices login languages learning hinglish; do build/QuietWords.app/Contents/MacOS/QuietWords --demo $d | tail -1; done`

## Decided, with evidence in plan.md

- **No automatic LLM clean-up.** Apple's on-device model answered dictation instead of
  cleaning it, or returned it unchanged after 7s. Explicit transforms are where it fits.
- **No cloud APIs.** Costs the only structural advantage over Wispr.
- **No training yet.** Use the rule-based pass daily, read `history.jsonl`, then decide.
  If it happens: LoRA on an open 1–3B via MLX, not an Apple adapter (they break every OS update).
- **`hi_IN` is not obtainable here** — zero-unit install request. Hinglish goes via the custom LM.

## Open, needs a human

- Hinglish quality on a real voice (checks use a TTS voice).
- Injection matrix beyond Antigravity: TextEdit, Notes, Safari address bar, Slack, Terminal.
- All four window panes and the icon — see "App shape" below.

## App shape — built 2026-09-11, awaiting a look

Now a regular Dock app, like Wispr Flow: Dock icon, Cmd+Tab, a main menu bar
(Settings… is Cmd+,), and the window opens at launch. Clicking the Dock icon reopens it;
closing it leaves dictation running. The menu-bar icon stays for status.

- Icon: `scripts/make-icon.swift` draws it; `Resources/AppIcon.icns` is committed and
  `bundle.sh` copies it in. Rerun the script to change it.
- Window: sidebar of Home, History, Dictionary, Settings. Home has the words / WPM /
  streak cards, pending learned corrections, and the last five transcripts. Dictionary
  shows a badge when corrections are waiting.
- The main menu also fixes a quiet bug: with no Edit menu, Cmd+C/V did nothing in the
  app's own text fields — including our synthetic paste when dictating into them.
- To go back to menu-bar-only: `.regular` → `.accessory` in `main.swift`.

**Not yet checked by eye.** The layout of all four panes, and the icon, need a person to
look — nothing offscreen can capture SwiftUI's chrome.

## Next

1. **Onboarding window** on first launch — microphone, accessibility, then "hold Right
   Option and say something" with the result shown live.
2. **Later, one at a time:** Snippets (voice-triggered text expansion — the dictionary
   already does this for `my email`), Style per app, Command Mode on Apple's model.

Mobbin references pulled (web — Mobbin has no macOS category, and no Wispr Flow):
Otter AI, Fireflies and ElevenLabs home screens; Grammarly and Copilot sidebar
dashboards; Grammarly and WRITER vocabulary pages; Intercom's keyboard-shortcut
tutorial. Screen links are in the conversation that produced this file. The images
themselves were not viewed — see below.

## Gotchas for whoever resumes

- DictationTranscriber and anything needing TCC must run **inside the bundle**
  (`--demo …`), never from `swift file.swift` — it hangs indefinitely there.
- Settings fields must stay optional in `Saved`, or adding one resets all preferences.
- A conversation holding an image over 2000px makes every later image read fail, which
  is what blocked viewing Mobbin screens here. Downscale screenshots before sharing.
