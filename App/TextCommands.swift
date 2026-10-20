import SwiftUI
import AppKit
import Combine

/// Befehle an den gerade offenen Text-Editor (aus der Menüleiste oder der Werkzeugleiste).
enum EditorCommand: String, CaseIterable {
    case find, replace, findNext, findPrevious, dictate
    // Text-Werkzeuge (wie MacJournal Format › Text): wirken auf die Markierung, ohne Markierung auf den ganzen Text.
    case uppercase, lowercase, capitalize, sortLines, sortLinesDescending, removeDuplicateLines, joinLines,
         trimLeading, collapseSpaces, removeQuotes, removeChecked
    // Checklisten und Gliederung (Zeilen der Markierung).
    case insertCheckbox, toggleCheckbox, indent, outdent
    /// Eintrag an der Cursor-Stelle teilen: der Rest wird ein neuer Eintrag.
    case split

    static let notification = Notification.Name("JournalIT.editorCommand")

    func post() { NotificationCenter.default.post(name: Self.notification, object: rawValue) }

    /// Befehl in einer Text-Ansicht ausführen. Der Cursor bleibt, wo er war; dort landet auch diktierter Text.
    func perform(on textView: NSTextView) {
        textView.window?.makeFirstResponder(textView)
        switch self {
        case .dictate:
            // Eigene Spracherkennung (geht auch, wenn das Diktat von macOS aus ist).
            MacDictation.toggle(textView)
        case .split:
            break  // macht der Editor selbst (braucht die Datei)
        case .find, .replace, .findNext, .findPrevious:
            let action: NSTextFinder.Action = switch self {
            case .replace: .showReplaceInterface
            case .findNext: .nextMatch
            case .findPrevious: .previousMatch
            default: .showFindInterface
            }
            let item = NSMenuItem()
            item.tag = action.rawValue
            textView.performTextFinderAction(item)
        default:
            TextTools.apply(self, to: textView)
        }
    }

    var title: String {
        switch self {
        case .uppercase: "GROSSBUCHSTABEN"
        case .lowercase: "kleinbuchstaben"
        case .capitalize: "Wörter Groß Schreiben"
        case .sortLines: "Zeilen sortieren (A–Z)"
        case .sortLinesDescending: "Zeilen sortieren (Z–A)"
        case .removeDuplicateLines: "Doppelte Zeilen entfernen"
        case .joinLines: "Zeilenumbrüche entfernen"
        case .trimLeading: "Leerraum am Zeilenanfang entfernen"
        case .collapseSpaces: "Mehrfache Leerzeichen zu einem"
        case .removeQuotes: "Mail-Zitatzeichen (>) entfernen"
        case .removeChecked: "Abgehakte Zeilen entfernen"
        case .insertCheckbox: "Kästchen einfügen"
        case .toggleCheckbox: "Abhaken / Haken entfernen"
        case .indent: "Einrücken"
        case .outdent: "Ausrücken"
        case .split: "Eintrag hier teilen"
        default: rawValue
        }
    }

    /// Nur der Editor im vordersten Fenster reagiert.
    static func command(from note: Notification, for textView: NSTextView?) -> EditorCommand? {
        guard let raw = note.object as? String, let command = EditorCommand(rawValue: raw),
              let window = textView?.window, window.isKeyWindow || window.isMainWindow else { return nil }
        return command
    }
}

/// Knopf in der Werkzeugleiste: Diktieren starten und beenden (Text kommt an die Cursor-Stelle).
struct DictateButton: View {
    @ObservedObject private var dictation = PhoneDictation.shared

    var body: some View {
        Button {
            if dictation.active { dictation.stop() } else { EditorCommand.dictate.post() }
        } label: {
            Label(dictation.active ? "Diktat beenden" : "Diktieren", systemImage: dictation.active ? "mic.fill" : "mic")
        }
        .foregroundStyle(dictation.active ? Color.red : Color.primary)
        .help(dictation.active ? "Diktat beenden" : "Diktieren: sprechen statt tippen. Der Text kommt an die Cursor-Stelle. Noch einmal klicken zum Beenden.")
        .alert("Diktieren", isPresented: Binding(get: { dictation.problem != nil }, set: { if !$0 { dictation.problem = nil } })) {
            Button("OK") { dictation.problem = nil }
        } message: { Text(dictation.problem ?? "") }
    }
}

/// Diktat am Mac: das Gesagte laufend an der Cursor-Stelle der Text-Ansicht einsetzen (mit Rückgängig).
enum MacDictation {
    private static weak var textView: NSTextView?
    private static var range: NSRange?
    private static var watch: AnyCancellable?

