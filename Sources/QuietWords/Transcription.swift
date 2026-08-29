import AVFoundation
import Speech
import os

private let logger = Logger(subsystem: "com.sahidalam.quietwords", category: "speech")

enum TranscriptionError: Error, LocalizedError {
    case localeUnsupported(Locale)
    case notInstalled(Language)
    case notProvisioned(Language)
    case noCompatibleFormat

    var errorDescription: String? {
        switch self {
        case .localeUnsupported(let locale): "No model for \(locale.identifier)."
        case .notInstalled(let language): "\(language.name) is not downloaded yet."
        case .notProvisioned(let language):
            "macOS has no speech model to download for \(language.name). Add it under System Settings → Keyboard → Dictation → Languages, then try again."
        case .noCompatibleFormat: "No compatible audio format."
        }
    }
}

/// Both modules' results carry the same two things, but through separate types that share
/// no protocol exposing `text`. One extension each beats writing the consume loop twice.
protocol TranscriptResult {
    var text: AttributedString { get }
    var isFinal: Bool { get }
}
extension SpeechTranscriber.Result: TranscriptResult {}
extension DictationTranscriber.Result: TranscriptResult {}

/// One `SpeechAnalyzer` + `SpeechTranscriber` pair, fed by an `AnalyzerInput` stream.
/// Live-ish enough for push-to-talk: volatile results drive the HUD, finals accumulate.
/// Main-actor isolated — the analyzer is the actor that matters, this is just bookkeeping,
/// and global-actor isolation is what makes it safe to hand between tasks.
@MainActor
final class TranscriptionSession {
    /// The format the caller must convert its audio to. Feeding anything else is silent.
    let format: AVAudioFormat

    /// Which language this session was built for.
    let language: Language

    private let engine: Engine
    private let analyzer: SpeechAnalyzer
    private var results: Task<String, Never>?

    private init(engine: Engine, language: Language, format: AVAudioFormat) {
        self.engine = engine
        self.language = language
        self.format = format
        self.analyzer = SpeechAnalyzer(modules: [engine.module])
    }

    /// Warms the analyzer. Never downloads: a first download of a language runs for
    /// minutes, and doing it here means the hotkey hangs with the HUD up and nothing to
    /// look at. Downloading is `Languages.install`, driven from Settings.
    static func make(
        locale: Locale = .current,
        hinglishModel: URL? = nil
    ) async throws -> TranscriptionSession {
        guard let language = await Languages.resolve(locale) else {
            throw TranscriptionError.localeUnsupported(locale)
        }
        guard language.installed else { throw TranscriptionError.notInstalled(language) }
        try await Languages.reserve(language.locale)

        // A custom language model forces DictationTranscriber — it is the only module
        // that takes a content hint.
        let engine: Engine
        if let hinglishModel {
            engine = .dictation(DictationTranscriber(
                locale: language.locale,
                contentHints: [.customizedLanguage(
                    modelConfiguration: SFSpeechLanguageModel.Configuration(languageModel: hinglishModel))],
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []))
        } else {
            engine = Engine.make(language.locale, kind: language.kind)
        }
        // Let the framework pick. availableCompatibleAudioFormats is unordered and also
        // offers 8kHz, so taking .first there quietly costs accuracy.
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [engine.module])
        else { throw TranscriptionError.noCompatibleFormat }

        let session = TranscriptionSession(engine: engine, language: language, format: format)
        try await session.analyzer.prepareToAnalyze(in: format)
        logger.log("session ready \(language.locale.identifier, privacy: .public) via \(language.kind.rawValue, privacy: .public) format=\(format, privacy: .public)")
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
        switch engine {
        case .speech(let module):
            let stream = module.results
            results = Task { await Self.consume(stream, onVolatile: onVolatile) }
        case .dictation(let module):
            let stream = module.results
            results = Task { await Self.consume(stream, onVolatile: onVolatile) }
        }
        try await analyzer.start(inputSequence: inputs)
    }

    private static func consume<Results: AsyncSequence & Sendable>(
        _ stream: Results,
        onVolatile: @escaping @Sendable (String) -> Void
    ) async -> String where Results.Element: TranscriptResult {
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



/// Runs a recorded WAV back through the same analyzer path the hotkey uses. Retrying a
/// garbled transcript and the Phase 2 check are the same operation.
@MainActor
func transcribe(
    fileAt url: URL,
    locale: Locale = .current,
    bias: [String] = [],
    hinglishModel: URL? = nil
) async throws -> String {
    let session = try await TranscriptionSession.make(locale: locale, hinglishModel: hinglishModel)
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
