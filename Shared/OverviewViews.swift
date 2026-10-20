import SwiftUI
import MapKit
import Charts

/// Zeitleiste (wie MacJournal „Timeline“): oben Einträge pro Jahr, darunter alle nach Monaten gruppiert.
struct TimelineList<Row: View>: View {
    let entries: [Entry]
    @Binding var selection: URL?
    let row: (Entry) -> Row

    private static var monthFormat: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "LLLL yyyy"
        return f
    }

    var body: some View {
        let cal = Calendar.current
        let byMonth = Dictionary(grouping: entries) { cal.date(from: cal.dateComponents([.year, .month], from: $0.date)) ?? $0.date }
        let months = byMonth.keys.sorted(by: >)
        let perYear = Dictionary(grouping: entries) { cal.component(.year, from: $0.date) }.mapValues(\.count)
        VStack(spacing: 0) {
            if !perYear.isEmpty {
                Chart(perYear.sorted { $0.key < $1.key }, id: \.key) { item in
                    BarMark(x: .value("Jahr", String(item.key)), y: .value("Einträge", item.value))
                        .foregroundStyle(Color.accentColor)
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 110)
                .padding(12)
                Divider()
            }
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(months, id: \.self) { month in
                        let list = byMonth[month] ?? []
                        Section {
                            ForEach(list.sorted { $0.date > $1.date }) { entry in row(entry) }
                        } header: {
                            HStack {
                                Text(Self.monthFormat.string(from: month))
                                Spacer()
                                Text(list.count == 1 ? "1 Eintrag" : "\(list.count) Einträge")
                            }
                        }
                        .id(month)
                    }
                }
            }
        }
    }
}

/// Karte (wie MacJournal „Map View Mode“): Einträge mit Ort als Nadeln; Klick wählt den Eintrag.
struct EntryMap: View {
    let entries: [Entry]
    @Binding var selection: URL?

    var body: some View {
        let placed = entries.compactMap { entry in entry.coordinate.map { (entry, CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) } }
        if placed.isEmpty {
            ContentUnavailableView("Keine Einträge mit Ort", systemImage: "map",
                                   description: Text("Den Ort eines Eintrags setzt man unter Eintrag › Info."))
        } else {
            Map(selection: $selection) {
                ForEach(placed, id: \.0.url) { entry, coordinate in
                    Marker(entry.title, systemImage: "book.closed", coordinate: coordinate)
                        .tint(entry.labelColor ?? .accentColor)
                        .tag(entry.url)
                }
            }
            .mapControls {
                #if os(macOS)
                MapZoomStepper()
                #endif
                MapCompass()
            }
            .safeAreaInset(edge: .bottom) {
                Text(placed.count == 1 ? "1 Eintrag mit Ort" : "\(placed.count) Einträge mit Ort")
                    .font(.caption)
                    .padding(6)
                    .background(.bar, in: Capsule())
                    .padding(8)
            }
        }
    }
}

/// Statistik (wie MacJournal „Statistics“) über die gerade gezeigten Einträge.
struct StatisticsSheet: View {
    @EnvironmentObject private var library: Library
    let title: String
    let entries: [Entry]
    let done: () -> Void

    @State private var stats: Stats?

    struct Stats {
        var words = 0
        var longest: (title: String, words: Int)?
        var perYear: [(year: Int, words: Int, count: Int)] = []
        var topWords: [(word: String, count: Int)] = []
        var streak = 0
        var days = 0
    }

