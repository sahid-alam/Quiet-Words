import AVFoundation
import Speech
import os

private let logger = Logger(subsystem: "com.sahidalam.quietwords", category: "speech")

enum TranscriptionError: Error {
    case localeUnsupported(Locale)
    case noCompatibleFormat
}

/// One `SpeechAnalyzer` + `SpeechTranscriber` pair, fed by an `AnalyzerInput` stream.
/// Live-ish enough for push-to-talk: volatile results drive the HUD, finals accumulate.
/// Main-actor isolated — the analyzer is the actor that matters, this is just bookkeeping,
/// and global-actor isolation is what makes it safe to hand between tasks.
@MainActor
final class TranscriptionSession {
    /// The format the caller must convert its audio to. Feeding anything else is silent.
    let format: AVAudioFormat

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var results: Task<String, Never>?

    private init(transcriber: SpeechTranscriber, format: AVAudioFormat) {
        self.transcriber = transcriber
        self.format = format
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    /// Resolves assets and warms the analyzer. Do this once at launch, not on the hotkey.
    static func make(locale: Locale = .current) async throws -> TranscriptionSession {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        try await installAssets(for: transcriber, locale: locale)

        // Let the framework pick. availableCompatibleAudioFormats is unordered and also
        // offers 8kHz, so taking .first there quietly costs accuracy.
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noCompatibleFormat
        }
        let session = TranscriptionSession(transcriber: transcriber, format: format)
        try await session.analyzer.prepareToAnalyze(in: format)
        logger.log("session ready locale=\(locale.identifier, privacy: .public) format=\(format, privacy: .public)")
        return session
    }

    /// Biases the model toward terms it would otherwise mishear — names, product names,
    /// jargon. Cheaper than correcting them afterwards, and it fixes the volatile tail too.
    func bias(toward strings: [String]) async {
        guard !strings.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = strings
        do {
            try await analyzer.setContext(context)
        } catch {
            logger.error("setContext failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Begins analysis. `onVolatile` fires with the un-committed tail — display only.
    func start(
        inputs: some AsyncSequence<AnalyzerInput, Never> & Sendable,
        onVolatile: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        let stream = transcriber.results
        results = Task {
            var final = AttributedString()
            do {
                for try await result in stream {
                    if result.isFinal {
                        final += result.text
                        onVolatile("")
                    } else {
                        onVolatile(String(result.text.characters))
                    }
                }
            } catch {
                logger.error("results ended: \(error.localizedDescription, privacy: .public)")
            }
            return String(final.characters)
        }
        try await analyzer.start(inputSequence: inputs)
    }

    /// Drains what is still in flight and returns the committed transcript.
    /// The caller must have stopped the input stream first, or this waits forever.
    /// Never throws: a finalize failure must not swallow speech the user already gave.
    func finish() async -> String {
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            logger.error("finalize failed: \(error.localizedDescription, privacy: .public)")
            await analyzer.cancelAndFinishNow()   // otherwise results never terminates
        }
        return await results?.value ?? ""
    }

    /// Throws the audio away. Used for a hotkey tap too short to be speech.
    func cancel() async {
        await analyzer.cancelAndFinishNow()
        results?.cancel()
        _ = await results?.value
    }
}

/// The gate is reservation, not download — a locale already in `installedLocales` costs
/// one `reserve` call and downloads nothing. Reservations persist across launches.
private func installAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
    let status = await AssetInventory.status(forModules: [transcriber])
    logger.log("asset status \(String(describing: status), privacy: .public)")
    guard status != .installed else { return }
    if status == .unsupported { throw TranscriptionError.localeUnsupported(locale) }

    _ = try await AssetInventory.reserve(locale: locale)
    if await AssetInventory.status(forModules: [transcriber]) == .installed { return }

    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        logger.log("downloading assets for \(locale.identifier, privacy: .public)")
        try await request.downloadAndInstall()
    }
}


/// Runs a recorded WAV back through the same analyzer path the hotkey uses. Retrying a
/// garbled transcript and the Phase 2 check are the same operation.
@MainActor
func transcribe(fileAt url: URL, locale: Locale = .current, bias: [String] = []) async throws -> String {
    let session = try await TranscriptionSession.make(locale: locale)
    await session.bias(toward: bias)

    let file = try AVAudioFile(forReading: url)
    guard let converter = AVAudioConverter(from: file.processingFormat, to: session.format) else {
        throw TranscriptionError.noCompatibleFormat
    }
    let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
    try await session.start(inputs: stream)

    // Bound by framePosition — read(into:) throws at EOF rather than returning 0 frames.
    while file.framePosition < file.length {
        let chunk = AVAudioFrameCount(min(4096, file.length - file.framePosition))
        guard let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)
        else { break }
        try file.read(into: read, frameCount: chunk)
        if let out = convert(read, with: converter, to: session.format) {
            cont.yield(AnalyzerInput(buffer: out))
        }
    }
    cont.finish()
    return await session.finish().trimmingCharacters(in: .whitespacesAndNewlines)
}
