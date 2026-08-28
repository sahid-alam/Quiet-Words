import Foundation
import os

private let logger = Logger(subsystem: "com.sahidalam.quietwords", category: "store")

/// Everything the app persists lives here. JSON, no SwiftData, until a file measurably hurts.
let quietWordsDirectory = URL.applicationSupportDirectory.appending(path: "QuietWords")

func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let value = try? JSONDecoder().decode(type, from: data) else {
        logger.error("\(url.lastPathComponent, privacy: .public) unreadable — starting empty, leaving the file alone")
        return nil
    }
    return value
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) {
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    } catch {
        logger.error("save failed: \(error.localizedDescription, privacy: .public)")
    }
}

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

/// Never load-bearing — safe to strip from anyone's speech.
let fillerWords = ["um", "umm", "uh", "uhh", "erm", "er", "ah", "hmm"]

/// Load-bearing in ordinary speech — "code like this", "you know the drill" — so this
/// list is off by default. Stripping it silently corrupts meaning.
let discourseMarkers = ["like", "you know", "i mean", "sort of", "kind of", "basically", "actually"]

/// Removes `words` and the comma that only existed to set them off, then tidies the
/// spacing the removal left behind.
func removeFillers(from text: String, words: [String]) -> String {
    guard !words.isEmpty else { return text }
    let alternation = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    let pattern = "(?<!\\w)(?:\(alternation))(?!\\w),?"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return text }

    var out = regex.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    out = out.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
    out = out.replacingOccurrences(of: " ([,.!?])", with: "$1", options: .regularExpression)
    out = out.replacingOccurrences(of: "^[,\\s]+", with: "", options: .regularExpression)
    out = out.trimmingCharacters(in: .whitespaces)

    // The filler may have been the capitalised first word; hand that back to whatever
    // now leads the sentence.
    if let first = text.first, first.isUppercase, let lead = out.first, lead.isLowercase {
        out.replaceSubrange(out.startIndex...out.startIndex, with: lead.uppercased())
    }
    return out
}

struct Stats: Equatable {
    var words = 0
    var minutes = 0.0
    var streak = 0

    var wordsPerMinute: Int { minutes > 0 ? Int((Double(words) / minutes).rounded()) : 0 }
}

/// `now` and `calendar` are injected so the streak can be checked without waiting a day.
func stats(for history: [Entry], now: Date = Date(), calendar: Calendar = .current) -> Stats {
    var stats = Stats()
    stats.words = history.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    stats.minutes = history.reduce(0) { $0 + $1.duration } / 60

    // Consecutive calendar days with at least one dictation, ending today — or yesterday,
    // so the streak does not read as broken before you have spoken today.
    let days = Set(history.map { calendar.startOfDay(for: $0.date) })
    var day = calendar.startOfDay(for: now)
    if !days.contains(day) {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day),
              days.contains(yesterday) else { return stats }
        day = yesterday
    }
    while days.contains(day) {
        stats.streak += 1
        guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
        day = previous
    }
    return stats
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

    init(directory: URL = quietWordsDirectory) {
        self.directory = directory
        history = readJSON([Entry].self, from: directory.appending(path: "history.json")) ?? []
        terms = readJSON([Term].self, from: directory.appending(path: "dictionary.json")) ?? []
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

    private func saveHistory() { writeJSON(history, to: historyFile) }
    private func saveTerms() { writeJSON(terms, to: termsFile) }

}
