import SwiftUI
import AppKit
import EventKit
import UniformTypeIdentifiers

/// Austausch mit anderen Programmen (wie MacJournal „Export“, „Import“, „Make Calendar Event“, „Make Reminder“,
/// „Entries from Calendar“, „Copy As HTML“). Blog- und Day-One/Journler-Funktionen gibt es bewusst nicht.
enum Exchange {

    enum Format: String {
        case text, html
        var ext: String { self == .text ? "txt" : "html" }
        var label: String { self == .text ? "Text" : "HTML" }
    }

    // MARK: Export

    /// Einträge als Text- oder HTML-Dateien in einen gewählten Ordner. Ein Eintrag: Dateiname wählbar.
    static func export(_ urls: [URL], as format: Format, library: Library) throws -> Int {
        guard !urls.isEmpty else { return 0 }
        if urls.count == 1, let url = urls.first {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format == .text ? .plainText : .html]
            panel.nameFieldStringValue = fileName(url, library: library, ext: format.ext)
            panel.message = "Eintrag als \(format.label) sichern"
            guard panel.runModal() == .OK, let target = panel.url else { return 0 }
            try data(url, format: format, library: library).write(to: target, options: .atomic)
            return 1
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Exportieren"
        panel.message = "Ordner für \(urls.count) Einträge als \(format.label) wählen"
        guard panel.runModal() == .OK, let folder = panel.url else { return 0 }
        for url in urls {
            let target = Library.freeName(fileName(url, library: library, ext: format.ext), in: folder)
            try data(url, format: format, library: library).write(to: target, options: .atomic)
        }
        return urls.count
    }

    private static func fileName(_ url: URL, library: Library, ext: String) -> String {
        let entry = library.entries.first { $0.url == url }
        let title = Library.safeName(entry?.title ?? url.deletingPathExtension().lastPathComponent)
        let day = entry.map { Library.dayFormat.string(from: $0.date) } ?? ""
        return (title.hasPrefix(day) || day.isEmpty ? title : day + " " + title) + "." + ext
    }

    static func data(_ url: URL, format: Format, library: Library) throws -> Data {
        let text = library.printableText(url)
        switch format {
        case .text:
            return Data(text.string.replacingOccurrences(of: "\u{FFFC}", with: "").utf8)
        case .html:
            return try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                                      .characterEncoding: String.Encoding.utf8.rawValue])
        }
    }

    /// „Als HTML kopieren“: HTML und Rich Text in die Zwischenablage.
    static func copyHTML(_ url: URL, library: Library) {
        guard let html = try? data(url, format: .html, library: library) else { return }
        let text = library.printableText(url)
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(html, forType: .html)
        if let rtf = try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            board.setData(rtf, forType: .rtf)
        }
        board.setString(text.string, forType: .string)
    }

    // MARK: Import

    /// Dateien ins Journal holen. Markdown, Text, RTF, RTFD werden kopiert; Word, HTML, OpenDocument werden zu Rich Text.
    /// Ohne Datum vorne im Namen bekommt die Datei das Erstelldatum der Quelle.
    static func importFiles(into folder: URL, library: Library) throws -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .rtf, .rtfd, .html, .text,
                                     UTType(filenameExtension: "md") ?? .plainText,
                                     UTType(filenameExtension: "docx") ?? .data,
                                     UTType(filenameExtension: "doc") ?? .data,
                                     UTType(filenameExtension: "odt") ?? .data]
        panel.prompt = "Importieren"
        panel.message = "Dateien in „\(folder.lastPathComponent)“ übernehmen"
        guard panel.runModal() == .OK else { return [] }
        var created: [URL] = []
        library.lastOwnWrite = Date()
        for source in panel.urls {
            let name = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension.lowercased()
            let created1 = (try? source.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let hasDay = name.count >= 10 && Library.dayFormat.date(from: String(name.prefix(10))) != nil
            let base = hasDay ? name : Library.dayFormat.string(from: created1) + " " + name
            if Library.textTypes.contains(ext) || Library.richTypes.contains(ext) {
                let target = Library.freeName(base + "." + ext, in: folder)
                try FileManager.default.copyItem(at: source, to: target)
                created.append(target)
            } else {
                let text = try NSAttributedString(url: source, options: [:], documentAttributes: nil)
                var hasImages = false
                text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
                    if value != nil { hasImages = true; stop.pointee = true }
                }
                let target = Library.freeName(base + (hasImages ? ".rtfd" : ".rtf"), in: folder)
                try library.saveRich(text, to: target, title: .some(name))
                created.append(target)
            }
        }
        library.reload()
        return created
    }
}

// MARK: - Kalender und Erinnerungen

/// Zugriff auf Kalender und Erinnerungen (EventKit).
final class CalendarBridge {
    static let shared = CalendarBridge()
    let store = EKEventStore()

    func requestEvents() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func requestReminders() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }
}

/// Termin oder Erinnerung aus einem Eintrag (Titel, Zeit, Notiz mit Link zum Eintrag).
struct MakeEventSheet: View {
    @EnvironmentObject private var library: Library
    let url: URL
    let done: () -> Void

