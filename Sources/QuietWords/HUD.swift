import AppKit
import os

private let logger = Logger(subsystem: "com.sahidalam.quietwords", category: "hud")

/// The recording overlay.
///
/// It must never become key. A panel that activates changes the frontmost app, and the
/// transcript then injects into the HUD's owner instead of the user's editor — which
/// looks like an injection bug and isn't one.
@MainActor
final class HUD {
    private let panel: NonActivatingPanel
    private let view = HUDView()

    init() {
        panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = view
    }

    func show() {
        view.reset()
        moveToActiveScreen()
        panel.alphaValue = 0
        panel.orderFrontRegardless()   // never makeKeyAndOrderFront
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        logger.log("shown; frontmost is still \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public)")
    }

    func hide() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: { [panel] in
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    func push(level: Float) { view.push(level) }

    /// Renders the overlay to a PNG. The only way to check the drawing without the
    /// screen-recording grant that `screencapture` needs.
    func writePNG(to url: URL) throws {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: url)
    }
    func setText(_ text: String) { view.text = text }

    /// Bottom-centre of whichever screen the mouse is on — that is the one the user is
    /// looking at, which `NSScreen.main` is not reliably.
    private func moveToActiveScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 90))
    }
}

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HUDView: NSView {
    /// RMS is small and non-linear — bare values render as a flat line. sqrt for
    /// perceptual response, then a gain that suits a built-in mic at arm's length.
    /// ponytail: one constant, tuned by eye. Make it a setting if a headset needs a
    /// different one.
    private static let gain: CGFloat = 2.4
    private static let barCount = 44

    private var levels: [CGFloat] = []
    var text: String = "" { didSet { needsDisplay = true } }

    func push(_ level: Float) {
        levels.append(min(1, CGFloat(level).squareRoot() * Self.gain))
        if levels.count > Self.barCount { levels.removeFirst(levels.count - Self.barCount) }
        needsDisplay = true
    }

    func reset() {
        levels.removeAll()
        text = ""
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: box, xRadius: 16, yRadius: 16).fill()

        drawBars(in: NSRect(x: box.minX + 18, y: box.midY + 2, width: box.width - 36, height: 30))
        drawText(in: NSRect(x: box.minX + 18, y: box.minY + 10, width: box.width - 36, height: 18))
    }

    private func drawBars(in rect: NSRect) {
        let width: CGFloat = 3
        let gap = (rect.width - CGFloat(Self.barCount) * width) / CGFloat(Self.barCount - 1)
        NSColor.white.withAlphaComponent(0.9).setFill()
        // Newest on the right: pad the left so the trace grows in rather than jumping.
        let padding = Self.barCount - levels.count
        for (index, level) in levels.enumerated() {
            let height = max(3, level * rect.height)
            let x = rect.minX + CGFloat(padding + index) * (width + gap)
            let bar = NSRect(x: x, y: rect.midY - height / 2, width: width, height: height)
            NSBezierPath(roundedRect: bar, xRadius: width / 2, yRadius: width / 2).fill()
        }
    }

    private func drawText(in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingHead   // the tail is the new words
        let shown = text.isEmpty ? "Listening…" : text
        NSAttributedString(string: shown, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(text.isEmpty ? 0.45 : 0.95),
            .paragraphStyle: paragraph,
        ]).draw(in: rect)
    }
}
