import SwiftUI
import AVFoundation

/// Knöpfe zum Vorlesen: „Vorlesen“, solange still; beim Lesen Absatz zurück, Pause/Weiter, Absatz vor, Stopp.
/// Ohne eigenen Rahmen, damit jede Werkzeugleiste die Knöpfe einzeln führt.
struct SpeechControls: View {
    let url: URL
    let library: Library
    @ObservedObject private var speaker = Speaker.shared

    var body: some View {
        if speaker.speaking == url {
            Group {
                Button { speaker.previous() } label: { Label("Absatz zurück", systemImage: "backward.fill") }
                    .help("Absatz zurück (⌥⌘←)")
                Button { speaker.pauseOrResume() } label: {
                    Label(speaker.paused ? "Weiter" : "Pause", systemImage: speaker.paused ? "play.fill" : "pause.fill")
                }
                .help("Pause / Weiter (⌥⌘P)")
                Button { speaker.next() } label: { Label("Absatz vor", systemImage: "forward.fill") }
                    .help("Absatz vor (⌥⌘→)")
                Button { speaker.stop() } label: { Label("Stopp", systemImage: "stop.fill") }
                    .help("Vorlesen beenden (⌥⌘S)")
            }
            .labelStyle(.iconOnly)
        } else {
            Button { speaker.toggle(url, library: library) } label: {
                Label("Vorlesen", systemImage: "speaker.wave.2")
                    .labelStyle(.titleAndIcon)
            }
            .help("Eintrag vorlesen (⌥⌘S). Ist Text markiert, nur die Markierung; sonst ab dem Absatz mit dem Cursor.")
        }
    }
}

/// Einstellungen fürs Vorlesen: Stimme (mit Probe) und Tempo. Mac (Einstellungen) und iPhone (Blatt).
struct SpeechSettingsSection: View {
    @AppStorage(Speaker.voiceKey) private var voiceID = ""
    @AppStorage(Speaker.rateKey) private var rate = Speaker.defaultRate
    @AppStorage(Speaker.gapKey) private var gap = Speaker.defaultGap
    @AppStorage(Speaker.sentenceGapKey) private var sentenceGap = Speaker.defaultSentenceGap
    @AppStorage(Speaker.dashGapKey) private var dashGap = Speaker.defaultDashGap
    private let voices = Speaker.germanVoices()

    var body: some View {
        Section("Vorlesen") {
            Picker("Stimme", selection: Binding(get: { Speaker.voice?.identifier ?? "" }, set: { voiceID = $0 })) {
                ForEach(voices, id: \.identifier) { voice in
                    // Manche Namen tragen die Qualität schon („Anna (premium)“).
                    Text(voice.name.contains("(") ? "\(voice.name), \(voice.language)"
                         : "\(voice.name) (\(Speaker.qualityName(voice)), \(voice.language))").tag(voice.identifier)
                }
            }
            HStack {
                Button("Probe hören") { if let voice = Speaker.voice { Speaker.shared.sample(voice) } }
                Spacer()
                Text("\(voices.count) deutsche Stimmen").foregroundStyle(.secondary)
            }
            Slider(value: $rate, in: Double(AVSpeechUtteranceMinimumSpeechRate) + 0.2 ... Double(AVSpeechUtteranceMaximumSpeechRate) - 0.2) {
                Text("Tempo")
            } minimumValueLabel: {
                Image(systemName: "tortoise")
            } maximumValueLabel: {
                Image(systemName: "hare")
            }
            Slider(value: $gap, in: 0.2...3, step: 0.1) {
                Text("Pause zwischen Absätzen: \(gap.formatted(.number.precision(.fractionLength(1)))) s")
            }
            Slider(value: $sentenceGap, in: 0...2, step: 0.1) {
                Text("Pause zwischen Sätzen: \(sentenceGap.formatted(.number.precision(.fractionLength(1)))) s")
            }
            Slider(value: $dashGap, in: 0...2, step: 0.1) {
                Text("Pause bei Gedankenstrich: \(dashGap.formatted(.number.precision(.fractionLength(1)))) s")
            }
            Button("Tempo und Pausen zurücksetzen") {
                dashGap = Speaker.defaultDashGap
                rate = Speaker.defaultRate
                gap = Speaker.defaultGap
                sentenceGap = Speaker.defaultSentenceGap
            }
            if !voices.contains(where: { $0.quality == .premium }) {
                Text("Keine Premium-Stimme installiert. Sie klingt deutlich natürlicher: Systemeinstellungen › Bedienungshilfen › Gesprochene Inhalte › Systemstimme › Stimmen verwalten › Deutsch, z. B. „Anna (Premium)“ laden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
