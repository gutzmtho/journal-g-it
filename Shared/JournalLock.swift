import Foundation
import LocalAuthentication
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Gesperrte Journale (wie MacJournal „Change Password“): Einträge darin zeigt die App erst nach dem Passwort
/// (Vorgabe) oder Touch ID / Face ID. Einfach gesperrte Dateien bleiben lesbar (Finder, Claude) – die Sperre
/// schützt vor Blicken in der App. Verschlüsselte Journale und Einträge: siehe Vault.swift.
/// Gespeichert in „Gesperrte Journale.json“ im iCloud-Ordner der App; Mac und iPhone teilen die Liste.
/// Nach 5 Minuten außerhalb der App, im Ruhezustand und beim Bildschirmsperren wird wieder gesperrt.
extension Library {

    private var locksFile: URL? { iCloudDocuments?.appendingPathComponent("Gesperrte Journale.json") }

    private func urls(_ paths: [String]) -> [URL] {
        paths.map { path in
            path.hasPrefix("/") ? URL(fileURLWithPath: path) : (iCloudDocuments ?? URL(fileURLWithPath: "/")).appendingPathComponent(path)
        }
    }

    /// Gesperrte Ordner als Adressen (verschlüsselte sind immer auch gesperrt).
    var lockedURLs: [URL] { urls(lockedFolders + encryptedFolders) }

    /// Verschlüsselte Ordner als Adressen.
    var encryptedURLs: [URL] { urls(encryptedFolders) }

    /// Gibt es überhaupt gesperrte Journale?
    var hasLocks: Bool { !lockedFolders.isEmpty || hasEncrypted }

    /// Gibt es Verschlüsseltes (Journale oder einzelne Einträge)?
    var hasEncrypted: Bool { !encryptedFolders.isEmpty || encryptedEntryCount > 0 }

    /// Darf dieses Journal verschlüsselt werden? Alle außer dem täglichen Journal (Claude liest und schreibt es).
    func canEncrypt(_ url: URL) -> Bool {
        guard let daily = dailyJournalFolder else { return true }
        return Self.plainPath(daily) != Self.plainPath(url) && !Self.isInside(url, daily)
    }

    /// Ist genau dieser Ordner verschlüsselt?
    func isEncryptedFolder(_ url: URL) -> Bool {
        encryptedURLs.contains { Self.plainPath($0) == Self.plainPath(url) }
    }

    /// Liegt die Datei (oder der Ordner) in einem gesperrten Journal oder ist es selbst?
    func isLocked(_ url: URL) -> Bool {
        lockedURLs.contains { Self.plainPath($0) == Self.plainPath(url) || Self.isInside(url, $0) }
    }

    /// Ist der Inhalt gerade verborgen? (Gesperrt, oder verschlüsselt und ohne Schlüssel.)
    func isHidden(_ url: URL) -> Bool {
        guard isLocked(url) else { return false }
        if !unlocked { return true }
        let encrypted = encryptedURLs.contains { Self.plainPath($0) == Self.plainPath(url) || Self.isInside(url, $0) }
        return encrypted && !Vault.shared.hasKey
    }

    private var encryptedFile: URL? { iCloudDocuments?.appendingPathComponent("Verschlüsselte Journale.json") }