    static func toggle(_ view: NSTextView) {
        let dictation = PhoneDictation.shared
        if dictation.target == AnyHashable(ObjectIdentifier(view)) { dictation.stop(); return }
        textView = view
        range = nil
        watch = dictation.$transcript.dropFirst().receive(on: DispatchQueue.main).sink { insert($0) }
        dictation.start(for: AnyHashable(ObjectIdentifier(view)))
    }

    private static func insert(_ text: String) {
        // Eintrag inzwischen geschlossen: nicht weiter zuhören.
        guard let view = textView, view.window != nil else { PhoneDictation.shared.stop(); return }
        guard let storage = view.textStorage, !text.isEmpty,
              PhoneDictation.shared.target == AnyHashable(ObjectIdentifier(view)) else { return }
        if range == nil { range = view.selectedRange() }
        guard var current = range, NSMaxRange(current) <= storage.length else { range = nil; return }
        let before = current.location > 0 ? (storage.string as NSString).substring(with: NSRange(location: current.location - 1, length: 1)) : "\n"
        let gap = [" ", "\n", "\t"].contains(before) ? "" : " "
        let inserted = NSAttributedString(string: gap + text, attributes: view.typingAttributes)
        guard view.shouldChangeText(in: current, replacementString: inserted.string) else { return }
        storage.replaceCharacters(in: current, with: inserted)
        view.didChangeText()
        current.length = inserted.length
        range = current
        view.setSelectedRange(NSRange(location: NSMaxRange(current), length: 0))
        view.scrollRangeToVisible(view.selectedRange())
    }
}

/// Schlichter Text-Editor für Markdown (NSTextView): mit Suchleiste (Suchen und Ersetzen) und Diktieren.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: Double
    /// Befehl, der gleich nach dem Öffnen ausgeführt wird (z. B. Suchen aus der Leseansicht).
    var initialCommand: EditorCommand?
    /// Bekommt die Text-Ansicht (z. B. für einen eigenen Diktier-Knopf).
    var onTextView: ((NSTextView) -> Void)?
    /// „Eintrag hier teilen“: bekommt den Text nach dem Cursor (der hier schon entfernt ist).
    var onSplit: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.applyStyle()
        textView.string = text
        context.coordinator.applyStyle()
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.editorCommand(_:)),
                                               name: EditorCommand.notification, object: nil)
        onTextView?(textView)
        let command = initialCommand
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            if command == .dictate {
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                textView.scrollToEndOfDocument(nil)
            }
            if command == .split { context.coordinator.split() } else { command?.perform(on: textView) }
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let c = context.coordinator
        let sizeChanged = c.parent.fontSize != fontSize
        c.parent = self
        guard let textView = c.textView else { return }
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            c.applyStyle()
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        } else if sizeChanged {
            c.applyStyle()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        weak var textView: NSTextView?

        init(_ parent: PlainTextEditor) { self.parent = parent }

        /// Schrift und Zeilenabstand wie in der Leseansicht.
        func applyStyle() {
            guard let textView else { return }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = parent.fontSize * 0.25
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: parent.fontSize),
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: style,
            ]
            textView.typingAttributes = attributes
            textView.defaultParagraphStyle = style
            if let storage = textView.textStorage {
                storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
        }

        @objc func editorCommand(_ note: Notification) {
            guard let textView, let command = EditorCommand.command(from: note, for: textView) else { return }
            if command == .split { split() } else { command.perform(on: textView) }
        }

        /// Text ab dem Cursor abschneiden und weitergeben.
        func split() {
            guard let textView, let onSplit = parent.onSplit else { return }
            let length = (textView.string as NSString).length
            let start = textView.selectedRange().location
            let range = NSRange(location: start, length: length - start)
            let tail = (textView.string as NSString).substring(with: range)
            guard !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  textView.shouldChangeText(in: range, replacementString: "") else { NSSound.beep(); return }
            textView.textStorage?.replaceCharacters(in: range, with: "")
            textView.didChangeText()
            onSplit(tail)
        }
    }
}

/// Text-Werkzeuge für NSTextView (Markdown und Rich Text). Rückgängig (⌘Z) geht.
enum TextTools {
    /// Kästchen: im Rich Text ☐/☑, in Markdown „- [ ] “/„- [x] “ (zeigt die Leseansicht als ☐/☑).
    static let open = "☐ ", done = "☑ "

