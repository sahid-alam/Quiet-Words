import AppKit
import ServiceManagement
import Speech
import SwiftUI

/// History and dictionary. Opened from the menu bar — the app has no Dock icon, so this
/// window is the only place the app has a face.
@MainActor
final class MainWindowController {
    private let store: Store
    private let settings: Settings
    private var window: NSWindow?

    init(store: Store, settings: Settings) {
        self.store = store
        self.settings = settings
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 470),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = "Quiet Words"
            window.contentView = NSHostingView(rootView: MainView(store: store, settings: settings))
            window.isReleasedWhenClosed = false   // reopened from the menu, not rebuilt
            window.center()
            self.window = window
        }
        // An accessory app has to activate explicitly or the window opens behind
        // whatever is frontmost and text fields never take key.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct MainView: View {
    @Bindable var store: Store
    @Bindable var settings: Settings

    var body: some View {
        TabView {
            HistoryTab(store: store, settings: settings).tabItem { Label("History", systemImage: "clock") }
            DictionaryTab(store: store).tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            SettingsTab(settings: settings).tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .padding(12)
        .frame(minWidth: 600, minHeight: 400)
    }
}

private struct SettingsTab: View {
    @Bindable var settings: Settings
    @State private var locales: [Locale] = []
    @State private var current: AudioInput?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.loginItemStatus == .enabled },
                    set: { settings.setLoginItem($0) }))
                if settings.loginItemStatus != .enabled && settings.loginItemStatus != .notRegistered {
                    Text(loginItemNote)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Sound cues", isOn: $settings.soundCues)
            }

            Section("Recordings") {
                Toggle("Keep audio", isOn: $settings.saveAudio)
                Text("Roughly 2 MB a minute. Without it, History has no playback and no retry.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Stepper("Delete after \(settings.audioRetentionDays) days",
                        value: $settings.audioRetentionDays, in: 1...90)
                    .disabled(!settings.saveAudio)
                Stepper("Stop after \(settings.ceilingMinutes) minutes",
                        value: $settings.ceilingMinutes, in: 1...60)
            }

            Section("Microphone") {
                LabeledContent("Recording from", value: current?.name ?? "system default")
                if let current, current.isBluetooth {
                    Text("Quiet Words records from whatever macOS has set as the input. While a Bluetooth headset's microphone is open, macOS drops it into hands-free mode and everything you play through it — music, video, calls — falls to phone-call quality until dictation stops.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let wired = AudioDevices.preferredWired() {
                        Button("Switch system input to \(wired.name)") {
                            AudioDevices.makeSystemDefault(wired)
                            self.current = AudioDevices.systemDefault()
                            settings.onChange()   // rebuilds the menu bar warning
                        }
                    }
                }
            }

            Section("Dictation") {
                Picker("Hold to dictate", selection: $settings.hotkeyCode) {
                    ForEach(HotkeyChoice.all) { choice in
                        Text(choice.name).tag(choice.keyCode)
                    }
                }
                Toggle("Double-tap to latch hands-free", isOn: $settings.handsFree)
                Picker("Language", selection: $settings.localeIdentifier) {
                    Text("Follow System").tag("")
                    ForEach(locales, id: \.identifier) { locale in
                        Text(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            .tag(locale.identifier)
                    }
                }
            }

            Section("Clean-up") {
                Toggle("Remove filler words", isOn: $settings.stripFillers)
                Text(fillerWords.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Also remove hedges", isOn: $settings.stripDiscourseMarkers)
                Text("\(discourseMarkers.joined(separator: ", ")) — these carry meaning in ordinary speech, so this is off by default.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task {
            current = AudioDevices.systemDefault()
            locales = await SpeechTranscriber.installedLocales
                .sorted { $0.identifier < $1.identifier }
        }
    }


    /// Registration fails for an app outside /Applications, and the toggle must not
    /// claim otherwise.
    private var loginItemNote: String {
        switch settings.loginItemStatus {
        case .requiresApproval: "Approve Quiet Words in System Settings → General → Login Items."
        default: "macOS refused the login item. This usually means the app is not in /Applications."
        }
    }
}

private struct HistoryTab: View {
    @Bindable var store: Store
    @Bindable var settings: Settings
    @State private var search = ""
    @State private var retrying: Set<UUID> = []
    @State private var player: NSSound?

    private var shown: [Entry] {
        guard !search.isEmpty else { return store.history }
        return store.history.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 8) {
            if store.history.isEmpty {
                ContentUnavailableView("Nothing dictated yet",
                                       systemImage: "mic",
                                       description: Text("Hold Right Option and speak."))
            } else {
                let summary = stats(for: store.history)
                HStack(spacing: 18) {
                    stat("\(summary.words)", "words")
                    stat("\(summary.wordsPerMinute)", "wpm")
                    stat("\(summary.streak)", summary.streak == 1 ? "day streak" : "day streak")
                    Spacer()
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    // ponytail: a plain field, not .searchable — that modifier needs a
                    // navigation container on macOS and silently renders nothing without one.
                    TextField("Search transcripts", text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                List(shown) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.text)
                            Text(caption(for: entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if let audio = store.audioURL(for: entry) {
                            Button {
                                player?.stop()
                                player = NSSound(contentsOf: audio, byReference: true)
                                player?.play()
                            } label: {
                                Image(systemName: "play.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Play the recording")

                            Button {
                                retry(entry, audio: audio)
                            } label: {
                                if retrying.contains(entry.id) {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise.circle")
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(retrying.contains(entry.id))
                            .help("Transcribe the recording again")
                        }
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.text, forType: .string)
                        }
                        Button("Delete", role: .destructive) { store.delete(entry) }
                    }
                }

                HStack {
                    Text(shown.count == store.history.count
                         ? "\(store.history.count) entries"
                         : "\(shown.count) of \(store.history.count) entries")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear All", role: .destructive) { store.clearHistory() }
                }
            }
        }
    }

    /// Re-runs the saved recording through the analyzer. What the transcriber got wrong
    /// once it may get right with a dictionary that has grown since.
    private func retry(_ entry: Entry, audio: URL) {
        retrying.insert(entry.id)
        Task {
            defer { retrying.remove(entry.id) }
            do {
                let text = try await transcribe(fileAt: audio, locale: settings.locale,
                                                bias: store.contextualStrings)
                guard !text.isEmpty else { return }
                store.replace(entry, withText: settings.polish(store.correct(text)))
            } catch {
                NSSound.beep()
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title2).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func caption(for entry: Entry) -> String {
        let when = entry.date.formatted(date: .abbreviated, time: .shortened)
        let held = String(format: "%.1fs", entry.duration)
        let app = entry.app.map { $0.split(separator: ".").last.map(String.init) ?? $0 } ?? "unknown"
        return "\(when) · \(held) · \(app)"
    }
}

private struct DictionaryTab: View {
    @Bindable var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What you hear on the left, what you meant on the right. Terms on the right are also fed to the transcriber up front, so most of them stop needing correction. Longer replacements work too — \"my email\" can expand to the whole address.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach($store.terms) { $term in
                    HStack(spacing: 8) {
                        TextField("clawed code", text: $term.heard)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Claude Code", text: $term.meant)
                        Button {
                            store.terms.removeAll { $0.id == term.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }

            Button("Add Term", systemImage: "plus") {
                store.terms.append(Term(heard: "", meant: ""))
            }
        }
    }
}
