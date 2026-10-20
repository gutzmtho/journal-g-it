import Foundation
import CryptoKit

/// Sicherungen und frühere Versionen (wie MacJournal „Back Up“, „Browse Backups“, „Show Version History“).
/// Beides liegt nur auf diesem Gerät (Programm-Support der App), nicht in iCloud:
/// - Versionen: vor dem Überschreiben eines Eintrags eine Kopie, höchstens alle 10 Minuten, je Eintrag die letzten 30.
/// - Sicherungen: einmal am Tag der ganze iCloud-Ordner der App als ZIP, die letzten 30.
extension Library {

    static let supportFolder: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var versionsFolder: URL { supportFolder.appendingPathComponent("Versionen", isDirectory: true) }
    static var backupsFolder: URL { supportFolder.appendingPathComponent("Sicherungen", isDirectory: true) }

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f
    }()

    // MARK: Versionen

    /// Ordner mit den Versionen eines Eintrags (nach seinem Pfad benannt).
    private static func versionFolder(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(plainPath(url).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return versionsFolder.appendingPathComponent(hash, isDirectory: true)
    }

    /// Kopie des jetzigen Stands, bevor er überschrieben wird. `force`: auch wenn die letzte Kopie jung ist.
    func keepVersion(of url: URL, force: Bool = false) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let folder = Self.versionFolder(for: url)
        let existing = Self.versionFiles(in: folder)
        if !force, let newest = existing.first, Date().timeIntervalSince(newest.date) < 600 { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.plainPath(url).write(to: folder.appendingPathComponent("pfad.txt"), atomically: true, encoding: .utf8)
            let target = folder.appendingPathComponent(Self.stampFormat.string(from: Date()) + "." + url.pathExtension)
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: url, to: target)
            }
            for old in Self.versionFiles(in: folder).dropFirst(30) { try? FileManager.default.removeItem(at: old.url) }
        } catch {
            print("[JournalIT] Version sichern ging nicht: \(error)")
        }
    }

    private static func versionFiles(in folder: URL) -> [(url: URL, date: Date)] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.compactMap { url in
            guard url.lastPathComponent != "pfad.txt",
                  let date = stampFormat.date(from: url.deletingPathExtension().lastPathComponent) else { return nil }
            return (url, date)
        }.sorted { $0.date > $1.date }
    }

    /// Frühere Versionen eines Eintrags löschen (z. B. vor dem Verschlüsseln: sie wären lesbare Kopien).
    func forgetVersions(of url: URL) {
        try? FileManager.default.removeItem(at: Self.versionFolder(for: url))
    }

    /// Frühere Versionen eines Eintrags, neueste zuerst.
    func versions(of url: URL) -> [(url: URL, date: Date)] {
        Self.versionFiles(in: Self.versionFolder(for: url))
    }

    /// Eine frühere Version zurückholen. Der jetzige Stand wird vorher selbst als Version gesichert.
    func restore(version: URL, to url: URL) throws {
        keepVersion(of: url, force: true)
        lastOwnWrite = Date()
        let temp = url.deletingLastPathComponent().appendingPathComponent(".wiederherstellen-" + UUID().uuidString + "." + url.pathExtension)
        try FileManager.default.copyItem(at: version, to: temp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        reload()
        externalRevision += 1
    }

    // MARK: Sicherungen

    struct BackupFile: Identifiable, Hashable {
        let url: URL
        let date: Date
        let size: Int
        var id: URL { url }
    }

    /// Vorhandene Sicherungen, neueste zuerst.
    func backups() -> [BackupFile] {
        let items = (try? FileManager.default.contentsOfDirectory(at: Self.backupsFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items.compactMap { url in
            guard url.pathExtension == "zip" else { return nil }
            let stamp = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "Journal g-IT ", with: "")
            guard let date = Self.stampFormat.date(from: stamp) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return BackupFile(url: url, date: date, size: size)
        }.sorted { $0.date > $1.date }
    }

    /// Einmal am Tag sichern (beim Start der App aufgerufen).
    func backupIfDue() {
        if let newest = backups().first, Date().timeIntervalSince(newest.date) < 20 * 3600 { return }
        makeBackup()
    }

    /// Den ganzen iCloud-Ordner der App als ZIP sichern. Ältere als die letzten 30 werden entfernt.
    func makeBackup(_ done: ((Result<BackupFile, Error>) -> Void)? = nil) {
        guard let docs = iCloudDocuments else {
            done?(.failure(CocoaError(.fileNoSuchFile)))
            return
        }
        DispatchQueue.global(qos: .utility).async {
            var result: Result<BackupFile, Error> = .failure(CocoaError(.fileWriteUnknown))
            var coordinationError: NSError?
            // „forUploading“ liefert den Ordner fertig gepackt als ZIP.
            NSFileCoordinator().coordinate(readingItemAt: docs, options: .forUploading, error: &coordinationError) { zip in
                do {
                    try FileManager.default.createDirectory(at: Self.backupsFolder, withIntermediateDirectories: true)
                    let now = Date()
                    let target = Self.backupsFolder.appendingPathComponent("Journal g-IT " + Self.stampFormat.string(from: now) + ".zip")
                    try FileManager.default.copyItem(at: zip, to: target)
                    let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    result = .success(BackupFile(url: target, date: now, size: size))
                } catch {
                    result = .failure(error)
                }
            }
            if let coordinationError { result = .failure(coordinationError) }
            for old in self.backups().dropFirst(30) { try? FileManager.default.removeItem(at: old.url) }
            DispatchQueue.main.async { done?(result) }
        }
    }

    // MARK: Wiederherstellen

    /// Ein Eintrag in einer Sicherung und wie er zum jetzigen Stand steht.
    struct BackupItem: Identifiable, Hashable {
        enum State: String { case missing = "fehlt", changed = "geändert", same = "gleich" }
        let source: URL      // im ausgepackten Zwischenordner
        let relative: String // Pfad ab dem iCloud-Ordner der App, z. B. „Journal/2026/10/20/2026-10-20.md“
        let state: State
        var id: String { relative }
    }

    #if os(macOS)
    /// Sicherung in einen Zwischenordner auspacken und mit dem jetzigen Stand vergleichen.
    func openBackup(_ backup: BackupFile) throws -> (folder: URL, items: [BackupItem]) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Sicherung-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", backup.url.path, temp.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        // Die ZIP-Datei enthält den Ordner „Documents“ (den iCloud-Ordner der App).
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        let root = names.count == 1 ? temp.appendingPathComponent(names[0], isDirectory: true) : temp
        guard let docs = iCloudDocuments else { throw CocoaError(.fileNoSuchFile) }
        var items: [BackupItem] = []
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants, .skipsHiddenFiles]) {
            for case let url as URL in walker {
                let ext = url.pathExtension.lowercased()
                if ext == "rtfd" { walker.skipDescendants() }
                guard Self.textTypes.contains(ext) || Self.richTypes.contains(ext) else { continue }
                let relative = String(Self.plainPath(url).dropFirst(Self.plainPath(root).count + 1))
                let current = docs.appendingPathComponent(relative)
                let state: BackupItem.State
                if !FileManager.default.fileExists(atPath: current.path) {
                    state = .missing
                } else {
                    state = Self.sameContents(url, current) ? .same : .changed
                }
                items.append(BackupItem(source: url, relative: relative, state: state))
            }
        }
        items.sort { $0.relative.localizedStandardCompare($1.relative) == .orderedAscending }
        return (temp, items)
    }

    /// Gleicher Inhalt? (Bei .rtfd alle Dateien im Paket.)
    private static func sameContents(_ a: URL, _ b: URL) -> Bool {
        FileManager.default.contentsEqual(atPath: a.path, andPath: b.path)
    }

    /// Einträge aus der Sicherung zurückholen. Fehlende werden angelegt; vorhandene nur mit `replace`
    /// (der jetzige Stand kommt dann in „Frühere Versionen“). Gibt die Zahl der zurückgeholten zurück.
    func restore(_ items: [BackupItem], replace: Bool) throws -> Int {
        guard let docs = iCloudDocuments else { throw CocoaError(.fileNoSuchFile) }
        var count = 0
        lastOwnWrite = Date()
        for item in items where item.state != .same {
            let target = docs.appendingPathComponent(item.relative)
            if FileManager.default.fileExists(atPath: target.path) {
                guard replace else { continue }
                keepVersion(of: target, force: true)
                let temp = target.deletingLastPathComponent().appendingPathComponent(".wiederherstellen-" + UUID().uuidString + "." + target.pathExtension)
                try FileManager.default.copyItem(at: item.source, to: temp)
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            } else {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: item.source, to: target)
            }
            count += 1
        }
        reload()
        externalRevision += 1
        return count
    }
    #endif
}
