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

    /// Right Option. A deliberate deviation from Fn, which is already bound to the emoji
    /// picker or system dictation on most keyboards.
    let keyCode = Int64(kVK_RightOption)

    private let handler: (Signal) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var downAt: Date?

    var isHeld: Bool { downAt != nil }

    init?(handler: @escaping (Signal) -> Void) {
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
        logger.log("tap installed keyCode=\(self.keyCode, privacy: .public)")
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

        if type == .keyDown, code == Int64(kVK_Escape), downAt != nil {
            downAt = nil
            handler(.cancel)
            return false   // swallow the Escape that cancelled us
        }

        if type == .flagsChanged, code == keyCode {
            // .maskAlternate cannot tell left from right; the keycode already did.
            if event.flags.contains(.maskAlternate) {
                if downAt == nil {
                    downAt = Date()
                    logger.log("hotkey.down")
                    handler(.down)
                }
            } else if let start = downAt {
                downAt = nil
                let held = Date().timeIntervalSince(start)
                logger.log("hotkey.up held=\(String(format: "%.2f", held), privacy: .public)s")
                handler(.up(held: held))
            }
        }

        // Everything passes through. Right Option types special characters on many
        // layouts; swallowing it would break ordinary typing.
        return true
    }
}
