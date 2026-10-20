import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Echte Verschlüsselung für ausgewählte Journale (wie MacJournal „encrypts“).
///
/// - Ein zufälliger Schlüssel (AES-256) verschlüsselt die Einträge. Er liegt, mit dem Passwort verschlossen,
///   in „Verschlüsselung.json“ im iCloud-Ordner der App (PBKDF2-SHA256, 600.000 Runden). Mac und iPhone teilen ihn so.
/// - Nach der ersten Passwort-Eingabe merkt sich jedes Gerät den Schlüssel im eigenen Schlüsselbund (nicht in iCloud);
///   danach genügt Touch ID / Face ID. Im Speicher ist er nur, solange entsperrt ist.
/// - Verschlüsselte Datei: „JGITENC1“ + AES-GCM (Nonce, Text, Prüfsumme). Name und Endung bleiben (.md, .rtf);
///   bei .rtfd (Ordner) ist jede Datei darin verschlüsselt.
/// - Ohne Passwort ist der Inhalt verloren. Es gibt keine Hintertür.
final class Vault {
    static let shared = Vault()

    enum VaultError: LocalizedError {
        case locked, wrongPassword, noVault, damaged
        var errorDescription: String? {
            switch self {
            case .locked: "Das Journal ist verschlüsselt und gerade gesperrt. Erst entsperren."
            case .wrongPassword: "Das Passwort stimmt nicht."
            case .noVault: "Es ist noch kein Passwort für die Verschlüsselung festgelegt."
            case .damaged: "Die Datei lässt sich nicht entschlüsseln (beschädigt oder falscher Schlüssel)."
            }
        }
    }

    static let magic = Data("JGITENC1".utf8)
    static let fileName = "Verschlüsselung.json"
    private static let rounds: UInt32 = 600_000
    static let keychainService = "eu.gutzmannit.journalit.vault"

    private let lock = NSLock()
    private var _key: SymmetricKey?

    /// Schlüssel im Speicher (nur solange entsperrt).
    var key: SymmetricKey? {
        lock.lock(); defer { lock.unlock() }
        return _key
    }

    var hasKey: Bool { key != nil }

    private func setKey(_ key: SymmetricKey?) {
        lock.lock(); _key = key; lock.unlock()
    }

    /// Schlüssel aus dem Speicher nehmen (beim Sperren).
    func forget() { setKey(nil) }

    // MARK: Passwort und Schlüssel

    private struct Stored: Codable {
        var version = 1
        var salt: Data
        var rounds: UInt32
        var wrappedKey: Data
        var created: Date
    }

