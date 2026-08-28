import Foundation
import os

private let logger = Logger(subsystem: "com.sahidalam.quietwords", category: "store")

struct Entry: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var date = Date()
    var duration: TimeInterval
    /// Bundle identifier of whatever the text was injected into.
    var app: String?
}

/// A mishearing and what it should have been. Biasing the model with `meant` gets most
/// of these right up front; this is for the ones it still gets wrong.
struct Term: Codable, Identifiable, Equatable {
    var id = UUID()
    var heard: String
    var meant: String
}

/// Whole-word, case-insensitive replacement over the final transcript.
///
/// A free function, deliberately: the check calls it with no store, no file and no main
/// actor. The replacement keeps the casing the user typed — predictable beats clever.
func applyTerms(_ terms: [Term], to text: String) -> String {
    terms.reduce(text) { partial, term in
        guard !term.heard.isEmpty else { return partial }
        // Lookarounds, not \b: a term ending in a non-word character — C++, .NET, node.js —
        // has no word boundary after it and \b would silently never match.
        let pattern = "(?<!\\w)\(NSRegularExpression.escapedPattern(for: term.heard))(?!\\w)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return partial }
        return regex.stringByReplacingMatches(
            in: partial,
            range: NSRange(partial.startIndex..., in: partial),
            withTemplate: NSRegularExpression.escapedTemplate(for: term.meant))
    }
}

/// History and dictionary, one JSON file in Application Support. A few thousand rows is
/// nothing; SwiftData when a JSON file measurably hurts, not before.
@MainActor
@Observable
final class Store {
    private(set) var history: [Entry] = []
    var terms: [Term] = [] { didSet { if loaded { saveTerms() } } }

    private static let historyLimit = 2000
    private let directory: URL
    private var loaded = false

    // Two files, not one: the dictionary is rewritten on every keystroke in the editor
    // and the history can run to a few hundred KB. Keeping them apart makes that free.
    private var historyFile: URL { directory.appending(path: "history.json") }
    private var termsFile: URL { directory.appending(path: "dictionary.json") }

    init(directory: URL = .applicationSupportDirectory.appending(path: "QuietWords")) {
        self.directory = directory
        history = Self.read([Entry].self, from: historyFile) ?? []
        terms = Self.read([Term].self, from: termsFile) ?? []
        loaded = true
    }

    /// The strings to bias the transcriber toward, so it gets them right up front rather
    /// than only being corrected after the fact.
    var contextualStrings: [String] { terms.map(\.meant).filter { !$0.isEmpty } }

    func correct(_ text: String) -> String { applyTerms(terms, to: text) }

    func record(_ entry: Entry) {
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        saveHistory()
    }

    func delete(_ entry: Entry) {
        history.removeAll { $0.id == entry.id }
        saveHistory()
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    private func saveHistory() { write(history, to: historyFile) }
    private func saveTerms() { write(terms, to: termsFile) }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            logger.error("\(url.lastPathComponent, privacy: .public) unreadable — starting empty, leaving the file alone")
            return nil
        }
        return value
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            logger.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
