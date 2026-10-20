import Foundation
import AppIntents

/// Schnellnotiz: ein kurzer Gedanke als eigener Eintrag im heutigen Tagesordner des Journals
/// (Journal/JJJJ/MM/TT/JJJJ-MM-TT Notiz HH-mm.md). Eigene Datei, damit Claudes Tageseintrag unberührt bleibt.
enum QuickNoteFile {
    /// Notiz schreiben; gibt die neue Datei zurück. `journal` ist der Ordner des täglichen Journals.
    static func write(_ text: String, in journal: URL, at date: Date = Date()) throws -> URL {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = Library.dayFormat.string(from: date)
        let parts = day.split(separator: "-").map(String.init)
        let folder = journal.appendingPathComponent(parts[0]).appendingPathComponent(parts[1]).appendingPathComponent(parts[2])
        let time = Library.timeFormat.string(from: date)
        let clock = String(time.suffix(5))  // „13:45“
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("\(day) Notiz \(clock.replacingOccurrences(of: ":", with: "-")).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(day) Notiz \(clock.replacingOccurrences(of: ":", with: "-")) (\(n)).md")
            n += 1
        }
        let content = "---\ndatum: \(time)\n---\n\n# Notiz \(clock)\n\n\(body)\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Kurzbefehl „Schnellnotiz“: für Siri, die Kurzbefehle-App und die Aktionstaste am iPhone.
/// Siri fragt nach dem Text; man spricht ihn einfach.
struct QuickNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Schnellnotiz"
    static let description = IntentDescription("Schreibt eine kurze Notiz ins heutige Journal von Journal g-IT.")

    @Parameter(title: "Text", requestValueDialog: "Was möchtest du notieren?")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .result(dialog: "Die Notiz war leer und wurde nicht gesichert.")
        }
        guard let docs = FileManager.default.url(forUbiquityContainerIdentifier: Library.containerID)?
            .appendingPathComponent("Documents") else {
            return .result(dialog: "iCloud ist nicht verfügbar. Die Notiz wurde nicht gesichert.")
        }
        _ = try QuickNoteFile.write(text, in: docs.appendingPathComponent(Library.dailyJournal))
        return .result(dialog: "Notiz gesichert.")
    }
}

struct JournalShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: QuickNoteIntent(),
                    phrases: ["Schnellnotiz in \(.applicationName)", "Notiz in \(.applicationName)"],
                    shortTitle: "Schnellnotiz",
                    systemImageName: "note.text.badge.plus")
    }
}
