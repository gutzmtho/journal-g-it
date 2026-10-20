import SwiftUI

/// Eintrag in der Journal-Liste: alle Einträge oder ein Journal (Ordner).
enum PhoneSidebarItem: Hashable {
    case all
    case flagged
    case tag(String)
    case smart(UUID)
    case folder(URL)
}

enum PhoneSearchScope: Hashable { case all, folder }

/// iPhone: Journale → Einträge → Eintrag (auf dem iPad nebeneinander).
struct PhoneContentView: View {
    @EnvironmentObject private var library: Library
    @State private var sidebar: PhoneSidebarItem? = .all
    @State private var selection: URL?
    @State private var query = ""
    @State private var scope = PhoneSearchScope.all
    @State private var toTrash: URL?
    @State private var message: String?
    @State private var columns = NavigationSplitViewVisibility.all
    /// Journal (Ordner), das in den Papierkorb soll.
    @State private var folderToTrash: FolderNode?
    /// Namensabfrage für Journale: umbenennen oder neues Journal darin.
    @State private var nameRequest: PhoneNameRequest?
    @State private var nameText = ""
    @State private var dateRequest: DateRequest?
    @State private var dayToCreate: Date?
    @AppStorage(EntrySort.key) private var sort = EntrySort.date
    @AppStorage(EntrySort.ascendingKey) private var ascending = false
    @AppStorage(ListMode.key) private var listMode = ListMode.list
    @State private var calendarMonth = Date()
    @State private var calendarDay: Date? = Calendar.current.startOfDay(for: Date())
    @State private var tagRequest: TagRequest?
    @State private var smartRequest: SmartRequest?
    @State private var infoRequest: InfoRequest?
    @State private var toEncrypt: URL?

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            journalList
        } content: {
            entryList
        } detail: {
            if let selection {
                PhoneEntryView(url: selection, highlight: query)
                    .id(selection)
            } else {
                ContentUnavailableView("Kein Eintrag gewählt", systemImage: "doc.text",
                                       description: Text("Ein Journal wählen, dann einen Eintrag."))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openMacJournalEntry)) { note in
            guard let id = note.object as? String else { return }
            guard let target = library.url(forMacJournalID: id) else {
                message = "Der verlinkte MacJournal-Eintrag wurde nicht gefunden."
                return
            }
            guard !library.isHidden(target) else {
                message = "Der verlinkte Eintrag liegt in einem gesperrten Journal. Erst entsperren."
                return
            }
            query = ""
            if let folder, !Library.isInside(target, folder) { sidebar = .all }
            selection = target
        }
        .alert("Hinweis", isPresented: .constant(message != nil), presenting: message) { _ in
            Button("OK") { message = nil }
        } message: { Text($0) }
    }

    // MARK: Journale

    private var journalList: some View {
        List(selection: $sidebar) {
            if let problem = library.iCloudProblem {
                Label(problem, systemImage: "icloud.slash")
                    .foregroundStyle(.red)
            }
            if library.downloading > 0 {
                Label("iCloud lädt noch \(library.downloading) Einträge …", systemImage: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
            }
            if library.hasLocks {
                Button { library.unlocked ? library.lockNow() : library.unlock() } label: {
                    Label(library.unlocked ? "Gesperrte Journale sperren" : "Gesperrte Journale zeigen",
                          systemImage: library.unlocked ? "lock.open" : "lock.fill")
                }
            }
            NavigationLink(value: PhoneSidebarItem.all) {
                Label("Alle Einträge", systemImage: "tray.full")
                    .badge(library.entries.count)
            }
            NavigationLink(value: PhoneSidebarItem.flagged) {
                Label("Markiert", systemImage: "flag")
                    .badge(library.entries.filter(\.flagged).count)
            }
            Section("Intelligente Journale") {
                ForEach(library.smartJournals) { smart in
                    NavigationLink(value: PhoneSidebarItem.smart(smart.id)) {
                        Label(smart.name, systemImage: "gearshape").badge(library.entries(for: smart).count)
                    }
                    .contextMenu {
                        Button("Regeln bearbeiten …", systemImage: "slider.horizontal.3") {
                            smartRequest = SmartRequest(journal: smart, isNew: false)
                        }
                        Button("Löschen", systemImage: "trash", role: .destructive) {
                            if sidebar == .smart(smart.id) { sidebar = .all }
                            try? library.deleteSmartJournal(smart.id)
                        }
                    }
                }
                Button { smartRequest = SmartRequest(journal: SmartJournal(), isNew: true) } label: {
                    Label("Neues intelligentes Journal …", systemImage: "plus")
                }
            }
            let tags = library.allTags
            if !tags.isEmpty {
                Section("Schlagwörter") {
                    ForEach(tags, id: \.name) { tag in
                        NavigationLink(value: PhoneSidebarItem.tag(tag.name)) {
                            Label(tag.name, systemImage: "tag").badge(tag.count)
                        }
                    }
                }
            }
            ForEach(library.trees) { root in
                Section(root.name) {
                    NavigationLink(value: PhoneSidebarItem.folder(root.url)) {
                        Label("Alles in „\(root.name)“", systemImage: root.encrypted ? "lock.shield.fill" : root.locked ? "lock.fill" : "books.vertical")
                            .badge(root.count)
                    }
                    .contextMenu {
                        Button("Neues Journal darin …", systemImage: "folder.badge.plus") { askName(.newFolder, for: root.url) }
                        Divider()
                        encryptionButton(root)
                    }
                    OutlineGroup(root.children ?? [], children: \.children) { node in
                        NavigationLink(value: PhoneSidebarItem.folder(node.url)) {
                            Label(node.name, systemImage: node.encrypted ? "lock.shield.fill" : node.locked ? "lock.fill" : "book.closed")
                                .badge(node.count)
                        }
                        .contextMenu { folderMenu(node) }
                    }
                }
            }
        }
        .navigationTitle("Journal g-IT")
        .onAppear { LockTimer.shared.start(library) }
        .onReceive(NotificationCenter.default.publisher(for: .entryHidden)) { note in
            if let url = note.object as? URL, selection == url { selection = nil }
        }
        // Beim Sperren: gesperrten oder verschlüsselten Eintrag nicht offen lassen.
        .onChange(of: library.unlocked) { _, now in
            if !now, let selection, library.isLocked(selection) || Vault.isEncrypted(selection) { self.selection = nil }
        }
        .confirmationDialog("Journal verschlüsseln?", isPresented: Binding(get: { toEncrypt != nil }, set: { if !$0 { toEncrypt = nil } }),
                            titleVisibility: .visible, presenting: toEncrypt) { folder in
            Button("Verschlüsseln") {
                toEncrypt = nil
                library.encryptFolder(folder)
            }
            Button("Abbrechen", role: .cancel) { toEncrypt = nil }
        } message: { folder in
            Text("Alle Einträge in „\(folder.lastPathComponent)“ werden verschlüsselt. Nur Journal g-IT kann sie dann lesen. Öffnen mit Face ID.")
        }
        .sheet(item: $library.passwordRequest) { request in
            PasswordSheet(request: request) { library.passwordRequest = nil }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(get: { library.recoveryCode != nil }, set: { if !$0 { library.recoveryCode = nil } })) {
            RecoveryCodeSheet(code: library.recoveryCode ?? "") { library.recoveryCode = nil }
                .presentationDetents([.medium, .large])
        }
        .alert("Hinweis", isPresented: Binding(get: { library.notice != nil && !(library.notice ?? "").hasSuffix("…") },
                                               set: { if !$0 { library.notice = nil } })) {
            Button("OK") { library.notice = nil }
        } message: { Text(library.notice ?? "") }
        .overlay {
            if library.isLoading && library.entries.isEmpty { ProgressView("Lese Einträge …") }
        }
        .refreshable { library.reload() }
        .onChange(of: sidebar) { _, _ in query = "" }
        .alert(nameRequest?.title ?? "", isPresented: Binding(get: { nameRequest != nil }, set: { if !$0 { nameRequest = nil } }),
               presenting: nameRequest) { request in
            TextField("Name", text: $nameText)
            Button("OK") { applyName(request) }
            Button("Abbrechen", role: .cancel) { nameRequest = nil }
        }
        .sheet(item: $smartRequest) { request in
            NavigationStack {
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
                .navigationTitle(request.isNew ? "Neues intelligentes Journal" : "Regeln")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .confirmationDialog("Journal löschen?", isPresented: .constant(folderToTrash != nil), presenting: folderToTrash) { node in
            Button("Löschen", role: .destructive) { trashFolder(node) }
            Button("Abbrechen", role: .cancel) { folderToTrash = nil }
        } message: { node in
            Text("„\(node.name)“ mit \(node.count == 1 ? "1 Eintrag" : "\(node.count) Einträgen") und allen Unter-Journalen. Es kommt in „Zuletzt gelöscht“ in der Dateien-App.")
        }
    }

    /// Verschlüsseln / Verschlüsselung aufheben (nicht beim täglichen Journal).
    @ViewBuilder
    private func encryptionButton(_ node: FolderNode) -> some View {
        if library.isEncryptedFolder(node.url) {
            Button("Verschlüsselung aufheben …", systemImage: "lock.open") { library.decryptFolder(node.url) }
        } else if library.canEncrypt(node.url) {
            Button("Verschlüsseln …", systemImage: "lock.shield") { toEncrypt = node.url }
        }
    }

    /// Menü eines Journals (lange drücken), wie am Mac.
    @ViewBuilder
    private func folderMenu(_ node: FolderNode) -> some View {
        Button("Umbenennen …", systemImage: "pencil") { askName(.rename, for: node.url) }
        Menu {
            ForEach(library.allFolders, id: \.url) { target in
                Button(target.label) { move(node.url, to: target.url) }
                    .disabled(target.url.standardizedFileURL == node.url.deletingLastPathComponent().standardizedFileURL
                              || target.url.standardizedFileURL == node.url.standardizedFileURL
                              || Library.isInside(target.url, node.url))
            }
        } label: {
            Label("Verschieben", systemImage: "folder")
        }
        Button("Neues Journal darin …", systemImage: "folder.badge.plus") { askName(.newFolder, for: node.url) }
        Divider()
        encryptionButton(node)
        Divider()
        Button("Löschen …", systemImage: "trash", role: .destructive) { folderToTrash = node }
    }

    private func askName(_ kind: PhoneNameRequest.Kind, for url: URL) {
        nameText = kind == .rename ? url.lastPathComponent : ""
        nameRequest = PhoneNameRequest(url: url, kind: kind)
    }

    private func applyName(_ request: PhoneNameRequest) {
        nameRequest = nil
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            switch request.kind {
            case .rename:
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

    private func move(_ url: URL, to folder: URL) {
        do {
            followMove(from: url, to: try library.move(url, to: folder))
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

    // MARK: Einträge

    private var folder: URL? {
        if case .folder(let url) = sidebar { return url }
        return nil
    }

    /// Zeile mit Wischen und langem Drücken.
    private func phoneRow(_ entry: Entry) -> some View {
        NavigationLink(value: entry.url) {
            EntryRow(entry: entry, location: folder == nil || !query.isEmpty ? library.location(of: entry.url) : nil)
        }
        .swipeActions {
            Button("Löschen", systemImage: "trash", role: .destructive) { toTrash = entry.url }
        }
        .swipeActions(edge: .leading) {
            Button(entry.flagged ? "Entfernen" : "Markieren", systemImage: entry.flagged ? "flag.slash" : "flag") {
                toggleFlag(entry)
            }
            .tint(.orange)
        }
        .contextMenu {
            Button(entry.flagged ? "Markierung entfernen" : "Markieren", systemImage: entry.flagged ? "flag.slash" : "flag") {
                toggleFlag(entry)
            }
            Button("Info …", systemImage: "info.circle") { infoRequest = InfoRequest(url: entry.url) }
            if entry.encrypted {
                Button("Verschlüsselung aufheben …", systemImage: "lock.open") { library.decryptEntry(entry.url) }
            } else {
                Button("Verschlüsseln", systemImage: "lock.shield") { library.encryptEntry(entry.url) }
            }
            Button("Schlagwörter …", systemImage: "tag") { tagRequest = TagRequest(url: entry.url) }
            Button("Datum ändern …", systemImage: "calendar") { dateRequest = .change(entry.url) }
            Button("Als Vorlage sichern", systemImage: "doc.on.doc") {
                do {
                    let target = try library.saveAsTemplate(entry.url)
                    message = "Als Vorlage „\(target.deletingPathExtension().lastPathComponent)“ gesichert. Lange auf den Stift oben drücken."
                } catch {
                    message = "Als Vorlage sichern ging nicht: \(error.localizedDescription)"
                }
            }
        }
    }

    private var title: String {
        if sidebar == .flagged { return "Markiert" }
        if case .tag(let name) = sidebar { return name }
        if case .smart(let id) = sidebar { return library.smartJournals.first { $0.id == id }?.name ?? "Intelligentes Journal" }
        if !query.isEmpty && scope == .all { return "Alle Journale" }
        return folder?.lastPathComponent ?? "Alle Einträge"
    }

    private var entryList: some View {
        var list = library.entries(in: query.isEmpty || scope == .folder ? folder : nil, matching: query)
            .sorted(by: sort, ascending: ascending)
        if sidebar == .flagged { list = list.filter(\.flagged) }
        if case .tag(let name) = sidebar { list = list.filter { $0.tags.contains(name) } }
        if case .smart(let id) = sidebar, let smart = library.smartJournals.first(where: { $0.id == id }) {
            let matching = Set(library.entries(for: smart).map(\.url))
            list = list.filter { matching.contains($0.url) }
        }
        // Kalender: Monat oben, darunter nur die Einträge des gewählten Tages.
        let shown = listMode == .calendar
            ? calendarDay.map { day in list.filter { Calendar.current.isDate($0.date, inSameDayAs: day) } } ?? []
            : list
        return Group {
            if listMode == .map {
                EntryMap(entries: list, selection: $selection)
            } else {
                List(selection: $selection) {
                    if listMode == .calendar {
                        MonthCalendar(entries: list, month: $calendarMonth, selectedDay: calendarDay) { calendarDay = $0 }
                            .padding(.vertical, 6)
                        if shown.isEmpty, let calendarDay {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Kein Eintrag am \(Library.longDayFormat.string(from: calendarDay)).")
                                    .foregroundStyle(.secondary)
                                Button("Tageseintrag anlegen") { openDaily(calendarDay) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    if listMode == .timeline {
                        let cal = Calendar.current
                        let byMonth = Dictionary(grouping: shown) { cal.date(from: cal.dateComponents([.year, .month], from: $0.date)) ?? $0.date }
                        ForEach(byMonth.keys.sorted(by: >), id: \.self) { month in
                            Section(month.formatted(.dateTime.month(.wide).year()) + " – \(byMonth[month]?.count ?? 0)") {
                                ForEach(byMonth[month] ?? []) { entry in phoneRow(entry) }
                            }
                        }
                    } else {
                        ForEach(shown) { entry in phoneRow(entry) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .top, spacing: 0) { ListModePicker().background(.bar) }
        .onChange(of: selection, initial: true) { _, new in
            guard let new, let date = library.entries.first(where: { $0.url == new })?.date else { return }
            calendarMonth = date
            calendarDay = Calendar.current.startOfDay(for: date)
        }
        .safeAreaInset(edge: .top) {
            if library.downloading > 0 && !list.isEmpty {
                Label("iCloud lädt noch \(library.downloading) Einträge …", systemImage: "icloud.and.arrow.down")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(.bar)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Suchen")
        .searchScopes($scope) {
            Text("Alle Journale").tag(PhoneSearchScope.all)
            Text(folder?.lastPathComponent ?? "Dieses Journal").tag(PhoneSearchScope.folder)
        }
        .overlay {
            if list.isEmpty, let problem = library.iCloudProblem {
                ContentUnavailableView("Kein iCloud", systemImage: "icloud.slash", description: Text(problem))
            } else if list.isEmpty && library.downloading > 0 {
                ProgressView("iCloud lädt \(library.downloading) Einträge …")
            } else if list.isEmpty && (library.isLoading || library.sources.isEmpty) {
                ProgressView(library.sources.isEmpty ? "Suche den iCloud-Ordner …" : (library.progress ?? "Lese Einträge …"))
            } else if list.isEmpty {
                ContentUnavailableView(query.isEmpty ? "Keine Einträge" : "Nichts gefunden",
                                       systemImage: query.isEmpty ? "doc" : "magnifyingglass")
            }
        }
        .refreshable { library.reload() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Tippen: leerer Eintrag. Lange drücken: aus einer Vorlage.
                Menu {
                    let templates = library.templateList
                    ForEach(templates, id: \.self) { template in
                        Button(template.deletingPathExtension().lastPathComponent) { newEntry(from: template) }
                    }
                    if templates.isEmpty {
                        Button("Beispiel-Vorlage anlegen", systemImage: "doc.badge.plus") { _ = try? library.ensureTemplatesFolder() }
                    }
                } label: {
                    Label("Neuer Eintrag", systemImage: "square.and.pencil")
                } primaryAction: {
                    newEntry()
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Heute", systemImage: "calendar") { openDaily(Date()) }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Gehe zu Datum …", systemImage: "calendar.badge.clock") { dateRequest = .goTo }
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    SortPicker().pickerStyle(.inline)
                } label: {
                    Label("Sortieren", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .sheet(item: $infoRequest) { request in
            NavigationStack {
                InfoSheet(url: request.url) { infoRequest = nil }
                    .environmentObject(library)
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
            .presentationDetents([.large])
        }
        .sheet(item: $tagRequest) { request in
            let entry = library.entries.first { $0.url == request.url }
            NavigationStack {
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
            .presentationDetents([.medium, .large])
        }
        .alert("Kein Eintrag an diesem Tag", isPresented: Binding(get: { dayToCreate != nil }, set: { if !$0 { dayToCreate = nil } }),
               presenting: dayToCreate) { day in
            Button("Anlegen") { openDaily(day) }
            Button("Abbrechen", role: .cancel) { dayToCreate = nil }
        } message: { day in
            Text("Am \(Library.longDayFormat.string(from: day)) gibt es keinen Eintrag. Tageseintrag im Journal anlegen?")
        }
        .confirmationDialog("Eintrag löschen?", isPresented: .constant(toTrash != nil), presenting: toTrash) { url in
            Button("Löschen", role: .destructive) { trash(url) }
            Button("Abbrechen", role: .cancel) { toTrash = nil }
        } message: { _ in
            Text("Er kommt in „Zuletzt gelöscht“ in der Dateien-App.")
        }
    }

    // MARK: Datum

    private func initialDate(for request: DateRequest) -> Date {
        switch request {
        case .goTo: return selection.flatMap { url in library.entries.first { $0.url == url }?.date } ?? Date()
        case .change(let url): return library.entries.first { $0.url == url }?.date ?? Date()
        }
    }

    private func toggleFlag(_ entry: Entry) {
        do {
            try library.setFlag(entry.url, !entry.flagged)
        } catch {
            message = "Markieren ging nicht: \(error.localizedDescription)"
        }
    }

    private func show(_ url: URL) {
        query = ""
        if let folder, !Library.isInside(url, folder) { sidebar = .all }
        if sidebar == .flagged, library.entries.first(where: { $0.url == url })?.flagged != true { sidebar = .all }
        if case .tag(let name) = sidebar, library.entries.first(where: { $0.url == url })?.tags.contains(name) != true { sidebar = .all }
        if case .smart(let id) = sidebar, let smart = library.smartJournals.first(where: { $0.id == id }),
           !library.entries(for: smart).contains(where: { $0.url == url }) { sidebar = .all }
        selection = url
    }

    /// Tageseintrag öffnen; fehlt er, wird er angelegt (wie „Gehe zu Heute“ in MacJournal).
    private func openDaily(_ day: Date) {
        dayToCreate = nil
        do {
            show(try library.dailyEntry(for: day))
        } catch {
            message = "Der Tageseintrag ging nicht: \(error.localizedDescription)"
        }
    }

    private func goTo(_ day: Date) {
        if let url = library.entry(on: day, in: folder) ?? library.entry(on: day, in: nil) {
            show(url)
        } else {
            dayToCreate = day
        }
    }

    private func changeDate(_ url: URL, to date: Date) {
        do {
            followMove(from: url, to: try library.changeDate(url, to: date))
        } catch {
            message = "Datum ändern ging nicht: \(error.localizedDescription)"
        }
    }

    private func newEntry(from template: URL) {
        guard let target = folder ?? selection?.deletingLastPathComponent() ?? library.sources.first else { return }
        do {
            selection = try library.newEntry(from: template, in: target)
            query = ""
        } catch {
            message = "Eintrag aus Vorlage ging nicht: \(error.localizedDescription)"
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

    private func trash(_ url: URL) {
        toTrash = nil
        do {
            if selection == url { selection = nil }
            try library.trash(url)
        } catch {
            message = "Löschen ging nicht: \(error.localizedDescription)"
        }
    }
}

/// Wofür gerade ein Journal-Name abgefragt wird.
struct PhoneNameRequest: Identifiable {
    enum Kind { case rename, newFolder }
    let url: URL
    let kind: Kind
    var id: URL { url }
    var title: String { kind == .rename ? "Journal umbenennen" : "Neues Journal" }
}
