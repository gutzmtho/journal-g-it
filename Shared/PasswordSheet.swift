import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Passwort für verschlüsselte Journale: beim ersten Mal festlegen, auf jedem Gerät einmal eingeben.
struct PasswordSheet: View {
    let request: PasswordRequest
    let close: () -> Void

    @State private var password = ""
    @State private var repeated = ""
    @State private var message: String?
    @State private var working = false

    private var isCreate: Bool { request.mode == .create }

    private var problem: String? {
        guard isCreate else { return password.isEmpty ? "" : nil }
        if password.count < 10 { return "Mindestens 10 Zeichen." }
        if password != repeated { return repeated.isEmpty ? "" : "Die beiden Eingaben sind verschieden." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isCreate ? "Passwort für die Verschlüsselung festlegen"
                 : request.mode == .password ? "Passwort für Journal g-IT" : "Wiederherstellungsschlüssel eingeben")
                .font(.headline)
            Text(isCreate
                 ? "Mit diesem Passwort werden Journale und Einträge verschlüsselt und geöffnet.\n\nWichtig: Ohne Passwort ist der Inhalt verloren. Bitte in den Passwörtern oder in 1Password speichern."
                 : request.mode == .password ? "Zum Öffnen der gesperrten und verschlüsselten Journale und Einträge."
                 : "Der Schlüssel für die verschlüsselten Journale ist auf diesem Gerät nicht im Schlüsselbund. Bitte einmal den Wiederherstellungsschlüssel (oder das frühere Passwort) eingeben. Danach genügt Touch ID oder Face ID.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(request.mode == .enter ? "Wiederherstellungsschlüssel" : "Passwort", text: $password)
                .textContentType(isCreate ? .newPassword : .password)
            if isCreate {
                SecureField("Noch einmal", text: $repeated)
                    .textContentType(.newPassword)
            }
            if let message {
                Text(message).foregroundStyle(.red)
            } else if let problem, !problem.isEmpty {
                Text(problem).foregroundStyle(.secondary).font(.caption)
            }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Abbrechen", role: .cancel) {
                    _ = request.submit(nil)
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Button(isCreate ? "Festlegen" : "Öffnen", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || working)
            }
        }
        .padding()
        #if os(macOS)
        .frame(width: 420)
        #endif
    }

    private func submit() {
        working = true
        message = nil
        let password = password
        // Das Ableiten des Schlüssels dauert einen Moment (absichtlich, gegen Raten).
        DispatchQueue.global(qos: .userInitiated).async {
            let error = request.submit(password)
            DispatchQueue.main.async {
                working = false
                if let error { message = error } else { close() }
            }
        }
    }
}

/// Wiederherstellungsschlüssel einmal zeigen: zum Aufheben in 1Password oder Passwörter.
struct RecoveryCodeSheet: View {
    let code: String
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Wiederherstellungsschlüssel").font(.headline)
            Text("Der Schlüssel für deine verschlüsselten Journale liegt im iCloud-Schlüsselbund. Zum Öffnen genügt Touch ID oder Face ID, auch am iPhone.\n\nGeht der Schlüsselbund einmal verloren, brauchst du diesen Wiederherstellungsschlüssel. Ohne ihn ist der Inhalt verloren. Bitte jetzt kopieren und in 1Password oder Passwörter speichern.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(code)
                .font(.system(.title2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button(copied ? "Kopiert" : "Kopieren") {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    #else
                    UIPasteboard.general.string = code
                    #endif
                    copied = true
                }
                Spacer()
                Button("Fertig", action: close)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        #if os(macOS)
        .frame(width: 440)
        #endif
    }
}
