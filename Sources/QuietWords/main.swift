import AppKit
import AVFoundation
import os

let log = Logger(subsystem: "com.sahidalam.quietwords", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// A tap-and-release this short is a fumble, not speech.
    private static let minimumHold: TimeInterval = 0.2

    private var statusItem: NSStatusItem?
    private var hotkey: Hotkey?
    private let dictation = Dictation()
    private let hud = HUD()
    private let store = Store()
    private let settings = Settings()
    private lazy var mainWindow = MainWindowController(store: store, settings: settings)
    private var lastHold: TimeInterval = 0
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
        dictation.onTranscript = { [weak self] text, audio in
            guard let self else { return }
            let corrected = settings.polish(store.correct(text))
            log.log("dictated: \(corrected, privacy: .public)")
            let entry = Entry(text: corrected, duration: lastHold,
                              app: target?.bundleIdentifier, audio: audio)
            let target = self.target
            Task {
                // Inject first: writing history is a synchronous JSON encode, and doing it
                // before the paste puts it straight in the latency path of every dictation.
                await Injector.inject(corrected, into: target)
                self.store.record(entry)
                self.store.pruneAudio(olderThan: self.settings.audioRetentionDays)
            }
        }
        dictation.onAutoStop = { [weak self] in
            self?.hud.hide()
            self?.settings.play(.stop)
        }
        settings.onChange = { [weak self] in self?.applySettings() }
        applySettings()
        store.pruneAudio(olderThan: settings.audioRetentionDays)
        installHotkey()
        buildStatusItem()
    }

    private func handle(_ signal: Hotkey.Signal) {
        switch signal {
        case .down:
            // Capture the target before the HUD appears, so a HUD that misbehaves and
            // steals focus can't quietly retarget the injection.
            target = NSWorkspace.shared.frontmostApplication
            dictation.contextualStrings = store.contextualStrings
                + (settings.hinglishAssist ? hinglishBias : [])
            hud.show()
            dictation.begin()
            settings.play(.start)
        case .up(let held):
            lastHold = held
            hud.hide()
            if held < Self.minimumHold {
                dictation.cancel()
                settings.play(.cancel)
            } else {
                dictation.end()
                settings.play(.stop)
            }
        case .cancel:
            hud.hide()
            dictation.cancel()
            settings.play(.cancel)
        }
    }

    /// The grant can land at any moment and the tap cannot exist before it does. Poll,
    /// so granting takes effect without a relaunch — otherwise it looks like a bug.
    private func installHotkey() {
        hotkey = makeHotkey()
        guard hotkey == nil else { return }
        Task { @MainActor in
            while hotkey == nil {
                try? await Task.sleep(for: .seconds(2))
                // Retry tapCreate itself rather than gating on AXIsProcessTrusted(), which
                // a long-running process can serve from a cache and never see the grant.
                hotkey = makeHotkey()
            }
            statusItem?.menu = buildMenu()
        }
    }

    private func makeHotkey() -> Hotkey? {
        Hotkey(choice: settings.hotkey, handsFree: settings.handsFree) { [weak self] in
            self?.handle($0)
        }
    }

    /// The tap and the warm session are built from settings, so a change to either has to
    /// tear down and rebuild rather than being picked up in place.
    private func applySettings() {
        dictation.locale = settings.locale
        dictation.ceiling = TimeInterval(settings.ceilingMinutes) * 60
        dictation.recordingsDirectory = settings.saveAudio ? store.audioDirectory : nil
        guard statusItem != nil else { return }   // launch path installs the tap itself
        hotkey = nil                               // release the old tap before the new one
        hotkey = makeHotkey()
        statusItem?.menu = buildMenu()
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Quiet Words")
        item.menu = buildMenu()
        statusItem = item
    }

    /// Rebuilt every time the menu opens — earbuds get connected after launch, and a
    /// warning that only reflects the state at startup is worse than none.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        populate(menu)
        return menu
    }

    private func populate(_ menu: NSMenu) {
        if hotkey == nil {
            let grant = menu.addItem(withTitle: "Grant Accessibility to enable dictation…",
                                     action: #selector(openAccessibilitySettings), keyEquivalent: "")
            grant.target = self
            menu.addItem(.separator())
        } else {
            let hint = settings.handsFree
                ? "Hold \(settings.hotkey.name) to dictate, double-tap to latch"
                : "Hold \(settings.hotkey.name) to dictate"
            menu.addItem(withTitle: hint, action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(.separator())
        }
        // Bluetooth is worth surfacing without making anyone open Settings first.
        if let input = AudioDevices.systemDefault(), input.isBluetooth {
            let warning = menu.addItem(
                withTitle: "⚠︎ Recording from \(input.name) — dims its audio",
                action: #selector(openMainWindow), keyEquivalent: "")
            warning.target = self
            menu.addItem(.separator())
        }
        let history = menu.addItem(withTitle: "History & Dictionary…",
                                   action: #selector(openMainWindow), keyEquivalent: "")
        history.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Quiet Words", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func openMainWindow() { mainWindow.show() }

    /// Menu title reads "History & Dictionary…" but the window carries settings too.

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
