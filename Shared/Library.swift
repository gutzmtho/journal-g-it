import Foundation
import Combine
#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#endif

/// Ein Eintrag = eine Markdown-, Text- oder RTF-Datei.
struct Entry: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var title: String
    var date: Date
    var preview: String
    /// Markiert (Fahne), wie in MacJournal. Markdown: `markiert: ja` im Kopf; Rich Text: Stichwort „markiert“ im RTF-Kopf.
    var flagged = false
    /// Schlagwörter. Markdown: `tags: [A, B]` im Kopf (wie Obsidian); Rich Text: Stichwörter im RTF-Kopf.
    var tags: [String] = []
    /// Merkmale wie in MacJournal: Bewertung, Etikett, Stimmung, Status, Priorität, Ort (siehe EntryMeta.swift).
    var meta: [String: String] = [:]
    /// Datei ist verschlüsselt (einzeln oder weil das Journal verschlüsselt ist).
    var encrypted = false
}

/// Ein Journal = ein Ordner. Unterordner sind Unter-Journale.
struct FolderNode: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    let name: String
    var count: Int
    var children: [FolderNode]?
    /// Gesperrt (Touch ID / Passwort nötig, siehe JournalLock.swift).
    var locked = false
    /// Verschlüsselt (Vault.swift).
    var encrypted = false
}

/// RTF/RTFD-Eintrag mit Titel und MacJournal-Nummern aus dem RTF-Kopf ({\info{\title …}{\doccomm macjournal:…}}).
struct RichDocument {
    var text: NSAttributedString
    var title: String?
    var ids: [String]
    /// Stichwörter im RTF-Kopf ({\keywords …}); „markiert“ = Fahne.
    var keywords: [String] = []
}

/// Liest und schreibt die Einträge in den eingestellten Ordnern ("Quellen").
/// Es gibt keine eigene Datenbank: Was im Ordner liegt, zeigt die App.
/// Gemeinsam für Mac und iPhone; die Daten liegen im iCloud-Ordner der App.
final class Library: ObservableObject {

    @Published private(set) var sources: [URL] = []
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var trees: [FolderNode] = []
    @Published private(set) var isLoading = false
    /// Dateien, die iCloud gerade noch herunterlädt.
    @Published private(set) var downloading = 0
    /// Meldung, wenn iCloud fehlt (nicht angemeldet o. ä.).
    @Published private(set) var iCloudProblem: String?
    /// Zuletzt angelegter Eintrag – der Editor öffnet ihn gleich zum Schreiben.
    var justCreated: URL?
    /// Zählt Änderungen von außen (Claude, iCloud, Finder). Der Editor liest dann neu.
    @Published var externalRevision = 0
    /// Intelligente Journale (gespeicherte Regeln), aus „Intelligente Journale.json“ im iCloud-Ordner der App.
    @Published private(set) var smartJournals: [SmartJournal] = []
    /// Vorlagen (Dateien im Ordner „Vorlagen“), für die Menüs.
    @Published private(set) var templateList: [URL] = []
    /// Gesperrte Journale (Pfade relativ zum iCloud-Ordner, sonst absolut), aus „Gesperrte Journale.json“.
    @Published var lockedFolders: [String] = []
    /// Gesperrte Journale gerade offen (nach Touch ID / Passwort).
    @Published var unlocked = false
    /// Verschlüsselte Journale (wie lockedFolders), aus „Verschlüsselte Journale.json“. Sie sind immer auch gesperrt.
    @Published var encryptedFolders: [String] = []
    /// Passwort-Dialog für die Verschlüsselung (Festlegen oder Eingeben); die Ansichten zeigen ihn.
    @Published var passwordRequest: PasswordRequest?
    /// Nachricht für die Ansichten (z. B. „Journal verschlüsselt“).
    @Published var notice: String?
    /// Läuft gerade das Verschlüsseln (dann darf ein Schlüssel angelegt werden)?
    var settingUpEncryption = false
    /// Wiederherstellungsschlüssel, der einmal gezeigt wird (nach dem ersten Verschlüsseln).
    @Published var recoveryCode: String?
    /// Wie viele verschlüsselte Einträge es gibt (auch einzeln verschlüsselte außerhalb verschlüsselter Journale).
    @Published private(set) var encryptedEntryCount = 0

    #if os(macOS)
    private var stream: FSEventStreamRef?
    #endif
    private var pendingReload: DispatchWorkItem?
    /// Eigene Schreibvorgänge lösen ebenfalls Ordner-Ereignisse aus; die kurz danach ignorieren.
    var lastOwnWrite = Date.distantPast

    /// Volltext für die Suche, kleingeschrieben.
    private var searchText: [URL: String] = [:]
    /// MacJournal-Eintragsnummer → Datei.
    private var macJournalIndex: [String: URL] = [:]
    /// Links in jedem Eintrag (macjournal://…, file://…), für „Wer verlinkt hierher?“.
    var linksFrom: [URL: [String]] = [:]

    private static let sourcesKey = "sources"
    static let containerID = "iCloud.eu.gutzmannit.journalit"
    /// Ordner im iCloud-Bereich der App (Mac und iPhone sehen dieselben).
    /// „Journal“ ist das tägliche Journal (Claude schreibt dort als Markdown); bis 18.10.2026 lag es in Nextcloud.
    static let iCloudFolders = ["Journal", "MacJournal-Export", "Docmost-Export"]
    static let dailyJournal = "Journal"

    /// Quellen, auf die die App (Sandbox) noch keinen Zugriff hat; der Nutzer gibt sie einmal per Ordner-Dialog frei.
    @Published private(set) var lockedSources: [URL] = []
    private static let bookmarksKey = "sourceBookmarks"

    /// iCloud-Ordner der App, sobald bekannt.
    private(set) var iCloudDocuments: URL?

    init() {
        // Die iCloud-Adresse darf man nicht auf dem Hauptthread erfragen.
        DispatchQueue.global(qos: .userInitiated).async {
            let container = FileManager.default.url(forUbiquityContainerIdentifier: Self.containerID)
            var docs = container?.appendingPathComponent("Documents")
            #if targetEnvironment(simulator)
            // Der Simulator hat meist kein iCloud: dann der Dokumente-Ordner der App (zum Testen mit kopierten Daten).
            if docs == nil { docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first }
            #endif
            if let docs {
                for name in Self.iCloudFolders {
                    try? FileManager.default.createDirectory(at: docs.appendingPathComponent(name), withIntermediateDirectories: true)
                }
            }
            print("[JournalIT] iCloud-Ordner: \(docs?.path ?? "keiner")")
            DispatchQueue.main.async {
                self.iCloudDocuments = docs
                if docs == nil { self.iCloudProblem = "iCloud ist nicht verfügbar. Bitte in den Systemeinstellungen bei iCloud anmelden und iCloud Drive einschalten." }
                self.restoreAccess()
                self.sources = self.initialSources()
                self.updateLocked()
                self.reload()
                self.watch()
            }
        }
    }

    private var defaultSources: [URL] {
        Self.iCloudFolders.compactMap { iCloudDocuments?.appendingPathComponent($0) }
    }

