import SwiftUI

/// Was die Menüleiste mit dem gewählten Eintrag/Journal tun kann. Das Fenster stellt es bereit.
struct JournalActions {
    var entry: URL?
    var folder: URL?
    var folders: [(url: URL, label: String)]
    var rename: () -> Void
    var duplicate: () -> Void
    var copyLink: () -> Void
    var moveTo: (URL) -> Void
    var copyTo: (URL) -> Void
    var trash: () -> Void
    /// Gewähltes Journal in den Papierkorb (nicht bei den Quellen selbst); nil, wenn das nicht geht.
    var trashFolder: (() -> Void)?
    var reveal: () -> Void
    var newFolder: () -> Void
    var renameFolder: () -> Void
    var find: () -> Void
    var convertToRich: () -> Void
    var speak: () -> Void
    var goToToday: () -> Void
    var goToDate: () -> Void
    var changeDate: () -> Void
    var flagged: Bool
    var toggleFlag: () -> Void
    var editTags: () -> Void
    var printEntry: () -> Void
    var savePDF: () -> Void
    var templates: () -> [URL]
    var newFromTemplate: (URL) -> Void
    var saveAsTemplate: () -> Void
    var showTemplates: () -> Void
    var newSmartJournal: () -> Void
    /// Gewähltes intelligentes Journal bearbeiten; nil, wenn keines gewählt ist.
    var editSmartJournal: (() -> Void)?
    var showVersions: () -> Void
    var entryEncrypted: Bool
    var toggleEntryEncryption: () -> Void
    var showInfo: () -> Void
    var showStatistics: () -> Void
    var focusMode: Bool
    var toggleFocus: () -> Void
    /// Exportieren: Format, alle gezeigten (true) oder nur der gewählte Eintrag.
    var export: (Exchange.Format, Bool) -> Void
    var copyHTML: () -> Void
    var importFiles: () -> Void
    var importCalendar: () -> Void
    var makeEvent: () -> Void
    var isRich: Bool
    var canMerge: Bool
    var merge: () -> Void
    var showBacklinks: () -> Void
    var record: () -> Void
    var attachFile: () -> Void
    var newOutline: () -> Void
    var showBackups: () -> Void
    var hasLocks: Bool
    var unlocked: Bool
    var lockOrUnlock: () -> Void
    /// Ist das gewählte Journal gesperrt? nil, wenn keines gewählt ist.
    var folderLocked: Bool?
    /// Gewähltes Journal sperren / Sperre aufheben; nil bei den Quellen selbst.
    var toggleFolderLock: (() -> Void)?
    var folderEncrypted: Bool?
    /// Gewähltes Journal verschlüsseln / entschlüsseln; nil bei den Quellen selbst.
    var toggleEncryption: (() -> Void)?
}

struct JournalActionsKey: FocusedValueKey {
    typealias Value = JournalActions
}

extension FocusedValues {
    var journalActions: JournalActions? {
        get { self[JournalActionsKey.self] }
        set { self[JournalActionsKey.self] = newValue }
    }
}

