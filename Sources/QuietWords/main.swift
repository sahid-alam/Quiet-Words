import AppKit
import AVFoundation
import os

let log = Logger(subsystem: "com.sahidalam.quietwords", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A tap-and-release this short is a fumble, not speech.
    private static let minimumHold: TimeInterval = 0.2

    private var statusItem: NSStatusItem?
    private var hotkey: Hotkey?
    private let dictation = Dictation()
    private let hud = HUD()
    /// Whoever was frontmost at key-down owns the text, even if focus moves while talking.
    private var target: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        // ponytail: literal key — kAXTrustedCheckOptionPrompt is a global `var`, which
        // Swift 6 strict concurrency rejects. The string is ABI-stable.
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        // .notice so a plain `log show` (which skips debug/info) finds these.
        log.log("permissions mic=\(mic.rawValue, privacy: .public) accessibility=\(trusted, privacy: .public)")

        Task {
            let granted = await requestMicAccess()
            log.log("mic access granted=\(granted, privacy: .public)")
        }

        dictation.onVolatile = { [hud] in hud.setText($0) }
        dictation.onLevel = { [hud] level in
            Task { @MainActor in hud.push(level: level) }
        }
        dictation.onTranscript = { [weak self] text in
            log.log("dictated: \(text, privacy: .public)")
            let target = self?.target
            Task { await Injector.inject(text, into: target) }
        }
        installHotkey()
        buildStatusItem()
    }

    private func handle(_ signal: Hotkey.Signal) {
        switch signal {
        case .down:
            // Capture the target before the HUD appears, so a HUD that misbehaves and
            // steals focus can't quietly retarget the injection.
            target = NSWorkspace.shared.frontmostApplication
            hud.show()
            dictation.begin()
        case .up(let held):
            hud.hide()
            held < Self.minimumHold ? dictation.cancel() : dictation.end()
        case .cancel:
            hud.hide()
            dictation.cancel()
        }
    }

    /// The grant can land at any moment and the tap cannot exist before it does. Poll,
    /// so granting takes effect without a relaunch — otherwise it looks like a bug.
    private func installHotkey() {
        hotkey = Hotkey { [weak self] in self?.handle($0) }
        guard hotkey == nil else { return }
        Task { @MainActor in
            while hotkey == nil {
                try? await Task.sleep(for: .seconds(2))
                // Retry tapCreate itself rather than gating on AXIsProcessTrusted(), which
                // a long-running process can serve from a cache and never see the grant.
                hotkey = Hotkey { [weak self] in self?.handle($0) }
            }
            statusItem?.menu = buildMenu()
        }
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Quiet Words")
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        if hotkey == nil {
            let grant = menu.addItem(withTitle: "Grant Accessibility to enable dictation…",
                                     action: #selector(openAccessibilitySettings), keyEquivalent: "")
            grant.target = self
            menu.addItem(.separator())
        } else {
            menu.addItem(withTitle: "Hold Right Option to dictate", action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Quit Quiet Words", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--demo"), i + 1 < CommandLine.arguments.count {
    await runDemo(CommandLine.arguments[i + 1])
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()   // strong ref — app.delegate is weak
app.delegate = delegate
app.run()
