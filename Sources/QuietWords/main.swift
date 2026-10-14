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
    private var cleanupLoad: Task<Void, Never>?
    private let editWatcher = EditWatcher()
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
                // If the user fixes a word in the next few seconds, that is a correction
                // worth offering to remember.
                self.editWatcher.watch(injected: corrected)
                self.store.record(entry)
                self.store.pruneAudio(olderThan: self.settings.audioRetentionDays)
            }
        }
        editWatcher.onCorrection = { [weak self] term in
            self?.store.suggest(term)
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
        installMainMenu()
        mainWindow.show()
    }

    /// Clicking the Dock icon with the window closed brings it back. Closing the window
    /// never quits — dictation lives in the hotkey, not the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow.show() }
        return true
    }

    /// A regular app with no main menu has no Cmd+Q, and — less obviously — no Cmd+C/V in
    /// its own text fields, because those key equivalents live on the Edit menu. That
    /// includes our own synthetic Cmd+V when dictating into the Dictionary tab.
    private func installMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Quiet Words",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Quiet Words", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Quiet Words", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        for submenu in [appMenu, edit, window] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }

    private func handle(_ signal: Hotkey.Signal) {
        switch signal {
        case .down:
            // Capture the target before the HUD appears, so a HUD that misbehaves and
            // steals focus can't quietly retarget the injection.
            target = NSWorkspace.shared.frontmostApplication
            editWatcher.stop()
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

    /// Compiling the model takes seconds, so it happens here and never on the hotkey.
    private func applyHinglish() {
        guard settings.hinglishAssist else {
            dictation.hinglishModel = nil
            return
        }
        let locale = settings.locale
        let extra = store.contextualStrings
        Task { @MainActor in
            dictation.hinglishModel = await HinglishModel.ensure(locale: locale, extra: extra)
        }
    }

    /// Downloads once, then loads in the background — ~6s and 2 GB. Dictation works raw
    /// until it is ready, and turning the setting off frees the memory.
    private func applyCleanup() {
        guard settings.aiCleanup else {
            cleanupLoad?.cancel()
            cleanupLoad = nil
            dictation.cleaner = nil
            settings.cleanupStatus = ""
            return
        }
        guard dictation.cleaner == nil, cleanupLoad == nil else { return }
        cleanupLoad = Task { @MainActor in
            defer { cleanupLoad = nil }
            do {
                if !CleanupModel.isInstalled {
                    settings.cleanupStatus = "Downloading the model…"
                    try await CleanupModel.ensure { fraction in
                        Task { @MainActor in
                            self.settings.cleanupStatus = "Downloading the model… \(Int(fraction * 100))%"
                        }
                    }
                }
                settings.cleanupStatus = "Loading the model…"
                let cleaner = try await Task.detached { try Cleaner() }.value
                await cleaner.warmUp()
                guard settings.aiCleanup else { return }
                dictation.cleaner = cleaner
                settings.cleanupStatus = "Ready"
            } catch {
                settings.cleanupStatus = "Not available: \(error.localizedDescription)"
                log.error("clean-up unavailable: \(error.localizedDescription, privacy: .public)")
            }
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
        applyHinglish()
        applyCleanup()
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
                action: #selector(openSettings), keyEquivalent: "")
            warning.target = self
            menu.addItem(.separator())
        }
        let open = menu.addItem(withTitle: "Open Quiet Words",
                                action: #selector(openMainWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Quiet Words", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func openMainWindow() { mainWindow.show() }
    @objc private func openSettings() { mainWindow.show(.settings) }

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
// A Dock icon and Cmd+Tab, like Wispr Flow. `.accessory` would make it a menu-bar-only
// agent again — the window still works, it just has no Dock presence.
app.setActivationPolicy(.regular)
let delegate = AppDelegate()   // strong ref — app.delegate is weak
app.delegate = delegate
app.run()
