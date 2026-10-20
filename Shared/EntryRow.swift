import SwiftUI

/// Zeile in der Eintragsliste: Titel, Datum, wo er liegt, Vorschau.
struct EntryRow: View {
    let entry: Entry
    /// Wo der Eintrag liegt („Schlaraffia › Kantzlerambt“); nur bei „Alle Einträge“ und bei der Suche.
    var location: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let color = entry.labelColor {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(color)
                        .accessibilityLabel("Etikett \(entry.meta[MetaKey.etikett.rawValue] ?? "")")
                }
                if entry.encrypted {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Verschlüsselt")
                }
                if entry.flagged {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Markiert")
                }
                Text(entry.title)
                    .font(.headline)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(entry.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
                if entry.rating > 0 {
                    Text(String(repeating: "★", count: entry.rating))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("\(entry.rating) Sterne")
                }
                if let status = entry.meta[MetaKey.status.rawValue] { Text(status) }
                if let place = entry.meta[MetaKey.ort.rawValue] {
                    Label(place, systemImage: "mappin").lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !entry.tags.isEmpty {
                Label(entry.tags.joined(separator: ", "), systemImage: "tag")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let location {
                Label(location, systemImage: "book.closed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if !entry.preview.isEmpty {
                Text(entry.preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}
