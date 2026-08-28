import AppKit
import Carbon.HIToolbox
import os

private let logger = Logger(subsystem: "com.sahidalam.quietwords", category: "inject")

/// Pasteboard + synthetic Cmd+V.
///
/// Not the accessibility route: `AXUIElementSetAttributeValue(kAXSelectedTextAttribute)`
/// returns `.success` and does nothing in every Chromium/Electron app, so designing
/// around it and bolting on a fallback is the bug. Paste is the primary path.
enum Injector {
    /// A snapshot has to hold the bytes, not the items — `clearContents()` invalidates
    /// `NSPasteboardItem`s, so re-writing the originals restores nothing.
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    static func snapshot(_ pasteboard: NSPasteboard = .general) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [:]) { out, type in out[type] = item.data(forType: type) }
        }
    }

    static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        pasteboard.writeObjects(snapshot.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        })
    }

    /// Puts `text` where the cursor is in `target`, then puts the user's clipboard back.
    @MainActor
    static func inject(_ text: String, into target: NSRunningApplication?) async {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ours = pasteboard.changeCount

        // The frontmost app must be the one that was frontmost at key-down.
        if let target, !target.isActive {
            target.activate()
            try? await Task.sleep(for: .milliseconds(80))
        }

        // Let the physical modifier the user was holding lift, or Cmd+V is read as
        // Cmd+Option+V and does something else entirely.
        try? await Task.sleep(for: .milliseconds(50))
        pressCommandV()

        // The target app has to read the pasteboard before we put it back.
        try? await Task.sleep(for: .milliseconds(150))
        guard pasteboard.changeCount == ours else {
            logger.log("pasteboard changed under us — leaving it alone")
            return
        }
        restore(saved, to: pasteboard)
        logger.log("injected \(text.count, privacy: .public) chars into \(target?.bundleIdentifier ?? "frontmost", privacy: .public)")
    }

    private static func pressCommandV() {
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: v, keyDown: false) else {
            logger.error("could not synthesise Cmd+V")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