    static func exists(in docs: URL?) -> Bool {
        guard let docs else { return false }
        let file = docs.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            return false
        }
        return true
    }

    /// Erstes Mal: neuen Schlüssel erzeugen, mit dem Passwort verschließen, speichern.
    func create(password: String, in docs: URL, remember: Bool = true) throws {
        let file = docs.appendingPathComponent(Self.fileName)
        guard !FileManager.default.fileExists(atPath: file.path) else { return try unlock(password: password, in: docs, remember: remember) }
        let key = SymmetricKey(size: .bits256)
        let salt = Self.random(16)
        let wrapper = try Self.derive(password, salt: salt, rounds: Self.rounds)
        let wrapped = try AES.GCM.seal(key.withUnsafeBytes { Data($0) }, using: wrapper).combined!
        let stored = Stored(salt: salt, rounds: Self.rounds, wrappedKey: wrapped, created: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dataEncodingStrategy = .base64
        try encoder.encode(stored).write(to: file, options: .atomic)
        setKey(key)
        if remember { saveToKeychain(key) }
    }

    /// Mit dem Passwort öffnen; danach merkt sich das Gerät den Schlüssel.
    /// `remember`: Schlüssel im Schlüsselbund behalten (für Touch ID). Beim Öffnen mit Passwort nicht.
    func unlock(password: String, in docs: URL, remember: Bool = true) throws {
        let file = docs.appendingPathComponent(Self.fileName)
        guard let data = try? Data(contentsOf: file) else { throw VaultError.noVault }
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        let stored = try decoder.decode(Stored.self, from: data)
        let wrapper = try Self.derive(password, salt: stored.salt, rounds: stored.rounds)
        guard let box = try? AES.GCM.SealedBox(combined: stored.wrappedKey),
              let raw = try? AES.GCM.open(box, using: wrapper) else { throw VaultError.wrongPassword }
        let key = SymmetricKey(data: raw)
        setKey(key)
        if remember { saveToKeychain(key) }
    }

    /// Nach Touch ID: Schlüssel aus dem Schlüsselbund holen (iCloud-Schlüsselbund, sonst dieses Gerät).
    /// false = Wiederherstellungsschlüssel bzw. Passwort nötig.
    @discardableResult
    func loadFromKeychain() -> Bool {
        for kind in KeychainKind.allCases {
            var query = kind.query
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count == 32 {
                let key = SymmetricKey(data: data)
                setKey(key)
                if kind != .synced { saveToKeychain(key) }  // ältere Ablage: in den iCloud-Schlüsselbund übernehmen
                return true
            }
        }
        return false
    }

    /// Wo der Schlüssel liegt. Zuerst im iCloud-Schlüsselbund (Mac und iPhone teilen ihn über die gemeinsame
    /// Schlüsselbund-Gruppe), als Rückfall nur auf diesem Gerät.
    private enum KeychainKind: CaseIterable {
        case synced, local, legacy

        /// Aus der Info.plist (dort mit der Team-ID ergänzt, siehe project.yml).
        static let group = Bundle.main.object(forInfoDictionaryKey: "JournalKeychainGroup") as? String ?? ""

        var query: [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Vault.keychainService,
                kSecAttrAccount as String: "schluessel",
            ]
            switch self {
            case .synced:
                query[kSecAttrSynchronizable as String] = true
                if !Self.group.isEmpty { query[kSecAttrAccessGroup as String] = Self.group }
                query[kSecUseDataProtectionKeychain as String] = true
            case .local:
                query[kSecAttrSynchronizable as String] = false
                query[kSecUseDataProtectionKeychain as String] = true
            case .legacy:
                #if os(macOS)
                query[kSecAttrSynchronizable as String] = false
                #endif
            }
            return query
        }

        var accessible: CFString {
            self == .synced ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    /// Schlüssel aus allen Schlüsselbünden entfernen (beim Öffnen mit Passwort soll er nirgends liegen).
    func removeFromKeychain() {
        for kind in KeychainKind.allCases { SecItemDelete(kind.query as CFDictionary) }
    }

    /// Schlüssel in den iCloud-Schlüsselbund legen; geht das nicht, nur auf diesem Gerät.
    private func saveToKeychain(_ key: SymmetricKey) {
        for kind in KeychainKind.allCases {
            SecItemDelete(kind.query as CFDictionary)
            var item = kind.query
            item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
            item[kSecAttrAccessible as String] = kind.accessible
            let status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecSuccess { return }
            print("[JournalIT] Schlüsselbund (\(kind)): \(status)")
        }
    }

    /// Wiederherstellungsschlüssel zum Aufheben, z. B. „K7MQ-2XWP-…“ (6 × 4 Zeichen, etwa 120 Bit).
    static func makeRecoveryCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let bytes = random(24)
        let chars = bytes.map { alphabet[Int($0) % alphabet.count] }
        return stride(from: 0, to: 24, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }

    private static func random(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    /// Schlüssel aus dem Passwort (PBKDF2-SHA256).
    static func derive(_ password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        let pass = Array(password.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            pass.withUnsafeBufferPointer { passBytes in
                passBytes.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pass.count) { passPointer in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passPointer, pass.count,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, out.count)
                }
            }
        }
        guard status == kCCSuccess else { throw VaultError.damaged }
        return SymmetricKey(data: out)
    }

    // MARK: Daten

    static func isEncrypted(_ data: Data) -> Bool { data.prefix(magic.count) == magic }

    /// Ist die Datei (bei .rtfd: der Text darin) verschlüsselt?
    static func isEncrypted(_ url: URL) -> Bool {
        var file = url
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue { file = url.appendingPathComponent("TXT.rtf") }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: magic.count)) == magic
    }

    func encrypt(_ data: Data) throws -> Data {
        guard let key else { throw VaultError.locked }
        return Self.magic + (try AES.GCM.seal(data, using: key).combined!)
    }

    func decrypt(_ data: Data) throws -> Data {
        guard Self.isEncrypted(data) else { return data }
        guard let key else { throw VaultError.locked }
        guard let box = try? AES.GCM.SealedBox(combined: data.dropFirst(Self.magic.count)),
              let plain = try? AES.GCM.open(box, using: key) else { throw VaultError.damaged }
        return plain
    }

    // MARK: Dateien

    /// Datei oder .rtfd-Ordner lesen und entschlüsseln. Bei .rtfd: entschlüsselte Kopie im Zwischenordner
    /// (wird nach `use` gelöscht).
    func withPlainCopy<T>(of url: URL, _ use: (URL) throws -> T) throws -> T {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let copy = temp.appendingPathComponent(url.lastPathComponent)
        try Self.mapFiles(from: url, to: copy) { try decrypt($0) }
        return try use(copy)
    }

    /// Datei oder Ordner verschlüsselt (bzw. entschlüsselt) an seinen Platz schreiben, über eine Kopie daneben.
    func transformInPlace(_ url: URL, encrypt: Bool) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".jgit-" + UUID().uuidString + "." + url.pathExtension)
        try Self.mapFiles(from: url, to: temp) { data in
            if encrypt { return Self.isEncrypted(data) ? data : try self.encrypt(data) }
            return try self.decrypt(data)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    /// Klartext (Datei oder fertiger .rtfd-Ordner `plain`) verschlüsselt nach `url` schreiben.
    func writeEncrypted(from plain: URL, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".jgit-" + UUID().uuidString + "." + url.pathExtension)
        try Self.mapFiles(from: plain, to: temp) { try self.encrypt($0) }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }

    func writeEncrypted(_ data: Data, to url: URL) throws {
        try encrypt(data).write(to: url, options: .atomic)
    }

    /// Datei oder Ordner (rekursiv) kopieren und dabei jede Datei umwandeln.
    private static func mapFiles(from source: URL, to target: URL, _ transform: (Data) throws -> Data) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else { throw CocoaError(.fileNoSuchFile) }
        if isDir.boolValue {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
                try mapFiles(from: source.appendingPathComponent(name), to: target.appendingPathComponent(name), transform)
            }
        } else {
            try transform(Data(contentsOf: source)).write(to: target, options: .atomic)
        }
    }
}
