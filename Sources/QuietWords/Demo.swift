import AppKit
import AVFoundation
import Speech
import os

/// Phase checks. Run from inside the bundle so TCC attributes the grants to the app:
///   build/QuietWords.app/Contents/MacOS/QuietWords --demo-audio
func runDemo(_ name: String) async {
    // Unbuffered: a precondition failure kills the process without flushing stdout, and a
    // check that fails silently is worse than no check.
    setvbuf(stdout, nil, _IONBF, 0)
    switch name {
    case "audio": await demoAudio()
    case "transcribe": await demoTranscribe()
    case "inject": await demoInject()
    case "hud": await demoHUD()
    case "dictionary": demoDictionary()
    case "window": await demoWindow()
    case "login": await demoLogin()
    case "devices": demoDevices()
    case "languages": await demoLanguages()
    default: print("unknown demo '\(name)'"); exit(2)
    }
}

private func demoAudio() async {
    guard await requestMicAccess() else { print("FAIL mic access denied"); exit(1) }

    let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                               channels: 1, interleaved: true)!
    let capture = AudioCapture()
    let peak = OSAllocatedUnfairLock(initialState: Float(0))
    let recording = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "quietwords-capture-check.wav")
    try? FileManager.default.removeItem(at: recording)

    print("recording 2s — say something")
    let stream: AsyncStream<AnalyzerInput>
    do {
        print("input: \(AudioDevices.systemDefault()?.name ?? "unknown")")
        stream = try capture.start(format: target, recordTo: recording) { level in
            peak.withLock { $0 = max($0, level) }
        }
    } catch {
        print("FAIL start: \(error)"); exit(1)
    }

    Task {
        try? await Task.sleep(for: .seconds(2))
        capture.stop()
    }

    var buffers = 0
    var frames: AVAudioFramePosition = 0
    var formats = Set<String>()
    for await input in stream {
        buffers += 1
        frames += AVAudioFramePosition(input.buffer.frameLength)
        formats.insert("\(input.buffer.format.sampleRate)/\(input.buffer.format.commonFormat.rawValue)")
    }

    let seconds = Double(frames) / target.sampleRate
    let level = peak.withLock { $0 }
    print("buffers=\(buffers) frames=\(frames) (\(String(format: "%.2f", seconds))s) formats=\(formats) peakRMS=\(level)")

    precondition(buffers > 0, "no buffers reached the stream")
    precondition(formats == ["16000.0/3"], "buffers were not converted to the target format")
    precondition(seconds > 1.0, "captured less than half the requested audio")
    precondition(level > 0, "peak RMS was zero — the tap saw silence")

    // The recording sink is what retry and playback depend on.
    let written = try? AVAudioFile(forReading: recording)
    precondition(written != nil, "no WAV was written")
    precondition(written!.length == frames, "WAV holds \(written!.length) frames, stream carried \(frames)")
    print("recorded \(recording.lastPathComponent) — \(written!.length) frames")
    print("PASS audio")
}

/// Deterministic end-to-end check: `say` renders a known sentence, the same analyzer path
/// the hotkey will use transcribes it. No committed fixture.
private func demoTranscribe() async {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "quietwords-demo.wav")
    let sentence = "the quick brown fox jumps over the lazy dog"
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", url.path, "--data-format=LEI16@16000", sentence]
    do {
        try say.run()
        say.waitUntilExit()
        precondition(say.terminationStatus == 0, "say failed")

        // Same call the History retry button makes, so both are covered at once.
        let text = try await transcribe(fileAt: url, locale: Locale(identifier: "en-US"),
                                        bias: ["Xcode", "Claude Code"])
        print("transcript: \(text)")
        precondition(!text.isEmpty, "transcript was empty")
        precondition(text.lowercased().contains("fox"), "transcript missing the expected word")
        print("PASS transcribe")
    } catch {
        print("FAIL \(error)"); exit(1)
    }
}

/// The automated half of Phase 4: the user's clipboard survives an injection intact.
/// The other half is the per-app matrix in docs/plan.md, which only a human can run.
@MainActor
private func demoInject() async {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString("original clipboard", forType: .string)
    pasteboard.setData(Data([0xDE, 0xAD, 0xBE, 0xEF]), forType: .init("com.quietwords.demo"))
    let before = Injector.snapshot(pasteboard)
    precondition(!before.isEmpty, "nothing was on the pasteboard to preserve")

    // Launched from a shell this binary inherits the terminal's TCC identity, not the
    // app's, so CGEvent.post is a no-op and only the round-trip below is proven. The
    // paste itself is the manual matrix in docs/plan.md.
    print("posting process trusted=\(AXIsProcessTrusted()) — false means no paste, only the round-trip")
    print("focus a text field — injecting in 3s")
    try? await Task.sleep(for: .seconds(3))
    await Injector.inject("quiet words injection check", into: NSWorkspace.shared.frontmostApplication)

    let after = Injector.snapshot(pasteboard)
    precondition(before == after, "pasteboard was not restored byte-identically")
    print("restored \(after.count) item(s), \(after.first?.count ?? 0) type(s)")
    print("PASS inject (clipboard preserved)")
}

