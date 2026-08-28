import AppKit
import AVFoundation
import Speech
import os

/// Phase checks. Run from inside the bundle so TCC attributes the grants to the app:
///   build/QuietWords.app/Contents/MacOS/QuietWords --demo-audio
func runDemo(_ name: String) async {
    switch name {
    case "audio": await demoAudio()
    case "transcribe": await demoTranscribe()
    case "inject": await demoInject()
    case "hud": await demoHUD()
    case "dictionary": demoDictionary()
    case "window": await demoWindow()
    default: print("unknown demo '\(name)'"); exit(2)
    }
}

private func demoAudio() async {
    guard await requestMicAccess() else { print("FAIL mic access denied"); exit(1) }

    let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                               channels: 1, interleaved: true)!
    let capture = AudioCapture()
    let peak = OSAllocatedUnfairLock(initialState: Float(0))

    print("recording 2s — say something")
    let stream: AsyncStream<AnalyzerInput>
    do {
        stream = try capture.start(format: target) { level in
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

        let session = try await TranscriptionSession.make(locale: Locale(identifier: "en-US"))
        let file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: session.format) else {
            print("FAIL no converter"); exit(1)
        }

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        try await session.start(inputs: stream) { print("  ~ \($0)") }

        // Bound by framePosition — read(into:) throws at EOF rather than returning 0 frames.
        while file.framePosition < file.length {
            let chunk = AVAudioFrameCount(min(4096, file.length - file.framePosition))
            guard let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            try file.read(into: read, frameCount: chunk)
            if let out = convert(read, with: converter, to: session.format) {
                cont.yield(AnalyzerInput(buffer: out))
            }
        }
        cont.finish()

        let text = await session.finish()
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

    let controller = MainWindowController(store: store)
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
    print("PASS window")
}
