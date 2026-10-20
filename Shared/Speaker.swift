import AVFoundation
import Combine
#if os(macOS)
import AppKit
#endif

/// Liest Einträge vor: absatzweise mit kurzen Pausen, mit aufbereiteter Aussprache (Abkürzungen, Uhrzeiten, Daten …).
/// Pause/Weiter, Absatz vor/zurück, ab Cursor; der gerade gelesene Absatz wird im Eintrag hervorgehoben.
/// Stimme und Tempo stehen in den Einstellungen (UserDefaults „speechVoice“, „speechRate“).
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    /// Eintrag, der gerade vorgelesen wird (nil = still).
    @Published private(set) var speaking: URL?
    @Published private(set) var paused = false
    /// Gerade gelesener Absatz: Bereich im Text (RTF) bzw. Nummer des Markdown-Blocks.
    @Published private(set) var currentRange: NSRange?
    @Published private(set) var currentBlock: Int?

    static let voiceKey = "speechVoice"
    static let rateKey = "speechRate"
    /// Pause zwischen Absätzen in Sekunden (Überschriften etwas länger, Listenpunkte etwas kürzer).
    static let gapKey = "speechGap"
    static let defaultGap = 0.9
    /// Pause zwischen Sätzen innerhalb eines Absatzes, in Sekunden.
    static let sentenceGapKey = "speechSentenceGap"
    static let defaultSentenceGap = 0.4
    /// Pause bei einem Gedankenstrich („ – “, „ - “), in Sekunden.
    static let dashGapKey = "speechDashGap"
    static let defaultDashGap = 0.4
    /// Interne Marke für einen Gedankenstrich; wird nie gesprochen.
    static let dashMark = "\u{2016}"
    static let defaultRate = Double(AVSpeechUtteranceDefaultSpeechRate)

    /// Ein Stück zum Vorlesen: aufbereiteter Text, Ort im Eintrag, Pause danach (Anteil der eingestellten Pause).
    struct Segment {
        var text: String
        var range: NSRange?
        var block: Int?
        var pause: TimeInterval
    }

    private let synth = AVSpeechSynthesizer()
    private var segments: [Segment] = []
    private var index = 0
    /// Satz im aktuellen Absatz.
    private var part = 0
    private var current: AVSpeechUtterance?
    /// Pause zwischen zwei Absätzen läuft; ein angehaltenes Vorlesen geht danach erst bei „Weiter“ los.
    private var waitingForNext = false
    private var gapToken = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    /// iPhone: als gesprochene Wiedergabe anmelden (wie Podcasts). Sonst schaltet der Stummschalter
    /// die Stimme stumm, und beim Sperren bricht sie ab. Andere Töne (Musik) werden leiser gestellt.
    private func audioOn() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif
    }

    private func audioOff() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: - Stimmen

    /// Alle deutschen Stimmen, beste zuerst (Premium, Erweitert, Standard), dann nach Name.
    static func germanVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("de") }
            .sorted { a, b in
                a.quality.rawValue != b.quality.rawValue ? a.quality.rawValue > b.quality.rawValue : a.name < b.name
            }
    }

    static func qualityName(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: "Premium"
        case .enhanced: "Erweitert"
        default: "Standard"
        }
    }

    /// Gewählte Stimme; sonst Anna (Premium), sonst die beste deutsche.
    static var voice: AVSpeechSynthesisVoice? {
        let all = germanVoices()
        if let id = UserDefaults.standard.string(forKey: voiceKey), let chosen = all.first(where: { $0.identifier == id }) {
            return chosen
        }
        return all.first { $0.name.hasPrefix("Anna") && $0.quality == .premium && $0.language == "de-DE" }
            ?? all.first { $0.language == "de-DE" }
            ?? all.first
    }

    private static var gap: TimeInterval {
        UserDefaults.standard.object(forKey: gapKey) as? Double ?? defaultGap
    }

    private static var sentenceGap: TimeInterval {
        UserDefaults.standard.object(forKey: sentenceGapKey) as? Double ?? defaultSentenceGap
    }

    private static var dashGap: TimeInterval {
        UserDefaults.standard.object(forKey: dashGapKey) as? Double ?? defaultDashGap
    }

    private static var rate: Float {
        let value = UserDefaults.standard.object(forKey: rateKey) as? Double ?? defaultRate
        return Float(min(max(value, Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
    }

    /// Probe einer Stimme (Einstellungen).
    func sample(_ voice: AVSpeechSynthesisVoice) {
        stop()
        audioOn()
        let utterance = AVSpeechUtterance(string: Self.spoken(
            "Das ist \(voice.name). Heute ist der 18.10.2026, es ist 15:08 Uhr – z. B. für das Journal.")
            .replacingOccurrences(of: Self.dashMark, with: ","))
        utterance.voice = voice
        utterance.rate = Self.rate
        synth.speak(utterance)
    }

    // MARK: - Steuerung

    /// Start/Stopp für einen Eintrag. Am Mac: Ist Text markiert, nur die Markierung; sonst ab dem Absatz mit dem Cursor.
    func toggle(_ url: URL, library: Library) {
        if speaking == url { stop(); return }
        var all = Self.segments(for: url, library: library)
        var start = 0
        #if os(macOS)
        if let view = NSApp?.keyWindow?.firstResponder as? NSTextView {
            let selected = view.selectedRange()
            if selected.length > 0 {
                all = Self.paragraphs(of: (view.string as NSString).substring(with: selected), offset: selected.location,
                                      withRanges: Library.isRich(url))
            } else if Library.isRich(url), selected.location > 0,
                      let hit = all.firstIndex(where: { $0.range.map { NSMaxRange($0) >= selected.location } ?? false }) {
                start = hit
            }
        }
        #endif
        play(all, from: start, url: url)
    }

    /// Ab einer Stelle im Text lesen (iPhone: Cursor im Eintrag).
    func play(_ url: URL, library: Library, from location: Int) {
        let all = Self.segments(for: url, library: library)
        let start = all.firstIndex { $0.range.map { NSMaxRange($0) >= location } ?? false } ?? 0
        play(all, from: start, url: url)
    }

    private func play(_ all: [Segment], from start: Int, url: URL) {
        stop()
        guard !all.isEmpty else { return }
        segments = all
        index = min(start, all.count - 1)
        part = 0
        speaking = url
        audioOn()
        speakCurrent()
    }

    func pauseOrResume() {
        guard speaking != nil else { return }
        if paused {
            paused = false
            if waitingForNext { waitingForNext = false; speakCurrent() } else { synth.continueSpeaking() }
        } else {
            paused = true
            synth.pauseSpeaking(at: .word)
        }
    }

    func next() { jump(to: index + 1) }

    /// Einen Absatz zurück.
    func previous() { jump(to: index - 1) }

    private func jump(to target: Int) {
        guard speaking != nil, !segments.isEmpty else { return }
        index = min(max(target, 0), segments.count - 1)
        part = 0
        paused = false
        current = nil
        gapToken += 1
        waitingForNext = false
        synth.stopSpeaking(at: .immediate)
        speakCurrent()
    }

    func stop() {
        current = nil
        gapToken += 1
        waitingForNext = false
        segments = []
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        speaking = nil
        paused = false
        currentRange = nil
        currentBlock = nil
        audioOff()
    }

    private func speakCurrent() {
        guard index < segments.count else { stop(); return }
        let segment = segments[index]
        currentRange = segment.range
        currentBlock = segment.block
        let pieces = Self.sentences(segment.text)
        let utterance = AVSpeechUtterance(string: pieces[min(part, pieces.count - 1)].text)
        utterance.voice = Self.voice
        utterance.rate = Self.rate
        current = utterance
        synth.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard utterance === self.current else { return }  // abgebrochen oder Probe
            let wait: TimeInterval
            let pieces = Self.sentences(self.segments[self.index].text)
            if self.part + 1 < pieces.count {
                // Nächster Satz (oder Teil nach einem Gedankenstrich) im selben Absatz.
                wait = pieces[self.part].gap
                self.part += 1
            } else {
                self.index += 1
                self.part = 0
                guard self.index < self.segments.count else { self.stop(); return }
                // Pause vor dem nächsten Absatz; die Markierung springt schon weiter.
                wait = self.segments[self.index - 1].pause * Self.gap
                self.currentRange = self.segments[self.index].range
                self.currentBlock = self.segments[self.index].block
            }
            self.gapToken += 1
            let token = self.gapToken
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                guard token == self.gapToken, self.speaking != nil else { return }
                if self.paused { self.waitingForNext = true } else { self.speakCurrent() }
            }
        }
    }

    // MARK: - Text in Stücke teilen

    /// Absatz in Sätze teilen: nach . ! ? … mit Leerzeichen und großem Anfang danach.
    /// Nicht nach Zahlen („18. Oktober“, „30. Tag“), damit Datum und Ordnungszahlen zusammen bleiben.
    /// Sätze werden zusätzlich an Gedankenstrichen geteilt. `gap` ist die Pause nach dem Stück.
    static func sentences(_ text: String) -> [(text: String, gap: TimeInterval)] {
        var whole: [String] = []
        if let regex = try? NSRegularExpression(pattern: #"(?<!\d)[.!?…]+[“”"')]*\s+(?=[\p{Lu}„"0-9])"#) {
            var start = text.startIndex
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                whole.append(String(text[start..<range.upperBound]))
                start = range.upperBound
            }
            whole.append(String(text[start...]))
        } else {
            whole = [text]
        }
        var result: [(text: String, gap: TimeInterval)] = []
        for sentence in whole {
            let parts = sentence.components(separatedBy: dashMark)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            for (number, part) in parts.enumerated() {
                result.append((part, number < parts.count - 1 ? dashGap : sentenceGap))
            }
        }
        return result.isEmpty ? [(text.replacingOccurrences(of: dashMark, with: " "), sentenceGap)] : result
    }

    /// Titel (wenn der Text nicht ohnehin damit anfängt) und dann Absatz für Absatz.
    static func segments(for url: URL, library: Library) -> [Segment] {
        let raw = library.read(url)
        var result = Library.isRich(url) ? paragraphs(of: raw, offset: 0, withRanges: true) : markdownSegments(raw)
        if let title = library.entries.first(where: { $0.url == url })?.title,
           !(result.first.map { $0.text.hasPrefix(spoken(title)) } ?? false) {
            result.insert(Segment(text: spoken(title), range: nil, block: nil, pause: 1.6), at: 0)
        }
        return result
    }

    static func paragraphs(of text: String, offset: Int, withRanges: Bool) -> [Segment] {
        var result: [Segment] = []
        let string = text as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { paragraph, range, _, _ in
            let words = spoken(paragraph ?? "")
            guard words.contains(where: \.isLetter) || words.contains(where: \.isNumber) else { return }
            let shifted = NSRange(location: range.location + offset, length: range.length)
            // Kurze Zeilen ohne Satzzeichen sind meist Überschriften: etwas längere Pause.
            let heading = words.count < 60 && !(words.last.map { ".!?:".contains($0) } ?? false)
            result.append(Segment(text: words, range: withRanges ? shifted : nil, block: nil, pause: heading ? 1.6 : 1))
        }
        return result
    }

    static func markdownSegments(_ markdown: String) -> [Segment] {
        func clean(_ s: String) -> String {
            let attributed = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return spoken(attributed.map { String($0.characters) } ?? s)
        }
        return MarkdownBlock.parse(markdown).enumerated().compactMap { number, block -> Segment? in
            let text: String
            var pause = 1.0
            switch block {
            case .heading(_, let s): text = clean(s); pause = 1.6
            case .paragraph(let s), .quote(let s): text = clean(s)
            case .item(_, _, let s): text = clean(s); pause = 0.6
            case .table(let rows): text = rows.map { $0.map(clean).joined(separator: ", ") }.joined(separator: ". ")
            case .rule, .code, .image: return nil
            }
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return Segment(text: text, range: nil, block: number, pause: pause)
        }
    }

    /// Markdown ohne Zeichen (für andere Stellen, die nur den Text brauchen).
    static func plainText(_ markdown: String) -> String {
        markdownSegments(markdown).map(\.text).joined(separator: "\n\n")
    }

    // MARK: - Aussprache

    private static let months = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August",
                                 "September", "Oktober", "November", "Dezember"]

    /// Abkürzungen ausgeschrieben (Muster, Ersatz). Reihenfolge zählt: lange vor kurzen.
    private static let abbreviations: [(String, String)] = [
        (#"\bz\.\s?B\."#, "zum Beispiel"), (#"\bd\.\s?h\."#, "das heißt"), (#"\bu\.\s?a\."#, "unter anderem"),
        (#"\bz\.\s?T\."#, "zum Teil"), (#"\bu\.\s?U\."#, "unter Umständen"), (#"\bo\.\s?ä\."#, "oder ähnlich"),
        (#"\bi\.\s?d\.\s?R\."#, "in der Regel"), (#"\bs\.\s?o\."#, "siehe oben"), (#"\bs\.\s?u\."#, "siehe unten"),
        (#"\bca\."#, "circa"), (#"\bNr\."#, "Nummer"), (#"\bbzw\."#, "beziehungsweise"), (#"\busw\."#, "und so weiter"),
        (#"\bevtl\."#, "eventuell"), (#"\bggf\."#, "gegebenenfalls"), (#"\binkl\."#, "inklusive"),
        (#"\bexkl\."#, "exklusive"), (#"\bvgl\."#, "vergleiche"), (#"\bsog\."#, "sogenannt"), (#"\bTel\."#, "Telefon"),
        (#"\bStr\."#, "Straße"), (#"\bmind\."#, "mindestens"), (#"\bmax\."#, "maximal"), (#"\bgem\."#, "gemäß"),
        (#"\bbspw\."#, "beispielsweise"), (#"\bzzgl\."#, "zuzüglich"), (#"\bMio\."#, "Millionen"), (#"\bMrd\."#, "Milliarden"),
        (#"\bKW\s?(\d{1,2})\b"#, "Kalenderwoche $1"), (#"\bkw\s?(\d{1,2})\b"#, "Kalenderwoche $1"),
        // Schlaraffia: Ritter, Junker, Knappe (auch „Kn 312“), Jahreszahl „a.U. 166“.
        (#"\bRtt?\.?(?=\s)"#, "Ritter"), (#"\bJk\.?(?=\s|\d)"#, "Junker"), (#"\bKn\.?(?=\s|\d)"#, "Knappe"),
        (#"\ba\.\s?U\."#, "anno Uhui"), (#"\ba\.\s?D\."#, "außer Dienst"), (#"\ba\.\s(?=\p{Ll})"#, "auf "),
        (#"\bCT\s?(\d+)"#, "C T $1"), (#"\bVM\s?(\d+)"#, "V M $1"), (#"\bLXC\b"#, "L X C"),
    ]

    /// Text so aufbereiten, dass die Stimme ihn gut liest.
    static func spoken(_ input: String) -> String {
        var s = input.replacingOccurrences(of: "\u{FFFC}", with: " ")
        // Links: nur die Domain; Markdown-Links [Text](Adresse) → Text.
        s = replace(#"\[([^\]]+)\]\([^)]*\)"#, in: s, with: "$1")
        s = replace(#"https?://(?:www\.)?([^/\s)\]>]+)[^\s)\]>]*"#, in: s, with: "$1")
        // Markdown-Reste.
        s = replace(#"(?m)^\s{0,3}#{1,6}\s*"#, in: s, with: "")
        s = replace(#"(?m)^\s*[-*+]\s+(\[[ xX]\]\s*)?"#, in: s, with: "")
        s = replace(#"\*\*|__|\*|`|~~"#, in: s, with: "")
        // Uhrzeiten: 15:08 → 15 Uhr 8; 9:00 Uhr → 9 Uhr.
        s = transform(#"\b([01]?\d|2[0-3]):([0-5]\d)(?:\s*Uhr\b)?"#, in: s) { g in
            let minutes = Int(g[2]) ?? 0
            return "\(Int(g[1]) ?? 0) Uhr" + (minutes == 0 ? "" : " \(minutes)")
        }
        // Datum: 18.10.2026 → 18. Oktober 2026; 18.10. → 18. Oktober.
        // Nicht bei IP-Adressen (10.10.60.152) und Versionen (macOS 27.2.).
        s = transform(#"(?<![\d.])(?<!macOS |iOS |Version |Build )\b(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})?(?!\.?\d)"#, in: s) { g in
            guard let day = Int(g[1]), let month = Int(g[2]), (1...31).contains(day), (1...12).contains(month) else { return g[0] }
            return "\(day). \(months[month - 1])" + (g[3].isEmpty ? "" : " " + (g[3].count == 2 ? "20" + g[3] : g[3]))
        }
        for (pattern, replacement) in abbreviations { s = replace(pattern, in: s, with: replacement) }
        // Zeichen.
        s = replace(#"\s*(→|->|=>|⇒|➜)\s*"#, in: s, with: " nach ")
        s = replace(#"\s*(←|<-)\s*"#, in: s, with: " von ")
        s = replace(#"(\d|Uhr)\s*–\s*(\d)"#, in: s, with: "$1 bis $2")  // 14:00–14:45
        // Gedankenstrich mit Leerzeichen: eigene Pause (Marke, beim Teilen in Sätze entfernt); sonst ein Komma.
        s = replace(#"\s+[–—-]\s+"#, in: s, with: " \(dashMark) ")
        s = replace(#"[–—]"#, in: s, with: ", ")
        s = replace(#"\s*&\s*"#, in: s, with: " und ")
        s = replace(#"\s*%"#, in: s, with: " Prozent")
        s = replace(#"€\s*(\d[\d.,]*)"#, in: s, with: "$1 Euro")
        s = replace(#"\s*€"#, in: s, with: " Euro")
        s = replace(#"\s*°C\b"#, in: s, with: " Grad Celsius")
        s = replace(#"\s*°"#, in: s, with: " Grad")
        s = replace(#"~\s*(\d)"#, in: s, with: "etwa $1")
        s = replace(#"≈\s*"#, in: s, with: "etwa ")
        s = replace(#"(\d)\s*[x×]\s*(\d)"#, in: s, with: "$1 mal $2")
        s = replace(#"\s+/\s+"#, in: s, with: ", ")
        s = replace(#"\bkm/h\b"#, in: s, with: "Kilometer pro Stunde")
        s = replace(#"\b(\p{L}*bit|\p{L}*[bB]yte|[KMGT]B|Bilder|Anfragen)/s\b"#, in: s, with: "$1 pro Sekunde")
        s = replace(#"(?<![/\w.-])(\p{L}+)/(\p{L}+)(?![/\w.-])"#, in: s, with: "$1 oder $2")  // Mac/iPhone, nicht /usr/bin
        s = replace(#"(?<=\p{L})-(?=\d)"#, in: s, with: " ")  // proxmox-3 → proxmox 3
        // Klammern: Inhalt bleibt, als kleine Pause.
        s = replace(#"\s*[(\[{]\s*"#, in: s, with: ", ")
        s = replace(#"\s*[)\]}]"#, in: s, with: ",")
        // Emojis und Bildzeichen weglassen (Ziffern, # und * bleiben).
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { scalar in
            if scalar.value == 0xFE0F || scalar.value == 0x200D { return false }
            return !(scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value > 0x2100))
        }))
        // Aufräumen: doppelte Kommas und Leerzeichen.
        s = replace(#",\s*([,.;:!?])"#, in: s, with: "$1")
        s = replace(#"^\s*,\s*|\s*,\s*$"#, in: s, with: "")
        s = replace(#"[ \t]{2,}"#, in: s, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Ersetzen mit eigener Logik; groups[0] ist der ganze Treffer, fehlende Gruppen sind "".
    private static func transform(_ pattern: String, in text: String, _ make: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text) else { continue }
            let groups = (0..<match.numberOfRanges).map { i in
                Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
            }
            result += text[last..<whole.lowerBound] + make(groups)
            last = whole.upperBound
        }
        return result + text[last...]
    }
}