/// Phase 5's check: the overlay is visible and the frontmost app does not change. If it
/// does, the panel became key and every injection after it lands in the wrong window.
@MainActor
private func demoHUD() async {
    NSApplication.shared.setActivationPolicy(.accessory)
    let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"

    let hud = HUD()
    hud.show()
    hud.setText("the quick brown fox jumps over the lazy dog")
    for _ in 0..<45 {
        hud.push(level: Float.random(in: 0.0005...0.2))
        try? await Task.sleep(for: .milliseconds(70))
    }
    let after = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    let shot = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "quietwords-hud.png")
    try? hud.writePNG(to: shot)
    print("rendered \(shot.path)")
    hud.hide()
    try? await Task.sleep(for: .milliseconds(400))

    print("frontmost before=\(before) after=\(after)")
    precondition(before == after, "the HUD stole focus — injection would land in the wrong app")
    print("PASS hud")
}

/// Phase 6's check: the post-processing function alone, no store and no window.
private func demoDictionary() {
    let terms = [
        Term(heard: "clawed code", meant: "Claude Code"),
        Term(heard: "ex code", meant: "Xcode"),
    ]
    let cases: [(String, String)] = [
        ("I opened clawed code in ex code.", "I opened Claude Code in Xcode."),
        ("Clawed Code is running", "Claude Code is running"),          // case-insensitive
        ("unclawed coded", "unclawed coded"),                          // whole words only
        ("clawed code, then ex code!", "Claude Code, then Xcode!"),    // punctuation intact
        ("nothing to fix here", "nothing to fix here"),
    ]
    for (input, expected) in cases {
        let got = applyTerms(terms, to: input)
        precondition(got == expected, "\(input) -> \(got), expected \(expected)")
        print("  \(input)  ->  \(got)")
    }
    // A term with regex metacharacters must not be compiled as a pattern.
    precondition(applyTerms([Term(heard: "c++", meant: "C++")], to: "i like c++") == "i like C++")

    let fillerCases: [(String, String)] = [
        ("Um, hello there", "Hello there"),                    // leading filler, case restored
        ("So, uh, I think so", "So, I think so"),              // mid-sentence, comma cleaned
        ("write code like this", "write code like this"),      // 'like' is not in the safe list
        ("hmm let me see", "let me see"),   // no leading capital to restore
        ("nothing to strip", "nothing to strip"),
    ]
    for (input, expected) in fillerCases {
        let got = removeFillers(from: input, words: fillerWords)
        precondition(got == expected, "\(input) -> \(got), expected \(expected)")
        print("  \(input)  ->  \(got)")
    }
    let stutterCases: [(String, String)] = [
        ("the the build is is failing on on main", "the build is failing on main"),
        ("i i think we we should ship it", "i think we should ship it"),
        ("he had had a point", "he had had a point"),        // legitimate double, left alone
        ("no repeats in this one", "no repeats in this one"),
        ("THE the case is is mixed", "THE case is mixed"),   // first spelling wins
    ]
    for (input, expected) in stutterCases {
        let got = collapseRepeats(in: input)
        precondition(got == expected, "\(input) -> \(got), expected \(expected)")
        print("  \(input)  ->  \(got)")
    }

    // The aggressive list does strip 'like' — which is why it is off by default.
    precondition(removeFillers(from: "write code like this", words: discourseMarkers) == "write code this")
    print("PASS dictionary")
}

/// Store round-trip against a throwaway directory, so the real history is untouched.
/// The window is opened too, which at least proves the view tree builds without trapping —
/// but how it *looks* is not checked here. Offscreen rendering only captures the
/// AppKit-backed List; SwiftUI's own chrome never lands in the bitmap either through
/// cacheDisplay or the layer tree. Eyeballing the real window is the check.
@MainActor
private func demoWindow() {
    NSApplication.shared.setActivationPolicy(.accessory)
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "quietwords-demo-store")
    try? FileManager.default.removeItem(at: scratch)

    let store = Store(directory: scratch)
    store.terms = [
        Term(heard: "clawed code", meant: "Claude Code"),
        Term(heard: "ex code", meant: "Xcode"),
    ]
    store.record(Entry(text: "Hold Right Option and speak — the text lands at the cursor.",
                       duration: 3.4, app: "com.apple.TextEdit"))
    store.record(Entry(text: "I opened Claude Code in Xcode.", duration: 1.9,
                       app: "com.google.antigravity-ide"))

    let scratchSettings = Settings(directory: scratch)
    let controller = MainWindowController(store: store, settings: scratchSettings)
    controller.show()
    // SwiftUI needs run-loop turns to finish laying out, and this demo never reaches
    // NSApplication.run(). Pump it by hand — which is why this function is not async,
    // since Swift 6 bans blocking run-loop calls from an async context.
    let deadline = Date().addingTimeInterval(1.5)
    while Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.05, true)
    }

    // The dictionary survived a round trip through disk.
    let reread = Store(directory: scratch)
    precondition(reread.terms.count == 2, "dictionary did not persist")
    precondition(reread.history.count == 2, "history did not persist")
    precondition(reread.correct("clawed code is running") == "Claude Code is running",
                 "terms did not survive the round trip")
    // Stats over a known history — `now` is injected so the streak needs no waiting.
    let calendar = Calendar(identifier: .gregorian)
    let now = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
    func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: now)! }
    let seeded = [
        Entry(text: "one two three four five six", date: now, duration: 60),
        Entry(text: "seven eight", date: daysAgo(1), duration: 60),
        Entry(text: "nine", date: daysAgo(2), duration: 60),
        Entry(text: "ten", date: daysAgo(9), duration: 60),   // breaks the streak
    ]
    let summary = stats(for: seeded, now: now, calendar: calendar)
    precondition(summary.words == 10, "counted \(summary.words) words")
    precondition(summary.minutes == 4, "counted \(summary.minutes) minutes")
    precondition(summary.wordsPerMinute == 3, "wpm was \(summary.wordsPerMinute)")
    precondition(summary.streak == 3, "streak was \(summary.streak)")
    // Nothing today, something yesterday — the streak still stands.
    precondition(stats(for: [Entry(text: "hi", date: daysAgo(1), duration: 1)],
                       now: now, calendar: calendar).streak == 1)
    // Nothing for two days — broken.
    precondition(stats(for: [Entry(text: "hi", date: daysAgo(2), duration: 1)],
                       now: now, calendar: calendar).streak == 0)
    print("PASS window")
}

