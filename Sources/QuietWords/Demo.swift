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