    func loadLocks() {
        if let file = encryptedFile {
            if FileManager.default.fileExists(atPath: file.path) {
                if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([String].self, from: data),
                   list != encryptedFolders { encryptedFolders = list }
            } else {
                try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            }
        }
        guard let file = locksFile else { return }
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            return
        }
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([String].self, from: data), list != lockedFolders else { return }
        lockedFolders = list
    }

    /// Pfad zum Speichern: im iCloud-Ordner relativ (gilt dann auch am iPhone), sonst absolut.
    private func lockKey(_ url: URL) -> String {
        if let docs = iCloudDocuments, Self.isInside(url, docs) {
            return String(Self.plainPath(url).dropFirst(Self.plainPath(docs).count + 1))
        }
        return Self.plainPath(url)
    }

    /// Journal sperren oder die Sperre aufheben. Aufheben geht nur, wenn gerade entsperrt ist.
    func setLocked(_ folder: URL, _ locked: Bool) throws {
        guard let file = locksFile else { throw CocoaError(.fileNoSuchFile) }
        let key = lockKey(folder)
        var list = lockedFolders.filter { $0 != key }
        if locked { list.append(key) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        lastOwnWrite = Date()
        try encoder.encode(list.sorted()).write(to: file, options: .atomic)
        lockedFolders = list.sorted()
        if locked { unlocked = false }
        reload()
    }

    /// Öffnen mit Passwort (Vorgabe) oder Touch ID / Face ID (Einstellung „unlockWithPassword“ = false).
    var usePassword: Bool { UserDefaults.standard.object(forKey: "unlockWithPassword") as? Bool ?? true }

    /// Bestätigen, dass du es bist: Passwort (lädt dabei gleich den Schlüssel) oder Touch ID / Face ID.
    /// Gibt es noch kein Passwort (nichts verschlüsselt), dann Touch ID / Mac-Passwort von macOS.
    func authenticate(_ reason: String, _ done: @escaping (Bool) -> Void) {
        if usePassword, let docs = iCloudDocuments, Vault.exists(in: docs) {
            Vault.shared.removeFromKeychain()
            if Vault.shared.hasKey && unlocked { done(true); return }
            askPassword(.password, docs: docs, done)
            return
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { done(false); return }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    /// Gesperrte Journale und verschlüsselte Einträge öffnen.
    func unlock(_ done: ((Bool) -> Void)? = nil) {
        authenticate("gesperrte Journale zeigen") { ok in
            guard ok else { done?(false); return }
            self.withKey { gotKey in
                // Ohne Schlüssel bleiben nur die verschlüsselten zu; die einfach gesperrten gehen trotzdem auf.
                self.unlocked = true
                self.reload()
                done?(gotKey || !self.hasEncrypted)
            }
        }
    }

    /// Sofort wieder sperren (Schlüssel aus dem Speicher).
    func lockNow() {
        Vault.shared.forget()
        guard unlocked else { return }
        unlocked = false
        reload()
    }

    /// Schlüssel sicherstellen: im Speicher; mit Touch ID aus dem Schlüsselbund; sonst Passwort abfragen.
    /// Beim allerersten Verschlüsseln wird er angelegt (Passwort festlegen bzw. Wiederherstellungsschlüssel).
    func withKey(_ done: @escaping (Bool) -> Void) {
        if Vault.shared.hasKey { done(true); return }
        // Nichts verschlüsselt und nichts einzurichten: kein Schlüssel nötig.
        if !hasEncrypted && !settingUpEncryption { done(false); return }
        guard let docs = iCloudDocuments else { done(false); return }
        if Vault.exists(in: docs) {
            if !usePassword, Vault.shared.loadFromKeychain() { done(true); return }
            askPassword(usePassword ? .password : .enter, docs: docs, done)
            return
        }
        if usePassword {
            // Erstes Verschlüsseln: Passwort festlegen.
            passwordRequest = PasswordRequest(mode: .create) { password in
                guard let password else { DispatchQueue.main.async { done(false) }; return nil }
                do {
                    try Vault.shared.create(password: password, in: docs, remember: false)
                    DispatchQueue.main.async { done(true) }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
            return
        }
        // Erstes Verschlüsseln mit Touch ID: Schlüssel in den iCloud-Schlüsselbund, Wiederherstellungsschlüssel zeigen.
        let code = Vault.makeRecoveryCode()
        do {
            try Vault.shared.create(password: code, in: docs, remember: true)
            recoveryCode = code
            done(true)
        } catch {
            notice = "Die Verschlüsselung ließ sich nicht einrichten: \(error.localizedDescription)"
            done(false)
        }
    }

    /// Passwort (oder Wiederherstellungsschlüssel) abfragen und damit den Schlüssel öffnen.
    private func askPassword(_ mode: PasswordRequest.Mode, docs: URL, _ done: @escaping (Bool) -> Void) {
        let remember = !usePassword
        passwordRequest = PasswordRequest(mode: mode) { password in
            guard let password else { DispatchQueue.main.async { done(false) }; return nil }
            do {
                do {
                    try Vault.shared.unlock(password: password, in: docs, remember: remember)
                } catch Vault.VaultError.wrongPassword {
                    // Wiederherstellungsschlüssel ohne Rücksicht auf Groß-/Kleinschreibung und Leerzeichen.
                    let code = password.uppercased().filter { $0.isLetter || $0.isNumber }
                    guard code.count == 24 else { throw Vault.VaultError.wrongPassword }
                    let grouped = stride(from: 0, to: 24, by: 4).map { i in
                        String(code[code.index(code.startIndex, offsetBy: i)..<code.index(code.startIndex, offsetBy: i + 4)])
                    }.joined(separator: "-")
                    try Vault.shared.unlock(password: grouped, in: docs, remember: remember)
                }
                DispatchQueue.main.async { done(true) }
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    // MARK: Verschlüsseln

    /// Journal verschlüsseln: Touch ID, Schlüssel (beim ersten Mal Passwort festlegen), dann jede Datei darin.
    /// Das tägliche Journal geht nicht (Claude liest und schreibt es).
    func encryptFolder(_ folder: URL) {
        if let daily = dailyJournalFolder, Self.plainPath(daily) == Self.plainPath(folder) || Self.isInside(folder, daily) {
            notice = "Das tägliche Journal bleibt unverschlüsselt, damit Claude es lesen und schreiben kann."
            return
        }
        // Verschlüsseln braucht keine Bestätigung mit Touch ID: es macht den Inhalt nur sicherer.
        settingUpEncryption = true
        withKey { gotKey in
            self.settingUpEncryption = false
            guard gotKey else { return }
            self.transformFolder(folder, encrypt: true)
        }
    }

    /// Verschlüsselung aufheben (Inhalt wieder lesbar, z. B. für Claude). Nur mit Schlüssel.
    func decryptFolder(_ folder: URL) {
        authenticate("die Verschlüsselung aufheben") { ok in
            guard ok else { return }
            self.withKey { gotKey in
                guard gotKey else { return }
                self.transformFolder(folder, encrypt: false)
            }
        }
    }

    private func transformFolder(_ folder: URL, encrypt: Bool) {
        notice = encrypt ? "Verschlüssele „\(folder.lastPathComponent)“ …" : "Entschlüssele „\(folder.lastPathComponent)“ …"
        let key = lockKey(folder)
        DispatchQueue.global(qos: .userInitiated).async {
            var files: [URL] = []
            var waiting = 0
            if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) {
                for case let url as URL in walker {
                    let name = url.lastPathComponent
                    if name.hasPrefix(".") {
                        if name.hasSuffix(".icloud") {
                            waiting += 1
                            let real = url.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(7)))
                            try? FileManager.default.startDownloadingUbiquitousItem(at: real)
                        }
                        continue
                    }
                    let ext = url.pathExtension.lowercased()
                    if Self.textTypes.contains(ext) || Self.richTypes.contains(ext) { files.append(url) }
                }
            }
            if waiting > 0 {
                DispatchQueue.main.async {
                    self.notice = "iCloud lädt noch \(waiting) Einträge dieses Journals. Bitte in einer Minute noch einmal versuchen."
                }
                return
            }
            var failed = 0
            for url in files {
                do {
                    try Vault.shared.transformInPlace(url, encrypt: encrypt)
                    // Frühere Versionen (auf diesem Gerät) wären sonst lesbare Kopien.
                    if encrypt { self.forgetVersions(of: url) }
                } catch {
                    failed += 1
                }
            }
            DispatchQueue.main.async {
                var list = self.encryptedFolders.filter { $0 != key }
                if encrypt { list.append(key) }
                do {
                    try self.writeEncryptedList(list.sorted())
                } catch {
                    self.notice = "Die Liste der verschlüsselten Journale ließ sich nicht sichern: \(error.localizedDescription)"
                    return
                }
                let what = encrypt ? "verschlüsselt" : "entschlüsselt"
                if encrypt && !self.unlocked { Vault.shared.forget() }
                self.notice = failed == 0
                    ? "„\(folder.lastPathComponent)“ ist \(what) (\(files.count) Einträge)."
                    : "„\(folder.lastPathComponent)“: \(files.count - failed) Einträge \(what), \(failed) gingen nicht."
                self.reload()
            }
        }
    }

    private func writeEncryptedList(_ list: [String]) throws {
        guard let file = encryptedFile else { throw CocoaError(.fileNoSuchFile) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        lastOwnWrite = Date()
        try encoder.encode(list).write(to: file, options: .atomic)
        encryptedFolders = list
    }

    /// Beim Einlesen: Klartext im verschlüsselten Journal verschlüsseln. Verschlüsseltes bleibt verschlüsselt,
    /// auch außerhalb (einzeln verschlüsselte oder hinausgeschobene Einträge); entschlüsselt wird nur auf Wunsch.
    /// false = verschlüsselt und kein Schlüssel da (nicht lesbar).
    static func normalizeEncryption(_ url: URL, encrypted: inout Bool, roots: [URL]) -> Bool {
        let inside = roots.contains { isInside(url, $0) }
        if Vault.shared.hasKey, inside, !encrypted, (try? Vault.shared.transformInPlace(url, encrypt: true)) != nil { encrypted = true }
        return !encrypted || Vault.shared.hasKey
    }

    // MARK: Einzelne Einträge

    /// Einen Eintrag verschlüsseln (beim ersten Mal wird der Schlüssel angelegt).
    func encryptEntry(_ url: URL) {
        settingUpEncryption = true
        withKey { gotKey in
            self.settingUpEncryption = false
            guard gotKey else { return }
            do {
                self.lastOwnWrite = Date()
                try Vault.shared.transformInPlace(url, encrypt: true)
                self.forgetVersions(of: url)
                self.notice = self.unlocked
                    ? "Der Eintrag ist verschlüsselt."
                    : "Der Eintrag ist verschlüsselt. Er ist jetzt verborgen; zum Öffnen oben den Schloss-Knopf (Touch ID)."
                if !self.unlocked {
                    // Gesperrt bleibt gesperrt: Schlüssel wieder weg, offener Eintrag zu.
                    Vault.shared.forget()
                    NotificationCenter.default.post(name: .entryHidden, object: url)
                }
                self.reload()
            } catch {
                self.notice = "Verschlüsseln ging nicht: \(error.localizedDescription)"
            }
        }
    }

    /// Verschlüsselung eines Eintrags aufheben. Nicht in einem verschlüsselten Journal.
    func decryptEntry(_ url: URL) {
        if encryptedURLs.contains(where: { Self.isInside(url, $0) }) {
            notice = "Der Eintrag liegt in einem verschlüsselten Journal. Dort bleibt er verschlüsselt."
            return
        }
        authenticate("die Verschlüsselung aufheben") { ok in
            guard ok else { return }
            self.withKey { gotKey in
                guard gotKey else { return }
                do {
                    self.lastOwnWrite = Date()
                    try Vault.shared.transformInPlace(url, encrypt: false)
                    self.reload()
                } catch {
                    self.notice = "Entschlüsseln ging nicht: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// Sperrt nach einer Pause wieder: App 5 Minuten im Hintergrund, Ruhezustand, Bildschirm gesperrt.
final class LockTimer {
    static let shared = LockTimer()
    private weak var library: Library?
    private var leftAt: Date?
    private var observers: [NSObjectProtocol] = []
    static let minutes: TimeInterval = 5

    func start(_ library: Library) {
        guard self.library == nil else { return }
        self.library = library
        let center = NotificationCenter.default
        #if os(macOS)
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.leftAt = Date()
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cameBack()
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.library?.lockNow()
            })
        }
        // Bildschirm gesperrt (⌃⌘Q).
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.library?.lockNow()
        })
        #else
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.leftAt = Date()
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cameBack()
        })
        #endif
    }

    private func cameBack() {
        if let leftAt, Date().timeIntervalSince(leftAt) > Self.minutes * 60 { library?.lockNow() }
        leftAt = nil
    }
}

/// Passwort-Dialog für die Verschlüsselung: festlegen (zweimal tippen) oder eingeben.
/// `submit` bekommt das Passwort (nil = abgebrochen) und gibt eine Fehlermeldung zurück oder nil (= fertig).
struct PasswordRequest: Identifiable {
    /// create: Passwort festlegen; password: Passwort zum Öffnen; enter: Ersatz, wenn der Schlüsselbund fehlt.
    enum Mode { case create, password, enter }
    let id = UUID()
    let mode: Mode
    let submit: (String?) -> String?
}
