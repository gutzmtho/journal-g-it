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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sicherungen").font(.headline)
            Text("Einmal am Tag sichert die App alle Journale als ZIP-Datei auf diesem Mac (die letzten 30). Zum Zurückholen: im Finder die ZIP-Datei öffnen und den Eintrag herauskopieren.")
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
        .frame(width: 560, height: 460)
        .onAppear { list = library.backups() }
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
            Text("Dieses Journal ist gesperrt. Zum Öffnen Touch ID oder das Mac-Passwort benutzen.")
        } actions: {
            Button("Entsperren") { library.unlock() }
                .buttonStyle(.borderedProminent)
        }
    }
}
