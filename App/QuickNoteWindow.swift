import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Schnellnotiz am Mac: ⌃⌥⌘N öffnet überall ein kleines Fenster (wie MacJournal „Quick Note“).
/// Das Kürzel wirkt, solange die App läuft; darum lässt sie sich beim Anmelden starten (Einstellungen).
final class QuickNote: ObservableObject {
    static let shared = QuickNote()
    static let windowID = "quicknote"
    static let title = "Schnellnotiz"

    /// Entwurf: bleibt erhalten, wenn das Fenster ohne Sichern zugeht.
    @Published var draft = ""
    /// War die App vorne, als das Fenster aufging? Sonst nach dem Sichern zurück zur vorigen App.
    private(set) var wasActive = true
    private var openWindow: OpenWindowAction?
    private var hotKey: EventHotKeyRef?

    /// Einmal beim Start (aus dem Hauptfenster): Fenster-Öffner merken, Tastenkürzel anmelden.
    func setUp(_ openWindow: OpenWindowAction) {
        self.openWindow = openWindow
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { QuickNote.shared.show() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4A_49_54_4E), id: 1)  // „JITN“
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey | controlKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    func show() {
        wasActive = NSApp.isActive
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: Self.windowID)
    }

    /// Fenster zu; kam der Aufruf aus einer anderen App, dorthin zurück.
    func close(_ dismiss: DismissWindowAction) {
        dismiss(id: Self.windowID)
        if !wasActive { NSApp.hide(nil) }
        wasActive = true
    }

    /// App beim Anmelden starten, damit das Kürzel immer geht.
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }
}

/// Inhalt des Schnellnotiz-Fensters: Text tippen oder diktieren, ⌘↩ sichert ins heutige Journal.
struct QuickNoteView: View {
    @EnvironmentObject private var library: Library
    @ObservedObject private var note = QuickNote.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("fontSize") private var fontSize = 16.0
    @State private var textView = TextViewRef()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kommt als eigener Eintrag ins heutige Journal.")
                .font(.callout)
                .foregroundStyle(.secondary)
            PlainTextEditor(text: $note.draft, fontSize: fontSize, onTextView: { textView.view = $0 })
                .frame(minHeight: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button {
                    if let view = textView.view { EditorCommand.dictate.perform(on: view) }
                } label: {
                    Label("Diktieren", systemImage: "mic")
                }
                .help("Sprechen statt tippen. Beenden mit „Fertig“ oder der fn-Taste.")
                Spacer()
                Button("Abbrechen", role: .cancel) { note.close(dismissWindow) }
                    .keyboardShortcut(.cancelAction)
                Button("Sichern", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(note.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Notiz sichern (⌘↩)")
            }
        }
        .padding()
        .frame(minWidth: 420, idealWidth: 480, minHeight: 280)
    }

    private func save() {
        do {
            _ = try library.quickNote(note.draft)
            note.draft = ""
            error = nil
            note.close(dismissWindow)
        } catch {
            self.error = "Sichern ging nicht: \(error.localizedDescription)"
        }
    }
}

/// Merkt sich die Text-Ansicht des Fensters (für den Diktier-Knopf).
final class TextViewRef {
    weak var view: NSTextView?
}
