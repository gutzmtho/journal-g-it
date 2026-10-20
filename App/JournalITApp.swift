import SwiftUI

extension Notification.Name {
    static let newEntry = Notification.Name("JournalIT.newEntry")
    /// Link macjournal://<id> angeklickt; object = Eintragsnummer.
    static let openMacJournalEntry = Notification.Name("JournalIT.openMacJournalEntry")
}

@main
struct JournalITApp: App {
    @StateObject private var library = Library()
    static let mainWindowID = "main"

    var body: some Scene {
        WindowGroup("Journal g-IT", id: Self.mainWindowID) {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            JournalCommands(reload: library.reload)
        }

        // Schnellnotiz (⌃⌥⌘N, auch aus anderen Apps): kleines Fenster, bleibt vorne.
        Window(QuickNote.title, id: QuickNote.windowID) {
            QuickNoteView()
                .environmentObject(library)
        }
        .windowResizability(.contentMinSize)
        .windowLevel(.floating)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environmentObject(library)
        }
    }
}
