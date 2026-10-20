import SwiftUI

/// Intelligentes Journal (wie MacJournal „Smart Journal“): gespeicherte Regeln statt eines Ordners.
/// Alle Regeln müssen passen; leere Regeln gelten nicht.
struct SmartJournal: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    /// Schlagwörter; `anyTag`: eines genügt, sonst müssen alle passen.
    var tags: [String] = []
    var anyTag = false
    var flaggedOnly = false
    /// Suchwörter im Text (wie das Suchfeld).
    var text = ""
    /// Nur die letzten … Tage; 0 = egal.
    var days = 0
    /// Mindestens so viele Sterne; 0 = egal.
    var minRating = 0
    /// Etikett-Farbe, Status; leer = egal.
    var label = ""
    var status = ""

    init() {}

    // Ältere Dateien kennen die neueren Regeln noch nicht: fehlende Werte = egal.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        anyTag = try c.decodeIfPresent(Bool.self, forKey: .anyTag) ?? false
        flaggedOnly = try c.decodeIfPresent(Bool.self, forKey: .flaggedOnly) ?? false
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        days = try c.decodeIfPresent(Int.self, forKey: .days) ?? 0
        minRating = try c.decodeIfPresent(Int.self, forKey: .minRating) ?? 0
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
    }
}

/// Wofür der Regel-Dialog offen ist.
struct SmartRequest: Identifiable {
    var journal: SmartJournal
    var isNew: Bool
    var id: UUID { journal.id }
}

/// Dialog: Name und Regeln eines intelligenten Journals, mit Anzahl der passenden Einträge.
struct SmartJournalSheet: View {
    @EnvironmentObject private var library: Library
    @State var journal: SmartJournal
    let isNew: Bool
    let done: (SmartJournal?) -> Void

    private static let periods = [(0, "Egal"), (7, "Letzte 7 Tage"), (30, "Letzte 30 Tage"), (90, "Letzte 3 Monate"), (365, "Letztes Jahr")]

    var body: some View {
        let known = library.allTags.map(\.name)
        let count = library.entries(for: journal).count
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $journal.name, prompt: Text("z. B. Lubeca wichtig"))
                }
                Section("Regeln") {
                    Toggle("Nur markierte Einträge", isOn: $journal.flaggedOnly)
                    TextField("Text enthält", text: $journal.text, prompt: Text("Wörter, leer = egal"))
                    Picker("Zeitraum", selection: $journal.days) {
                        ForEach(Self.periods, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("Bewertung", selection: $journal.minRating) {
                        Text("egal").tag(0)
                        ForEach(1...5, id: \.self) { n in Text("mindestens " + String(repeating: "★", count: n)).tag(n) }
                    }
                    Picker("Etikett", selection: $journal.label) {
                        Text("egal").tag("")
                        ForEach(MetaKey.labelColors, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    Picker("Status", selection: $journal.status) {
                        Text("egal").tag("")
                        ForEach(MetaKey.status.choices, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("Schlagwörter") {
                    if known.isEmpty {
                        Text("Noch keine Schlagwörter vergeben.").foregroundStyle(.secondary)
                    } else {
                        Picker("Es müssen passen", selection: $journal.anyTag) {
                            Text("alle gewählten").tag(false)
                            Text("eines davon").tag(true)
                        }
                        ForEach(known, id: \.self) { tag in
                            Toggle(tag, isOn: Binding(
                                get: { journal.tags.contains(tag) },
                                set: { on in
                                    journal.tags.removeAll { $0 == tag }
                                    if on { journal.tags.append(tag) }
                                }))
                        }
                    }
                }
                Section {
                    Text(count == 1 ? "Passt jetzt auf 1 Eintrag." : "Passt jetzt auf \(count) Einträge.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Anlegen" : "Sichern") {
                    var result = journal
                    result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.name.isEmpty { result.name = "Intelligentes Journal" }
                    done(result)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        #if os(macOS)
        .frame(width: 440, height: 560)
        #endif
    }
}
