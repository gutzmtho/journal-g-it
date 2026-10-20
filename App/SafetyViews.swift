import SwiftUI
import AppKit

/// Frühere Versionen eines Eintrags: links die Zeitpunkte, rechts der Text; „Wiederherstellen“ holt sie zurück.
struct VersionsSheet: View {
    @EnvironmentObject private var library: Library
    let url: URL
    let done: () -> Void
    @State private var chosen: URL?
    @State private var message: String?

    var body: some View {
        let versions = library.versions(of: url)
        VStack(spacing: 0) {
            Text("Frühere Versionen von „\(library.entries.first { $0.url == url }?.title ?? url.lastPathComponent)“")
                .font(.headline)
                .padding()
            if versions.isEmpty {
                ContentUnavailableView("Noch keine früheren Versionen", systemImage: "clock.arrow.circlepath",
                                       description: Text("Vor jeder Änderung sichert die App den alten Stand (höchstens alle 10 Minuten)."))
            } else {
                HSplitView {
                    List(versions, id: \.url, selection: $chosen) { version in
                        Text(version.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute())
                            .tag(version.url)
                    }
                    .frame(minWidth: 200, maxWidth: 260)
                    ScrollView {
                        Text(chosen.map(preview) ?? "Links eine Version wählen.")
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .frame(minWidth: 360)
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
            Divider()
            HStack {
                if let message { Text(message).foregroundStyle(.secondary) }
                Spacer()
                Button("Schließen", role: .cancel, action: done)
                    .keyboardShortcut(.cancelAction)
                Button("Diese Version wiederherstellen") { restore() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
            .padding()
        }
        .frame(width: 720, height: 520)
        .onAppear { chosen = versions.first?.url }
    }

    private func preview(_ version: URL) -> String {
        if Library.isRich(version) { return Library.readRich(version)?.text.string ?? "" }
        return Library.readText(version) ?? ""
    }

    private func restore() {
        guard let chosen else { return }
        do {
            try library.restore(version: chosen, to: url)
            done()
        } catch {
            message = "Wiederherstellen ging nicht: \(error.localizedDescription)"
        }
    }
}

/// Sicherungen des ganzen iCloud-Ordners: Liste, „Jetzt sichern“, im Finder zeigen.
struct BackupsSheet: View {
    @EnvironmentObject private var library: Library
    let done: () -> Void
    @State private var list: [Library.BackupFile] = []
    @State private var working = false
    @State private var message: String?
    @State private var restoring: Library.BackupFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sicherungen").font(.headline)
            Text("Einmal am Tag sichert die App alle Journale als ZIP-Datei auf diesem Mac (die letzten 30). Zum Zurückholen: bei der Sicherung auf „Wiederherstellen …“ klicken.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(list) { backup in
                HStack {
                    Text(backup.date, format: .dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(backup.size), countStyle: .file))
                        .foregroundStyle(.secondary)
                    Button("Zeigen") { NSWorkspace.shared.activateFileViewerSelecting([backup.url]) }
                    Button("Wiederherstellen …") { restoring = backup }
                }
            }
            .overlay { if list.isEmpty { ContentUnavailableView("Noch keine Sicherung", systemImage: "externaldrive") } }
            if let message { Text(message).foregroundStyle(.secondary) }
            HStack {
                Button("Ordner im Finder zeigen") {
                    try? FileManager.default.createDirectory(at: Library.backupsFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([Library.backupsFolder])
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Jetzt sichern") { backupNow() }
                    .disabled(working)
                Button("Schließen", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 620, height: 460)
        .onAppear { list = library.backups() }
        .sheet(item: $restoring) { backup in
            RestoreSheet(backup: backup) { result in
                restoring = nil
                if let result { message = result }
            }
            .environmentObject(library)
        }
    }

    private func backupNow() {
        working = true
        library.makeBackup { result in
            working = false
            list = library.backups()
            switch result {
            case .success: message = "Gesichert."
            case .failure(let error): message = "Sichern ging nicht: \(error.localizedDescription)"
            }
        }
    }
}

/// Anzeige für ein gesperrtes Journal: Schloss und Knopf zum Entsperren.
struct LockedView: View {
    @EnvironmentObject private var library: Library

    var body: some View {
        ContentUnavailableView {
            Label("Gesperrt", systemImage: "lock.fill")
        } description: {
            Text(library.usePassword
                 ? "Dieses Journal ist gesperrt. Zum Öffnen „Entsperren“ und dein Passwort für Journal g-IT eingeben."
                 : "Dieses Journal ist gesperrt. Zum Öffnen „Entsperren“ und Touch ID benutzen.")
        } actions: {
            Button("Entsperren") { library.unlock() }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Einträge aus einer Sicherung zurückholen (wie MacJournal „Browse Backups“).
struct RestoreSheet: View {
    @EnvironmentObject private var library: Library
    let backup: Library.BackupFile
    let done: (String?) -> Void

    @State private var items: [Library.BackupItem] = []
    @State private var folder: URL?
    @State private var chosen: Set<String> = []
    @State private var filter = ""
    @State private var onlyDifferent = true
    @State private var replace = false
    @State private var loading = true
    @State private var message: String?

    private var shown: [Library.BackupItem] {
        items.filter { item in
            (!onlyDifferent || item.state != .same)
                && (filter.isEmpty || item.relative.localizedCaseInsensitiveContains(filter))
        }
    }

    private var selected: [Library.BackupItem] { items.filter { chosen.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wiederherstellen aus der Sicherung vom \(backup.date.formatted(.dateTime.day().month(.wide).year().hour().minute()))")
                .font(.headline)
            if loading {
                ProgressView("Sicherung wird geöffnet …").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    TextField("Suchen", text: $filter).textFieldStyle(.roundedBorder)
                    Toggle("Nur fehlende und geänderte", isOn: $onlyDifferent)
                }
                List(shown) { item in
                    Toggle(isOn: Binding(get: { chosen.contains(item.id) },
                                         set: { on in if on { chosen.insert(item.id) } else { chosen.remove(item.id) } })) {
                        HStack {
                            Text(item.relative).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(item.state.rawValue)
                                .foregroundStyle(item.state == .missing ? Color.orange : item.state == .changed ? Color.blue : Color.secondary)
                        }
                    }
                    .disabled(item.state == .same)
                }
                .overlay { if shown.isEmpty { ContentUnavailableView("Nichts zum Wiederherstellen", systemImage: "checkmark.circle",
                                                                        description: Text("Alles in der Sicherung ist auch jetzt so vorhanden.")) } }
                HStack {
                    Button("Alle fehlenden wählen") { chosen.formUnion(items.filter { $0.state == .missing }.map(\.id)) }
                    Button("Auswahl leeren") { chosen.removeAll() }
                    Spacer()
                    Text("\(items.filter { $0.state == .missing }.count) fehlen, \(items.filter { $0.state == .changed }.count) geändert")
                        .foregroundStyle(.secondary)
                }
                Toggle("Geänderte ersetzen (der jetzige Stand kommt in „Frühere Versionen“)", isOn: $replace)
            }
            if let message { Text(message).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(selected.isEmpty ? "Wiederherstellen" : "\(selected.count) wiederherstellen", action: restore)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
        }
        .padding()
        .frame(width: 720, height: 560)
        .task { await open() }
    }

    private func open() async {
        let library = library
        let backup = backup
        let result = await Task.detached { try? library.openBackup(backup) }.value
        loading = false
        guard let result else {
            message = "Die Sicherung ließ sich nicht öffnen."
            return
        }
        folder = result.folder
        items = result.items
    }

    private func restore() {
        let changedSkipped = !replace && selected.contains { $0.state == .changed }
        do {
            let count = try library.restore(selected, replace: replace)
            var text = count == 1 ? "1 Eintrag wiederhergestellt." : "\(count) Einträge wiederhergestellt."
            if changedSkipped { text += " Geänderte wurden nicht ersetzt (Haken „Geänderte ersetzen“)." }
            finish(text)
        } catch {
            message = "Wiederherstellen ging nicht: \(error.localizedDescription)"
        }
    }

    /// Zwischenordner wieder löschen.
    private func finish(_ result: String?) {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        done(result)
    }
}
