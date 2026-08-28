import Accelerate
import AVFoundation
import Speech
import os

private let logger = Logger(subsystem: "com.sahidalam.quietwords", category: "audio")

enum AudioCaptureError: Error {
    case noConverter(from: AVAudioFormat, to: AVAudioFormat)
}

/// Microphone → `AnalyzerInput` in whatever format the transcriber asked for.
/// A format mismatch here produces silence rather than an error, so the conversion is
/// not optional even when the rates look close. One capture at a time.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var sink: RecordingSink?

    /// Installs the tap and starts the engine. `onLevel` fires once per buffer *on the
    /// audio thread* with that buffer's RMS (0...1) — the HUD waveform reads it.
    ///
    /// `recordTo` writes the same converted buffers to a WAV as they go by. That file is
    /// what makes retry, playback and crash recovery possible; without it a garbled
    /// transcript is gone.
    func start(
        format: AVAudioFormat,
        recordTo url: URL? = nil,
        onLevel: @escaping @Sendable (Float) -> Void = { _ in }
    ) throws -> AsyncStream<AnalyzerInput> {
        let input = engine.inputNode
        // inputFormat is the hardware's own format; outputFormat is a cached view of it
        // that can go stale. See the input-device trap in CLAUDE.md.
        let inputFormat = input.inputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw AudioCaptureError.noConverter(from: inputFormat, to: format)
        }
        logger.debug("capture \(inputFormat) -> \(format)")

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        continuation = cont

        let sink = url.flatMap { RecordingSink(url: $0, format: format) }
        self.sink = sink

        // AVAudioEngine serialises tap callbacks, so the converter is only ever touched
        // by one thread at a time.
        let conv = converter
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            onLevel(rms(of: buffer))
            if let out = convert(buffer, with: conv, to: format) {
                sink?.write(out)
                cont.yield(AnalyzerInput(buffer: out))
            }
        }
        engine.prepare()
        try engine.start()
        return stream
    }

    /// Stops the engine and closes the stream. Safe to call when not started.
    func stop() {
        guard continuation != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sink?.close()
        sink = nil
        continuation?.finish()
        continuation = nil
    }
}

/// Owns the recording file so it can be closed on demand.
///
/// `AVAudioFile` only flushes its remaining samples and finalises the WAV header when it
/// deallocates. Left captured inside the tap closure it outlives `removeTap`, and reading
/// the file back gives a truncated few kilobytes of a two-second recording.
private final class RecordingSink: Sendable {
    private let file: OSAllocatedUnfairLock<AVAudioFile?>

    init?(url: URL, format: AVAudioFormat) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // commonFormat and interleaved must be given explicitly. The two-argument
            // initialiser leaves processingFormat as deinterleaved float32, and
            // write(from:) then raises an Objective-C exception on the Int16 buffer —
            // which `try?` does not catch, so it takes the process down.
            file = OSAllocatedUnfairLock(initialState: try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved))
        } catch {
            logger.error("cannot record to \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        // withLock's body is @Sendable and the buffer is not, but the lock is what makes
        // the hand-off safe — nothing else touches it inside.
        nonisolated(unsafe) let buffer = buffer
        file.withLock { try? $0?.write(from: buffer) }
    }

    /// The lock matters here, not just for tidiness: `removeTap` does not promise there is
    /// no callback already in flight.
    func close() {
        file.withLock { $0 = nil }
    }
}

/// Sample-rate + sample-format conversion. Returns nil on a buffer that produced no output.
func convert(
    _ buffer: AVAudioPCMBuffer,
    with converter: AVAudioConverter,
    to format: AVAudioFormat
) -> AVAudioPCMBuffer? {
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

    // ponytail: the input block runs synchronously inside convert(), but the SDK types it
    // @Sendable. nonisolated(unsafe) states what is already true.
    nonisolated(unsafe) var supplied = false
    nonisolated(unsafe) let source = buffer
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
        if supplied {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return source
    }
    if let error {
        logger.error("convert failed: \(error.localizedDescription, privacy: .public)")
        return nil
    }
    return out.frameLength > 0 ? out : nil
}

private func rms(of buffer: AVAudioPCMBuffer) -> Float {
    guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
    var meanSquare: Float = 0
    vDSP_measqv(channel, 1, &meanSquare, vDSP_Length(buffer.frameLength))
    return meanSquare.squareRoot()
}

/// Prompts on first call, returns the standing answer afterwards.
func requestMicAccess() async -> Bool {
    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
    return await AVCaptureDevice.requestAccess(for: .audio)
}
