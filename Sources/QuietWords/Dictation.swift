import AVFoundation
import Speech
import os

private let logger = Logger(subsystem: "com.sahidalam.quietwords", category: "dictation")

/// One push-to-talk press: mic → transcript. Holds a warm `TranscriptionSession` so
/// key-down doesn't pay the ~250ms setup cost, and serialises begin/end/cancel so a
/// fast tap can't finish before it started.
@MainActor
final class Dictation {
    /// Committed transcript and the file name of its recording, once per completed press.
    var onTranscript: @MainActor (String, String?) -> Void = { _, _ in }
    /// Fired when a session ends on its own — the ceiling below, not a key release.
    var onAutoStop: @MainActor () -> Void = {}
    /// Volatile tail while speaking — display only, empty between presses.
    var onVolatile: @MainActor (String) -> Void = { _ in }
    /// Per-buffer RMS, 0...1. Fires on the audio thread.
    var onLevel: @Sendable (Float) -> Void = { _ in }
    /// Dictionary terms to bias the model toward. Read fresh at each key-down.
    var contextualStrings: [String] = []
    /// Where recordings go. nil keeps no audio, which also disables retry and playback.
    var recordingsDirectory: URL?
    /// A latched hands-free session with nobody in the room would otherwise run forever.
    var ceiling: TimeInterval = 20 * 60

    /// Which locale the warm session is built for. Changing it re-warms.
    var locale: Locale = .current {
        didSet { if locale != oldValue { warmUp() } }
    }

    private let capture = AudioCapture()
    private var warm: Task<TranscriptionSession, Error>?
    private var active: TranscriptionSession?
    private var chain: Task<Void, Never>?
    private var recording: URL?
    private var autoStop: Task<Void, Never>?

    init() { warmUp() }

    func begin() { serialised { await self.open() } }
    func cancel() { serialised { await self.discard() } }

    func end() {
        serialised {
            let (text, audio) = await self.close()
            if let text { self.onTranscript(text, audio) }
        }
    }

    /// begin/end/cancel arrive as fast as the user can tap. Run them in order.
    private func serialised(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func warmUp() {
        let locale = locale
        warm = Task { try await TranscriptionSession.make(locale: locale) }
    }

    private func open() async {
        guard active == nil, let warm else { return }
        do {
            let session = try await warm.value
            await session.bias(toward: contextualStrings)
            let volatileSink = onVolatile
            recording = recordingsDirectory?.appending(path: "\(UUID().uuidString).wav")
            let stream = try capture.start(format: session.format, recordTo: recording,
                                           onLevel: onLevel)
            try await session.start(inputs: stream) { text in
                Task { @MainActor in volatileSink(text) }
            }
            active = session
            autoStop = Task { @MainActor [ceiling] in
                try? await Task.sleep(for: .seconds(ceiling))
                guard !Task.isCancelled, self.active != nil else { return }
                logger.log("hit the \(Int(ceiling), privacy: .public)s ceiling — finishing")
                self.onAutoStop()
                self.end()
            }
        } catch {
            logger.error("begin failed: \(error.localizedDescription, privacy: .public)")
            capture.stop()
            warmUp()
        }
    }

    private func close() async -> (String?, String?) {
        guard let session = active else { return (nil, nil) }
        active = nil
        autoStop?.cancel()
        capture.stop()
        let text = await session.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        onVolatile("")
        warmUp()
        logger.log("transcript \(text.count, privacy: .public) chars")

        let audio = recording
        recording = nil
        guard !text.isEmpty else {
            // Nothing was said; the recording is silence nobody wants.
            if let audio { try? FileManager.default.removeItem(at: audio) }
            return (nil, nil)
        }
        return (text, audio?.lastPathComponent)
    }

    private func discard() async {
        guard let session = active else { return }
        active = nil
        autoStop?.cancel()
        capture.stop()
        if let recording { try? FileManager.default.removeItem(at: recording) }
        recording = nil
        onVolatile("")
        await session.cancel()
        warmUp()
        logger.log("cancelled")
    }
}
