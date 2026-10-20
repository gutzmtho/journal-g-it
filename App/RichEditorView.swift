import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// Rechte Seite für RTF und RTFD: Text mit Schrift, Farben und Bildern, direkt bearbeitbar (wie in TextEdit).
/// Gespeichert wird von selbst, kurz nach dem letzten Tippen.
struct RichEditorView: View {
    @EnvironmentObject private var library: Library
    let url: URL
    var highlight = ""

    @State private var status = "Gespeichert"
    @State private var words = 0
    @ObservedObject private var speaker = Speaker.shared
    @AppStorage("fontSize") private var fontSize = 16.0

    var body: some View {
        VStack(spacing: 0) {
            RichTextView(url: url, library: library, revision: library.externalRevision, status: $status, words: $words,
                         zoom: fontSize / 12, highlight: highlight)
            HStack {
                Text(url.deletingLastPathComponent().lastPathComponent + " / " + url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                WritingStatus(words: words)
                Text(status)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .onDisappear {
            if speaker.speaking == url { speaker.stop() }
        }
        .toolbar {
            ToolbarItemGroup {
                SpeechControls(url: url, library: library)
            }
            ToolbarItem {
                DictateButton()
            }
            ToolbarItem {
                Button {
                    NSFontManager.shared.orderFrontFontPanel(nil)
                } label: {
                    Label("Schrift", systemImage: "textformat")
                        .labelStyle(.titleAndIcon)
                }
                .help("Schrift und Farbe für den markierten Text (oder ⌘T)")
            }
            ToolbarItem {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Im Finder zeigen", systemImage: "folder")
                }
                .help("Datei im Finder zeigen")
            }
        }
    }
}

/// NSTextView in SwiftUI. Lädt die Datei, speichert Änderungen nach 1 Sekunde Pause.
struct RichTextView: NSViewRepresentable {
    let url: URL
    let library: Library
    let revision: Int
    @Binding var status: String
    @Binding var words: Int
    /// Vergrößerung wie die Schriftgröße in den Einstellungen (16 = 1,33-fach, ähnlich MacJournal).
    var zoom: Double = 1
    var highlight = ""

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Bewusst die ältere Textdarstellung (TextKit 1): Sie kann RTF-Listen und Bilder zuverlässig,
        // und das Einpassen der Bilder braucht sie ohnehin. Ein späterer Wechsel stört sonst die Anzeige.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.autoresizingMask = []  // Breite setzt fitWidth() (wegen der Vergrößerung)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        scroll.allowsMagnification = true
        scroll.magnification = zoom
        // Bei Vergrößerung ist der sichtbare Bereich schmaler: Textbreite daran anpassen, sonst laufen Zeilen rechts hinaus.
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.fitWidth),
                                                   name: name, object: scroll.contentView)
        }
        context.coordinator.scrollView = scroll
        textView.isRichText = true
        textView.importsGraphics = url.pathExtension.lowercased() == "rtfd"  // Bilder nur in RTFD
        textView.allowsImageEditing = true
        textView.usesFontPanel = true
        textView.usesRuler = true
        textView.allowsUndo = true
        textView.usesFindBar = true  // Suchen und Ersetzen (⌘F, ⌥⌘F)
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 24, height: 16)
        // RTF hat meist feste schwarze Schrift: darum immer weißes Papier, auch im dunklen Modus.
        textView.backgroundColor = .white
        textView.insertionPointColor = .black
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.load()
        context.coordinator.observeSpeech()
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.editorCommand(_:)),
                                               name: EditorCommand.notification, object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.insertAttachment(_:)),
                                               name: .insertAttachment, object: nil)
        // Fenster breiter/schmaler: Bilder neu einpassen.
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.fitImages),
                                               name: NSView.frameDidChangeNotification, object: textView)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if abs(nsView.magnification - zoom) > 0.01 {
            nsView.magnification = zoom
            context.coordinator.fitWidth()
        }
        if context.coordinator.highlighted != highlight { context.coordinator.applyHighlight() }
        // Datei wurde außerhalb geändert: neu lesen, wenn hier nichts ungespeichert ist.
        if context.coordinator.revision != revision {
            context.coordinator.revision = revision
            if !context.coordinator.dirty { context.coordinator.load() }
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.saveNow()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextView
        weak var textView: NSTextView?
        var revision: Int
        var dirty = false
        private var pending: DispatchWorkItem?

        init(_ parent: RichTextView) {
            self.parent = parent
            self.revision = parent.revision
        }

        func load() {
            guard let textView, let text = Library.readRich(parent.url)?.text else { return }
            textView.textStorage?.setAttributedString(text)
            // Leerer oder neuer Eintrag: gleich in MacJournal-Schrift schreiben.
            textView.typingAttributes = text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : Library.richTypingAttributes
            if parent.library.justCreated == parent.url {
                parent.library.justCreated = nil
                DispatchQueue.main.async {
                    textView.window?.makeFirstResponder(textView)
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                }
            }
            dirty = false
            countWords()
            fittedWidth = 0
            DispatchQueue.main.async {  // erst nach dem Layout ist die Breite bekannt
                self.fitWidth()
                self.fitImages()
                self.applyHighlight()
            }
        }

        private var fittedWidth: CGFloat = 0
        weak var scrollView: NSScrollView?

        /// Text so breit wie der sichtbare Bereich (in vergrößerten Koordinaten).
        @objc func fitWidth() {
            guard let scrollView, let textView else { return }
            let width = scrollView.contentView.bounds.width
            if width > 0, abs(textView.frame.width - width) > 0.5 {
                textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            }
        }
        var highlighted = ""

        private var speechWatch: AnyCancellable?

        /// Beim Vorlesen den gerade gelesenen Absatz hinterlegen und hinrollen (nur Anzeige).
        func observeSpeech() {
            speechWatch = Speaker.shared.$currentRange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] range in self?.showSpoken(range) }
        }

        private func showSpoken(_ range: NSRange?) {
            applyHighlight(scroll: false)  // alte Markierung weg, Suchtreffer bleiben
            guard Speaker.shared.speaking == parent.url, let range, let textView, let layout = textView.layoutManager,
                  NSMaxRange(range) <= (textView.textStorage?.length ?? 0) else { return }
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.2), forCharacterRange: range)
            textView.scrollRangeToVisible(range)
        }

        /// Fundstellen der Suche gelb hinterlegen (nur Anzeige, wird nicht gespeichert) und zur ersten springen.
        func applyHighlight(scroll: Bool = true) {
            highlighted = parent.highlight
            guard let textView, let layout = textView.layoutManager, let storage = textView.textStorage else { return }
            let all = NSRange(location: 0, length: storage.length)
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
            let text = storage.string as NSString
            var first: NSRange?
            for word in highlighted.split(separator: " ") where !word.isEmpty {
                var search = all
                while true {
                    let found = text.range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive], range: search)
                    guard found.location != NSNotFound else { break }
                    layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.6), forCharacterRange: found)
                    if first == nil || found.location < first!.location { first = found }
                    search = NSRange(location: NSMaxRange(found), length: all.length - NSMaxRange(found))
                }
            }
            if scroll, let first { textView.scrollRangeToVisible(first) }
        }

        /// Große Bilder (z. B. Fotos von Protokollen) auf die Fensterbreite verkleinern, wie MacJournal.
        /// Ändert nur die Anzeige; das Bild in der Datei bleibt in voller Größe.
        @objc func fitImages() {
            guard let textView, let storage = textView.textStorage else { return }
            let width = textView.bounds.width - textView.textContainerInset.width * 2 - 2 * (textView.textContainer?.lineFragmentPadding ?? 5)
            guard width > 100, abs(width - fittedWidth) > 10 else { return }
            fittedWidth = width
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                let image = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:))
                guard let image, image.size.width > 0 else {
                    // Kein Bild (z. B. Word-Datei): Symbol mit Dateinamen, wie MacJournal.
                    if let name = Self.fileName(of: attachment), !(attachment.attachmentCell is FileAttachmentCell) {
                        attachment.attachmentCell = FileAttachmentCell(name: name)
                    }
                    return
                }
                let scale = min(1, width / image.size.width)
                // Eigene Anzeige-Zelle mit verkleinerter Kopie; die Datei im Anhang bleibt unverändert.
                let shown = image.copy() as! NSImage
                shown.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                attachment.attachmentCell = NSTextAttachmentCell(imageCell: shown)
            }
            textView.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
            textView.needsDisplay = true
        }

        static func fileName(of attachment: NSTextAttachment) -> String? {
            attachment.fileWrapper?.preferredFilename ?? attachment.fileWrapper?.filename
        }

        /// Klick auf einen Anhang, der kein Bild ist: Datei mit der passenden App öffnen (z. B. .doc in ONLYOFFICE).
        func textView(_ textView: NSTextView, clickedOn cell: any NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
            guard cell is FileAttachmentCell, let attachment = cell.attachment else { return }
            open(attachment)
        }

        /// Doppelklick auf ein Bild oder eine Datei: mit der passenden App öffnen.
        func textView(_ textView: NSTextView, doubleClickedOn cell: any NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
            guard let attachment = cell.attachment else { return }
            open(attachment)
        }

        private func open(_ attachment: NSTextAttachment) {
            guard let name = Self.fileName(of: attachment) else { return }
            // Gespeicherter Anhang liegt im .rtfd-Ordner; sonst (gerade eingefügt) eine Kopie im Zwischenordner.
            var file = parent.url.appendingPathComponent(name)
            // Im verschlüsselten Eintrag ist die Datei im Ordner verschlüsselt: die entschlüsselte aus dem Text nehmen.
            if !FileManager.default.fileExists(atPath: file.path) || Vault.isEncrypted(parent.url), let wrapper = attachment.fileWrapper {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                file = dir.appendingPathComponent(name)
                guard (try? wrapper.write(to: file, options: [], originalContentsURL: nil)) != nil else { return }
            }
            NSWorkspace.shared.open(file)
        }

        /// Links auf andere MacJournal-Einträge (macjournal://<id>) hier in der App öffnen.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, url.scheme?.lowercased() == "macjournal", let id = url.host ?? url.pathComponents.last else { return false }
            NotificationCenter.default.post(name: .openMacJournalEntry, object: id)
            return true
        }

        @objc func editorCommand(_ note: Notification) {
            guard let textView, let command = EditorCommand.command(from: note, for: textView) else { return }
            if command == .split { split() } else { command.perform(on: textView) }
        }

        /// „Eintrag hier teilen“: Text ab dem Cursor wird ein neuer Eintrag.
        private func split() {
            guard let textView, let storage = textView.textStorage else { return }
            let start = textView.selectedRange().location
            let range = NSRange(location: start, length: storage.length - start)
            let tail = storage.attributedSubstring(from: range)
            guard !tail.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  textView.shouldChangeText(in: range, replacementString: "") else { NSSound.beep(); return }
            storage.replaceCharacters(in: range, with: "")
            textView.didChangeText()
            saveNow()
            do {
                let part = try parent.library.splitOff(rich: tail, from: parent.url)
                NotificationCenter.default.post(name: .selectEntry, object: part)
            } catch {
                parent.status = "Teilen ging nicht: \(error.localizedDescription)"
            }
        }

        /// Datei (Bild, Tonaufnahme, PDF …) an der Cursor-Stelle einfügen. Eine .rtf wird dafür zur .rtfd.
        @objc func insertAttachment(_ note: Notification) {
            guard let file = note.object as? URL, let textView, let window = textView.window,
                  window.isKeyWindow || window.isMainWindow,
                  let wrapper = try? FileWrapper(url: file, options: .immediate) else { return }
            wrapper.preferredFilename = file.lastPathComponent
            let attachment = NSTextAttachment(fileWrapper: wrapper)
            let insert = NSMutableAttributedString(attachment: attachment)
            insert.append(NSAttributedString(string: "\n", attributes: textView.typingAttributes))
            let range = textView.selectedRange()
            guard textView.shouldChangeText(in: range, replacementString: insert.string) else { return }
            textView.textStorage?.replaceCharacters(in: range, with: insert)
            textView.didChangeText()
            fittedWidth = 0
            fitImages()
            if parent.url.pathExtension.lowercased() == "rtf" {
                pending?.cancel()
                do {
                    let target = try parent.library.moveToRTFD(parent.url, text: textView.attributedString())
                    dirty = false
                    NotificationCenter.default.post(name: .entryMoved, object: [parent.url, target])
                } catch {
                    parent.status = "Anhang einfügen ging nicht: \(error.localizedDescription)"
                }
            } else {
                saveNow()
            }
        }

        private var countWork: DispatchWorkItem?

        /// Wörter zählen (kurz nach dem Tippen, nicht bei jedem Zeichen).
        func countWords() {
            countWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let text = self.textView?.string else { return }
                self.parent.words = Library.wordCount(text)
            }
            countWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        func textDidChange(_ notification: Notification) {
            countWords()
            dirty = true
            parent.status = "Ungespeichert …"
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.saveNow() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }

        func saveNow() {
            pending?.cancel()
            guard dirty, let text = textView?.attributedString() else { return }
            do {
                try parent.library.saveRich(text, to: parent.url)
                dirty = false
                parent.status = "Gespeichert"
            } catch {
                parent.status = "Speichern fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }
}

/// Anzeige eines Datei-Anhangs: Symbol der Dateiart, darunter der Name als Link (wie MacJournal).
/// Nur Anzeige; gespeichert wird weiter die Datei selbst.
final class FileAttachmentCell: NSTextAttachmentCell {
    private let name: String
    private let icon: NSImage
    private static let iconSize: CGFloat = 32
    private static let maxWidth: CGFloat = 220
    private var label: NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        return NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .paragraphStyle: style,
        ])
    }

    init(name: String) {
        self.name = name
        let ext = (name as NSString).pathExtension
        icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) { fatalError("nicht benutzt") }

    override func cellSize() -> NSSize {
        let width = min(Self.maxWidth, max(Self.iconSize, ceil(label.size().width) + 4))
        return NSSize(width: width, height: Self.iconSize + 4 + ceil(label.size().height))
    }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -4) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let iconRect = NSRect(x: cellFrame.midX - Self.iconSize / 2, y: cellFrame.minY, width: Self.iconSize, height: Self.iconSize)
        icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let textRect = NSRect(x: cellFrame.minX, y: iconRect.maxY + 4, width: cellFrame.width, height: cellFrame.height - Self.iconSize - 4)
        label.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }
}
