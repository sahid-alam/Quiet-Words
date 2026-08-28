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

    /// Installs the tap and starts the engine. `onLevel` fires once per buffer *on the
    /// audio thread* with that buffer's RMS (0...1) — the HUD waveform reads it.
    func start(
        format: AVAudioFormat,
        onLevel: @escaping @Sendable (Float) -> Void = { _ in }
    ) throws -> AsyncStream<AnalyzerInput> {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw AudioCaptureError.noConverter(from: inputFormat, to: format)
        }
        logger.debug("capture \(inputFormat) -> \(format)")

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        continuation = cont

        // AVAudioEngine serialises tap callbacks, so the converter is only ever touched
        // by one thread at a time.
        let conv = converter
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            onLevel(rms(of: buffer))
            if let out = convert(buffer, with: conv, to: format) {
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
        continuation?.finish()
        continuation = nil
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
