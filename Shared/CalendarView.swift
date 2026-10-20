import SwiftUI

/// Mitte als Liste oder als Monatskalender (wie MacJournal „Calendar View Mode“). Mac und iPhone merken sich die Wahl.
enum ListMode: String, CaseIterable {
    case list, calendar, timeline, map
    static let key = "listMode"

    var label: String {
        switch self {
        case .list: "Liste"
        case .calendar: "Kalender"
        case .timeline: "Zeitleiste"
        case .map: "Karte"
        }
    }
}

/// Umschalter Liste / Kalender / Zeitleiste / Karte über der Eintragsliste.
struct ListModePicker: View {
    @AppStorage(ListMode.key) private var mode = ListMode.list

    var body: some View {
        Picker("Ansicht", selection: $mode) {
            ForEach(ListMode.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Ein Monat auf einen Blick: Tage mit Einträgen haben einen Punkt, heute ist farbig, der gewählte Tag hinterlegt.
struct MonthCalendar: View {
    /// Einträge, die gezählt werden (schon nach Journal und Suche gefiltert).
    let entries: [Entry]
    /// Irgendein Tag im gezeigten Monat.
    @Binding var month: Date
    let selectedDay: Date?
    let pick: (Date) -> Void

    /// Woche beginnt am Montag, deutsche Monatsnamen.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "de_DE")
        c.firstWeekday = 2
        return c
    }()
    private static let weekdays = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
    private static let monthFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    var body: some View {
        let cal = Self.calendar
        let counts = Dictionary(grouping: entries) { cal.startOfDay(for: $0.date) }.mapValues(\.count)
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        let days = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let offset = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let inMonth = counts.filter { cal.isDate($0.key, equalTo: first, toGranularity: .month) }.values.reduce(0, +)

        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button { shift(.year, -1) } label: { Label("Ein Jahr zurück", systemImage: "chevron.backward.2").labelStyle(.iconOnly) }
                    .help("Ein Jahr zurück")
                Button { shift(.month, -1) } label: { Label("Einen Monat zurück", systemImage: "chevron.backward").labelStyle(.iconOnly) }
                    .help("Einen Monat zurück")
                Spacer()
                VStack(spacing: 0) {
                    Text(Self.monthFormat.string(from: first)).font(.headline)
                    Text(inMonth == 1 ? "1 Eintrag" : "\(inMonth) Einträge").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { shift(.month, 1) } label: { Label("Einen Monat vor", systemImage: "chevron.forward").labelStyle(.iconOnly) }
                    .help("Einen Monat vor")
                Button { shift(.year, 1) } label: { Label("Ein Jahr vor", systemImage: "chevron.forward.2").labelStyle(.iconOnly) }
                    .help("Ein Jahr vor")
            }
            .buttonStyle(.borderless)
            .font(.title3)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(Self.weekdays, id: \.self) { name in
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(0..<offset, id: \.self) { _ in
                    Color.clear.frame(height: 1)
                }
                ForEach(1...days, id: \.self) { day in
                    let date = cal.date(byAdding: .day, value: day - 1, to: first) ?? first
                    Button { pick(date) } label: {
                        DayCell(day: day, count: counts[date] ?? 0, isToday: cal.isDateInToday(date),
                                isSelected: selectedDay.map { cal.isDate($0, inSameDayAs: date) } ?? false)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button("Heute") {
                month = Date()
                pick(cal.startOfDay(for: Date()))
            }
            .buttonStyle(.borderless)
        }
    }

    private func shift(_ unit: Calendar.Component, _ value: Int) {
        month = Self.calendar.date(byAdding: unit, value: value, to: month) ?? month
    }
}

/// Ein Tag im Kalender: Zahl und darunter ein Punkt, wenn es Einträge gibt.
private struct DayCell: View {
    let day: Int
    let count: Int
    let isToday: Bool
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text("\(day)")
                .font(.body.monospacedDigit())
                .fontWeight(isToday || count > 0 ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.white : isToday ? Color.accentColor : count > 0 ? Color.primary : Color.secondary)
            Circle()
                .fill(count > 0 ? (isSelected ? Color.white : Color.accentColor) : Color.clear)
                .frame(width: 5, height: 5)
        }
        .frame(maxWidth: .infinity, minHeight: 38)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isToday && !isSelected ? Color.accentColor : Color.clear))
        .contentShape(Rectangle())
        .help(count == 0 ? "Kein Eintrag" : count == 1 ? "1 Eintrag" : "\(count) Einträge")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day). \(count == 0 ? "kein Eintrag" : count == 1 ? "1 Eintrag" : "\(count) Einträge")")
    }
}
