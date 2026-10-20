import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Einträge teilen, zusammenführen, Gliederung anlegen, Rich Text für Anhänge vorbereiten
/// (wie MacJournal „Split“, „Merge Entries“, „New Outline Entry“).
extension Library {

    /// Titel ohne Datei: aus der Liste, sonst aus der Datei.
    func title(of url: URL) -> String {
        if let entry = entries.first(where: { $0.url == url }) { return entry.title }
        if Self.isRich(url) { return Self.readRich(url)?.title ?? url.deletingPathExtension().lastPathComponent }
        return Self.parse(read(url), url: url).title
    }

    /// Dateiname für einen neuen Teil: „<Datum> <Titel>.<Endung>“ im selben Ordner.
    private func partURL(for url: URL, title: String, ext: String) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        let day = name.count >= 10 && Self.dayFormat.date(from: String(name.prefix(10))) != nil ? String(name.prefix(10)) + " " : ""
        return Self.freeName(day + Self.safeName(title) + "." + ext, in: url.deletingLastPathComponent())
    }

    /// Markdown-Eintrag teilen: `tail` (der Text nach dem Cursor) wird ein neuer Eintrag „<Titel> (Teil 2)“.
    func splitOff(text tail: String, from url: URL) throws -> URL {
        let entry = entries.first { $0.url == url } ?? Self.parse(read(url), url: url)
        let title = entry.title + " (Teil 2)"
        let target = partURL(for: url, title: title, ext: url.pathExtension)
        let body = "---\ndatum: \(Self.timeFormat.string(from: entry.date))\n---\n\n# \(title)\n\n"
            + tail.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        lastOwnWrite = Date()
        try writeText(body, to: target)
        reload()
        return target
    }

    /// Rich-Text-Eintrag teilen: `tail` wird ein neuer Eintrag mit gleicher Endung (Bilder bleiben in .rtfd).
    func splitOff(rich tail: NSAttributedString, from url: URL) throws -> URL {
        let title = title(of: url) + " (Teil 2)"
        let target = partURL(for: url, title: title, ext: url.pathExtension)
        try saveRich(tail, to: target, title: .some(title), ids: [], keywords: [])
        // Gleiches Datum wie das Original (Rich Text: Erstelldatum der Datei).
        if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate {
            try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: target.path)
        }
        reload()
        return target
    }

    /// Mehrere Einträge zu einem zusammenführen (nach Datum). Nur Markdown → Markdown, sonst Rich Text.
    /// Die Originale kommen in den Papierkorb. Gibt den neuen Eintrag zurück.
    func merge(_ urls: [URL]) throws -> URL {
        let list = urls.map { url in entries.first { $0.url == url } ?? Entry(url: url, title: title(of: url), date: Date(), preview: "") }
            .sorted { $0.date < $1.date }
        guard let first = list.first, list.count > 1 else { throw CocoaError(.featureUnsupported) }
        let folder = first.url.deletingLastPathComponent()
        let title = first.title + " (zusammengeführt)"
        let day = Self.dayFormat.string(from: first.date)
        let tags = Array(Set(list.flatMap(\.tags))).sorted()
        lastOwnWrite = Date()
        let target: URL
        if list.allSatisfy({ !Self.isRich($0.url) }) {
            var parts = ["---", "datum: " + Self.timeFormat.string(from: first.date)]
            if !tags.isEmpty { parts.append("tags: [" + tags.joined(separator: ", ") + "]") }
            parts += ["---", "", "# " + title]
            for entry in list {
                parts += ["", "## " + entry.title, "", "*" + Self.longDayFormat.string(from: entry.date) + "*", "", Self.bodyWithoutHead(read(entry.url), title: entry.title)]
            }
            target = Self.freeName(day + " " + Self.safeName(title) + ".md", in: folder)
            try writeText(parts.joined(separator: "\n") + "\n", to: target)
        } else {
            let result = NSMutableAttributedString()
            let base = Self.richTypingAttributes[.font] as! PlatformFont
            let bold = Self.font(base, bold: true, italic: false)
            let grey: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: PlatformColor.darkGray]
            var images = false
            for (n, entry) in list.enumerated() {
                if n > 0 { result.append(NSAttributedString(string: "\n\n", attributes: Self.richTypingAttributes)) }
                result.append(NSAttributedString(string: entry.title + "\n", attributes: [.font: bold, .foregroundColor: PlatformColor.black]))
                result.append(NSAttributedString(string: Self.longDayFormat.string(from: entry.date) + "\n\n", attributes: grey))
                if Self.isRich(entry.url) {
                    if let text = Self.readRich(entry.url)?.text {
                        result.append(text)
                        if entry.url.pathExtension.lowercased() == "rtfd" { images = true }
                    }
                } else {
                    result.append(Self.markdownForPrint(read(entry.url), skipTitle: entry.title, base: base))
                }
            }
            target = Self.freeName(day + " " + Self.safeName(title) + (images ? ".rtfd" : ".rtf"), in: folder)
            try saveRich(result, to: target, title: .some(title), ids: [], keywords: tags)
        }
        for entry in list { try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil) }
        reload()
        return target
    }

    /// Markdown ohne Kopf (--- … ---) und ohne Titel-Überschrift.
    static func bodyWithoutHead(_ raw: String, title: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...end) }
        if let i = lines.firstIndex(of: "# " + title) { lines.remove(at: i) }
        // Überschriften eine Stufe tiefer, damit sie unter dem Teil-Titel stehen.
        lines = lines.map { $0.hasPrefix("#") ? "#" + $0 : $0 }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Neue Gliederung (Markdown-Liste mit Einrückung; Einrücken/Ausrücken unter Format › Text).
    func newOutline(in folder: URL) throws -> URL {
        let folder = Self.folderForNew(folder)
        let today = Self.dayFormat.string(from: Date())
        let target = Self.freeName("\(today) Gliederung.md", in: folder)
        let text = "---\ndatum: \(today)\n---\n\n# Gliederung\n\n- Erster Punkt\n  - Unterpunkt\n- Zweiter Punkt\n"
        lastOwnWrite = Date()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeText(text, to: target)
        reload()
        justCreated = target
        return target
    }

    /// Rich Text (.rtf) als .rtfd sichern, damit Bilder und Dateien hineinpassen. Die .rtf kommt in den Papierkorb.
    func moveToRTFD(_ url: URL, text: NSAttributedString) throws -> URL {
        let old = Self.readRich(url)
        let target = Self.freeName(url.deletingPathExtension().lastPathComponent + ".rtfd", in: url.deletingLastPathComponent())
        let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        try saveRich(text, to: target, title: .some(old?.title), ids: old?.ids ?? [], keywords: old?.keywords ?? [])
        if let created { try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: target.path) }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload()
        return target
    }
}

extension Notification.Name {
    /// Ein Eintrag soll gewählt werden (object = URL), z. B. nach dem Teilen.
    static let selectEntry = Notification.Name("JournalIT.selectEntry")
    /// Eintrag hat eine neue Datei (object = [alt, neu]), z. B. .rtf → .rtfd.
    static let entryMoved = Notification.Name("JournalIT.entryMoved")
    /// Eintrag ist jetzt verborgen (z. B. verschlüsselt, während gesperrt ist); object = URL.
    static let entryHidden = Notification.Name("JournalIT.entryHidden")
    /// Datei als Anhang in den offenen Rich-Text-Eintrag einfügen (object = URL).
    static let insertAttachment = Notification.Name("JournalIT.insertAttachment")
}