    /// Gespeicherte Quellen, aufgeräumt: alte Pfade in ~/Documents und das alte Nextcloud-Journal zeigen auf den
    /// iCloud-Ordner; der ganze iCloud-Ordner als Quelle fällt weg (sonst stehen alle Einträge doppelt da);
    /// keine Quelle doppelt.
    private func initialSources() -> [URL] {
        guard let saved = UserDefaults.standard.stringArray(forKey: Self.sourcesKey) else { return defaultSources }
        var list: [URL] = []
        for path in saved {
            var url = URL(fileURLWithPath: path)
            if let docs = iCloudDocuments {
                if Self.plainPath(url) == Self.plainPath(docs) { continue }
                let name = url.lastPathComponent
                let movedToICloud = (Self.iCloudFolders.contains(name) && url.deletingLastPathComponent().lastPathComponent == "Documents"
                                     && !path.contains("Mobile Documents"))
                    || path.hasSuffix("/Nextcloud/I+T/gutzmtho/Journal")
                if movedToICloud { url = docs.appendingPathComponent(name) }
            }
            if !list.contains(where: { Self.plainPath($0) == Self.plainPath(url) }) { list.append(url) }
        }
        for url in defaultSources where !list.contains(where: { Self.plainPath($0) == Self.plainPath(url) }) {
            list.append(url)
        }
        // Feste Reihenfolge: Journal, MacJournal-Export, Docmost-Export; selbst hinzugefügte Ordner danach.
        let order = defaultSources.map(Self.plainPath)
        list = list.enumerated().sorted { a, b in
            let ia = order.firstIndex(of: Self.plainPath(a.element)) ?? order.count + a.offset
            let ib = order.firstIndex(of: Self.plainPath(b.element)) ?? order.count + b.offset
            return ia < ib
        }.map(\.element)
        if list.map(\.path) != saved { UserDefaults.standard.set(list.map(\.path), forKey: Self.sourcesKey) }
        return list
    }

    // MARK: - Ordner überwachen

    private func watch() {
        #if os(macOS)
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        guard !sources.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Library>.fromOpaque(info).takeUnretainedValue().foldersChanged()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, sources.map(\.path) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        #endif
    }

    /// Von außen geändert (Mac: Ordner-Ereignis; iPhone: App kommt nach vorne).
    func foldersChanged() {
        guard Date().timeIntervalSince(lastOwnWrite) > 3 else { return }
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reload()
            self?.externalRevision += 1
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - Quellen

    func addSource(_ url: URL) {
        rememberAccess(to: url)
        guard !sources.contains(url) else { updateLocked(); reload(); watch(); return }
        setSources(sources + [url])
    }

    // MARK: - Zugriff (Sandbox)

    /// Lesezeichen mit Zugriffsrecht merken (vom Ordner-Dialog) und sofort benutzen.
    private func rememberAccess(to url: URL) {
        #if os(macOS)
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.bookmarksKey) as? [String: Data] ?? [:]
        all[url.path] = data
        UserDefaults.standard.set(all, forKey: Self.bookmarksKey)
        _ = url.startAccessingSecurityScopedResource()
        #endif
    }

