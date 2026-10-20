import SwiftUI
import Speech
import AVFoundation

/// Diktieren mit eigenem Knopf, am Mac und am iPhone: Apples Spracherkennung, wenn möglich auf dem Gerät.
/// Geht ohne das Diktat von macOS/iOS. `transcript` wächst beim Sprechen; der Editor fügt ihn laufend ein.
/// Hält die Erkennung von selbst an (Pause, Zeitlimit), geht es nahtlos weiter, bis man „Stopp“ wählt.
final class PhoneDictation: ObservableObject {
    static let shared = PhoneDictation()

    /// Wofür gerade diktiert wird (iPhone: der Eintrag, Mac: die Text-Ansicht); nil = aus.
    @Published private(set) var target: AnyHashable?
    /// Alles, was seit dem Start gesagt wurde.
    @Published private(set) var transcript = ""
    @Published var problem: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Fertige Stücke früherer Erkennungen (nach einer Pause).
    private var committed = ""

    var active: Bool { target != nil }

    func toggle(for url: AnyHashable) {
        if target == url { stop() } else { start(for: url) }
    }

    func start(for url: AnyHashable) {
        stop()
        problem = nil
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    guard status == .authorized, granted else {
                        self.problem = "Diktieren braucht Mikrofon und Spracherkennung. Bitte in den Einstellungen (Datenschutz) für Journal g-IT erlauben."
                        return
                    }
                    guard self.recognizer?.isAvailable == true else {
                        self.problem = "Die Spracherkennung ist gerade nicht verfügbar."
                        return
                    }
                    self.committed = ""
                    self.transcript = ""
                    self.target = url
                    self.begin()
                }
            }
        }
    }

    func stop() {
        guard target != nil || engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        target = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func begin() {
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }
            engine.prepare()
            try engine.start()
            recognize()
        } catch {
            problem = "Diktieren ging nicht: \(error.localizedDescription)"
            stop()
        }
    }

    /// Eine Erkennung starten; endet sie (Pause, Zeitlimit), die nächste anhängen.
    private func recognize() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.target != nil, self.request === request else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.transcript = [self.committed, text].filter { !$0.isEmpty }.joined(separator: " ")
                    if result.isFinal {
                        self.committed = self.transcript
                        self.recognize()
                    }
                } else if error != nil {
                    // Z. B. lange Pause ohne Sprache: kurz warten, dann weiter zuhören.
                    self.committed = self.transcript
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if self.target != nil, self.request === request { self.recognize() }
                    }
                }
            }
        }
    }
}

/// Leiste unten beim Diktieren: was gerade erkannt wird, und „Stopp“.
struct DictationBar: View {
    @ObservedObject var dictation = PhoneDictation.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative)
                .foregroundStyle(.red)
            Text(dictation.transcript.isEmpty ? "Ich höre zu …" : dictation.transcript)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Stopp") { dictation.stop() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .padding(10)
        .background(.bar)
    }
}

extension Notification.Name {
    /// Diktierter Text für den Rich-Text-Eintrag (object = URL, userInfo["text"] = alles bisher, ["done"] = Ende).
    static let phoneDictationText = Notification.Name("JournalIT.phoneDictationText")
}
