import SwiftUI
import AppKit

/// Einstellungen: welche Ordner die App liest, und wie groß die Schrift ist.
struct SettingsView: View {
    @EnvironmentObject private var library: Library
    @AppStorage("fontSize") private var fontSize = 16.0
    @AppStorage("newEntriesRich") private var newEntriesRich = true
    @AppStorage("wordGoal") private var wordGoal = 0
    @AppStorage("unlockWithPassword") private var unlockWithPassword = true
    @State private var launchAtLogin = QuickNote.launchAtLogin

    var body: some View {
        Form {
            Section("Ordner (Quellen)") {
                ForEach(library.sources, id: \.self) { url in
                    HStack {
                        Image(systemName: "folder")
                        Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Entfernen") { library.removeSource(url) }
                    }
                }
                Button("Ordner hinzufügen …", action: addFolder)
            }
            Section("Neue Einträge") {
                Picker("Format", selection: $newEntriesRich) {
                    Text("Rich Text (wie MacJournal: fett, Farben, Bilder)").tag(true)
                    Text("Markdown (einfacher Text)").tag(false)
                }
                Text("Das tägliche Journal (Ordner „Journal“) bleibt immer Markdown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Schnellnotiz") {
                Toggle("Beim Anmelden starten", isOn: Binding(get: { launchAtLogin },
                                                              set: { QuickNote.launchAtLogin = $0; launchAtLogin = QuickNote.launchAtLogin }))
                Text("⌃⌥⌘N öffnet überall eine Schnellnotiz – aber nur, wenn die App läuft. Startet sie beim Anmelden, geht das Kürzel immer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Gesperrte und verschlüsselte Journale") {
                Picker("Öffnen mit", selection: $unlockWithPassword) {
                    Text("Passwort").tag(true)
                    Text("Touch ID").tag(false)
                }
                Text(unlockWithPassword
                     ? "Zum Öffnen jedes Mal das Passwort eingeben. Der Schlüssel bleibt nicht auf dem Mac."
                     : "Zum Öffnen Touch ID. Der Schlüssel liegt dafür im Schlüsselbund.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Schreiben") {
                Stepper(value: $wordGoal, in: 0...5000, step: 50) {
                    Text(wordGoal == 0 ? "Schreibziel: aus" : "Schreibziel: \(wordGoal) Wörter pro Eintrag")
                }
                Text("Unten im Eintrag steht, wie viele Wörter er hat; mit Ziel auch, ob es erreicht ist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Schrift") {
                Slider(value: $fontSize, in: 12...28, step: 1) {
                    Text("Größe: \(Int(fontSize))")
                }
            }
            SpeechSettingsSection()
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Hinzufügen"
        if panel.runModal() == .OK, let url = panel.url {
            library.addSource(url)
        }
    }
}
