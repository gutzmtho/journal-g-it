import SwiftUI

extension Notification.Name {
    /// Link macjournal://<id> angetippt; object = Eintragsnummer.
    static let openMacJournalEntry = Notification.Name("JournalIT.openMacJournalEntry")
}

/// Journal g-IT für iPhone und iPad. Liest dieselben Einträge wie der Mac aus dem iCloud-Ordner der App.
@main
struct JournalITPhoneApp: App {
    @StateObject private var library = Library()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneContentView()
                .environmentObject(library)
        }
        // Zurück in der App: Änderungen vom Mac (über iCloud) einlesen.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.foldersChanged() }
        }
    }
}
