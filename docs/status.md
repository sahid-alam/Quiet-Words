# Status — where things stand

Snapshot as of 2026-10-13. Read this first when resuming; [plan.md](plan.md) holds the
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
| Smart clean-up | Gemma 4 E2B (general build) via LiteRT-LM, per segment, on by default; fixes grammar, safety check falls back to raw | `--demo cleanup` |
| Languages | 54 via two engines (`SpeechTranscriber` preferred, `DictationTranscriber` for the rest) | `--demo languages` |
| Hinglish | Custom language model on `en_IN`; 2 → 8 Hinglish words recognised | `--demo hinglish` |
| Mic choice, launch at login, sound cues, recordings | Shipped | `--demo devices`, `login` |

Run every check: `for d in audio transcribe dictionary hud window inject devices login languages learning hinglish cleanup ui; do build/QuietWords.app/Contents/MacOS/QuietWords --demo $d | tail -1; done`

## Decided, with evidence in plan.md

- **Automatic clean-up is Gemma 4 E2B, not Apple's model** (reversed 2026-10-13). Apple's
  answered dictation or returned it unchanged after 7s. E2B: 0.35–0.6s a segment, loads in
  2s, ~480 MB footprint, keeps Hinglish in Hinglish. 12B took 3.4–4.5s. Numbers and the
  safety check's rules in plan.md.
- **Hinglish assist is on by default** (it is the main use case).
- **No cloud APIs.** Costs the only structural advantage over Wispr.
- **No training yet.** Use the rule-based pass daily, read `history.jsonl`, then decide.
  If it happens: LoRA on an open 1–3B via MLX, not an Apple adapter (they break every OS update).
- **`hi_IN` is not obtainable here** — zero-unit install request. Hinglish goes via the custom LM.

## Open, needs a human

- Smart clean-up on real speech: hold the key, say two sentences with a "no wait" in them,
  then `log show --last 2m --predicate 'subsystem == "com.sahidalam.quietwords"'` — the
  `… after key-up` line is the real latency, and `rejected:` lines (private; enable private
  data to read them) are outputs the safety check threw out. The checks use `say`.
- Expect ~0.5s after key-up even for one phrase: each segment is held until the next one
  shows it is not being corrected, so a one-phrase dictation is cleaned entirely after
  key-up. Overlap only helps multi-phrase speech. That is the price of applying corrections.
- The download path (`CleanupModel.ensure`) has not run — the model was moved in by hand
  on this machine. Move it aside once to see Settings' status line go through it.
- `--demo audio` reads peakRMS 0 and `--demo ui` fails on Settings (title bar moves at
  clicks 3 and 5). Both fail identically on eb7ca8d, before the clean-up work — not caused
  by it, not yet investigated.

- Hinglish quality on a real voice (checks use a TTS voice).
- Injection matrix beyond Antigravity: TextEdit, Notes, Safari address bar, Slack, Terminal.

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

**Tested end to end with `--demo ui`.** It clicks Home → History → Dictionary → Settings →
Home → Settings → History → Dictionary → Home on the real window, captures the window
after every click to `$TMPDIR/quietwords-ui/`, and fails if the window changes size, the
sidebar is left with nothing selected, a pane renders blank (under 20 brightness levels in
the content area), or the title bar or sidebar top moves. Review the PNGs in a subagent
(see Gotchas). Fixed by that run, 2026-09-11:

- **Dictionary rendered completely blank**, with the sidebar collapsed beside it — a VStack
  of a paragraph, a card and a List asked for 2567pt. Now a grouped Form, like Settings.
- Clicking empty sidebar space deselected everything. `Router` now refuses nil.
- Every pane started at a different height and inset. Now they line up.
- Still there: **clicking Settings costs 100–220ms**, because the Form is rebuilt. Keeping
  panes built removed that but broke the title bar — see CLAUDE.md trap 13.

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
- A conversation holding an image over 2000px makes every later image read fail. Mobbin's
  own results are that big, so run Mobbin — and any screenshot review — in a subagent,
  and have it downscale with `sips -Z 1200` before reading.
