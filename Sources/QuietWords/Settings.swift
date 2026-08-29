import AppKit
import Carbon.HIToolbox
import Foundation
import ServiceManagement
import os

private let logger = Logger(subsystem: "com.sahidalam.quietwords", category: "settings")

/// A modifier that can be held to dictate. `flag` matters as much as `keyCode`: the tap
/// sees a `.flagsChanged` event and has to know which flag means "still down".
struct HotkeyChoice: Identifiable, Hashable {
    var id: Int64 { keyCode }
    let name: String
    let keyCode: Int64
    /// CGEventFlags is an OptionSet without Hashable, so the key code carries identity.
    let flag: CGEventFlags

    static func == (a: HotkeyChoice, b: HotkeyChoice) -> Bool { a.keyCode == b.keyCode }
    func hash(into hasher: inout Hasher) { hasher.combine(keyCode) }

    static let all: [HotkeyChoice] = [
        .init(name: "Right Option", keyCode: Int64(kVK_RightOption), flag: .maskAlternate),
        .init(name: "Left Option", keyCode: Int64(kVK_Option), flag: .maskAlternate),
        .init(name: "Right Command", keyCode: Int64(kVK_RightCommand), flag: .maskCommand),
        .init(name: "Right Control", keyCode: Int64(kVK_RightControl), flag: .maskControl),
        // Fn works, but on most keyboards it is already the emoji picker or system
        // dictation. Offered, not defaulted.
        .init(name: "Fn", keyCode: Int64(kVK_Function), flag: .maskSecondaryFn),
    ]

    static let `default` = all[0]

    static func named(_ keyCode: Int64) -> HotkeyChoice {
        all.first { $0.keyCode == keyCode } ?? .default
    }
}

/// Short cues so you know the app heard you without looking at the HUD.
enum Cue: String {
    case start = "Tink"
    case stop = "Pop"
    case cancel = "Basso"

    func play() {
        guard let sound = NSSound(named: rawValue) else { return }
        sound.volume = 0.25   // a cue, not an alarm
        sound.stop()          // retrigger cleanly on a fast second dictation
        sound.play()
    }
}

@MainActor
@Observable
final class Settings {
    var soundCues = true { didSet { save() } }
    /// Recordings are what make retry and playback possible. ~2MB a minute.
    var saveAudio = true { didSet { save(); onChange() } }
    var audioRetentionDays = 7 { didSet { save() } }
    var ceilingMinutes = 20 { didSet { save(); onChange() } }
    var stripFillers = true { didSet { save() } }
    var stripDiscourseMarkers = false { didSet { save() } }
    /// Bias the model toward romanized Hindi. See `hinglishBias`.
    var hinglishAssist = false { didSet { save(); onChange() } }
    var collapseStutters = true { didSet { save() } }
    /// These three cannot be applied in place — the tap and the warm transcription
    /// session are both built from them, so the app rebuilds when they change.
    var handsFree = true { didSet { save(); onChange() } }
    var hotkeyCode = HotkeyChoice.default.keyCode { didSet { save(); onChange() } }
    /// Empty means follow the system.
    var localeIdentifier = "" { didSet { save(); onChange() } }

    /// Set by the app delegate. Not fired while loading from disk.
    @ObservationIgnored var onChange: () -> Void = {}

    /// Read back from the system rather than stored — registration can fail and the
    /// toggle must not lie about what actually happened.
    private(set) var loginItemStatus = SMAppService.mainApp.status

    private let file: URL
    private var loaded = false

    init(directory: URL = quietWordsDirectory) {
        file = directory.appending(path: "settings.json")
        if let saved = readJSON(Saved.self, from: file) {
            soundCues = saved.soundCues ?? soundCues
            saveAudio = saved.saveAudio ?? saveAudio
            audioRetentionDays = saved.audioRetentionDays ?? audioRetentionDays
            ceilingMinutes = saved.ceilingMinutes ?? ceilingMinutes
            stripFillers = saved.stripFillers ?? stripFillers
            stripDiscourseMarkers = saved.stripDiscourseMarkers ?? stripDiscourseMarkers
            hinglishAssist = saved.hinglishAssist ?? hinglishAssist
            collapseStutters = saved.collapseStutters ?? collapseStutters
            handsFree = saved.handsFree ?? handsFree
            hotkeyCode = saved.hotkeyCode ?? hotkeyCode
            localeIdentifier = saved.localeIdentifier ?? localeIdentifier
            // onChange is still the default no-op here; the app sets it after init.
        }
        loaded = true
    }

    var hotkey: HotkeyChoice { .named(hotkeyCode) }

    var locale: Locale {
        localeIdentifier.isEmpty ? .current : Locale(identifier: localeIdentifier)
    }

    /// Filler removal, per the two toggles. Applied after the dictionary, so an explicit
    /// correction always wins over a blanket strip.
    func polish(_ text: String) -> String {
        var words: [String] = []
        if stripFillers { words += fillerWords }
        if stripDiscourseMarkers { words += discourseMarkers }
        let stripped = removeFillers(from: text, words: words)
        return collapseStutters ? collapseRepeats(in: stripped) : stripped
    }

    func play(_ cue: Cue) {
        guard soundCues else { return }
        cue.play()
    }

    /// `register()` throws for an app that is not in /Applications, so the caller gets the
    /// system's answer back, not the one it asked for.
    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("login item \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        loginItemStatus = SMAppService.mainApp.status
        logger.log("login item status=\(self.loginItemStatus.rawValue, privacy: .public)")
    }

    /// Every field optional, deliberately.
    ///
    /// Swift's synthesised `Decodable` does not fall back to a property's default when a
    /// key is missing — it throws. So adding one setting made every existing
    /// settings.json fail to decode and silently reset every other preference. Optionals
    /// decode as nil when absent, and the defaults live at the point of use below.
    private struct Saved: Codable {
        var soundCues: Bool?
        var saveAudio: Bool?
        var audioRetentionDays: Int?
        var ceilingMinutes: Int?
        var stripFillers: Bool?
        var stripDiscourseMarkers: Bool?
        var hinglishAssist: Bool?
        var collapseStutters: Bool?
        var handsFree: Bool?
        var hotkeyCode: Int64?
        var localeIdentifier: String?
    }

    private func save() {
        guard loaded else { return }
        // `loaded` also gates onChange — see the didSet observers above, which call save()
        // first and would otherwise fire a rebuild for every field restored at launch.
        writeJSON(Saved(soundCues: soundCues, saveAudio: saveAudio,
                        audioRetentionDays: audioRetentionDays, ceilingMinutes: ceilingMinutes,
                        stripFillers: stripFillers,
                        stripDiscourseMarkers: stripDiscourseMarkers,
                        hinglishAssist: hinglishAssist, collapseStutters: collapseStutters,
                        handsFree: handsFree,
                        hotkeyCode: hotkeyCode, localeIdentifier: localeIdentifier),
                  to: file)
    }
}
