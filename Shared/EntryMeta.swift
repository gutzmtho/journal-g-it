import SwiftUI

/// Merkmale eines Eintrags (wie MacJournal: Rating, Label, Mood, Status, Priority, Location).
/// Markdown: im Kopf (`bewertung: 4`, `etikett: rot`, `ort: Lübeck`, `geo: 53.87, 10.69` …).
/// Rich Text: als Stichwort im RTF-Kopf (`bewertung:4`), neben Schlagwörtern und „markiert“.
enum MetaKey: String, CaseIterable {
    case bewertung, etikett, stimmung, status
    case prioritaet = "priorität"
    case ort, geo

    var label: String {
        switch self {
        case .bewertung: "Bewertung"
        case .etikett: "Etikett"
        case .stimmung: "Stimmung"
        case .status: "Status"
        case .prioritaet: "Priorität"
        case .ort: "Ort"
        case .geo: "Koordinaten"
        }
    }

    /// Feste Auswahl (leer = freier Text).
    var choices: [String] {
        switch self {
        case .bewertung: ["1", "2", "3", "4", "5"]
        case .etikett: MetaKey.labelColors.map(\.name)
        case .stimmung: ["sehr gut", "gut", "neutral", "schlecht", "sehr schlecht"]
        case .status: ["offen", "in Arbeit", "wartet", "erledigt"]
        case .prioritaet: ["hoch", "mittel", "niedrig"]
        case .ort, .geo: []
        }
    }

    static let labelColors: [(name: String, color: Color)] = [
        ("rot", .red), ("orange", .orange), ("gelb", .yellow), ("grün", .green),
        ("blau", .blue), ("lila", .purple), ("grau", .gray),
    ]

    static func color(forLabel name: String?) -> Color? {
        labelColors.first { $0.name == name?.lowercased() }?.color
    }

    /// Stichwort „bewertung:4“ → (bewertung, "4"); sonst nil.
    static func parse(keyword: String) -> (MetaKey, String)? {
        guard let colon = keyword.firstIndex(of: ":"),
              let key = MetaKey(rawValue: keyword[..<colon].lowercased()) else { return nil }
        // Im RTF-Kopf steht „;“ statt „,“ (das Komma trennt dort die Stichwörter).
        let value = keyword[keyword.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ";", with: ",")
        return value.isEmpty ? nil : (key, value)
    }

    static func meta(fromKeywords keywords: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for keyword in keywords { if let (key, value) = parse(keyword: keyword) { result[key.rawValue] = value } }
        return result
    }
}

extension Entry {
    var rating: Int { Int(meta[MetaKey.bewertung.rawValue] ?? "") ?? 0 }
    var labelColor: Color? { MetaKey.color(forLabel: meta[MetaKey.etikett.rawValue]) }
    /// Koordinaten aus `geo: 53.87, 10.69`.
    var coordinate: (latitude: Double, longitude: Double)? {
        guard let geo = meta[MetaKey.geo.rawValue] else { return nil }
        let parts = geo.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
}

extension Library {

    /// Ein Merkmal setzen, ändern oder (nil/leer) entfernen.
    func setMeta(_ url: URL, _ key: MetaKey, _ value: String?) throws {
        let value = value?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let clean = (value?.isEmpty ?? true) ? nil : value
        lastOwnWrite = Date()
        if Self.isRich(url) {
            var keywords = Self.readRich(url)?.keywords ?? []
            keywords.removeAll { MetaKey.parse(keyword: $0)?.0 == key }
            // Kommas trennen Stichwörter im RTF-Kopf: im Wert durch „;“ ersetzen.
            if let clean { keywords.append(key.rawValue + ":" + clean.replacingOccurrences(of: ",", with: ";")) }
            try rewriteRichInfo(url, keywords: keywords)
        } else {
            try save(Self.settingHeader(read(url), key.rawValue, clean), to: url)
        }
        externalRevision += 1
    }

    /// Mehrere Merkmale auf einmal (aus dem Info-Dialog).
    func setMeta(_ url: URL, _ values: [MetaKey: String?]) throws {
        for (key, value) in values { try setMeta(url, key, value) }
    }

    // MARK: Links

    /// Ziele von Links in einem Text: macjournal://…, file://… (in Markdown und als Link-Merkmal im Rich Text).
    static func links(in text: NSAttributedString) -> [String] {
        var found: Set<String> = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL { found.insert(url.absoluteString) }
            if let string = value as? String { found.insert(string) }
        }
        for link in links(in: text.string) { found.insert(link) }
        return found.sorted()
    }

    static func links(in raw: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(macjournal://[A-Za-z0-9-]+|file://[^\s)\]>"]+)"#) else { return [] }
        let range = NSRange(raw.startIndex..., in: raw)
        return Array(Set(regex.matches(in: raw, range: range).compactMap { Range($0.range, in: raw).map { String(raw[$0]) } })).sorted()
    }

    /// Einträge, die auf diesen Eintrag verlinken (über MacJournal-Nummer oder Dateilink).
    func backlinks(to url: URL) -> [Entry] {
        let ids = Set(macJournalIDs(of: url).map { "macjournal://" + $0.uppercased() })
        let path = Self.plainPath(url)
        let targets = entries.filter { entry in
            guard entry.url != url, let links = linksFrom[entry.url] else { return false }
            return links.contains { link in
                if link.lowercased().hasPrefix("macjournal://") {
                    return ids.contains("macjournal://" + link.dropFirst("macjournal://".count).uppercased())
                }
                if let file = URL(string: link), file.isFileURL { return Self.plainPath(file) == path }
                return false
            }
        }
        return targets
    }

    // MARK: Wörter

    static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }
}

/// Sterne zum Anklicken (Bewertung 0–5).
struct StarRating: View {
    @Binding var value: Int
    var size: CGFloat = 16

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { n in
                Image(systemName: n <= value ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(n <= value ? Color.orange : Color.secondary)
                    .onTapGesture { value = value == n ? 0 : n }
                    .accessibilityLabel("\(n) Sterne")
            }
        }
    }
}

/// Wofür der Info-Dialog offen ist.
struct InfoRequest: Identifiable {
    let url: URL
    var id: URL { url }
}