    static func apply(_ command: EditorCommand, to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        var range = textView.selectedRange()
        if range.length == 0 && ![.insertCheckbox, .toggleCheckbox, .indent, .outdent].contains(command) {
            range = NSRange(location: 0, length: text.length)
        }
        switch command {
        case .uppercase, .lowercase, .capitalize:
            // Je Abschnitt gleicher Formatierung, damit fett/kursiv erhalten bleibt.
            let pieces = NSMutableAttributedString()
            storage.attributedSubstring(from: range).enumerateAttributes(in: NSRange(location: 0, length: range.length)) { attributes, part, _ in
                let piece = (storage.string as NSString).substring(with: NSRange(location: range.location + part.location, length: part.length))
                let changed = command == .uppercase ? piece.uppercased() : command == .lowercase ? piece.lowercased() : piece.capitalized
                pieces.append(NSAttributedString(string: changed, attributes: attributes))
            }
            replace(range, with: pieces, in: textView)
        default:
            let lineRange = text.lineRange(for: range)
            var block = text.substring(with: lineRange)
            let endsWithNewline = block.hasSuffix("\n")
            if endsWithNewline { block.removeLast() }
            var lines = block.components(separatedBy: "\n")
            let rich = textView.isRichText
            switch command {
            case .sortLines: lines.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            case .sortLinesDescending: lines.sort { $0.localizedStandardCompare($1) == .orderedDescending }
            case .removeDuplicateLines:
                var seen = Set<String>()
                lines = lines.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty || seen.insert($0).inserted }
            case .joinLines:
                lines = [lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")]
            case .trimLeading: lines = lines.map { String($0.drop { $0 == " " || $0 == "\t" }) }
            case .collapseSpaces:
                lines = lines.map { $0.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression) }
            case .removeQuotes:
                lines = lines.map { $0.replacingOccurrences(of: "^(\\s*>)+\\s?", with: "", options: .regularExpression) }
            case .removeChecked:
                lines = lines.filter { !isChecked($0) }
            case .insertCheckbox:
                lines = lines.map { hasBox($0) ? $0 : addBox($0, rich: rich) }
            case .toggleCheckbox:
                lines = lines.map { line in
                    if !hasBox(line) { return addBox(line, rich: rich) }
                    if line.contains("☐") { return line.replacingOccurrences(of: "☐", with: "☑") }
                    if line.contains("☑") { return line.replacingOccurrences(of: "☑", with: "☐") }
                    if line.contains("[ ]") { return line.replacingOccurrences(of: "[ ]", with: "[x]") }
                    return line.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
                }
            case .indent: lines = lines.map { (rich ? "\t" : "  ") + $0 }
            case .outdent:
                lines = lines.map { line in
                    if line.hasPrefix("\t") { return String(line.dropFirst()) }
                    if line.hasPrefix("  ") { return String(line.dropFirst(2)) }
                    return line
                }
            default: return
            }
            let result = lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
            let attributes = lineRange.length > 0 && lineRange.location < storage.length
                ? storage.attributes(at: lineRange.location, effectiveRange: nil) : textView.typingAttributes
            replace(lineRange, with: NSAttributedString(string: result, attributes: attributes), in: textView)
        }
    }

    private static func hasBox(_ line: String) -> Bool {
        line.contains("☐") || line.contains("☑") || line.range(of: "^\\s*[-*] \\[[ xX]\\]", options: .regularExpression) != nil
    }

    private static func isChecked(_ line: String) -> Bool {
        line.contains("☑") || line.range(of: "^\\s*[-*] \\[[xX]\\]", options: .regularExpression) != nil
    }

    /// Kästchen nach dem Einzug einfügen; ein Markdown-Listenpunkt wird zum Aufgabenpunkt.
    private static func addBox(_ line: String, rich: Bool) -> String {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        var rest = String(line.dropFirst(indent.count))
        if rich { return indent + open + rest }
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") { rest.removeFirst(2) }
        return indent + "- [ ] " + rest
    }

    private static func replace(_ range: NSRange, with text: NSAttributedString, in textView: NSTextView) {
        guard textView.shouldChangeText(in: range, replacementString: text.string) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location, length: text.length))
    }
}

/// Menü „Text“ mit den Text-Werkzeugen (für Menüleiste und Werkzeugleiste).
struct TextToolsMenu: View {
    var body: some View {
        ForEach([EditorCommand.insertCheckbox, .toggleCheckbox, .removeChecked], id: \.self) { command in
            Button(command.title) { command.post() }
        }
        Divider()
        ForEach([EditorCommand.indent, .outdent], id: \.self) { command in
            Button(command.title) { command.post() }
        }
        Divider()
        ForEach([EditorCommand.uppercase, .lowercase, .capitalize], id: \.self) { command in
            Button(command.title) { command.post() }
        }
        Divider()
        ForEach([EditorCommand.sortLines, .sortLinesDescending, .removeDuplicateLines, .joinLines,
                 .trimLeading, .collapseSpaces, .removeQuotes], id: \.self) { command in
            Button(command.title) { command.post() }
        }
    }
}
