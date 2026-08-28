import AppKit
import Carbon.HIToolbox
import os

private let logger = Logger(subsystem: "com.sahidalam.quietwords", category: "hotkey")

/// Global push-to-talk tap. Push-to-talk is a state machine, not an event: the modifier
/// going down opens a capture and going up closes it, so both edges must be observed.
/// `init` returns nil when accessibility is not granted — there is no tap without it.
@MainActor
final class Hotkey {
    enum Signal {
        case down
        case up(held: TimeInterval)
        case cancel
    }

    /// A release shorter than this arms a double-tap; a second press inside
    /// `doubleTapGap` latches hands-free instead of starting another hold.
    private static let tapMax: TimeInterval = 0.25
    private static let doubleTapGap: TimeInterval = 0.35

    private enum State {
        case idle
        case holding(since: Date)
        case handsFree(since: Date)
    }

    private let choice: HotkeyChoice
    private let handsFreeEnabled: Bool
    private let handler: (Signal) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var state = State.idle
    private var lastReleaseAt: Date?

    var isActive: Bool {
        if case .idle = state { return false }
        return true
    }

    init?(choice: HotkeyChoice, handsFree: Bool, handler: @escaping (Signal) -> Void) {
        self.choice = choice
        self.handsFreeEnabled = handsFree
        self.handler = handler

        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                // CGEvent isn't Sendable, but the tap runs on the main run loop — the same
                // thread this actor is isolated to. Nothing crosses a thread here.
                nonisolated(unsafe) let event = event
                let passThrough = MainActor.assumeIsolated {
                    Unmanaged<Hotkey>.fromOpaque(info).takeUnretainedValue().handle(type, event)
                }
                return passThrough ? Unmanaged.passUnretained(event) : nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("tapCreate returned nil — accessibility trusted=\(AXIsProcessTrusted(), privacy: .public)")
            return nil
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        logger.log("tap installed key=\(choice.name, privacy: .public) code=\(choice.keyCode, privacy: .public) handsFree=\(handsFree, privacy: .public)")
    }

    isolated deinit {
        if let source { CFRunLoopSourceInvalidate(source) }
        if let tap { CFMachPortInvalidate(tap) }
    }

    /// Returns true to let the event through to the app underneath.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        // The system disables a tap that took too long. It will happen; re-arm and move on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.log("tap disabled (\(type.rawValue, privacy: .public)) — re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyDown, code == Int64(kVK_Escape), isActive {
            state = .idle
            lastReleaseAt = nil
            handler(.cancel)
            return false   // swallow the Escape that cancelled us
        }

        if type == .flagsChanged, code == choice.keyCode {
            // The flag mask cannot tell left from right; the key code already did.
            event.flags.contains(choice.flag) ? pressed() : released()
        }

        // Everything passes through. Right Option types special characters on many
        // layouts; swallowing it would break ordinary typing.
        return true
    }

    private func pressed() {
        switch state {
        case .handsFree(let since):
            // The press that ends a latched session. Its release is ignored below.
            state = .idle
            lastReleaseAt = nil
            let held = Date().timeIntervalSince(since)
            logger.log("hotkey.handsFree.stop held=\(String(format: "%.2f", held), privacy: .public)s")
            handler(.up(held: held))

        case .idle, .holding:
            let armed = handsFreeEnabled
                && lastReleaseAt.map { Date().timeIntervalSince($0) < Self.doubleTapGap } == true
            lastReleaseAt = nil
            if armed {
                state = .handsFree(since: Date())
                logger.log("hotkey.handsFree.start")
            } else {
                state = .holding(since: Date())
                logger.log("hotkey.down")
            }
            handler(.down)
        }
    }

    private func released() {
        // A release in .handsFree is the second tap of the double-tap letting go, and a
        // release in .idle is the tap that just ended a latched session. Neither is an end
        // of dictation — emitting .up for them would close a capture that never opened.
        guard case .holding(let since) = state else { return }
        state = .idle
        let held = Date().timeIntervalSince(since)
        lastReleaseAt = held < Self.tapMax ? Date() : nil
        logger.log("hotkey.up held=\(String(format: "%.2f", held), privacy: .public)s")
        handler(.up(held: held))
    }
}
