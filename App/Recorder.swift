import SwiftUI
import AVFoundation

/// Tonaufnahme (wie MacJournal „Recording Bar“): aufnehmen, anhören, in den Eintrag einfügen.
/// Die Aufnahme kommt als .m4a-Anhang in den Rich-Text-Eintrag (Doppelklick spielt sie ab).
struct RecordingSheet: View {
    let done: (URL?) -> Void

    @StateObject private var recorder = AudioRecorder()

    var body: some View {
        VStack(spacing: 16) {
            Text("Tonaufnahme").font(.headline)
            Text(recorder.timeText)
                .font(.system(size: 40, weight: .light, design: .rounded))
                .monospacedDigit()
            if let message = recorder.message {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if recorder.recording {
                    Button { recorder.stop() } label: { Label("Stopp", systemImage: "stop.circle.fill") }
                        .keyboardShortcut(.space, modifiers: [])
                } else {
                    Button { recorder.start() } label: {
                        Label(recorder.file == nil ? "Aufnahme starten" : "Neu aufnehmen", systemImage: "record.circle")
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    if recorder.file != nil {
                        Button { recorder.togglePlay() } label: {
                            Label(recorder.playing ? "Anhalten" : "Anhören", systemImage: recorder.playing ? "pause.circle" : "play.circle")
                        }
                    }
                }
            }
            .controlSize(.large)
            Divider()
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { recorder.stop(); done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("In den Eintrag einfügen") { recorder.stop(); done(recorder.file) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(recorder.file == nil || recorder.recording)
            }
        }
        .padding()
        .frame(width: 380)
    }
}

final class AudioRecorder: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var recording = false
    @Published private(set) var playing = false
    @Published private(set) var timeText = "0:00"
    @Published private(set) var file: URL?
    @Published private(set) var message: String?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    private static let nameFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f
    }()

    func start() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                guard ok else {
                    self.message = "Kein Zugriff auf das Mikrofon. Bitte in Systemeinstellungen › Datenschutz › Mikrofon erlauben."
                    return
                }
                self.begin()
            }
        }
    }

    private func begin() {
        player?.stop()
        playing = false
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Aufnahme " + Self.nameFormat.string(from: Date()) + ".m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                       AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            file = nil
            recording = true
            message = nil
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self, let recorder = self.recorder else { return }
                self.timeText = Self.format(recorder.currentTime)
            }
        } catch {
            message = "Aufnahme ging nicht: \(error.localizedDescription)"
        }
    }

    func stop() {
        timer?.invalidate()
        if let recorder, recording {
            recorder.stop()
            file = recorder.url
        }
        recording = false
        player?.stop()
        playing = false
    }

    func togglePlay() {
        if playing {
            player?.pause()
            playing = false
            return
        }
        guard let file else { return }
        if player?.url != file { player = try? AVAudioPlayer(contentsOf: file) }
        player?.delegate = self
        playing = player?.play() ?? false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.playing = false }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
