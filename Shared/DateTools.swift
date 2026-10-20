import SwiftUI

/// Sortierung der Eintragsliste (Ansicht › Sortieren nach). Mac und iPhone merken sich die Wahl.
enum EntrySort: String, CaseIterable, Identifiable {
    case date, title
    var id: Self { self }
    var label: String { self == .date ? "Datum" : "Titel" }

    static let key = "sortBy"
    static let ascendingKey = "sortAscending"
}

extension Array where Element == Entry {
    func sorted(by sort: EntrySort, ascending: Bool) -> [Entry] {
        sorted { a, b in
            let order: ComparisonResult
            switch sort {
            case .date:
                order = a.date == b.date ? a.title.localizedStandardCompare(b.title) : (a.date < b.date ? .orderedAscending : .orderedDescending)
            case .title:
                let byTitle = a.title.localizedStandardCompare(b.title)
                order = byTitle != .orderedSame ? byTitle : (a.date < b.date ? .orderedAscending : .orderedDescending)
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}

/// Auswahl der Sortierung, als Menü (Werkzeugleiste) oder in der Menüleiste.
struct SortPicker: View {
    @AppStorage(EntrySort.key) private var sort = EntrySort.date
    @AppStorage(EntrySort.ascendingKey) private var ascending = false

    var body: some View {
        Picker("Sortieren nach", selection: $sort) {
            ForEach(EntrySort.allCases) { Text($0.label).tag($0) }
        }
        Picker("Reihenfolge", selection: $ascending) {
            // Feste Namen: Die Menüleiste aktualisiert wechselnde Beschriftungen nicht zuverlässig.
            Text("Absteigend (neueste bzw. Z zuerst)").tag(false)
            Text("Aufsteigend (älteste bzw. A zuerst)").tag(true)
        }
    }
}

/// Wozu der Datums-Dialog gerade offen ist.
enum DateRequest: Identifiable {
    case goTo
    case change(URL)
    var id: String {
        switch self {
        case .goTo: "goTo"
        case .change(let url): url.path
        }
    }
}

/// Dialog mit Kalender: „Gehe zu Datum“ (nur Tag) oder „Datum ändern“ (Tag und Uhrzeit).
struct DateSheet: View {
    let request: DateRequest
    @State var date: Date
    let done: (Date?) -> Void

    private var isGoTo: Bool { if case .goTo = request { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isGoTo ? "Gehe zu Datum" : "Datum ändern").font(.headline)
            // Feld zum Tippen und Kalender zum Klicken zeigen dasselbe Datum.
            DatePicker(isGoTo ? "Datum" : "Datum und Uhrzeit", selection: $date,
                       displayedComponents: isGoTo ? [.date] : [.date, .hourAndMinute])
            #if os(macOS)
            // Der Kalender ist am Mac sehr klein: vergrößert zeigen.
            DatePicker("Kalender", selection: $date, displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
                .scaleEffect(1.6, anchor: .topLeading)
                .frame(width: 139 * 1.6, height: 148 * 1.6, alignment: .topLeading)
            #else
            DatePicker("Kalender", selection: $date, displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
            #endif
            if !isGoTo {
                Text("Liegt der Eintrag in einem Tagesordner (JJJJ/MM/TT), wandert er in den Ordner des neuen Tages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Heute") { date = isGoTo ? Date() : Calendar.current.date(bySettingHour: Calendar.current.component(.hour, from: date),
                                                                                minute: Calendar.current.component(.minute, from: date),
                                                                                second: 0, of: Date()) ?? Date() }
                Spacer()
                Button("Abbrechen", role: .cancel) { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(isGoTo ? "Gehe zu" : "Ändern") { done(date) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 300)
    }
}