    var body: some View {
        VStack(spacing: 0) {
            if let stats {
                Form {
                    Section(title) {
                        LabeledContent("Einträge", value: entries.count.formatted())
                        LabeledContent("Wörter gesamt", value: stats.words.formatted())
                        LabeledContent("Wörter je Eintrag", value: (entries.isEmpty ? 0 : stats.words / entries.count).formatted())
                        if let longest = stats.longest {
                            LabeledContent("Längster Eintrag", value: "\(longest.title) (\(longest.words.formatted()) Wörter)")
                        }
                        LabeledContent("Tage mit Einträgen", value: stats.days.formatted())
                        LabeledContent("Tage in Folge bis heute", value: stats.streak.formatted())
                    }
                    if stats.perYear.count > 1 {
                        Section("Einträge pro Jahr") {
                            Chart(stats.perYear, id: \.year) { item in
                                BarMark(x: .value("Jahr", String(item.year)), y: .value("Einträge", item.count))
                            }
                            .frame(height: 140)
                        }
                    }
                    if !stats.topWords.isEmpty {
                        Section("Häufigste Wörter") {
                            ForEach(stats.topWords, id: \.word) { item in
                                LabeledContent(item.word, value: item.count.formatted())
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ProgressView("Zähle Wörter …").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button("Schließen", action: done).keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        #if os(macOS)
        .frame(width: 480, height: 620)
        #endif
        .task { await compute() }
    }

    /// Kurze und häufige Füllwörter zählen nicht zu den „häufigsten Wörtern“.
    private static let stopWords: Set<String> = ["aber", "alle", "allem", "allen", "aller", "alles", "also", "andere", "anderen", "auch", "auf", "aus",
        "bei", "beim", "bin", "bis", "bist", "dann", "darf", "darum", "das", "dass", "dein", "deine", "dem", "den", "denn", "der", "des", "dessen",
        "die", "dies", "diese", "diesem", "diesen", "dieser", "dieses", "doch", "dort", "durch", "ein", "eine", "einem", "einen", "einer", "eines",
        "etwas", "euch", "für", "gegen", "gibt", "hab", "habe", "haben", "hat", "hatte", "hätte", "heute", "hier", "ich", "ihm", "ihn", "ihr",
        "ihre", "ihren", "ihrer", "immer", "ist", "jede", "jedem", "jeden", "jeder", "jetzt", "kann", "kein", "keine", "können", "machen", "man",
        "mehr", "mein", "meine", "meinem", "meinen", "meiner", "mich", "mir", "mit", "muss", "nach", "nicht", "nichts", "noch", "nun", "nur",
        "oder", "ohne", "schon", "sehr", "sein", "seine", "seinem", "seinen", "seiner", "sich", "sie", "sind", "soll", "sollte", "sondern", "und",
        "uns", "unser", "unter", "viel", "vom", "von", "vor", "war", "waren", "warum", "was", "weil", "wenn", "wer", "werden", "wie", "wieder",
        "wir", "wird", "wo", "wurde", "zum", "zur", "zwei", "über", "the", "and", "for", "with", "that", "this", "you", "are", "http", "https", "www"]

    private func compute() async {
        let texts = entries.map { (entry: $0, text: library.indexedText($0.url) ?? "") }
        let today = Calendar.current.startOfDay(for: Date())
        let result = await Task.detached(priority: .userInitiated) { () -> Stats in
            var stats = Stats()
            var counts: [String: Int] = [:]
            var years: [Int: (words: Int, count: Int)] = [:]
            var days: Set<Date> = []
            for (entry, text) in texts {
                var words = 0
                text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, _, _, _ in
                    words += 1
                    if let word, word.count >= 4, !Self.stopWords.contains(word), word.rangeOfCharacter(from: .decimalDigits) == nil {
                        counts[word, default: 0] += 1
                    }
                }
                stats.words += words
                if words > (stats.longest?.words ?? -1) { stats.longest = (entry.title, words) }
                let year = Calendar.current.component(.year, from: entry.date)
                years[year, default: (0, 0)].words += words
                years[year, default: (0, 0)].count += 1
                days.insert(Calendar.current.startOfDay(for: entry.date))
            }
            stats.days = days.count
            var day = today
            if !days.contains(day) { day = Calendar.current.date(byAdding: .day, value: -1, to: day)! }
            while days.contains(day) {
                stats.streak += 1
                day = Calendar.current.date(byAdding: .day, value: -1, to: day)!
            }
            stats.perYear = years.sorted { $0.key < $1.key }.map { ($0.key, $0.value.words, $0.value.count) }
            stats.topWords = counts.sorted { $0.value > $1.value }.prefix(20).map { ($0.key, $0.value) }
            return stats
        }.value
        stats = result
    }
}
