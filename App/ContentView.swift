import SwiftUI

/// Eintrag in der Seitenleiste: alle Einträge, die markierten oder ein Journal (Ordner).
enum SidebarItem: Hashable {
    case all
    case flagged
    case tag(String)
    case smart(UUID)
    case folder(URL)
    /// Einträge, die auf diesen Eintrag verlinken.
    case backlinks(URL)
}

enum SearchScope: Hashable { case all, folder }

/// Eine Datei als Anlass für einen Dialog (z. B. frühere Versionen).
struct URLRequest: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Wofür gerade ein Name abgefragt wird.
struct NameRequest: Identifiable {
    enum Kind { case entry, folder, newFolder }
    let url: URL
    let kind: Kind
    var id: URL { url }

    var title: String {
        switch kind {
        case .entry: "Eintrag umbenennen"
        case .folder: "Journal umbenennen"
        case .newFolder: "Neues Journal"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var library: Library
    @State private var sidebar: SidebarItem? = .all
    /// Gewählte Einträge (mehrere mit ⌘/⇧-Klick, z. B. zum Zusammenführen).
    @State private var selected: Set<URL> = []
    /// Der eine gewählte Eintrag; bei mehreren nil.
    private var selection: URL? {
        get { selected.count == 1 ? selected.first : nil }
        nonmutating set { selected = newValue.map { [$0] } ?? [] }
    }
    private var selectionBinding: Binding<URL?> {
        Binding(get: { selection }, set: { selection = $0 })
    }
    @State private var toMerge: [URL]?
    /// Journal, das verschlüsselt werden soll (Rückfrage vorher).
    @State private var toEncrypt: URL?
    @State private var showRecording = false
    @State private var query = ""
    @State private var message: String?
    @State private var toTrash: URL?
    /// Journal (Ordner), das in den Papierkorb soll.
    @State private var folderToTrash: FolderNode?
    @State private var nameRequest: NameRequest?
    @State private var nameText = ""
    /// Aufgeklappte Journale links.
    @State private var expanded: Set<URL> = []
    @State private var scope = SearchScope.all
    /// Eintrag, zu dem die Liste rollen soll (nur bei Sprüngen über Links, nicht bei eigenen Klicks).
    @State private var scrollTarget: URL?
    @FocusState private var searchFocused: Bool
    /// Datums-Dialog: Gehe zu Datum oder Datum ändern.
    @State private var dateRequest: DateRequest?
    /// Tag ohne Eintrag: Rückfrage, ob der Tageseintrag angelegt werden soll.
    @State private var dayToCreate: Date?
    @AppStorage(EntrySort.key) private var sort = EntrySort.date
    @AppStorage(EntrySort.ascendingKey) private var ascending = false
    @Environment(\.openWindow) private var openWindow
    @AppStorage(ListMode.key) private var listMode = ListMode.list
    /// Kalender-Ansicht: gezeigter Monat und gewählter Tag.
    @State private var calendarMonth = Date()
    @State private var calendarDay: Date?
    @State private var tagRequest: TagRequest?
    @State private var smartRequest: SmartRequest?
    @State private var versionsRequest: URLRequest?
    @State private var showBackups = false
    @State private var infoRequest: InfoRequest?
    @State private var showStatistics = false
    @State private var eventRequest: URLRequest?
    @State private var calendarImportFolder: URLRequest?
    @State private var columns = NavigationSplitViewVisibility.all
    @ObservedObject private var writingTimer = WritingTimer.shared

    var body: some View {
        dialogsB(encryptionDialogs(dialogsA(mainView)).focusedSceneValue(\.journalActions, journalActions))
    }

    private var mainView: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebarList
                .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        } content: {
            entryList
                .navigationSplitViewColumnWidth(min: 260, ideal: 330)
        } detail: {
            if let selection, Library.isRich(selection) {
                RichEditorView(url: selection, highlight: query)
                    .id(selection)
            } else if let selection {
                EditorView(url: selection, highlight: query)
                    .id(selection)
            } else if selected.count > 1 {
                ContentUnavailableView {
                    Label("\(selected.count) Einträge gewählt", systemImage: "doc.on.doc")
                } description: {
                    Text("Zusammenführen macht daraus einen Eintrag (nach Datum). Die einzelnen kommen in den Papierkorb.")
                } actions: {
                    Button("Zusammenführen …") { toMerge = Array(selected) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView("Kein Eintrag gewählt", systemImage: "doc.text",
                                       description: Text("Links ein Journal wählen, in der Mitte einen Eintrag."))
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Suchen")
        // Wie MacJournal: Suche zuerst in allen Journalen, wahlweise nur im gewählten.
        .searchScopes($scope) {
            Text("Alle Journale").tag(SearchScope.all)
            Text(folder?.lastPathComponent ?? "Dieses Journal").tag(SearchScope.folder)
        }
        .toolbar {
            ToolbarItem {
                Button(action: goToToday) {
                    Label("Heute", systemImage: "calendar")
                }
                .help("Zum heutigen Eintrag im Journal (⌃⌘T); fehlt er, wird er angelegt")
            }
            ToolbarItem {
                Menu {
                    SortPicker().pickerStyle(.inline)
                } label: {
                    Label("Sortieren", systemImage: "arrow.up.arrow.down")
                }
                .help("Liste nach Datum oder Titel sortieren")
            }
            ToolbarItem {
                // Klick: leerer Eintrag. Pfeil daneben: aus einer Vorlage.
                Menu {
                    ForEach(library.templateList, id: \.self) { template in
                        Button(template.deletingPathExtension().lastPathComponent) { newEntry(from: template) }
                    }
                    Divider()
                    Button("Vorlagen-Ordner zeigen", action: showTemplates)
                } label: {
                    Label("Neuer Eintrag", systemImage: "square.and.pencil")
                } primaryAction: {
                    newEntry()
                }
                .help("Neuer Eintrag im gewählten Journal; der Pfeil bietet Vorlagen an")
            }
            ToolbarItem {
                Button(action: library.reload) {
                    Label("Neu einlesen", systemImage: "arrow.clockwise")
                }
                .help("Ordner neu einlesen")
            }
            if library.hasLocks {
                ToolbarItem {
                    Button { library.unlocked ? library.lockNow() : library.unlock() } label: {
                        Label(library.unlocked ? "Sperren" : "Entsperren", systemImage: library.unlocked ? "lock.open" : "lock.fill")
                    }
                    .help(library.unlocked ? "Gesperrte Journale wieder sperren (⌃⌘L)" : "Gesperrte Journale zeigen (Passwort oder Touch ID)")
                }
            }
            if let selection {
                ToolbarItem {
                    let flagged = library.entries.first { $0.url == selection }?.flagged ?? false
                    Button { toggleFlag(selection) } label: {
                        Label(flagged ? "Markierung entfernen" : "Markieren", systemImage: flagged ? "flag.fill" : "flag")
                    }
                    .foregroundStyle(flagged ? Color.orange : Color.primary)
                    .help(flagged ? "Markierung entfernen (⇧⌘L)" : "Eintrag markieren (⇧⌘L)")
                }
                ToolbarItem {
                    Button { tagRequest = TagRequest(url: selection) } label: {
                        Label("Schlagwörter", systemImage: "tag")
                    }
                    .help("Schlagwörter des Eintrags (⇧⌘K)")
                }
                ToolbarItem {
                    Button { infoRequest = InfoRequest(url: selection) } label: {
                        Label("Info", systemImage: "info.circle")
                    }
                    .help("Bewertung, Etikett, Stimmung, Status, Ort (⌥⌘I)")
                }
                ToolbarItem {
                    Button { askName(.entry, for: selection) } label: {
                        Label("Umbenennen", systemImage: "pencil.line")
                    }
                    .help("Eintrag umbenennen")
                }
                ToolbarItem {
                    moveMenu(for: selection)
                }
                ToolbarItem {
                    Button { toTrash = selection } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                    .help("Eintrag in den Papierkorb legen")
                }
            }
        }
    }

    /// Verschlüsseln: Rückfrage, Passwort, Hinweise.
    private func encryptionDialogs(_ content: some View) -> some View {
        content
        .confirmationDialog("Journal verschlüsseln?", isPresented: Binding(get: { toEncrypt != nil }, set: { if !$0 { toEncrypt = nil } }),
                            presenting: toEncrypt) { folder in
            Button("Verschlüsseln") {
                toEncrypt = nil
                library.encryptFolder(folder)
            }
            Button("Abbrechen", role: .cancel) { toEncrypt = nil }
        } message: { folder in
            Text("Alle Einträge in „\(folder.lastPathComponent)“ werden verschlüsselt. Nur Journal g-IT kann sie dann lesen – nicht der Finder, nicht Claude. Öffnen mit Touch ID.")
        }
        .sheet(item: $library.passwordRequest) { request in
            PasswordSheet(request: request) { library.passwordRequest = nil }
        }
        .sheet(isPresented: Binding(get: { library.recoveryCode != nil }, set: { if !$0 { library.recoveryCode = nil } })) {
            RecoveryCodeSheet(code: library.recoveryCode ?? "") { library.recoveryCode = nil }
        }
        .alert("Hinweis", isPresented: Binding(get: { library.notice != nil && !(library.notice ?? "").hasSuffix("…") },
                                               set: { if !$0 { library.notice = nil } })) {
            Button("OK") { library.notice = nil }
        } message: { Text(library.notice ?? "") }
    }

    private func dialogsA(_ content: some View) -> some View {
        content
        .confirmationDialog("Eintrag in den Papierkorb legen?", isPresented: .constant(toTrash != nil), presenting: toTrash) { url in
            Button("In den Papierkorb", role: .destructive) { trash(url) }
            Button("Abbrechen", role: .cancel) { toTrash = nil }
        } message: { url in
            Text("„\(url.deletingPathExtension().lastPathComponent)“ – du kannst ihn im Finder aus dem Papierkorb zurücklegen.")
        }
        .confirmationDialog("Journal in den Papierkorb legen?", isPresented: .constant(folderToTrash != nil), presenting: folderToTrash) { node in
            Button("In den Papierkorb", role: .destructive) { trashFolder(node) }
            Button("Abbrechen", role: .cancel) { folderToTrash = nil }
        } message: { node in
            Text("„\(node.name)“ mit \(node.count == 1 ? "1 Eintrag" : "\(node.count) Einträgen") und allen Unter-Journalen – du kannst es im Finder aus dem Papierkorb zurücklegen.")
        }
        .alert(nameRequest?.title ?? "", isPresented: Binding(get: { nameRequest != nil }, set: { if !$0 { nameRequest = nil } }),
               presenting: nameRequest) { request in
            TextField("Name", text: $nameText)
            Button("OK") { applyName(request) }
            Button("Abbrechen", role: .cancel) { nameRequest = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newEntry)) { _ in newEntry() }
        .onAppear {
            QuickNote.shared.setUp(openWindow)
            LockTimer.shared.start(library)
            // Tägliche Sicherung, wenn die App nach dem Start zur Ruhe gekommen ist.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { library.backupIfDue() }
        }
        .sheet(item: $versionsRequest) { request in
            VersionsSheet(url: request.url) { versionsRequest = nil }
                .environmentObject(library)
        }
        .sheet(item: $infoRequest) { request in
            InfoSheet(url: request.url) { infoRequest = nil }
                .environmentObject(library)
        }
        .confirmationDialog("Einträge zusammenführen?", isPresented: Binding(get: { toMerge != nil }, set: { if !$0 { toMerge = nil } }),
                            presenting: toMerge) { urls in
            Button("Zusammenführen") { merge(urls) }
            Button("Abbrechen", role: .cancel) { toMerge = nil }
        } message: { urls in
            Text("\(urls.count) Einträge werden ein neuer Eintrag. Die einzelnen kommen in den Papierkorb (im Finder wiederherstellbar).")
        }
        .sheet(isPresented: $showRecording) {
            RecordingSheet { file in
                showRecording = false
                if let file { NotificationCenter.default.post(name: .insertAttachment, object: file) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectEntry)) { note in
            if let url = note.object as? URL { show(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .entryMoved)) { note in
            if let pair = note.object as? [URL], pair.count == 2 { followMove(from: pair[0], to: pair[1]) }
        }
        .sheet(item: $eventRequest) { request in
            MakeEventSheet(url: request.url) { eventRequest = nil }
                .environmentObject(library)
        }
        .sheet(item: $calendarImportFolder) { request in
            CalendarImportSheet(folder: request.url) { created in
                calendarImportFolder = nil
                if let first = created.first {
                    message = created.count == 1 ? "1 Eintrag aus dem Kalender angelegt." : "\(created.count) Einträge aus dem Kalender angelegt."
                    selection = first
                }
            }
            .environmentObject(library)
        }
        .sheet(isPresented: $showStatistics) {
            StatisticsSheet(title: title, entries: visibleEntries) { showStatistics = false }
                .environmentObject(library)
        }
        .alert("Die Zeit ist um", isPresented: $writingTimer.finished) {
            Button("OK") {}
        } message: {
            Text("Der Schreib-Timer ist abgelaufen.")
        }
        .sheet(isPresented: $showBackups) {
            BackupsSheet { showBackups = false }
                .environmentObject(library)
        }
        // Vorlagen können im Finder dazukommen: beim Zurückkehren in die App neu lesen.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            library.refreshTemplates()
        }
        .searchFocused($searchFocused)
    }

    private var journalActions: JournalActions {
        JournalActions(
            entry: selection,
            folder: folder,
            folders: library.allFolders,
            rename: { if let selection { askName(.entry, for: selection) } },
            duplicate: { if let selection { duplicate(selection) } },
            copyLink: { if let selection { copyLink(selection) } },
            moveTo: { target in if let selection { move(selection, to: target) } },
            copyTo: { target in if let selection { copy(selection, to: target) } },
            trash: { toTrash = selection },
            trashFolder: selectedFolderNode.map { node in { folderToTrash = node } },
            reveal: { if let selection { NSWorkspace.shared.activateFileViewerSelecting([selection]) } },
            newFolder: { if let parent = folder ?? library.sources.first { askName(.newFolder, for: parent) } },
            renameFolder: { if let folder, !library.sources.contains(folder) { askName(.folder, for: folder) } },
            find: { searchFocused = true },
            convertToRich: { if let selection { convertToRich(selection) } },
            speak: { if let selection { Speaker.shared.toggle(selection, library: library) } },
            goToToday: goToToday,
            goToDate: { dateRequest = .goTo },
            changeDate: { if let selection { dateRequest = .change(selection) } },
            flagged: selection.flatMap { url in library.entries.first { $0.url == url }?.flagged } ?? false,
            toggleFlag: { if let selection { toggleFlag(selection) } },
            editTags: { if let selection { tagRequest = TagRequest(url: selection) } },
            printEntry: { if let selection { EntryPrinter.print(selection, library: library) } },
            savePDF: { if let selection { EntryPrinter.savePDF(selection, library: library) } },
            templates: { library.templateList },
            newFromTemplate: { newEntry(from: $0) },
            saveAsTemplate: { if let selection { saveAsTemplate(selection) } },
            showTemplates: showTemplates,
            newSmartJournal: { smartRequest = SmartRequest(journal: SmartJournal(), isNew: true) },
            editSmartJournal: selectedSmart.map { smart in { smartRequest = SmartRequest(journal: smart, isNew: false) } },
            showVersions: { if let selection { versionsRequest = URLRequest(url: selection) } },
            entryEncrypted: selection.map { url in library.entries.first { $0.url == url }?.encrypted ?? false } ?? false,
            toggleEntryEncryption: {
                guard let selection else { return }
                if library.entries.first(where: { $0.url == selection })?.encrypted == true {
                    library.decryptEntry(selection)
                } else {
                    library.encryptEntry(selection)
                }
            },
            showInfo: { if let selection { infoRequest = InfoRequest(url: selection) } },
            showStatistics: { showStatistics = true },
            focusMode: columns == .detailOnly,
            toggleFocus: toggleFocus,
            export: { format, all in exportEntries(format, all: all) },
            copyHTML: { if let selection { Exchange.copyHTML(selection, library: library) } },
            importFiles: importFiles,
            importCalendar: { if let target = newEntryFolder { calendarImportFolder = URLRequest(url: Library.folderForNew(target)) } },
            makeEvent: { if let selection { eventRequest = URLRequest(url: selection) } },
            isRich: selection.map(Library.isRich) ?? false,
            canMerge: selected.count > 1,
            merge: { if selected.count > 1 { toMerge = Array(selected) } },
            showBacklinks: { if let selection { sidebar = .backlinks(selection) } },
            record: { startAttachment { showRecording = true } },
            attachFile: { startAttachment(chooseAttachment) },
            newOutline: newOutline,
            showBackups: { showBackups = true },
            hasLocks: library.hasLocks,
            unlocked: library.unlocked,
            lockOrUnlock: { library.unlocked ? library.lockNow() : library.unlock() },
            folderLocked: folder.map { library.isLocked($0) },
            toggleFolderLock: folder.flatMap { f in library.isEncryptedFolder(f) ? nil : { toggleLock(f) } },
            folderEncrypted: folder.map { library.isEncryptedFolder($0) },
            toggleEncryption: folder.flatMap { f in
                library.isEncryptedFolder(f) ? { library.decryptFolder(f) } : library.canEncrypt(f) ? { toEncrypt = f } : nil
            }
        )
    }

    private func dialogsB(_ content: some View) -> some View {
        content
        .sheet(item: $smartRequest) { request in
            SmartJournalSheet(journal: request.journal, isNew: request.isNew) { result in
                smartRequest = nil
                guard let result else { return }
                do {
                    try library.saveSmartJournal(result)
                    sidebar = .smart(result.id)
                } catch {
                    message = "Intelligentes Journal sichern ging nicht: \(error.localizedDescription)"
                }
            }
            .environmentObject(library)
        }
        .sheet(item: $tagRequest) { request in
            let entry = library.entries.first { $0.url == request.url }
            TagSheet(title: entry?.title ?? request.url.lastPathComponent, known: library.allTags.map(\.name),
                     tags: entry?.tags ?? []) { tags in
                tagRequest = nil
                guard let tags else { return }
                do {
                    try library.setTags(request.url, tags)
                } catch {
                    message = "Schlagwörter ändern ging nicht: \(error.localizedDescription)"
                }
            }
        }
        .sheet(item: $dateRequest) { request in
            DateSheet(request: request, date: initialDate(for: request)) { date in
                dateRequest = nil
                guard let date else { return }
                switch request {
                case .goTo: goTo(date)
                case .change(let url): changeDate(url, to: date)
                }
            }
        }
        .alert("Kein Eintrag an diesem Tag", isPresented: Binding(get: { dayToCreate != nil }, set: { if !$0 { dayToCreate = nil } }),
               presenting: dayToCreate) { day in
            Button("Anlegen") { openDaily(day) }
            Button("Abbrechen", role: .cancel) { dayToCreate = nil }
        } message: { day in
            Text("Am \(Library.longDayFormat.string(from: day)) gibt es keinen Eintrag. Tageseintrag im Journal anlegen?")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openMacJournalEntry)) { note in
            guard let id = note.object as? String else { return }
            guard let target = library.url(forMacJournalID: id) else {
                message = "Der verlinkte MacJournal-Eintrag (\(id)) wurde nicht gefunden."
                return
            }
            guard !library.isHidden(target) else {
                message = "Der verlinkte Eintrag liegt in einem gesperrten Journal. Erst entsperren."
                return
            }
            query = ""
            if let folder, !Library.isInside(target, folder) { sidebar = .all }
            selection = target
            scrollTarget = target
        }
        // Anderes Journal gewählt: alte Suche gilt nicht mehr (sonst wirkt das Journal leer).
        .onChange(of: sidebar) { _, _ in query = "" }
        .onChange(of: selection) { _, new in reveal(new) }
        .onReceive(NotificationCenter.default.publisher(for: .entryHidden)) { note in
            if let url = note.object as? URL, selected.contains(url) { selection = nil }
        }
        // Beim Sperren: gesperrten oder verschlüsselten Eintrag nicht offen lassen.
        .onChange(of: library.unlocked) { _, now in
            if !now, let selection, library.isLocked(selection) || Vault.isEncrypted(selection) { self.selection = nil }
        }
        .alert("Hinweis", isPresented: .constant(message != nil), presenting: message) { _ in
            Button("OK") { message = nil }
        } message: { Text($0) }
    }

    // MARK: Seitenleiste

    private var sidebarList: some View {
        ScrollViewReader { proxy in
        List(selection: $sidebar) {
            if !library.lockedSources.isEmpty {
                Section("Zugriff nötig") {
                    ForEach(library.lockedSources, id: \.self) { url in
                        Button {
                            grantAccess(to: url)
                        } label: {
                            Label("„\(url.lastPathComponent)“ freigeben …", systemImage: "lock.open")
                        }
                        .help("Die App darf diesen Ordner noch nicht lesen. Einmal im Ordner-Dialog auf „Freigeben“ klicken.")
                    }
                }
            }
            Label("Alle Einträge", systemImage: "tray.full")
                .badge(library.entries.count)
                .tag(SidebarItem.all)
            Label("Markiert", systemImage: "flag")
                .badge(library.entries.filter(\.flagged).count)
                .tag(SidebarItem.flagged)
            Section("Intelligente Journale") {
                ForEach(library.smartJournals) { smart in
                    Label(smart.name, systemImage: "gearshape")
                        .badge(library.entries(for: smart).count)
                        .tag(SidebarItem.smart(smart.id))
                        .contextMenu {
                            Button("Regeln bearbeiten …") { smartRequest = SmartRequest(journal: smart, isNew: false) }
                            Button("Löschen", role: .destructive) { deleteSmart(smart) }
                        }
                }
                Button { smartRequest = SmartRequest(journal: SmartJournal(), isNew: true) } label: {
                    Label("Neues intelligentes Journal …", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Einträge nach Regeln sammeln: Schlagwörter, Fahne, Text, Zeitraum")
            }
            let tags = library.allTags
            if !tags.isEmpty {
                Section("Schlagwörter") {
                    ForEach(tags, id: \.name) { tag in
                        Label(tag.name, systemImage: "tag")
                            .badge(tag.count)
                            .tag(SidebarItem.tag(tag.name))
                    }
                }
            }
            ForEach(library.trees) { root in
                Section(root.name) {
                    Label("Alles in „\(root.name)“", systemImage: root.encrypted ? "lock.shield.fill" : root.locked ? "lock.fill" : "books.vertical")
                        .badge(root.count)
                        .tag(SidebarItem.folder(root.url))
                        .contextMenu {
                            Button("Neues Journal darin …") { askName(.newFolder, for: root.url) }
                            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([root.url]) }
                            Divider()
                            protectionMenu(root)
                        }
                    ForEach(root.children ?? []) { node in
                        FolderRow(node: node, expanded: $expanded, current: currentFolder) { node in
                            folderMenu(node)
                        }
                    }
                }
            }
        }
        .overlay {
            if library.isLoading && library.entries.isEmpty { ProgressView("Lese Einträge …") }
        }
        // Zum Journal des gewählten Eintrags rollen (nach dem Aufklappen).
        .onChange(of: selection) { _, _ in
            guard let folder = currentFolder else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation { proxy.scrollTo(folder, anchor: .center) }
            }
        }
        }
    }

    @ViewBuilder
    private func folderMenu(_ node: FolderNode) -> some View {
        Button("Umbenennen …") { askName(.folder, for: node.url) }
        moveMenu(for: node.url, isFolder: true)
        Button("Neues Journal darin …") { askName(.newFolder, for: node.url) }
        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        Divider()
        protectionMenu(node)
        Button("In den Papierkorb …", role: .destructive) { folderToTrash = node }
    }

    /// Sperren / Verschlüsseln für ein Journal (auch für die Hauptquellen; Verschlüsseln nicht beim täglichen Journal).
    @ViewBuilder
    private func protectionMenu(_ node: FolderNode) -> some View {
        if library.isEncryptedFolder(node.url) {
            Button("Verschlüsselung aufheben …") { library.decryptFolder(node.url) }
        } else {
            Button(node.locked ? "Sperre aufheben" : "Sperren") { toggleLock(node.url) }
            if library.canEncrypt(node.url) {
                Button("Verschlüsseln …") { toEncrypt = node.url }
            }
        }
    }

    /// Journal, in dem der gewählte Eintrag liegt (wird links markiert, wie in MacJournal).
    private var currentFolder: URL? {
        selection?.deletingLastPathComponent().standardizedFileURL
    }

    /// Alle Journale über dem gewählten Eintrag aufklappen, damit man sieht, wo er liegt.
    private func reveal(_ url: URL?) {
        guard let url, let root = library.sources.first(where: { Library.isInside(url, $0) })?.standardizedFileURL else { return }
        var folder = url.deletingLastPathComponent().standardizedFileURL
        while folder.path.count > root.path.count {
            expanded.insert(folder)
            folder = folder.deletingLastPathComponent().standardizedFileURL
        }
    }

    // MARK: Liste der Einträge

    private var folder: URL? {
        if case .folder(let url) = sidebar { return url }
        return nil
    }

    /// Das links gewählte Journal als Knoten (nicht die Quellen selbst, die lassen sich nicht löschen).
    private var selectedFolderNode: FolderNode? {
        guard let folder else { return nil }
        let path = Library.plainPath(folder)
        func find(_ nodes: [FolderNode]) -> FolderNode? {
            for node in nodes {
                if Library.plainPath(node.url) == path { return node }
                if let hit = find(node.children ?? []) { return hit }
            }
            return nil
        }
        return find(library.trees.flatMap { $0.children ?? [] })
    }

    private var title: String {
        if sidebar == .flagged { return "Markiert" }
        if case .tag(let name) = sidebar { return name }
        if case .backlinks(let url) = sidebar { return "Verweise auf „\(library.title(of: url))“" }
        if case .smart(let id) = sidebar { return library.smartJournals.first { $0.id == id }?.name ?? "Intelligentes Journal" }
        if !query.isEmpty && scope == .all { return "Alle Journale" }
        return folder?.lastPathComponent ?? "Alle Einträge"
    }

    /// Die Einträge, die die Mitte gerade zeigt (Journal, Suche, Markiert, Schlagwort, intelligentes Journal).
    private var visibleEntries: [Entry] {
        if case .backlinks(let url) = sidebar { return library.backlinks(to: url).sorted(by: sort, ascending: ascending) }
        var list = library.entries(in: query.isEmpty || scope == .folder ? folder : nil, matching: query)
            .sorted(by: sort, ascending: ascending)
        if sidebar == .flagged { list = list.filter(\.flagged) }
        if case .tag(let name) = sidebar { list = list.filter { $0.tags.contains(name) } }
        if case .smart(let id) = sidebar, let smart = library.smartJournals.first(where: { $0.id == id }) {
            let matching = Set(library.entries(for: smart).map(\.url))
            list = list.filter { matching.contains($0.url) }
        }
        return list
    }

    private var entryList: some View {
        let list = visibleEntries
        return Group {
            if let folder, library.isHidden(folder) {
                LockedView()
            } else {
                switch listMode {
                case .calendar: calendarList(list)
                case .timeline: TimelineList(entries: list, selection: selectionBinding) { entryRow($0) }
                case .map: EntryMap(entries: list, selection: selectionBinding)
                case .list: plainList(list)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { ListModePicker().background(.bar) }
        .navigationTitle(title)
        .navigationSubtitle("\(list.count) Einträge")
        // Kalender folgt dem gewählten Eintrag (auch bei Heute, Gehe zu Datum, Links).
        .onChange(of: selection, initial: true) { _, new in
            guard let new, let date = library.entries.first(where: { $0.url == new })?.date else { return }
            calendarMonth = date
            calendarDay = Calendar.current.startOfDay(for: date)
        }
    }

    /// Zeile mit Rechtsklick-Menü (Liste und Kalender).
    private func entryRow(_ entry: Entry) -> some View {
        EntryRow(entry: entry, location: folder == nil || !query.isEmpty ? library.location(of: entry.url) : nil)
            .tag(entry.url)
            .contextMenu {
                Button(entry.flagged ? "Markierung entfernen" : "Markieren") { toggleFlag(entry.url) }
                Button("Schlagwörter …") { tagRequest = TagRequest(url: entry.url) }
                Button("Info …") { infoRequest = InfoRequest(url: entry.url) }
                Button("Wer verlinkt hierher?") { sidebar = .backlinks(entry.url) }
                if entry.encrypted {
                    Button("Verschlüsselung aufheben …") { library.decryptEntry(entry.url) }
                } else {
                    Button("Verschlüsseln") { library.encryptEntry(entry.url) }
                }
                if selected.count > 1 && selected.contains(entry.url) {
                    Button("\(selected.count) Einträge zusammenführen …") { toMerge = Array(selected) }
                }
                Divider()
                Button("Umbenennen …") { askName(.entry, for: entry.url) }
                Button("Datum ändern …") { dateRequest = .change(entry.url) }
                Button("Als Vorlage sichern") { saveAsTemplate(entry.url) }
                Button("Frühere Versionen …") { versionsRequest = URLRequest(url: entry.url) }
                if !Library.isRich(entry.url) {
                    Button("In Rich Text umwandeln") { convertToRich(entry.url) }
                }
                moveMenu(for: entry.url)
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                Divider()
                Button("Termin oder Erinnerung …") { eventRequest = URLRequest(url: entry.url) }
                Button("Als HTML kopieren") { Exchange.copyHTML(entry.url, library: library) }
                Button("Drucken …") { EntryPrinter.print(entry.url, library: library) }
                Button("Als PDF sichern …") { EntryPrinter.savePDF(entry.url, library: library) }
                Divider()
                Button("In den Papierkorb …", role: .destructive) { toTrash = entry.url }
            }
    }

    /// Monatskalender oben, darunter die Einträge des gewählten Tages.
    private func calendarList(_ list: [Entry]) -> some View {
        let day = calendarDay.map { day in list.filter { Calendar.current.isDate($0.date, inSameDayAs: day) } } ?? []
        return VStack(spacing: 0) {
            MonthCalendar(entries: list, month: $calendarMonth, selectedDay: calendarDay) { date in
                calendarDay = date
                // Gibt es Einträge an dem Tag, gleich den ersten zeigen; sonst rechts nichts.
                selection = list.first { Calendar.current.isDate($0.date, inSameDayAs: date) }?.url
            }
            .padding(12)
            Divider()
            List(day, selection: $selected) { entry in entryRow(entry) }
                .overlay {
                    if let calendarDay, day.isEmpty {
                        ContentUnavailableView {
                            Label("Kein Eintrag", systemImage: "calendar")
                        } description: {
                            Text(Library.longDayFormat.string(from: calendarDay))
                        } actions: {
                            Button("Tageseintrag anlegen") { openDaily(calendarDay) }
                        }
                    }
                }
        }
    }

    private func plainList(_ list: [Entry]) -> some View {
        ScrollViewReader { proxy in
        List(list, selection: $selected) { entry in entryRow(entry) }
        .overlay {
            if list.isEmpty && !library.isLoading {
                if query.isEmpty {
                    ContentUnavailableView("Keine Einträge", systemImage: "doc")
                } else {
                    ContentUnavailableView {
                        Label("Nichts gefunden", systemImage: "magnifyingglass")
                    } description: {
                        Text("Suche nach „\(query)“ in „\(title)“.")
                    } actions: {
                        Button("Suche löschen") { query = "" }
                    }
                }
            }
        }
        // Eintrag von außen gewählt (z. B. über einen Link): in der Liste dorthin rollen.
        .onChange(of: scrollTarget) { _, new in
            guard let new else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                proxy.scrollTo(new, anchor: .center)
                scrollTarget = nil
            }
        }
        }
    }

    private func moveMenu(for url: URL, isFolder: Bool = false) -> some View {
        Menu {
            ForEach(library.allFolders, id: \.url) { folder in
                Button(folder.label) { move(url, to: folder.url) }
                    .disabled(folder.url.standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL
                              || folder.url.standardizedFileURL == url.standardizedFileURL
                              || Library.isInside(folder.url, url))
            }
        } label: {
            Label("Verschieben", systemImage: "folder.badge.gearshape")
        }
        .help(isFolder ? "Journal in ein anderes Journal verschieben" : "Eintrag in ein anderes Journal verschieben")
    }

    private func move(_ url: URL, to folder: URL) {
        do {
            let target = try library.move(url, to: folder)
            followMove(from: url, to: target)
        } catch {
            message = "Verschieben ging nicht: \(error.localizedDescription)"
        }
    }

    /// Nach Verschieben oder Umbenennen: Auswahl auf den neuen Ort setzen.
    private func followMove(from old: URL, to new: URL) {
        func moved(_ url: URL) -> URL {
            if url.standardizedFileURL == old.standardizedFileURL { return new }
            guard Library.isInside(url, old) else { return url }
            let rest = String(url.standardizedFileURL.path.dropFirst(old.standardizedFileURL.path.count))
            return URL(fileURLWithPath: new.standardizedFileURL.path + rest)
        }
        if let selection { self.selection = moved(selection) }
        if case .folder(let url) = sidebar { sidebar = .folder(moved(url)) }
    }

    private func askName(_ kind: NameRequest.Kind, for url: URL) {
        switch kind {
        case .entry: nameText = library.entries.first { $0.url == url }?.title ?? url.deletingPathExtension().lastPathComponent
        case .folder: nameText = url.lastPathComponent
        case .newFolder: nameText = ""
        }
        nameRequest = NameRequest(url: url, kind: kind)
    }

    private func applyName(_ request: NameRequest) {
        nameRequest = nil
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            switch request.kind {
            case .entry:
                followMove(from: request.url, to: try library.renameEntry(request.url, to: name))
            case .folder:
                followMove(from: request.url, to: try library.renameFolder(request.url, to: name))
            case .newFolder:
                // Ein leeres Journal zeigt die App nicht; darum gleich ein erster Eintrag.
                let folder = try library.newFolder(named: name, in: request.url)
                selection = try library.newEntry(in: folder)
                sidebar = .folder(folder)
            }
        } catch {
            message = "Das ging nicht: \(error.localizedDescription)"
        }
    }

    private func convertToRich(_ url: URL) {
        do {
            selection = try library.convertToRich(url)
        } catch {
            message = "Umwandeln ging nicht: \(error.localizedDescription)"
        }
    }

    /// Ordner-Dialog, der auf den gesperrten Ordner zeigt; „Freigeben“ gibt der App dauerhaft Zugriff.
    private func grantAccess(to url: URL) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = url
        panel.prompt = "Freigeben"
        panel.message = "Journal g-IT möchte den Ordner „\(url.lastPathComponent)“ lesen und schreiben. Bitte auf „Freigeben“ klicken."
        if panel.runModal() == .OK, let chosen = panel.url {
            library.addSource(chosen)
        }
    }

    private func duplicate(_ url: URL) {
        do {
            let copy = try library.duplicate(url)
            selection = copy
            scrollTarget = copy
        } catch {
            message = "Duplizieren ging nicht: \(error.localizedDescription)"
        }
    }

    private func copy(_ url: URL, to folder: URL) {
        do {
            _ = try library.copy(url, to: folder)
        } catch {
            message = "Kopieren ging nicht: \(error.localizedDescription)"
        }
    }

    /// Wie MacJournal „Copy URL of Entry“: macjournal://<id>, sonst der Dateipfad als Link.
    private func copyLink(_ url: URL) {
        let link = library.macJournalIDs(of: url).first.map { "macjournal://\($0)" } ?? url.absoluteString
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    private func trash(_ url: URL) {
        toTrash = nil
        do {
            if selection == url { selection = nil }
            try library.trash(url)
        } catch {
            message = "Löschen ging nicht: \(error.localizedDescription)"
        }
    }

    private func trashFolder(_ node: FolderNode) {
        folderToTrash = nil
        do {
            if let selection, Library.isInside(selection, node.url) { self.selection = nil }
            if case .folder(let current) = sidebar,
               Library.plainPath(current) == Library.plainPath(node.url) || Library.isInside(current, node.url) {
                sidebar = .all
            }
            try library.trash(node.url)
        } catch {
            message = "Löschen ging nicht: \(error.localizedDescription)"
        }
    }

    // MARK: Datum

    private func initialDate(for request: DateRequest) -> Date {
        switch request {
        case .goTo: return selection.flatMap { url in library.entries.first { $0.url == url }?.date } ?? Date()
        case .change(let url): return library.entries.first { $0.url == url }?.date ?? Date()
        }
    }

    /// Eintrag auswählen, in der Liste hinrollen; liegt er nicht im gewählten Journal, „Alle Einträge“ zeigen.
    private func show(_ url: URL) {
        query = ""
        if let folder, !Library.isInside(url, folder) { sidebar = .all }
        if sidebar == .flagged, library.entries.first(where: { $0.url == url })?.flagged != true { sidebar = .all }
        if case .tag(let name) = sidebar, library.entries.first(where: { $0.url == url })?.tags.contains(name) != true { sidebar = .all }
        if case .smart(let id) = sidebar, let smart = library.smartJournals.first(where: { $0.id == id }),
           !library.entries(for: smart).contains(where: { $0.url == url }) { sidebar = .all }
        selection = url
        scrollTarget = url
    }

    /// Wie MacJournal „Gehe zu Heute“: heutiger Eintrag im Journal; fehlt er, wird er angelegt.
    private func goToToday() { openDaily(Date()) }

    private func openDaily(_ day: Date) {
        dayToCreate = nil
        do {
            show(try library.dailyEntry(for: day))
        } catch {
            message = "Der Tageseintrag ging nicht: \(error.localizedDescription)"
        }
    }

    /// Zum Eintrag eines Tages: erst im gewählten Journal, sonst überall; gibt es keinen, Rückfrage zum Anlegen.
    private func goTo(_ day: Date) {
        if let url = library.entry(on: day, in: folder) ?? library.entry(on: day, in: nil) {
            show(url)
        } else {
            dayToCreate = day
        }
    }

    private func toggleFlag(_ url: URL) {
        let flagged = library.entries.first { $0.url == url }?.flagged ?? false
        do {
            try library.setFlag(url, !flagged)
        } catch {
            message = "Markieren ging nicht: \(error.localizedDescription)"
        }
    }

    private func changeDate(_ url: URL, to date: Date) {
        do {
            let target = try library.changeDate(url, to: date)
            followMove(from: url, to: target)
            scrollTarget = target
        } catch {
            message = "Datum ändern ging nicht: \(error.localizedDescription)"
        }
    }

    /// Wo neue Einträge hinkommen: gewähltes Journal, sonst das des gewählten Eintrags, sonst die erste Quelle.
    private var newEntryFolder: URL? {
        folder ?? selection?.deletingLastPathComponent() ?? library.sources.first
    }

    private var selectedSmart: SmartJournal? {
        if case .smart(let id) = sidebar { return library.smartJournals.first { $0.id == id } }
        return nil
    }

    private func deleteSmart(_ smart: SmartJournal) {
        do {
            if sidebar == .smart(smart.id) { sidebar = .all }
            try library.deleteSmartJournal(smart.id)
        } catch {
            message = "Löschen ging nicht: \(error.localizedDescription)"
        }
    }

    private func newEntry(from template: URL) {
        guard let target = newEntryFolder else { return }
        do {
            selection = try library.newEntry(from: template, in: target)
            query = ""
        } catch {
            message = "Eintrag aus Vorlage ging nicht: \(error.localizedDescription)"
        }
    }

    private func saveAsTemplate(_ url: URL) {
        do {
            let target = try library.saveAsTemplate(url)
            message = "Als Vorlage „\(target.deletingPathExtension().lastPathComponent)“ gesichert. Sie steht jetzt unter Ablage › Neuer Eintrag aus Vorlage."
        } catch {
            message = "Als Vorlage sichern ging nicht: \(error.localizedDescription)"
        }
    }

    /// Vorlagen-Ordner im Finder (legt ihn mit einer Beispiel-Vorlage an, wenn nötig).
    private func showTemplates() {
        do {
            if let folder = try library.ensureTemplatesFolder() { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        } catch {
            message = "Vorlagen-Ordner ging nicht: \(error.localizedDescription)"
        }
    }

    private func merge(_ urls: [URL]) {
        toMerge = nil
        do {
            let target = try library.merge(urls)
            show(target)
        } catch {
            message = "Zusammenführen ging nicht: \(error.localizedDescription)"
        }
    }

    private func newOutline() {
        guard let target = newEntryFolder else { return }
        do {
            selection = try library.newOutline(in: target)
            query = ""
        } catch {
            message = "Neue Gliederung ging nicht: \(error.localizedDescription)"
        }
    }

    /// Anhänge gehen nur in Rich Text; bei Markdown erst fragen.
    private func startAttachment(_ action: () -> Void) {
        guard let selection else { return }
        if Library.isRich(selection) {
            action()
        } else {
            message = "Bilder, Dateien und Tonaufnahmen gehen nur in Rich-Text-Einträgen. Erst Eintrag › „In Rich Text umwandeln“."
        }
    }

    private func chooseAttachment() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Einfügen"
        panel.message = "Bilder, Videos, PDFs oder andere Dateien in den Eintrag einfügen"
        guard panel.runModal() == .OK else { return }
        for file in panel.urls { NotificationCenter.default.post(name: .insertAttachment, object: file) }
    }

    /// Gewählten Eintrag oder alle gezeigten als Text/HTML sichern.
    private func exportEntries(_ format: Exchange.Format, all: Bool) {
        let urls = all ? visibleEntries.map(\.url) : (selection.map { [$0] } ?? [])
        do {
            let count = try Exchange.export(urls, as: format, library: library)
            if count > 1 { message = "\(count) Einträge als \(format.label) gesichert." }
        } catch {
            message = "Exportieren ging nicht: \(error.localizedDescription)"
        }
    }

    /// Dateien ins gewählte Journal holen.
    private func importFiles() {
        guard let target = newEntryFolder else { return }
        do {
            let created = try Exchange.importFiles(into: target, library: library)
            if let first = created.first { selection = first }
        } catch {
            message = "Importieren ging nicht: \(error.localizedDescription)"
        }
    }

    /// Fokus-Modus: nur der Eintrag, im Vollbild (wie MacJournal „Enter Focused Editing“).
    private func toggleFocus() {
        let entering = columns != .detailOnly
        withAnimation { columns = entering ? .detailOnly : .all }
        if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) != entering {
            window.toggleFullScreen(nil)
        }
    }

    /// Journal sperren; die Sperre aufheben geht nur nach Entsperren (Touch ID / Passwort).
    private func toggleLock(_ folder: URL) {
        let locked = library.isLocked(folder) && library.lockedURLs.contains { Library.plainPath($0) == Library.plainPath(folder) }
        func apply() {
            do {
                try library.setLocked(folder, !locked)
                if !locked, let selection, Library.isInside(selection, folder) { self.selection = nil }
            } catch {
                message = "Sperren ging nicht: \(error.localizedDescription)"
            }
        }
        if locked && !library.unlocked {
            library.unlock { ok in if ok { apply() } }
        } else {
            apply()
        }
    }

    private func newEntry() {
        guard let target = folder ?? selection?.deletingLastPathComponent() ?? library.sources.first else { return }
        do {
            selection = try library.newEntry(in: target)
            query = ""
        } catch {
            message = "Neuer Eintrag ging nicht: \(error.localizedDescription)"
        }
    }
}

/// Ein Journal links, mit Unter-Journalen zum Aufklappen. Das Journal des gewählten Eintrags ist markiert.
struct FolderRow<Menu: View>: View {
    let node: FolderNode
    @Binding var expanded: Set<URL>
    let current: URL?
    let menu: (FolderNode) -> Menu

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(node.url.standardizedFileURL) },
                set: { if $0 { expanded.insert(node.url.standardizedFileURL) } else { expanded.remove(node.url.standardizedFileURL) } }
            )) {
                ForEach(children) { child in
                    FolderRow(node: child, expanded: $expanded, current: current, menu: menu)
                }
            } label: { label }
        } else {
            label
        }
    }

    private var isCurrent: Bool { current == node.url.standardizedFileURL }

    private var label: some View {
        Label {
            Text(node.name).fontWeight(isCurrent ? .bold : .regular)
        } icon: {
            Image(systemName: node.encrypted ? "lock.shield.fill" : node.locked ? "lock.fill" : (isCurrent ? "book.fill" : "book.closed"))
        }
        .badge(node.count)
        .tag(SidebarItem.folder(node.url))
        .id(node.url.standardizedFileURL)
        .help(isCurrent ? "Hier liegt der gewählte Eintrag" : "")
        .contextMenu { menu(node) }
    }
}
