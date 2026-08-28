import AVFoundation
import Speech
import os

private let logger = Logger(subsystem: "com.sahidalam.quietwords", category: "dictation")

/// One push-to-talk press: mic → transcript. Holds a warm `TranscriptionSession` so
/// key-down doesn't pay the ~250ms setup cost, and serialises begin/end/cancel so a
/// fast tap can't finish before it started.
@MainActor
final class Dictation {
    /// Committed transcript, once per completed press.
    var onTranscript: @MainActor (String) -> Void = { _ in }
    /// Volatile tail while speaking — display only, empty between presses.
    var onVolatile: @MainActor (String) -> Void = { _ in }
    /// Per-buffer RMS, 0...1. Fires on the audio thread.
    var onLevel: @Sendable (Float) -> Void = { _ in }

    private let capture = AudioCapture()
    private var warm: Task<TranscriptionSession, Error>?
    private var active: TranscriptionSession?
    private var chain: Task<Void, Never>?

    init() { warmUp() }

    func begin() { serialised { await self.open() } }
    func cancel() { serialised { await self.discard() } }

    func end() {
        serialised {
            if let text = await self.close() { self.onTranscript(text) }
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
        warm = Task { try await TranscriptionSession.make() }
    }

    private func open() async {
        guard active == nil, let warm else { return }
        do {
            let session = try await warm.value
            let volatileSink = onVolatile
            let stream = try capture.start(format: session.format, onLevel: onLevel)
            try await session.start(inputs: stream) { text in
                Task { @MainActor in volatileSink(text) }
            }
            active = session
        } catch {
            logger.error("begin failed: \(error.localizedDescription, privacy: .public)")
            capture.stop()
            warmUp()
        }
    }

    private func close() async -> String? {
        guard let session = active else { return nil }
        active = nil
        capture.stop()
        let text = await session.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        onVolatile("")
        warmUp()
        logger.log("transcript \(text.count, privacy: .public) chars")
        return text.isEmpty ? nil : text
    }

    private func discard() async {
        guard let session = active else { return }
        active = nil
        capture.stop()
        onVolatile("")
        await session.cancel()
        warmUp()
        logger.log("cancelled")
    }
}