/// Registering a login item is the one Phase 7 piece that can fail while the toggle
/// claims success, so the check reads the status back rather than trusting the call.
/// Leaves the machine as it found it.
@MainActor
private func demoLogin() {
    let settings = Settings(directory: URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "quietwords-demo-settings"))
    let before = settings.loginItemStatus
    settings.setLoginItem(true)
    let after = settings.loginItemStatus
    print("login item: before=\(before.rawValue) afterRegister=\(after.rawValue)")
    print("  0=notRegistered 1=enabled 2=requiresApproval 3=notFound")
    if before != .enabled { settings.setLoginItem(false) }   // leave it as we found it
    precondition(after != before || after == .enabled, "register() changed nothing at all")
    print("PASS login")
}

/// Enumeration works, and automatic selection never lands on a Bluetooth mic — which is
/// the whole point: holding a Bluetooth mic drops that headset's output to phone quality.
private func demoDevices() {
    let inputs = AudioDevices.inputs()
    for input in inputs {
        print("  \(input.name)  uid=\(input.uid)  builtIn=\(input.isBuiltIn) bluetooth=\(input.isBluetooth)")
    }
    precondition(!inputs.isEmpty, "no input devices found at all")
    precondition(inputs.allSatisfy { !$0.uid.isEmpty }, "a device came back with no UID")

    print("recording from -> \(AudioDevices.systemDefault()?.name ?? "unknown")")
    let wired = AudioDevices.preferredWired()
    print("would switch to -> \(wired?.name ?? "nothing — every input is Bluetooth")")
    if let wired {
        precondition(!wired.isBluetooth, "the suggested input is itself Bluetooth")
    }
    print("PASS devices")
}

/// What the two modules actually cover, and that resolution survives the identifier
/// mismatch that `en_US` / `en-US` / `en_US@rg=inzzzz` creates.
private func demoLanguages() async {
    let catalog = await Languages.catalog()
    let installed = catalog.filter(\.installed)
    print("catalog=\(catalog.count) installed=\(installed.count)")
    for language in installed { print("  \(language.locale.identifier)  \(language.kind.rawValue)  \(language.name)") }

    precondition(catalog.count >= 54, "expected at least DictationTranscriber's 54 locales, got \(catalog.count)")
    precondition(!installed.isEmpty, "no language installed at all")

    // SpeechTranscriber wins where both modules can do a locale.
    let english = catalog.first { $0.locale.identifier == "en_US" }
    precondition(english?.kind == .speech, "en_US should route to SpeechTranscriber")
    // Hindi exists only on DictationTranscriber — the whole reason for two engines.
    let hindi = catalog.first { $0.locale.identifier == "hi_IN" }
    precondition(hindi != nil, "hi_IN missing from the catalog")
    precondition(hindi?.kind == .dictation, "hi_IN should route to DictationTranscriber")

    // The identifiers the app actually passes around, all of which must resolve.
    for identifier in ["en-US", "en_US", "en_US@rg=inzzzz", "en-IN"] {
        let resolved = await Languages.resolve(Locale(identifier: identifier))
        precondition(resolved != nil, "\(identifier) did not resolve")
        print("  \(identifier) -> \(resolved!.locale.identifier) via \(resolved!.kind.rawValue)")
    }
    let nonsense = await Languages.resolve(Locale(identifier: "xx-XX"))
    precondition(nonsense == nil, "a nonsense locale resolved to something")

    precondition(!hinglishBias.isEmpty && hinglishBias.contains("yaar"))
    print("PASS languages")
}
