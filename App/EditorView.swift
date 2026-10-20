import SwiftUI
import AppKit

/// Rechte Seite: Eintrag schön lesen oder als Rohtext bearbeiten.
/// Gespeichert wird von selbst, kurz nach dem letzten Tippen.
struct EditorView: View {
    @EnvironmentObject private var library: Library
    let url: URL
    /// Suchbegriffe, die im Text gelb markiert werden.
    var highlight = ""

    @State private var text = ""
    @State private var savedText = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var status = ""
    @State private var editing = false
    /// Suchen oder Diktieren aus der Leseansicht: erst zum Bearbeiten wechseln, dann ausführen.
    @State private var pendingCommand: EditorCommand?
    @ObservedObject private var speaker = Speaker.shared
    @AppStorage("fontSize") private var fontSize = 16.0

    var body: some View {
        VStack(spacing: 0) {
            if editing {
                PlainTextEditor(text: $text, fontSize: fontSize, initialCommand: pendingCommand, onSplit: split)
            } else {
                MarkdownView(text: text, fontSize: fontSize, highlight: highlight,
                             activeBlock: speaker.speaking == url ? speaker.currentBlock : nil)
                    .onTapGesture(count: 2) { editing = true }
            }
            HStack {
                Text(url.deletingLastPathComponent().lastPathComponent + " / " + url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                WritingStatus(words: Library.wordCount(text))
                Text(text == savedText ? "Gespeichert" : status)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear(perform: load)
        .onChange(of: text) { _, _ in scheduleSave() }
        .onReceive(NotificationCenter.default.publisher(for: EditorCommand.notification)) { note in
            // Nicht, wenn der Befehl der Schnellnotiz gilt.
            guard !editing, NSApp.keyWindow?.title != QuickNote.title,
                  let raw = note.object as? String, let command = EditorCommand(rawValue: raw) else { return }
            pendingCommand = command
            editing = true
        }
        .onChange(of: editing) { _, now in if !now { pendingCommand = nil } }
        .onDisappear {
            saveNow()
            if speaker.speaking == url { speaker.stop() }
        }
        // Datei wurde außerhalb geändert (z. B. von Claude oder iCloud): neu lesen, wenn hier nichts ungespeichert ist.
        .onChange(of: library.externalRevision) { _, _ in
            if text == savedText { load() }
        }
        // Das Journal schreibt auch Claude. Ungeänderte Einträge beim Zurückkehren neu lesen.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if text == savedText { load() }
        }
        .toolbar {
            ToolbarItemGroup {
                SpeechControls(url: url, library: library)
            }
            ToolbarItem {
                DictateButton()
            }
            ToolbarItem {
                Button {
                    if editing { saveNow() }
                    editing.toggle()
                } label: {
                    Label(editing ? "Fertig" : "Bearbeiten", systemImage: editing ? "checkmark.circle" : "pencil")
                        .labelStyle(.titleAndIcon)
                }
                .help(editing ? "Zurück zur Leseansicht" : "Text bearbeiten (oder Doppelklick in den Text)")
            }
            ToolbarItem {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Im Finder zeigen", systemImage: "folder")
                }
                .help("Datei im Finder zeigen")
            }
        }
    }

    /// „Eintrag hier teilen“: der Rest wird ein neuer Eintrag, der gleich gezeigt wird.
    private func split(_ tail: String) {
        saveNow()
        do {
            let part = try library.splitOff(text: tail, from: url)
            NotificationCenter.default.post(name: .selectEntry, object: part)
        } catch {
            status = "Teilen ging nicht: \(error.localizedDescription)"
        }
    }

    private func load() {
        let disk = library.read(url)
        text = disk
        savedText = disk
        // Ein gerade angelegter Eintrag startet gleich zum Schreiben.
        if library.justCreated == url {
            editing = true
            library.justCreated = nil
        }
    }

    private func scheduleSave() {
        guard text != savedText else { return }
        status = "Ungespeichert …"
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await MainActor.run { saveNow() }
        }
    }

    private func saveNow() {
        guard text != savedText else { return }
        do {
            try library.save(text, to: url)
            savedText = text
        } catch {
            status = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}
