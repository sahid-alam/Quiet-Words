import AppKit
import SwiftUI

/// History and dictionary. Opened from the menu bar — the app has no Dock icon, so this
/// window is the only place the app has a face.
@MainActor
final class MainWindowController {
    private let store: Store
    private var window: NSWindow?

    init(store: Store) { self.store = store }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 470),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = "Quiet Words"
            window.contentView = NSHostingView(rootView: MainView(store: store))
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

    var body: some View {
        TabView {
            HistoryTab(store: store).tabItem { Label("History", systemImage: "clock") }
            DictionaryTab(store: store).tabItem { Label("Dictionary", systemImage: "character.book.closed") }
        }
        .padding(12)
        .frame(minWidth: 560, minHeight: 360)
    }
}

private struct HistoryTab: View {
    @Bindable var store: Store
    @State private var search = ""

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
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.text)
                        Text(caption(for: entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            Text("What you hear on the left, what you meant on the right. Terms on the right are also fed to the transcriber up front, so most of them stop needing correction.")
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