/// Menüs nach dem Vorbild von MacJournal: Bearbeiten, Eintrag, Journal, Format.
struct JournalCommands: Commands {
    @FocusedValue(\.journalActions) private var actions
    @ObservedObject private var speaker = Speaker.shared
    @ObservedObject private var timer = WritingTimer.shared
    @Environment(\.openWindow) private var openWindow
    let reload: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neuer Eintrag") { NotificationCenter.default.post(name: .newEntry, object: nil) }
                .keyboardShortcut("n")
            Button("Neues Journal …") { actions?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Neue Gliederung") { actions?.newOutline() }
                .disabled(actions == nil)
            Menu("Neuer Eintrag aus Vorlage") {
                ForEach(actions?.templates() ?? [], id: \.self) { template in
                    Button(template.deletingPathExtension().lastPathComponent) { actions?.newFromTemplate(template) }
                }
                Divider()
                Button("Vorlagen-Ordner zeigen") { actions?.showTemplates() }
            }
            .disabled(actions == nil)
            Button("Schnellnotiz …") { QuickNote.shared.show() }
                .keyboardShortcut("n", modifiers: [.command, .option, .control])
            Divider()
            Button("Neues Fenster") { openWindow(id: JournalITApp.mainWindowID) }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])
            Button("Neuer Tab") { newTab() }
                .keyboardShortcut("t", modifiers: [.command, .option])
        }

        CommandGroup(after: .saveItem) {
            Menu("Importieren") {
                Button("Dateien …") { actions?.importFiles() }
                Button("Termine aus dem Kalender …") { actions?.importCalendar() }
            }
            .disabled(actions == nil)
            Menu("Exportieren") {
                Button("Eintrag als Text …") { actions?.export(.text, false) }
                    .disabled(actions?.entry == nil)
                Button("Eintrag als HTML …") { actions?.export(.html, false) }
                    .disabled(actions?.entry == nil)
                Divider()
                Button("Alle gezeigten als Text …") { actions?.export(.text, true) }
                Button("Alle gezeigten als HTML …") { actions?.export(.html, true) }
            }
            .disabled(actions == nil)
            Divider()
            Button("Sicherungen …") { actions?.showBackups() }
                .disabled(actions == nil)
        }

        CommandGroup(replacing: .printItem) {
            Button("Als PDF sichern …") { actions?.savePDF() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(actions?.entry == nil)
            Button("Drucken …") { actions?.printEntry() }
                .keyboardShortcut("p")
                .disabled(actions?.entry == nil)
        }

        // Bearbeiten: nach „Kopieren“ wie in MacJournal.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Link zum Eintrag kopieren") { actions?.copyLink() }
                .keyboardShortcut("c", modifiers: [.command, .shift, .control])
                .disabled(actions?.entry == nil)
            Button("Als HTML kopieren") { actions?.copyHTML() }
                .disabled(actions?.entry == nil)
            Button("Duplizieren") { actions?.duplicate() }
                .keyboardShortcut("d")
                .disabled(actions?.entry == nil)
            Divider()
            folderMenu("Verschieben nach") { actions?.moveTo($0) }
            folderMenu("Kopieren nach") { actions?.copyTo($0) }
            // Ohne gewählten Eintrag gilt es für das gewählte Journal (wie im Rechtsklick-Menü links).
            Button("In den Papierkorb") {
                if actions?.entry != nil { actions?.trash() } else { actions?.trashFolder?() }
            }
                .keyboardShortcut(.delete)
                .disabled(actions?.entry == nil && actions?.trashFolder == nil)
            Divider()
            // Im Eintrag suchen wie in TextEdit (Suchleiste über dem Text); ohne Eintrag in allen Einträgen.
            Button("Im Eintrag suchen …") {
                if actions?.entry != nil { EditorCommand.find.post() } else { actions?.find() }
            }
                .keyboardShortcut("f")
            Button("Suchen und Ersetzen …") { EditorCommand.replace.post() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(actions?.entry == nil)
            Button("Weitersuchen") { EditorCommand.findNext.post() }
                .keyboardShortcut("g")
                .disabled(actions?.entry == nil)
            Button("Rückwärts suchen") { EditorCommand.findPrevious.post() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(actions?.entry == nil)
            Button("In allen Einträgen suchen") { actions?.find() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }

        // Darstellung: Sortierung der Liste.
        CommandGroup(after: .toolbar) {
            Button("Als Liste") { UserDefaults.standard.set(ListMode.list.rawValue, forKey: ListMode.key) }
                .keyboardShortcut("1")
            Button("Als Kalender") { UserDefaults.standard.set(ListMode.calendar.rawValue, forKey: ListMode.key) }
                .keyboardShortcut("2")
            Button("Als Zeitleiste") { UserDefaults.standard.set(ListMode.timeline.rawValue, forKey: ListMode.key) }
                .keyboardShortcut("3")
            Button("Als Karte") { UserDefaults.standard.set(ListMode.map.rawValue, forKey: ListMode.key) }
                .keyboardShortcut("4")
            Divider()
            Button(actions?.focusMode == true ? "Fokus-Modus beenden" : "Fokus-Modus") { actions?.toggleFocus() }
                .keyboardShortcut("f", modifiers: [.command, .option, .control])
                .disabled(actions == nil)
            Button("Statistik …") { actions?.showStatistics() }
                .disabled(actions == nil)
            Divider()
            Menu("Sortieren") {
                SortPicker().pickerStyle(.inline)
            }
        }

        CommandMenu("Gehe zu") {
            Button("Heute") { actions?.goToToday() }
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(actions == nil)
            Button("Gehe zu Datum …") { actions?.goToDate() }
                .keyboardShortcut("g", modifiers: [.command, .control])
                .disabled(actions == nil)
        }

        CommandMenu("Eintrag") {
            Button("Neuer Eintrag") { NotificationCenter.default.post(name: .newEntry, object: nil) }
            Button("Umbenennen …") { actions?.rename() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(actions?.entry == nil)
            Button("Duplizieren") { actions?.duplicate() }
                .disabled(actions?.entry == nil)
            Button("In Rich Text umwandeln") { actions?.convertToRich() }
                .disabled(actions?.entry.map { Library.isRich($0) } ?? true)
            Button(actions?.flagged == true ? "Markierung entfernen" : "Markieren") { actions?.toggleFlag() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(actions?.entry == nil)
            Button("Schlagwörter …") { actions?.editTags() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(actions?.entry == nil)
            Button("Info …") { actions?.showInfo() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(actions?.entry == nil)
            Button("Als Vorlage sichern") { actions?.saveAsTemplate() }
                .disabled(actions?.entry == nil)
            Button("Datum ändern …") { actions?.changeDate() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(actions?.entry == nil)
            Button("Frühere Versionen …") { actions?.showVersions() }
                .disabled(actions?.entry == nil)
            Button(actions?.entryEncrypted == true ? "Verschlüsselung aufheben …" : "Eintrag verschlüsseln") { actions?.toggleEntryEncryption() }
                .disabled(actions?.entry == nil)
            Button("Termin oder Erinnerung …") { actions?.makeEvent() }
                .disabled(actions?.entry == nil)
            Button("Wer verlinkt hierher?") { actions?.showBacklinks() }
                .disabled(actions?.entry == nil)
            Divider()
            Button("Eintrag hier teilen") { EditorCommand.split.post() }
                .disabled(actions?.entry == nil)
            Button("Einträge zusammenführen …") { actions?.merge() }
                .disabled(actions?.canMerge != true)
            Divider()
            Button("Bild oder Datei einfügen …") { actions?.attachFile() }
                .disabled(actions?.entry == nil)
            Button("Tonaufnahme …") { actions?.record() }
                .disabled(actions?.entry == nil)
            Divider()
            Button("Diktieren") { EditorCommand.dictate.post() }
                .disabled(actions?.entry == nil)
            Menu("Schreib-Timer") {
                ForEach(WritingTimer.choices, id: \.self) { minutes in
                    Button("\(minutes) Minuten") { timer.start(minutes: minutes) }
                }
                Divider()
                Button("Timer anhalten") { timer.stop() }
                    .disabled(timer.remaining == nil)
            }
            Divider()
            Button(speaker.speaking == nil ? "Vorlesen" : "Vorlesen beenden") {
                if speaker.speaking != nil { speaker.stop() } else { actions?.speak() }
            }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(actions?.entry == nil && speaker.speaking == nil)
            Button(speaker.paused ? "Vorlesen fortsetzen" : "Vorlesen anhalten") { speaker.pauseOrResume() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(speaker.speaking == nil)
            Button("Absatz zurück") { speaker.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(speaker.speaking == nil)
            Button("Absatz vor") { speaker.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(speaker.speaking == nil)
            Divider()
            Button("Im Finder zeigen") { actions?.reveal() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.entry == nil)
        }

        CommandMenu("Journal") {
            Button("Neues Journal …") { actions?.newFolder() }
                .disabled(actions == nil)
            Button("Journal umbenennen …") { actions?.renameFolder() }
                .disabled(actions?.folder == nil)
            Button("Journal in den Papierkorb …") { actions?.trashFolder?() }
                .disabled(actions?.trashFolder == nil)
            Divider()
            Button("Neues intelligentes Journal …") { actions?.newSmartJournal() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("Regeln bearbeiten …") { actions?.editSmartJournal?() }
                .disabled(actions?.editSmartJournal == nil)
            Divider()
            Button(actions?.folderLocked == true ? "Sperre aufheben" : "Journal sperren") { actions?.toggleFolderLock?() }
                .disabled(actions?.toggleFolderLock == nil)
            Button(actions?.folderEncrypted == true ? "Verschlüsselung aufheben …" : "Journal verschlüsseln …") { actions?.toggleEncryption?() }
                .disabled(actions?.toggleEncryption == nil)
            Button(actions?.unlocked == true ? "Gesperrte Journale sperren" : "Gesperrte Journale zeigen …") { actions?.lockOrUnlock() }
                .keyboardShortcut("l", modifiers: [.command, .control])
                .disabled(actions?.hasLocks != true)
            Divider()
            Button("Neu einlesen") { reload() }
                .keyboardShortcut("r")
        }

        // Format: Schrift, fett, kursiv, Größe – wirkt im RTF-Text.
        TextFormattingCommands()

        // Text-Werkzeuge, Checklisten, Gliederung (Markdown und Rich Text).
        CommandMenu("Text") {
            TextToolsMenu()
                .disabled(actions?.entry == nil)
        }
    }

    /// Neues Fenster als Tab im vorderen Fenster.
    private func newTab() {
        let current = NSApp.keyWindow
        openWindow(id: JournalITApp.mainWindowID)
        DispatchQueue.main.async {
            guard let current, let new = NSApp.keyWindow, new !== current else { return }
            current.addTabbedWindow(new, ordered: .above)
            new.makeKeyAndOrderFront(nil)
        }
    }

    private func folderMenu(_ title: String, action: @escaping (URL) -> Void) -> some View {
        Menu(title) {
            ForEach(actions?.folders ?? [], id: \.url) { folder in
                Button(folder.label) { action(folder.url) }
            }
        }
        .disabled(actions?.entry == nil)
    }
}
