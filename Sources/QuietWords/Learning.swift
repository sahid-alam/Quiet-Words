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
    guard !heard.isEmpty, !meant.isEmpty,
          heard.split(separator: " ").count <= 4,
          meant.split(separator: " ").count <= 4,
          heard.caseInsensitiveCompare(meant) != .orderedSame
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

    private var task: Task<Void, Never>?

    /// `injected` is the text just pasted; the field also holds whatever was there before.
    func watch(injected: String) {
        task?.cancel()
        guard !injected.isEmpty else { return }
        guard let baseline = focusedText() else {
            // Whether reading AX works is per-app and unknowable in advance, so say so
            // at notice level rather than leaving the feature to fail invisibly.
            logger.log("no AX text from the focused element — cannot learn from edits in \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public)")
            return
        }
        logger.log("watching \(baseline.count, privacy: .public) chars in \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public) for edits")

        task = Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                guard let current = focusedText(), current != baseline else { continue }
                // Compare only what we put there: the surrounding document is not ours.
                guard let edited = revised(injected, within: baseline, now: current) else { return }
                if let term = correction(from: injected, to: edited) {
                    logger.log("learned candidate: \(term.heard, privacy: .public) -> \(term.meant, privacy: .public)")
                    onCorrection(term)
                }
                return
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
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