    enum Kind: String { case event, reminder }
    @State private var kind = Kind.event
    @State private var title = ""
    @State private var date = Date()
    @State private var minutes = 60
    @State private var message: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Termin oder Erinnerung").font(.headline)
            Picker("Art", selection: $kind) {
                Text("Termin im Kalender").tag(Kind.event)
                Text("Erinnerung").tag(Kind.reminder)
            }
            .pickerStyle(.radioGroup)
            TextField("Titel", text: $title)
            DatePicker(kind == .event ? "Beginn" : "Fällig", selection: $date)
            if kind == .event {
                Picker("Dauer", selection: $minutes) {
                    ForEach([15, 30, 60, 90, 120, 240], id: \.self) { Text("\($0) Minuten").tag($0) }
                    Text("ganztägig").tag(0)
                }
            }
            Text("In der Notiz stehen der Anfang des Eintrags und der Pfad zur Datei.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message { Text(message).foregroundStyle(.red) }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Abbrechen", role: .cancel, action: done).keyboardShortcut(.cancelAction)
                Button("Anlegen") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding()
        .frame(width: 420)
        .onAppear {
            let entry = library.entries.first { $0.url == url }
            title = entry?.title ?? url.deletingPathExtension().lastPathComponent
            // Datum des Eintrags, um 9 Uhr, wenn er keine Uhrzeit hat; liegt es in der Vergangenheit: morgen 9 Uhr.
            var start = entry?.date ?? Date()
            if Calendar.current.startOfDay(for: start) == start { start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: start) ?? start }
            if start < Date() {
                start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0,
                                              of: Calendar.current.date(byAdding: .day, value: 1, to: Date())!) ?? Date()
            }
            date = start
        }
    }

    @MainActor
    private func create() async {
        working = true
        defer { working = false }
        let bridge = CalendarBridge.shared
        let entry = library.entries.first { $0.url == url }
        let notes = [entry?.preview ?? "", "Eintrag: " + url.absoluteString].filter { !$0.isEmpty }.joined(separator: "\n\n")
        do {
            if kind == .event {
                guard await bridge.requestEvents() else {
                    message = "Kein Zugriff auf den Kalender. Bitte in Systemeinstellungen › Datenschutz › Kalender erlauben."
                    return
                }
                let event = EKEvent(eventStore: bridge.store)
                event.title = title
                event.calendar = bridge.store.defaultCalendarForNewEvents
                event.isAllDay = minutes == 0
                event.startDate = minutes == 0 ? Calendar.current.startOfDay(for: date) : date
                event.endDate = minutes == 0 ? event.startDate : date.addingTimeInterval(TimeInterval(minutes * 60))
                event.notes = notes
                event.url = url
                try bridge.store.save(event, span: .thisEvent)
            } else {
                guard await bridge.requestReminders() else {
                    message = "Kein Zugriff auf Erinnerungen. Bitte in Systemeinstellungen › Datenschutz › Erinnerungen erlauben."
                    return
                }
                let reminder = EKReminder(eventStore: bridge.store)
                reminder.title = title
                reminder.calendar = bridge.store.defaultCalendarForNewReminders()
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                reminder.addAlarm(EKAlarm(absoluteDate: date))
                reminder.notes = notes
                reminder.url = url
                try bridge.store.save(reminder, commit: true)
            }
            done()
        } catch {
            message = "Anlegen ging nicht: \(error.localizedDescription)"
        }
    }
}

/// Einträge aus dem Kalender (wie MacJournal „Entries from Calendar“): je Termin ein Eintrag (Markdown).
struct CalendarImportSheet: View {
    @EnvironmentObject private var library: Library
    let folder: URL
    let done: ([URL]) -> Void

    @State private var from = Calendar.current.startOfDay(for: Date())
    @State private var to = Date()
    @State private var message: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Einträge aus dem Kalender").font(.headline)
            Text("Jeder Termin im Zeitraum wird ein eigener Eintrag in „\(folder.lastPathComponent)“: Titel, Zeit, Ort und Notiz.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DatePicker("Von", selection: $from, displayedComponents: .date)
            DatePicker("Bis", selection: $to, displayedComponents: .date)
            if let message { Text(message).foregroundStyle(.red) }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Abbrechen", role: .cancel) { done([]) }.keyboardShortcut(.cancelAction)
                Button("Übernehmen") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || to < from)
            }
        }
        .padding()
        .frame(width: 420)
    }

    @MainActor
    private func run() async {
        working = true
        defer { working = false }
        let bridge = CalendarBridge.shared
        guard await bridge.requestEvents() else {
            message = "Kein Zugriff auf den Kalender. Bitte in Systemeinstellungen › Datenschutz › Kalender erlauben."
            return
        }
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to)) ?? to
        let predicate = bridge.store.predicateForEvents(withStart: Calendar.current.startOfDay(for: from), end: end, calendars: nil)
        let events = bridge.store.events(matching: predicate)
        guard !events.isEmpty else {
            message = "Keine Termine in diesem Zeitraum."
            return
        }
        var created: [URL] = []
        library.lastOwnWrite = Date()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for event in events {
                let title = (event.title ?? "Termin").trimmingCharacters(in: .whitespaces)
                let start = event.startDate ?? Date()
                var lines = ["---", "datum: " + Library.timeFormat.string(from: start), "---", "", "# " + title, ""]
                if event.isAllDay {
                    lines.append("Ganztägig, " + Library.longDayFormat.string(from: start))
                } else {
                    let time = DateFormatter.localizedString(from: start, dateStyle: .none, timeStyle: .short)
                    let endTime = event.endDate.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? ""
                    lines.append(Library.longDayFormat.string(from: start) + ", " + time + (endTime.isEmpty ? "" : "–" + endTime) + " Uhr")
                }
                if let place = event.location, !place.isEmpty { lines += ["", "Ort: " + place] }
                if let calendar = event.calendar?.title { lines += ["", "Kalender: " + calendar] }
                if let notes = event.notes, !notes.isEmpty { lines += ["", notes] }
                let target = Library.freeName(Library.dayFormat.string(from: start) + " " + Library.safeName(title) + ".md", in: folder)
                try library.writeText(lines.joined(separator: "\n") + "\n", to: target)
                created.append(target)
            }
            library.reload()
            done(created)
        } catch {
            message = "Übernehmen ging nicht: \(error.localizedDescription)"
        }
    }
}
