import AppKit
import ApplicationServices
import os

private let logger = Logger(subsystem: "com.sahidalam.quietwords", category: "learning")

/// Reads the text of whatever field currently has focus.
///
/// Reading is not writing. `AXUIElementSetAttributeValue` is the call that lies in
/// Electron apps — see trap 1 — but reading `AXValue` is a different code path, and
/// whether it works per-app is an empirical question the log answers.
func focusedText() -> String? {
    var focused: CFTypeRef?
    // Literal keys: the kAX… globals are `var`s, which Swift 6 rejects as shared state.
    guard AXUIElementCopyAttributeValue(
        AXUIElementCreateSystemWide(), "AXFocusedUIElement" as CFString, &focused) == .success,
        let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
    else { return nil }

    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element as! AXUIElement, "AXValue" as CFString, &value) == .success
    else { return nil }
    return value as? String
}

/// One contiguous edit, expressed as what was heard and what it should have been.
///
/// Only single-region changes are proposed. If someone rewrites half the paragraph there
/// is no correction to learn from it, and guessing produces noise the user has to clear.
func correction(from original: String, to edited: String) -> Term? {
    let before = original.split(separator: " ").map(String.init)
    let after = edited.split(separator: " ").map(String.init)
    guard before != after, !before.isEmpty, !after.isEmpty else { return nil }

    var head = 0
    while head < before.count, head < after.count, before[head] == after[head] { head += 1 }
    var tail = 0
    while tail < before.count - head, tail < after.count - head,
          before[before.count - 1 - tail] == after[after.count - 1 - tail] { tail += 1 }

    let heard = before[head..<(before.count - tail)].joined(separator: " ")
    let meant = after[head..<(after.count - tail)].joined(separator: " ")
    // Pure insertions and deletions are not corrections, and a long replacement is a
    // rewrite rather than a fix.
    // Adding a comma is an edit, not a correction, and "created -> created," is noise.
    let bare = { (s: String) in
        s.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }
    guard !heard.isEmpty, !meant.isEmpty,
          heard.split(separator: " ").count <= 4,
          meant.split(separator: " ").count <= 4,
          bare(heard) != bare(meant)
    else { return nil }
    return Term(heard: heard, meant: meant)
}

/// Watches the field we just dictated into, and notices when a word gets fixed.
///
/// Polling rather than an `AXObserver`: an observer needs a run loop source per target
/// application and careful teardown, where this needs to watch one field for a few
/// seconds. `ponytail: poll for 20s; move to AXObserver if it ever costs measurable CPU.`
@MainActor
final class EditWatcher {
    var onCorrection: @MainActor (Term) -> Void = { _ in }

    /// Where the text comes from, and how often to look. Injected so the settling logic
    /// can be driven by a scripted sequence instead of a real keyboard.
    private let read: @MainActor () -> String?
    private let interval: Duration
    private let window: Int
    /// Consecutive unchanged polls before an edit counts as finished.
    private let settle: Int
    private var task: Task<Void, Never>?

    init(
        read: @escaping @MainActor () -> String? = focusedText,
        interval: Duration = .milliseconds(400),
        window: Int = 50,
        settle: Int = 4
    ) {
        self.read = read
        self.interval = interval
        self.window = window
        self.settle = settle
    }

    /// `injected` is the text just pasted; the field also holds whatever was there before.
    func watch(injected: String) {
        task?.cancel()
        guard !injected.isEmpty else { return }
        guard let baseline = read() else {
            // Whether reading AX works is per-app and unknowable in advance, so say so
            // at notice level rather than leaving the feature to fail invisibly.
            logger.log("no AX text from the focused element — cannot learn from edits in \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public)")
            return
        }
        logger.log("watching \(baseline.count, privacy: .public) chars in \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public) for edits")

        task = Task { @MainActor in
            // Typing arrives one keystroke at a time. Emitting on the first difference
            // catches a half-typed word — "blood" -> "c" on the way to "Claude" — so wait
            // for the text to stop moving before deciding what the correction was.
            var latest = baseline
            var still = 0
            for _ in 0..<window {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                guard let current = read() else { continue }
                if current != latest {
                    latest = current
                    still = 0
                } else if latest != baseline {
                    still += 1
                    if still >= settle { break }
                }
            }
            guard latest != baseline,
                  let edited = revised(injected, within: baseline, now: latest),
                  let term = correction(from: injected, to: edited)
            else { return }
            logger.log("learned candidate: \(term.heard, privacy: .public) -> \(term.meant, privacy: .public)")
            onCorrection(term)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Waits for the watch to finish. Only the check needs this.
    func finish() async {
        await task?.value
    }

    /// Locates the injected run inside the field and returns what it has become. The text
    /// around it is the user's own document and must not be diffed.
    private func revised(_ injected: String, within baseline: String, now current: String) -> String? {
        guard let range = baseline.range(of: injected) else { return nil }
        let prefix = baseline[baseline.startIndex..<range.lowerBound]
        let suffix = baseline[range.upperBound...]
        guard current.hasPrefix(prefix), current.hasSuffix(suffix) else { return nil }
        let start = current.index(current.startIndex, offsetBy: prefix.count)
        let end = current.index(current.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        return String(current[start..<end])
    }
}
