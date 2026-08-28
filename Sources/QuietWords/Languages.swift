import AVFoundation
import Speech
import os

private let logger = Logger(subsystem: "com.sahidalam.quietwords", category: "language")

/// Two modules, because neither covers the languages on its own.
///
/// `SpeechTranscriber` does 30 locales and is the better of the two — it is the module
/// Apple built for live transcription. `DictationTranscriber` does 54, including Hindi
/// and every other language `SpeechTranscriber` omits. Neither takes more than one locale
/// at a time: `selectedLocales` is read-only and there is no initialiser accepting an
/// array, so there is no code-switching to be had at any price.
///
/// docs/plan.md said an engine abstraction should be added "at that point, not now",
/// when native coverage proved inadequate. Hindi is that point.
enum Engine {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    var module: any SpeechModule {
        switch self {
        case .speech(let module): module
        case .dictation(let module): module
        }
    }

    static func make(_ locale: Locale, kind: Kind) -> Engine {
        switch kind {
        case .speech: .speech(SpeechTranscriber(locale: locale, preset: .progressiveTranscription))
        case .dictation: .dictation(DictationTranscriber(locale: locale, preset: .progressiveLongDictation))
        }
    }

    enum Kind: String, Codable, Sendable {
        case speech, dictation
    }
}

struct Language: Identifiable, Hashable, Sendable {
    var id: String { locale.identifier }
    let locale: Locale
    let kind: Engine.Kind
    let installed: Bool

    var name: String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

enum Languages {
    /// Every locale either module can do, preferring `SpeechTranscriber` where both can.
    static func catalog() async -> [Language] {
        let speechSupported = await SpeechTranscriber.supportedLocales
        let speechInstalled = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
        let dictationSupported = await DictationTranscriber.supportedLocales
        let dictationInstalled = Set(await DictationTranscriber.installedLocales.map(\.identifier))

        var byIdentifier: [String: Language] = [:]
        for locale in dictationSupported {
            byIdentifier[locale.identifier] = Language(
                locale: locale, kind: .dictation,
                installed: dictationInstalled.contains(locale.identifier))
        }
        // SpeechTranscriber wins where both can do it.
        for locale in speechSupported {
            byIdentifier[locale.identifier] = Language(
                locale: locale, kind: .speech,
                installed: speechInstalled.contains(locale.identifier))
        }
        return byIdentifier.values.sorted { $0.name < $1.name }
    }

    /// Identifiers do not match across call sites — `en-US`, `en_US` and
    /// `en_US@rg=inzzzz` are all the same language, and a `contains` check fails on that.
    /// Each module knows its own equivalent, so ask it.
    static func resolve(_ locale: Locale) async -> Language? {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let installed = await SpeechTranscriber.installedLocales
            return Language(locale: match, kind: .speech,
                            installed: installed.contains { $0.identifier == match.identifier })
        }
        if let match = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let installed = await DictationTranscriber.installedLocales
            return Language(locale: match, kind: .dictation,
                            installed: installed.contains { $0.identifier == match.identifier })
        }
        return nil
    }

    /// Reservations are capped at five and persist across launches, so a user who has
    /// tried a few languages will start getting `false` back — and a session built for an
    /// unreserved locale fails later, somewhere less obvious.
    static func reserve(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { $0.identifier == locale.identifier }) else { return }
        if reserved.count >= AssetInventory.maximumReservedLocales, let evict = reserved.first {
            let released = await AssetInventory.release(reservedLocale: evict)
            logger.log("released \(evict.identifier, privacy: .public) to make room: \(released, privacy: .public)")
        }
        guard try await AssetInventory.reserve(locale: locale) else {
            throw TranscriptionError.localeUnsupported(locale)
        }
    }

    /// Explicit, never on the hot path. A first download of a language runs for minutes,
    /// and doing it inside `make()` means the hotkey hangs with the HUD up and no
    /// explanation. `onProgress` gets 0...1.
    static func install(_ language: Language, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        try await reserve(language.locale)
        let engine = Engine.make(language.locale, kind: language.kind)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [engine.module])
        else {
            onProgress(1)
            return
        }
        let progress = request.progress
        let watcher = Task {
            while !Task.isCancelled {
                onProgress(progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { watcher.cancel() }
        logger.log("downloading \(language.locale.identifier, privacy: .public), units=\(progress.totalUnitCount, privacy: .public)")
        try await request.downloadAndInstall()
        onProgress(1)
        logger.log("installed \(language.locale.identifier, privacy: .public)")
    }
}

/// Romanized Hindi that an English model will not reach for on its own.
///
/// There is no Hinglish model and no code-switching in the framework. What there is:
/// `en_IN` plus contextual bias, which nudges the transcriber toward these tokens instead
/// of the English words they sound like. The alternative — `hi_IN` — transcribes Hindi
/// properly but returns Devanagari, which is a different thing to want.
let hinglishBias = [
    "yaar", "matlab", "accha", "theek hai", "bhai", "arre", "haan", "nahi", "kya",
    "abhi", "thoda", "bohot", "kaam", "chalo", "bas", "kuch", "sahi", "galat",
    "jaldi", "phir", "lekin", "kyunki", "waise", "actually matlab", "na yaar",
]