    /// Gemerkte Zugriffsrechte beim Start wieder öffnen.
    private func restoreAccess() {
        #if os(macOS)
        let all = UserDefaults.standard.dictionary(forKey: Self.bookmarksKey) as? [String: Data] ?? [:]
        for data in all.values {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                if stale { rememberAccess(to: url) }
            }
        }
        #endif
    }

    private func updateLocked() {
        lockedSources = sources.filter { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) == nil }
    }

    func removeSource(_ url: URL) {
        setSources(sources.filter { $0 != url })
    }

    private func setSources(_ list: [URL]) {
        sources = list
        UserDefaults.standard.set(list.map(\.path), forKey: Self.sourcesKey)
        updateLocked()
        reload()
        watch()
    }

    /// Alle Ordner zum Verschieben, mit Pfad als Anzeige („Journal / 2026 / 10“).
    var allFolders: [(url: URL, label: String)] {
        func walk(_ node: FolderNode, _ prefix: String) -> [(url: URL, label: String)] {
            let label = prefix.isEmpty ? node.name : prefix + " / " + node.name
            return [(node.url, label)] + (node.children ?? []).flatMap { walk($0, label) }
        }
        return trees.flatMap { walk($0, "") }
    }

    // MARK: - Einlesen

    /// Zwischenspeicher pro Datei: nur geänderte Dateien werden neu gelesen (2.000 RTF lesen dauert sonst lange).
    private struct CachedEntry: Codable {
        var modified: Date
        var title: String
        var date: Date
        var preview: String
        var search: String
        var ids: [String]
        var flagged: Bool?  // fehlt in älteren Zwischenspeichern
        var tags: [String]?
        var meta: [String: String]?
        var links: [String]?
    }

    private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("eu.gutzmannit.journalit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("eintraege-v2.plist")
    }()

    private static func loadCache() -> [String: CachedEntry] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        return (try? PropertyListDecoder().decode([String: CachedEntry].self, from: data)) ?? [:]
    }

    private static func saveCache(_ cache: [String: CachedEntry]) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try? encoder.encode(cache).write(to: cacheURL, options: .atomic)
    }

    /// Änderungsdatum; bei .rtfd zählt auch der Text darin.
    private static func modified(_ url: URL) -> Date {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        guard url.pathExtension.lowercased() == "rtfd" else { return date }
        let inner = (try? url.appendingPathComponent("TXT.rtf").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return max(date, inner)
    }

    /// Läuft gerade ein Einlesen? Dann danach noch einmal, statt doppelt gleichzeitig.
    private var reloading = false
    private var reloadAgain = false
    /// Fortschritt beim ersten Einlesen („400 von 2.060“).
    @Published private(set) var progress: String?

    func reload() {
        loadSmartJournals()
        loadLocks()
        refreshTemplates()
        guard !reloading else { reloadAgain = true; return }
        reloading = true
        isLoading = true
        let sources = self.sources
        let locks = LockSnapshot(all: lockedURLs, hidden: unlocked ? [] : lockedURLs, encrypted: encryptedURLs, unlocked: unlocked)
        #if os(iOS) && !targetEnvironment(simulator)
        // Auf dem iPhone ist das Durchsuchen des iCloud-Ordners sehr langsam; die iCloud-Abfrage liefert die Liste sofort.
        // (Nicht im Simulator: Der liest einen gewöhnlichen Ordner, den die iCloud-Abfrage nicht kennt.)
        if let docs = iCloudDocuments, sources.allSatisfy({ Self.isInside($0, docs) || $0 == docs }) {
            ICloudListing.run { listing in
                DispatchQueue.global(qos: .userInitiated).async {
                    let files = listing.filter { item in sources.contains { Self.isInside(item.url, $0) } }
                    self.process(files: files, waiting: listing.filter(\.waiting).count, sources: sources, locks: locks)
                }
            }
            return
        }
        #endif
        DispatchQueue.global(qos: .userInitiated).async {
            var files: [ListedFile] = []
            var seen: Set<String> = []
            var waiting = 0
            for source in sources {
                let (urls, w) = Self.files(in: source)
                waiting += w
                // Liegt eine Quelle in einer anderen, kämen ihre Dateien sonst doppelt.
                for url in urls where seen.insert(Self.plainPath(url)).inserted {
                    files.append(ListedFile(url: url, modified: Self.modified(url), waiting: false))
                }
            }
            self.process(files: files, waiting: waiting, sources: sources, locks: locks)
        }
    }

    struct ListedFile {
        let url: URL
        let modified: Date
        let waiting: Bool
    }

    /// Dateien einlesen (aus dem Zwischenspeicher, wenn unverändert) und Liste, Suche und Baum setzen.
    /// Gesperrte Journale beim Einlesen: alle (für das Schloss links) und die gerade verborgenen.
    struct LockSnapshot {
        let all: [URL]
        let hidden: [URL]
        /// Verschlüsselte Journale: Klartext darin wird verschlüsselt.
        let encrypted: [URL]
        /// Gesperrtes ist gerade offen (sonst bleiben auch einzeln verschlüsselte Einträge verborgen).
        let unlocked: Bool
    }

    private func process(files: [ListedFile], waiting: Int, sources: [URL], locks: LockSnapshot) {
        let cache = Self.loadCache()
        var newCache: [String: CachedEntry] = [:]
        var found: [Entry] = []
        var text: [URL: String] = [:]
        var index: [String: URL] = [:]
        var linkIndex: [URL: [String]] = [:]
        /// Verschlüsselte Einträge ohne Schlüssel: nur zum Zählen im Journal-Baum, nicht in der Liste.
        var placeholders: [Entry] = []
        /// Verschlüsselte Einträge (bleiben verborgen, solange gesperrt ist).
        var secrets: Set<URL> = []
        let started = Date()
        let ready = files.filter { !$0.waiting }
        for (n, file) in ready.enumerated() {
            let url = file.url
            let item: CachedEntry
            var secret = false
            if let cached = cache[url.path], cached.modified == file.modified {
                item = cached
                // Klartext in einem verschlüsselten Journal (z. B. hineinkopiert): jetzt verschlüsseln.
                if Vault.shared.hasKey, locks.encrypted.contains(where: { Self.isInside(url, $0) }) {
                    try? Vault.shared.transformInPlace(url, encrypt: true)
                    secret = true
                }
            } else if Self.isRich(url) {
                secret = Vault.isEncrypted(url)
                if !Self.normalizeEncryption(url, encrypted: &secret, roots: locks.encrypted) { placeholders.append(Self.placeholder(url)); continue }
                guard let doc = Self.readRich(url) else { continue }
                let raw = doc.text.string
                let entry = Self.parseRich(raw, url: url, title: doc.title, keywords: doc.keywords)
                item = CachedEntry(modified: file.modified, title: entry.title, date: entry.date, preview: entry.preview,
                                   search: (entry.title + "\n" + entry.tags.joined(separator: " ") + "\n" + raw).lowercased(),
                                   ids: doc.ids, flagged: entry.flagged, tags: entry.tags, meta: entry.meta,
                                   links: Self.links(in: doc.text))
            } else {
                secret = Vault.isEncrypted(url)
                if !Self.normalizeEncryption(url, encrypted: &secret, roots: locks.encrypted) { placeholders.append(Self.placeholder(url)); continue }
                guard let raw = Self.readText(url) else { continue }
                let entry = Self.parse(raw, url: url)
                item = CachedEntry(modified: file.modified, title: entry.title, date: entry.date, preview: entry.preview,
                                   search: (entry.title + "\n" + raw).lowercased(), ids: [], flagged: entry.flagged, tags: entry.tags,
                                   meta: entry.meta, links: Self.links(in: raw))
            }
            // Inhalt verschlüsselter Einträge nie in den Zwischenspeicher (der liegt unverschlüsselt auf dem Gerät).
            if !secret { newCache[url.path] = item } else { secrets.insert(url) }
            found.append(Entry(url: url, title: item.title, date: item.date, preview: item.preview,
                               flagged: item.flagged ?? false, tags: item.tags ?? [], meta: item.meta ?? [:], encrypted: secret))
            text[url] = item.search
            linkIndex[url] = item.links ?? []
            for id in item.ids { index[id.uppercased()] = url }
            if n % 100 == 0, Date().timeIntervalSince(started) > 2 {
                let label = "Lese Einträge … \(n) von \(ready.count)"
                DispatchQueue.main.async { self.progress = label }
            }
        }
        Self.saveCache(newCache)
        print("[JournalIT] eingelesen: \(found.count) Einträge, \(waiting) warten auf iCloud, \(Int(Date().timeIntervalSince(started))) s")
        found.sort { $0.date > $1.date }
        let lockedPaths = Set(locks.all.map(Self.plainPath))
        let encryptedPaths = Set(locks.encrypted.map(Self.plainPath))
        let trees = sources.compactMap { Self.tree(for: $0, entries: found + placeholders, locked: lockedPaths, encrypted: encryptedPaths) }
        // Einträge in gesperrten Journalen erscheinen nirgends (Liste, Suche, Schlagwörter), bis entsperrt ist.
        if !locks.hidden.isEmpty {
            found.removeAll { entry in locks.hidden.contains { Self.isInside(entry.url, $0) } }
        }
        if !locks.unlocked { found.removeAll { secrets.contains($0.url) } }
        let secretCount = secrets.count + placeholders.count
        DispatchQueue.main.async {
            self.entries = found
            self.encryptedEntryCount = secretCount
            self.searchText = text
            self.linksFrom = linkIndex
            self.macJournalIndex = index
            self.trees = trees
            self.isLoading = false
            self.progress = nil
            self.downloading = waiting
            self.reloading = false
            if self.reloadAgain {
                self.reloadAgain = false
                self.reload()
            } else if waiting > 0 {
                // iCloud lädt noch: gleich noch einmal nachsehen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.reload() }
            }
        }
    }

    /// Platzhalter für einen verschlüsselten Eintrag, der gerade nicht lesbar ist.
    private static func placeholder(_ url: URL) -> Entry {
        Entry(url: url, title: url.deletingPathExtension().lastPathComponent, date: modified(url), preview: "")
    }

    static let textTypes = ["md", "txt", "markdown"]
    static let richTypes = ["rtf", "rtfd"]

    /// Einträge mit Formatierung (RTF, RTFD mit Bildern) statt Markdown.
    static func isRich(_ url: URL) -> Bool {
        richTypes.contains(url.pathExtension.lowercased())
    }

    /// Einträge in einem Ordner. Noch nicht geladene iCloud-Dateien („.Name.rtf.icloud“) werden angestoßen und gezählt.
    private static func files(in folder: URL) -> (urls: [URL], waiting: Int) {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsPackageDescendants]) else { return ([], 0) }
        var found: [URL] = []
        var waiting = 0
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                if name.hasSuffix(".icloud") {
                    let real = url.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(7)))
                    if textTypes.contains(real.pathExtension.lowercased()) || richTypes.contains(real.pathExtension.lowercased()) {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: real)
                        waiting += 1
                    }
                }
                // Nur versteckte Ordner überspringen; bei einer Datei würde skipDescendants den Rest des Ordners auslassen.
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { walker.skipDescendants() }
                continue
            }
            let ext = url.pathExtension.lowercased()
            if ext == "rtfd" { walker.skipDescendants() }  // .rtfd ist ein Ordner: als ein Eintrag zählen
            if textTypes.contains(ext) || richTypes.contains(ext) { found.append(url) }
        }
        return (found, waiting)
    }

    /// Ordnerbaum einer Quelle — nur Ordner, in denen (auch tiefer) Einträge liegen. Nur aus den Pfaden der Einträge
    /// gebaut, in einem Durchgang (auf dem iPhone ist Ordner-Lesen im iCloud-Ordner langsam).
    private static func tree(for folder: URL, entries: [Entry], locked: Set<String> = [], encrypted: Set<String> = []) -> FolderNode? {
        final class Node {
            var count = 0
            var children: [String: Node] = [:]
        }
        let root = plainPath(folder)
        let top = Node()
        for entry in entries {
            let path = plainPath(entry.url)
            guard path.hasPrefix(root + "/") else { continue }
            let parts = path.dropFirst(root.count + 1).split(separator: "/").dropLast()  // ohne Dateinamen
            top.count += 1
            var node = top
            for part in parts {
                let key = String(part)
                let next = node.children[key] ?? Node()
                node.children[key] = next
                next.count += 1
                node = next
            }
        }
        guard top.count > 0 else { return nil }
        func build(_ node: Node, url: URL, name: String) -> FolderNode {
            let children = node.children.keys
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { build(node.children[$0]!, url: url.appendingPathComponent($0, isDirectory: true), name: $0) }
            return FolderNode(url: url, name: name, count: node.count, children: children.isEmpty ? nil : children,
                              locked: locked.contains(plainPath(url)), encrypted: encrypted.contains(plainPath(url)))
        }
        return build(top, url: folder, name: folder.lastPathComponent)
    }

    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        plainPath(url).hasPrefix(plainPath(folder) + "/")
    }

    /// Pfad ohne „/private“ vorne (iOS meldet iCloud-Dateien mal mit, mal ohne).
    static func plainPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    // MARK: - Datei auswerten

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Datum mit Uhrzeit im Kopf: `datum: 2026-10-19 14:30`.
    static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// Datum: `datum:` im Kopf → Datum am Anfang des Dateinamens → Änderungsdatum der Datei.
    /// Titel: erste Überschrift `# …` → Dateiname ohne Datum.
    static func parse(_ raw: String, url: URL) -> Entry {
        var body = Substring(raw)
        var headerDate: Date?
        var flagged = false
        var tags: [String] = []
        var meta: [String: String] = [:]
        if raw.hasPrefix("---\n"), let end = raw.range(of: "\n---", range: raw.index(raw.startIndex, offsetBy: 4)..<raw.endIndex) {
            for line in raw[raw.index(raw.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, ["datum", "date"].contains(parts[0].lowercased()) {
                    headerDate = timeFormat.date(from: String(parts[1].prefix(16))) ?? dayFormat.date(from: String(parts[1].prefix(10)))
                }
                if parts.count == 2, parts[0].lowercased() == flagKey {
                    flagged = ["ja", "true", "yes", "1"].contains(parts[1].lowercased())
                }
                if parts.count == 2, tagKeys.contains(parts[0].lowercased()) {
                    tags = parseTagList(parts[1])
                }
                if parts.count == 2, MetaKey(rawValue: parts[0].lowercased()) != nil, !parts[1].isEmpty {
                    meta[parts[0].lowercased()] = parts[1]
                }
            }
            body = raw[end.upperBound...]
        }

        let name = url.deletingPathExtension().lastPathComponent
        let nameDate = name.count >= 10 ? dayFormat.date(from: String(name.prefix(10))) : nil
        let fileDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast

        let lines = body.split(separator: "\n", omittingEmptySubsequences: true)
        let heading = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        var fallback = nameDate != nil ? String(name.dropFirst(10)) : name
        fallback = fallback.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))

        let preview = lines
            .filter { !$0.hasPrefix("#") && !$0.hasPrefix("---") && !$0.hasPrefix("![") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(3)
            .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "*", with: "") }
            .joined(separator: " ")

        return Entry(url: url,
                     title: heading ?? (fallback.isEmpty ? name : fallback),
                     date: headerDate ?? nameDate ?? fileDate,
                     preview: String(preview.prefix(160)),
                     flagged: flagged,
                     tags: tags,
                     meta: meta)
    }

    /// RTF/RTFD-Eintrag: Titel aus dem RTF-Kopf → Dateiname ohne Datum → erste Zeile.
    /// Datum = Datum im Dateinamen → Änderungsdatum.
    static func parseRich(_ plain: String, url: URL, title stored: String?, keywords: [String] = []) -> Entry {
        let name = url.deletingPathExtension().lastPathComponent
        let nameDate = name.count >= 10 ? dayFormat.date(from: String(name.prefix(10))) : nil
        let fileDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let lines = plain.replacingOccurrences(of: "\u{FFFC}", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var fallback = nameDate != nil ? String(name.dropFirst(10)) : name
        fallback = fallback.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        let title = stored ?? (fallback.isEmpty ? String((lines.first ?? name).prefix(100)) : fallback)
        let preview = lines.drop { $0 == title }.prefix(3).joined(separator: " ")
        // Uhrzeit: Erstelldatum der Datei, wenn es auf denselben Tag fällt wie das Datum im Namen.
        var date = nameDate ?? fileDate
        if let nameDate, let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
           Calendar.current.isDate(created, inSameDayAs: nameDate) {
            date = created
        }
        return Entry(url: url, title: title, date: date, preview: String(preview.prefix(160)),
                     flagged: keywords.contains(flagKeyword),
                     tags: keywords.filter { $0 != flagKeyword && MetaKey.parse(keyword: $0) == nil },
                     meta: MetaKey.meta(fromKeywords: keywords))
    }

    /// Früher standen Titel und Nummer als Dateimerkmal (xattr) an der Datei. Nur noch als Rückfall gelesen.
    private static func legacyAttribute(_ name: String, of url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let length = getxattr(path, name, nil, 0, 0, 0)
            guard length > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: length)
            guard getxattr(path, name, &buffer, length, 0, 0) == length else { return nil }
            let value = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    /// RTF-Kopf {\title …} und {\doccomm …}. Auf dem iPhone gibt es dafür keine benannten Schlüssel, darum die Rohwerte.
    private static let titleKey = NSAttributedString.DocumentAttributeKey(rawValue: "NSTitleDocumentAttribute")
    private static let commentKey = NSAttributedString.DocumentAttributeKey(rawValue: "NSCommentDocumentAttribute")
    static let keywordsKey = NSAttributedString.DocumentAttributeKey(rawValue: "NSKeywordsDocumentAttribute")
    /// Markierung: Stichwort im RTF-Kopf bzw. Schlüssel im Markdown-Kopf.
    static let flagKeyword = "markiert"
    static let flagKey = "markiert"
    /// Kopf-Schlüssel für Schlagwörter; geschrieben wird `tags` (versteht auch Obsidian).
    static let tagKeys = ["tags", "schlagwörter", "stichwörter"]

    /// „[A, B]“, „A, B“ oder „"A", 'B'“ → ["A", "B"].
    static func parseTagList(_ value: String) -> [String] {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'#")) }
            .filter { !$0.isEmpty }
    }

    /// Schlagwort säubern: ohne Komma, ohne Klammern, ohne Leerraum außen.
    static func cleanTag(_ tag: String) -> String {
        tag.replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]\"'#").union(.whitespacesAndNewlines))
    }

    /// RTF/RTFD lesen, mit Titel und MacJournal-Nummern aus dem Kopf.
    static func readRich(_ url: URL) -> RichDocument? {
        if Vault.isEncrypted(url) {
            return try? Vault.shared.withPlainCopy(of: url) { plain in readPlainRich(plain, original: url) }
        }
        return readPlainRich(url, original: url)
    }

    private static func readPlainRich(_ url: URL, original: URL) -> RichDocument? {
        var attributes: NSDictionary?
        // Listenzeichen („•“, „–“) als Text behalten, wie TextEdit. Sonst fehlen sie in der Anzeige.
        guard let text = try? NSAttributedString(url: url, options: [.textKit1ListMarkerFormatDocumentOption: true],
                                                 documentAttributes: &attributes) else { return nil }
        var title = (attributes?[Self.titleKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title?.isEmpty ?? true { title = legacyAttribute("eu.gutzmannit.journalit.title", of: original) }
        var ids: [String] = []
        if let comment = attributes?[Self.commentKey] as? String, comment.hasPrefix("macjournal:") {
            ids = comment.dropFirst("macjournal:".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else if let legacy = legacyAttribute("eu.gutzmannit.journalit.id", of: original) {
            ids = legacy.split(separator: ",").map(String.init)
        }
        let keywords = (attributes?[Self.keywordsKey] as? [String]) ?? []
        return RichDocument(text: text, title: title, ids: ids, keywords: keywords)
    }

    /// Text eines Eintrags (kleingeschrieben, aus dem Suchindex; mit Titel).
    func indexedText(_ url: URL) -> String? { searchText[url] }

    /// Eintrag zu einer MacJournal-Nummer (für Links macjournal://…).
    func url(forMacJournalID id: String) -> URL? {
        macJournalIndex[id.uppercased()]
    }

    /// MacJournal-Nummern eines Eintrags (für „Link zum Eintrag kopieren“).
    func macJournalIDs(of url: URL) -> [String] {
        macJournalIndex.filter { $0.value == url }.map(\.key)
    }

    /// Journal-Pfad eines Eintrags ab der Quelle, z. B. „MacJournal-Export › Schlaraffia › Kantzlerambt“.
    func location(of url: URL) -> String {
        let folder = url.deletingLastPathComponent().standardizedFileURL
        guard let root = sources.first(where: { Self.isInside(url, $0) })?.standardizedFileURL else { return folder.lastPathComponent }
        let rest = folder.path.dropFirst(root.path.count).split(separator: "/").map(String.init)
        return ([root.lastPathComponent] + rest).joined(separator: " › ")
    }

    // MARK: - Abfragen

    func entries(in folder: URL?, matching query: String) -> [Entry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return entries.filter { entry in
            (folder == nil || Self.isInside(entry.url, folder!))
                && (words.isEmpty || words.allSatisfy { searchText[entry.url]?.contains($0) == true })
        }
    }

    // MARK: - Lesen und Schreiben

    func read(_ url: URL) -> String {
        if Self.isRich(url) { return Self.readRich(url)?.text.string ?? "" }
        return Self.readText(url) ?? ""
    }

    /// Markdown/Text lesen, verschlüsselt oder nicht.
    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard Vault.isEncrypted(data) else { return String(data: data, encoding: .utf8) }
        return (try? Vault.shared.decrypt(data)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Muss diese Datei verschlüsselt geschrieben werden? (Liegt im verschlüsselten Journal oder ist es schon.)
    func mustEncrypt(_ url: URL) -> Bool {
        encryptedURLs.contains { Self.isInside(url, $0) } || Vault.isEncrypted(url)
    }

    /// Markdown/Text schreiben; im verschlüsselten Journal verschlüsselt.
    func writeText(_ text: String, to url: URL) throws {
        if mustEncrypt(url) {
            try Vault.shared.writeEncrypted(Data(text.utf8), to: url)
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// RTF oder RTFD speichern (RTFD behält Bilder). Titel und MacJournal-Nummern bleiben im Kopf erhalten,
    /// wenn nichts anderes angegeben ist.
    func saveRich(_ text: NSAttributedString, to url: URL, title newTitle: String?? = nil, ids newIDs: [String]? = nil,
                  keywords newKeywords: [String]? = nil) throws {
        lastOwnWrite = Date()
        keepVersion(of: url)
        let old = FileManager.default.fileExists(atPath: url.path) ? Self.readRich(url) : nil
        let title = newTitle ?? old?.title
        let ids = newIDs ?? old?.ids ?? []
        let keywords = newKeywords ?? old?.keywords ?? []
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [:]
        if let title { attributes[Self.titleKey] = title }
        if !ids.isEmpty { attributes[Self.commentKey] = "macjournal:" + ids.joined(separator: ",") }
        if !keywords.isEmpty { attributes[Self.keywordsKey] = keywords }
        let range = NSRange(location: 0, length: text.length)
        let secret = mustEncrypt(url)
        if secret && !Vault.shared.hasKey { throw Vault.VaultError.locked }
        if url.pathExtension.lowercased() == "rtfd" {
            attributes[.documentType] = NSAttributedString.DocumentType.rtfd
            let wrapper = try text.fileWrapper(from: range, documentAttributes: attributes)
            if secret {
                // Erst im Zwischenordner schreiben, dann verschlüsselt an den Platz (nie Klartext im iCloud-Ordner).
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temp) }
                let plain = temp.appendingPathComponent(url.lastPathComponent)
                try wrapper.write(to: plain, options: [], originalContentsURL: nil)
                try Vault.shared.writeEncrypted(from: plain, to: url)
            } else {
                try wrapper.write(to: url, options: [.atomic], originalContentsURL: nil)
            }
        } else {
            attributes[.documentType] = NSAttributedString.DocumentType.rtf
            let data = try text.data(from: range, documentAttributes: attributes)
            if secret { try Vault.shared.writeEncrypted(data, to: url) } else { try data.write(to: url, options: .atomic) }
        }
        var entry = Self.parseRich(text.string, url: url, title: title, keywords: keywords)
        entry.encrypted = secret
        searchText[url] = (entry.title + "\n" + text.string).lowercased()
        if let i = entries.firstIndex(where: { $0.url == url }) {
            entries[i] = entry
        }
    }

    /// Nur Titel und/oder Nummern im RTF-Kopf ändern.
    func rewriteRichInfo(_ url: URL, title: String?? = nil, ids: [String]? = nil, keywords: [String]? = nil) throws {
        guard let doc = Self.readRich(url) else { return }
        try saveRich(doc.text, to: url, title: title, ids: ids, keywords: keywords)
    }

    /// Eintrag markieren (Fahne) oder die Markierung entfernen.
    func setFlag(_ url: URL, _ flagged: Bool) throws {
        lastOwnWrite = Date()
        if Self.isRich(url) {
            var keywords = Self.readRich(url)?.keywords ?? []
            keywords.removeAll { $0 == Self.flagKeyword }
            if flagged { keywords.append(Self.flagKeyword) }
            try rewriteRichInfo(url, keywords: keywords)
        } else {
            try save(Self.settingHeader(read(url), Self.flagKey, flagged ? "ja" : nil), to: url)
        }
        externalRevision += 1  // offener Editor liest die Datei neu
    }

    /// Schlagwörter eines Eintrags setzen (leer = entfernen).
    func setTags(_ url: URL, _ tags: [String]) throws {
        var clean: [String] = []
        for tag in tags.map(Self.cleanTag) where !tag.isEmpty && tag != Self.flagKeyword {
            if !clean.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { clean.append(tag) }
        }
        lastOwnWrite = Date()
        if Self.isRich(url) {
            let old = Self.readRich(url)?.keywords ?? []
            let kept = old.filter { $0 == Self.flagKeyword || MetaKey.parse(keyword: $0) != nil }
            try rewriteRichInfo(url, keywords: clean + kept)
        } else {
            var raw = read(url)
            for key in Self.tagKeys where key != "tags" { raw = Self.settingHeader(raw, key, nil) }
            try save(Self.settingHeader(raw, "tags", clean.isEmpty ? nil : "[" + clean.joined(separator: ", ") + "]"), to: url)
        }
        externalRevision += 1
    }

    /// Alle Schlagwörter mit Anzahl der Einträge, alphabetisch.
    var allTags: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in entries { for tag in entry.tags { counts[tag, default: 0] += 1 } }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ text: String, to url: URL) throws {
        lastOwnWrite = Date()
        if mustEncrypt(url) && !Vault.shared.hasKey { throw Vault.VaultError.locked }
        keepVersion(of: url)
        try writeText(text, to: url)
        var entry = Self.parse(text, url: url)
        entry.encrypted = mustEncrypt(url)
        searchText[url] = (entry.title + "\n" + text).lowercased()
        if let i = entries.firstIndex(where: { $0.url == url }) {
            entries[i] = entry
        }
    }

    /// Neuen Eintrag mit heutigem Datum im Ordner anlegen.
    func newEntry(in folder: URL) throws -> URL {
        let folder = Self.folderForNew(folder)
        let today = Self.dayFormat.string(from: Date())
        if newEntriesRich(in: folder) {
            let url = Self.freeName("\(today) Neuer Eintrag.rtf", in: folder)
            lastOwnWrite = Date()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try saveRich(NSAttributedString(string: "\n", attributes: Self.richTypingAttributes), to: url, title: "Neuer Eintrag")
            reload()
            justCreated = url
            return url
        }
        var url = folder.appendingPathComponent("\(today) Neuer Eintrag.md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(today) Neuer Eintrag (\(n)).md")
            n += 1
        }
        let text = "---\ndatum: \(today)\n---\n\n# Neuer Eintrag\n\n"
        lastOwnWrite = Date()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeText(text, to: url)
        let entry = Self.parse(text, url: url)
        entries.insert(entry, at: 0)
        searchText[url] = text.lowercased()
        trees = sources.compactMap { Self.tree(for: $0, entries: entries, locked: Set(lockedURLs.map(Self.plainPath)),
                                                encrypted: Set(encryptedURLs.map(Self.plainPath))) }
        justCreated = url
        return url
    }

    /// Schrift für neuen Rich Text: wie MacJournal (Helvetica 12). iOS rechnet RTF-Größen um 4/3 um, darum dort 16.
    #if os(macOS)
    static let richBaseSize: CGFloat = 12
    #else
    static let richBaseSize: CGFloat = 16
    #endif
    static let richTypingAttributes: [NSAttributedString.Key: Any] = [
        .font: PlatformFont(name: "Helvetica", size: richBaseSize) ?? PlatformFont.systemFont(ofSize: richBaseSize),
        .foregroundColor: PlatformColor.black,
    ]

    /// Neue Einträge als Rich Text (Einstellung, Vorgabe: ja). Das tägliche Journal bleibt Markdown,
    /// weil Claude es als Markdown liest und schreibt.
    func newEntriesRich(in folder: URL) -> Bool {
        if let journal = iCloudDocuments?.appendingPathComponent(Self.dailyJournal),
           Self.plainPath(folder) == Self.plainPath(journal) || Self.isInside(folder, journal) { return false }
        return UserDefaults.standard.object(forKey: "newEntriesRich") as? Bool ?? true
    }

    /// Schrift mit fett/kursiv, auf Mac und iPhone.
    static func font(_ base: PlatformFont, bold: Bool, italic: Bool) -> PlatformFont {
        #if os(macOS)
        var font = base
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
        #else
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        return base.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: base.pointSize) } ?? base
        #endif
    }

    /// Markdown-Eintrag in Rich Text umwandeln (fett, kursiv, Code bleiben). Die .md kommt in den Papierkorb.
    func convertToRich(_ url: URL) throws -> URL {
        let raw = read(url)
        let entry = Self.parse(raw, url: url)
        var lines = raw.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...end) }
        if let i = lines.firstIndex(where: { $0.hasPrefix("# ") }) { lines.remove(at: i) }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        let result = NSMutableAttributedString()
        let base = Self.richTypingAttributes[.font] as! PlatformFont
        let mono = PlatformFont.monospacedSystemFont(ofSize: Self.richBaseSize, weight: .regular)
        for (n, line) in body.components(separatedBy: "\n").enumerated() {
            if n > 0 { result.append(NSAttributedString(string: "\n", attributes: Self.richTypingAttributes)) }
            let parsed = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(line)
            for run in parsed.runs {
                let intent = run.inlinePresentationIntent ?? []
                var attributes = Self.richTypingAttributes
                attributes[.font] = Self.font(intent.contains(.code) ? mono : base,
                                              bold: intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized))
                if let link = run.link { attributes[.link] = link }
                result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
        }
        if result.length == 0 { result.append(NSAttributedString(string: "\n", attributes: Self.richTypingAttributes)) }

        let name = url.deletingPathExtension().lastPathComponent
        let day = Self.dayFormat.string(from: entry.date)
        let file = (name.count >= 10 && Self.dayFormat.date(from: String(name.prefix(10))) != nil ? name : day + " " + name) + ".rtf"
        let target = Self.freeName(file, in: url.deletingLastPathComponent())
        lastOwnWrite = Date()
        try saveRich(result, to: target, title: entry.title)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload()
        return target
    }

    /// In den Papierkorb legen (lässt sich wiederherstellen).
    func trash(_ url: URL) throws {
        lastOwnWrite = Date()
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload()
    }

    /// Eintrag oder Ordner in einen anderen Ordner verschieben; gibt den neuen Ort zurück.
    func move(_ url: URL, to folder: URL) throws -> URL {
        let target = Self.freeName(url.lastPathComponent, in: folder)
        lastOwnWrite = Date()
        try FileManager.default.moveItem(at: url, to: target)
        reload()
        return target
    }

    /// Kopie eines Eintrags im selben Journal („… Kopie“); der Titel bekommt „(Kopie)“.
    func duplicate(_ url: URL) throws -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let target = Self.freeName(base + " Kopie." + url.pathExtension, in: url.deletingLastPathComponent())
        lastOwnWrite = Date()
        try FileManager.default.copyItem(at: url, to: target)
        if Self.isRich(target) {
            let doc = Self.readRich(target)
            let title = doc?.title ?? Self.parseRich(doc?.text.string ?? "", url: url, title: nil).title
            try rewriteRichInfo(target, title: title + " (Kopie)", ids: [])  // die MacJournal-Nummer gehört zum Original
        } else {
            let text = read(target)
            if let range = text.range(of: "(?m)^# .*$", options: .regularExpression) {
                try writeText(text.replacingCharacters(in: range, with: String(text[range]) + " (Kopie)"), to: target)
            }
        }
        reload()
        return target
    }

    /// Kopie in ein anderes Journal.
    func copy(_ url: URL, to folder: URL) throws -> URL {
        let target = Self.freeName(url.lastPathComponent, in: folder)
        lastOwnWrite = Date()
        try FileManager.default.copyItem(at: url, to: target)
        if Self.isRich(target) { try rewriteRichInfo(target, ids: []) }
        reload()
        return target
    }

    /// Eintrag umbenennen: Titel (Markdown: Überschrift `# …`, RTF: Kopf) und Dateiname (Datum vorne bleibt).
    func renameEntry(_ url: URL, to title: String) throws -> URL {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return url }
        let name = url.deletingPathExtension().lastPathComponent
        let date = name.count >= 10 && Self.dayFormat.date(from: String(name.prefix(10))) != nil ? String(name.prefix(10)) + " " : ""
        if Self.isRich(url) {
            let file = date + Self.safeName(title) + "." + url.pathExtension
            let target = file == url.lastPathComponent ? url : Self.freeName(file, in: url.deletingLastPathComponent())
            lastOwnWrite = Date()
            try rewriteRichInfo(url, title: title)
            if target != url { try FileManager.default.moveItem(at: url, to: target) }
            reload()
            return target
        }
        var lines = read(url).components(separatedBy: "\n")
        var start = 0
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { start = end + 1 }
        if let i = lines[start...].firstIndex(where: { $0.hasPrefix("# ") }) {
            lines[i] = "# " + title
        } else {
            lines.insert(contentsOf: ["", "# " + title], at: start)
        }
        let file = date + Self.safeName(title) + "." + url.pathExtension
        let folder = url.deletingLastPathComponent()
        let target = file == url.lastPathComponent ? url : Self.freeName(file, in: folder)
        lastOwnWrite = Date()
        try writeText(lines.joined(separator: "\n"), to: url)
        if target != url { try FileManager.default.moveItem(at: url, to: target) }
        reload()
        return target
    }

    /// Ordner umbenennen; gibt den neuen Ort zurück.
    func renameFolder(_ url: URL, to name: String) throws -> URL {
        let name = Self.safeName(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !name.isEmpty, name != url.lastPathComponent else { return url }
        let target = Self.freeName(name, in: url.deletingLastPathComponent())
        lastOwnWrite = Date()
        try FileManager.default.moveItem(at: url, to: target)
        reload()
        return target
    }

    /// Neuen, leeren Ordner anlegen. Er erscheint, sobald ein Eintrag darin liegt.
    func newFolder(named name: String, in parent: URL) throws -> URL {
        let target = Self.freeName(Self.safeName(name.trimmingCharacters(in: .whitespacesAndNewlines)), in: parent)
        lastOwnWrite = Date()
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    // MARK: - Intelligente Journale

    private var smartJournalsFile: URL? { iCloudDocuments?.appendingPathComponent("Intelligente Journale.json") }

    private func loadSmartJournals() {
        guard let file = smartJournalsFile else { return }
        if !FileManager.default.fileExists(atPath: file.path) {
            // Noch nicht von iCloud geladen? Dann anstoßen; beim nächsten Einlesen ist sie da.
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            return
        }
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([SmartJournal].self, from: data), list != smartJournals else { return }
        smartJournals = list
    }

    private func writeSmartJournals() throws {
        guard let file = smartJournalsFile else { throw CocoaError(.fileNoSuchFile) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        lastOwnWrite = Date()
        try encoder.encode(smartJournals).write(to: file, options: .atomic)
    }

    func saveSmartJournal(_ journal: SmartJournal) throws {
        if let i = smartJournals.firstIndex(where: { $0.id == journal.id }) {
            smartJournals[i] = journal
        } else {
            smartJournals.append(journal)
        }
        try writeSmartJournals()
    }

    func deleteSmartJournal(_ id: UUID) throws {
        smartJournals.removeAll { $0.id == id }
        try writeSmartJournals()
    }

    /// Einträge, die zu den Regeln passen (über alle Journale).
    func entries(for smart: SmartJournal) -> [Entry] {
        var list = entries(in: nil, matching: smart.text)
        if smart.flaggedOnly { list = list.filter(\.flagged) }
        if !smart.tags.isEmpty {
            list = list.filter { entry in
                smart.anyTag ? smart.tags.contains { entry.tags.contains($0) } : smart.tags.allSatisfy { entry.tags.contains($0) }
            }
        }
        if smart.minRating > 0 { list = list.filter { $0.rating >= smart.minRating } }
        if !smart.label.isEmpty { list = list.filter { $0.meta[MetaKey.etikett.rawValue] == smart.label } }
        if !smart.status.isEmpty { list = list.filter { $0.meta[MetaKey.status.rawValue] == smart.status } }
        if smart.days > 0, let from = Calendar.current.date(byAdding: .day, value: -smart.days, to: Calendar.current.startOfDay(for: Date())) {
            list = list.filter { $0.date >= from }
        }
        return list
    }

    // MARK: - Vorlagen

    /// Ordner mit Vorlagen (iCloud „Vorlagen“). Jede .md-, .rtf- oder .rtfd-Datei darin ist eine Vorlage.
    var templatesFolder: URL? { iCloudDocuments?.appendingPathComponent("Vorlagen") }

    /// Vorlagen-Liste für die Menüs neu lesen.
    func refreshTemplates() {
        let list = templates()
        if list != templateList { templateList = list }
    }

    /// Vorlagen, alphabetisch. Noch nicht geladene iCloud-Dateien werden zum Laden angestoßen.
    func templates() -> [URL] {
        guard let folder = templatesFolder,
              let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var result: [URL] = []
        for url in items {
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            } else if ["md", "txt", "rtf", "rtfd"].contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Platzhalter in Vorlagen.
    static func placeholders(_ date: Date) -> [(String, String)] {
        [("{{datum}}", dayFormat.string(from: date)),
         ("{{tag}}", longDayFormat.string(from: date)),
         ("{{uhrzeit}}", String(timeFormat.string(from: date).suffix(5)))]
    }

    /// Neuer Eintrag aus einer Vorlage: Dateiname „JJJJ-MM-TT <Vorlage>“, Platzhalter ersetzt,
    /// Datum im Kopf auf heute, ohne Fahne.
    func newEntry(from template: URL, in folder: URL) throws -> URL {
        let folder = Self.folderForNew(folder)
        let now = Date()
        let day = Self.dayFormat.string(from: now)
        let name = template.deletingPathExtension().lastPathComponent
        let target = Self.freeName("\(day) \(name).\(template.pathExtension)", in: folder)
        lastOwnWrite = now
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if Self.isRich(template) {
            guard let doc = Self.readRich(template) else { throw CocoaError(.fileReadCorruptFile) }
            let text = NSMutableAttributedString(attributedString: doc.text)
            for (key, value) in Self.placeholders(now) {
                text.mutableString.replaceOccurrences(of: key, with: value, options: [], range: NSRange(location: 0, length: text.length))
            }
            try saveRich(text, to: target, title: .some(doc.title ?? name), ids: [],
                         keywords: doc.keywords.filter { $0 != Self.flagKeyword })
        } else {
            var text = read(template)
            for (key, value) in Self.placeholders(now) { text = text.replacingOccurrences(of: key, with: value) }
            if text.hasPrefix("---\n") {
                text = Self.settingHeader(Self.settingHeader(text, Self.flagKey, nil), "datum", day)
            }
            try writeText(text, to: target)
        }
        reload()
        justCreated = target
        return target
    }

    /// Eintrag als Vorlage sichern: Kopie im Vorlagen-Ordner, benannt nach dem Titel.
    func saveAsTemplate(_ url: URL) throws -> URL {
        guard let folder = try ensureTemplatesFolder() else { throw CocoaError(.fileNoSuchFile) }
        let title = entries.first { $0.url == url }?.title ?? url.deletingPathExtension().lastPathComponent
        let target = Self.freeName(Self.safeName(title) + "." + url.pathExtension, in: folder)
        try FileManager.default.copyItem(at: url, to: target)
        if Self.isRich(target) { try rewriteRichInfo(target, ids: []) }  // MacJournal-Nummer gehört zum Original
        refreshTemplates()
        return target
    }

    /// Vorlagen-Ordner anlegen; ist er leer, kommt eine Beispiel-Vorlage hinein.
    @discardableResult
    func ensureTemplatesFolder() throws -> URL? {
        guard let folder = templatesFolder else { return nil }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if templates().isEmpty {
            let example = """
            ---
            datum: {{datum}}
            ---

            # Besprechung

            Am {{tag}} um {{uhrzeit}} Uhr.

            ## Teilnehmer

            -

            ## Themen

            -

            ## Ergebnis

            """
            try example.write(to: folder.appendingPathComponent("Besprechung.md"), atomically: true, encoding: .utf8)
            refreshTemplates()
        }
        return folder
    }

    // MARK: - Tagesjournal und Datum

    /// Ordner des täglichen Journals (iCloud „Journal“).
    var dailyJournalFolder: URL? {
        if let docs = iCloudDocuments { return docs.appendingPathComponent(Self.dailyJournal) }
        return sources.first { $0.lastPathComponent == Self.dailyJournal }
    }

    /// Tageseintrag, wie Claude ihn schreibt: Journal/JJJJ/MM/TT/JJJJ-MM-TT.md.
    func dailyEntryURL(for date: Date) -> URL? {
        guard let folder = dailyJournalFolder else { return nil }
        let day = Self.dayFormat.string(from: date)
        return Self.dayFolder(day, in: folder).appendingPathComponent(day + ".md")
    }

    /// Eintrag zu einem Tag: der Tageseintrag, sonst der früheste Eintrag dieses Tages (nur im Journal `folder`, wenn angegeben).
    func entry(on date: Date, in folder: URL?) -> URL? {
        if let daily = dailyEntryURL(for: date), FileManager.default.fileExists(atPath: daily.path),
           folder == nil || Self.isInside(daily, folder!) { return daily }
        return entries.last { (folder == nil || Self.isInside($0.url, folder!)) && Calendar.current.isDate($0.date, inSameDayAs: date) }?.url
    }

    static let longDayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE, d. MMMM yyyy"
        return f
    }()

    /// Tageseintrag holen; fehlt er, wird er angelegt (Markdown mit Überschrift, wie Claude ihn schreibt).
    func dailyEntry(for date: Date) throws -> URL {
        guard let url = dailyEntryURL(for: date) else { throw CocoaError(.fileNoSuchFile) }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let text = "# Journal — \(Self.longDayFormat.string(from: date))\n\n"
        lastOwnWrite = Date()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeText(text, to: url)
        let entry = Self.parse(text, url: url)
        entries.insert(entry, at: entries.firstIndex { $0.date < entry.date } ?? entries.count)
        searchText[url] = text.lowercased()
        trees = sources.compactMap { Self.tree(for: $0, entries: entries, locked: Set(lockedURLs.map(Self.plainPath)),
                                                encrypted: Set(encryptedURLs.map(Self.plainPath))) }
        justCreated = url
        return url
    }

    /// Schnellnotiz ins heutige Journal (eigene Datei im Tagesordner).
    func quickNote(_ text: String) throws -> URL {
        guard let journal = dailyJournalFolder else { throw CocoaError(.fileNoSuchFile) }
        lastOwnWrite = Date()
        let url = try QuickNoteFile.write(text, in: journal)
        reload()
        return url
    }

    /// Datum (und Uhrzeit) eines Eintrags ändern. Das Datum vorne im Dateinamen wird angepasst.
    /// Liegt der Eintrag in einem Tagesordner (…/JJJJ/MM/TT/), wandert er in den Ordner des neuen Tages.
    /// Uhrzeit: Markdown im Kopf (`datum: JJJJ-MM-TT HH:mm`), Rich Text als Erstelldatum der Datei.
    /// Gibt den neuen Ort zurück.
    func changeDate(_ url: URL, to date: Date) throws -> URL {
        let day = Self.dayFormat.string(from: date)
        let name = url.deletingPathExtension().lastPathComponent
        let hasDay = name.count >= 10 && Self.dayFormat.date(from: String(name.prefix(10))) != nil
        lastOwnWrite = Date()
        if Self.isRich(url) {
            // Änderungsdatum neu, damit der Zwischenspeicher die Datei neu liest.
            try FileManager.default.setAttributes([.creationDate: date, .modificationDate: Date()], ofItemAtPath: url.path)
        } else {
            let raw = read(url)
            // Einen Kopf nur, wenn nötig: Tageseinträge von Claude bleiben ohne Kopf, solange die Uhrzeit 0:00 ist.
            let midnight = Calendar.current.startOfDay(for: date) == date
            if raw.hasPrefix("---\n") || !hasDay || !midnight {
                try writeText(Self.settingHeader(raw, "datum", midnight && hasDay ? day : Self.timeFormat.string(from: date)),
                              to: url)
            }
        }
        var file = url.lastPathComponent
        if hasDay {
            file = day + String(file.dropFirst(10))
        } else if Self.isRich(url) {
            file = day + " " + file  // Rich Text hat sein Datum nur im Namen
        }
        let oldFolder = url.deletingLastPathComponent()
        var folder = oldFolder
        let base = Self.dayFolderBase(oldFolder)
        if let base {
            folder = Self.dayFolder(day, in: base)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var target = url
        if file != url.lastPathComponent || folder.standardizedFileURL != oldFolder.standardizedFileURL {
            target = Self.freeName(file, in: folder)
            try FileManager.default.moveItem(at: url, to: target)
            if base != nil { Self.removeEmptyDayFolders(oldFolder) }
        }
        reload()
        return target
    }

    /// Eintrag im Kopf (--- … ---) setzen, ändern oder (value nil) entfernen; ohne Kopf wird einer angelegt.
    /// „datum“ ersetzt auch ein englisches „date“.
    static func settingHeader(_ raw: String, _ key: String, _ value: String?) -> String {
        var lines = raw.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            guard let value else { return raw }
            return "---\n\(key): \(value)\n---\n\n" + raw
        }
        let names = key == "datum" ? ["datum", "date"] : [key]
        let matches: (String) -> Bool = { line in
            names.contains(line.split(separator: ":").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "")
        }
        if let i = lines[1..<end].firstIndex(where: matches) {
            if let value { lines[i] = "\(key): \(value)" } else { lines.remove(at: i) }
        } else if let value {
            lines.insert("\(key): \(value)", at: 1)
        }
        // Leerer Kopf bleibt nicht stehen.
        if lines.count >= 2, lines[0] == "---", lines[1] == "---" {
            lines.removeFirst(2)
            if lines.first == "" { lines.removeFirst() }
        }
        return lines.joined(separator: "\n")
    }

    /// Ordner JJJJ/MM/TT für einen Tag („2026-10-19“).
    private static func dayFolder(_ day: String, in base: URL) -> URL {
        let parts = day.split(separator: "-").map(String.init)
        return base.appendingPathComponent(parts[0]).appendingPathComponent(parts[1]).appendingPathComponent(parts[2])
    }

    /// Ziel für einen neuen Eintrag: Ist der Ordner ein Tagesordner (…/JJJJ/MM/TT), dann der Tagesordner von heute.
    static func folderForNew(_ folder: URL) -> URL {
        guard let base = dayFolderBase(folder) else { return folder }
        return dayFolder(dayFormat.string(from: Date()), in: base)
    }

    /// Bei einem Tagesordner …/JJJJ/MM/TT der Ordner darüber, sonst nil.
    private static func dayFolderBase(_ folder: URL) -> URL? {
        let parts = folder.standardizedFileURL.pathComponents
        guard parts.count > 4 else { return nil }
        let (y, m, d) = (parts[parts.count - 3], parts[parts.count - 2], parts[parts.count - 1])
        guard y.count == 4, m.count == 2, d.count == 2, Int(y) != nil, Int(m) != nil, Int(d) != nil else { return nil }
        return folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Leere Tages-, Monats- und Jahresordner nach dem Verschieben entfernen.
    private static func removeEmptyDayFolders(_ folder: URL) {
        var current = folder
        for _ in 0..<3 {
            guard let rest = try? FileManager.default.contentsOfDirectory(atPath: current.path),
                  rest.allSatisfy({ $0 == ".DS_Store" }) else { return }
            try? FileManager.default.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }

    static func safeName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// Freier Name im Ordner: „Name“, sonst „Name (2)“ usw.
    static func freeName(_ name: String, in folder: URL) -> URL {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var target = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return target
    }
}

#if os(iOS)
/// iCloud-Abfrage (NSMetadataQuery): alle Dateien im iCloud-Ordner der App mit Änderungsdatum und Ladezustand.
/// Viel schneller als den Ordner selbst zu durchsuchen. Nicht geladene Dateien werden zum Laden angestoßen.
final class ICloudListing: NSObject {
    private static var running: [ICloudListing] = []
    private let query = NSMetadataQuery()
    private let done: ([Library.ListedFile]) -> Void

    private init(done: @escaping ([Library.ListedFile]) -> Void) {
        self.done = done
        super.init()
    }

    static func run(_ done: @escaping ([Library.ListedFile]) -> Void) {
        DispatchQueue.main.async {
            let listing = ICloudListing(done: done)
            running.append(listing)
            listing.start()
        }
    }

    private func start() {
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        NotificationCenter.default.addObserver(self, selector: #selector(finished), name: .NSMetadataQueryDidFinishGathering, object: query)
        query.start()
    }

    @objc private func finished() {
        query.disableUpdates()
        var byURL: [URL: Library.ListedFile] = [:]
        for case let item as NSMetadataItem in query.results {
            guard var url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            // Dateien in einem .rtfd-Paket gehören zum Paket.
            let path = url.path
            if let range = path.range(of: ".rtfd/", options: .caseInsensitive) {
                url = URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".rtfd")
            }
            let ext = url.pathExtension.lowercased()
            guard Library.textTypes.contains(ext) || Library.richTypes.contains(ext) else { continue }
            let modified = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date ?? .distantPast
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let waiting = status != nil && status != NSMetadataUbiquitousItemDownloadingStatusCurrent
            if waiting { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
            let old = byURL[url]
            byURL[url] = Library.ListedFile(url: url, modified: max(old?.modified ?? .distantPast, modified),
                                            waiting: waiting || (old?.waiting ?? false))
        }
        query.stop()
        NotificationCenter.default.removeObserver(self)
        Self.running.removeAll { $0 === self }
        print("[JournalIT] iCloud-Abfrage: \(byURL.count) Einträge")
        done(Array(byURL.values))
    }
}
#endif

