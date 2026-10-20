import SwiftUI
import UIKit
import QuickLook
import Combine

extension Notification.Name {
    /// „Im Eintrag suchen“ im Rich Text; object = URL des Eintrags.
    static let phoneFindInEntry = Notification.Name("JournalIT.phoneFindInEntry")
}

/// Ein Eintrag auf dem iPhone: lesen; „Bearbeiten“ schaltet zum Schreiben. Speichert von selbst nach 1 Sekunde Pause.
struct PhoneEntryView: View {
    @EnvironmentObject private var library: Library
    let url: URL
    var highlight = ""

    @State private var editing = false
    @State private var markdown = ""
    @State private var savedMarkdown = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var status = ""
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var speechSettings = false
    /// Suchleiste im Markdown-Text (Suchen und Ersetzen).
    @State private var findShown = false
    @State private var tagsShown = false
    @ObservedObject private var speaker = Speaker.shared
    @ObservedObject private var dictation = PhoneDictation.shared
    /// Markdown-Text beim Start des Diktats; das Gesagte kommt hinten dran.
    @State private var dictationBase = ""
    @AppStorage("fontSize") private var fontSize = 17.0

    private var isRich: Bool { Library.isRich(url) }

    var body: some View {
        Group {
            if isRich {
                PhoneRichTextView(url: url, library: library, editing: editing, zoom: fontSize / 16,
                                  highlight: editing ? "" : highlight, revision: library.externalRevision, status: $status)
            } else if editing {
                TextEditor(text: $markdown)
                    .font(.system(size: fontSize))
                    .padding(.horizontal, 8)
                    .findNavigator(isPresented: $findShown)
            } else {
                MarkdownView(text: markdown, fontSize: fontSize, highlight: highlight,
                             activeBlock: speaker.speaking == url ? speaker.currentBlock : nil)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Beim Diktieren: erkannter Text und Stopp.
            if dictation.target == url { DictationBar() }
            // Beim Vorlesen: Absatz zurück, Pause/Weiter, Absatz vor, Stopp.
            if speaker.speaking == url {
                HStack { SpeechControls(url: url, library: library) }
                    .font(.title2)
                    .buttonStyle(.bordered)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
        .sheet(isPresented: $tagsShown) {
            let entry = library.entries.first { $0.url == url }
            TagSheet(title: entry?.title ?? url.lastPathComponent, known: library.allTags.map(\.name),
                     tags: entry?.tags ?? []) { tags in
                tagsShown = false
                if let tags { try? library.setTags(url, tags) }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $speechSettings) {
            NavigationStack {
                Form { SpeechSettingsSection() }
                    .navigationTitle("Stimme und Tempo")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Fertig") { speechSettings = false } }
            }
            .presentationDetents([.medium, .large])
        }
        .navigationTitle(library.entries.first { $0.url == url }?.title ?? url.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if !editing { editing = true }
                    if speaker.speaking != nil { speaker.stop() }  // Vorlesen und Zuhören zugleich geht nicht
                    dictationBase = markdown
                    dictation.toggle(for: url)
                } label: {
                    Label("Diktieren", systemImage: dictation.target == url ? "mic.fill" : "mic")
                }
                .tint(dictation.target == url ? .red : nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(editing ? "Fertig" : "Bearbeiten") {
                    if editing { saveMarkdownNow() }
                    editing.toggle()
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(speaker.speaking == url ? "Vorlesen beenden" : "Vorlesen",
                       systemImage: speaker.speaking == url ? "stop.circle" : "speaker.wave.2") {
                    speaker.toggle(url, library: library)
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                let flagged = library.entries.first { $0.url == url }?.flagged ?? false
                Button(flagged ? "Markierung entfernen" : "Markieren", systemImage: flagged ? "flag.slash" : "flag") {
                    if editing { saveMarkdownNow() }
                    try? library.setFlag(url, !flagged)
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Schlagwörter …", systemImage: "tag") {
                    if editing { saveMarkdownNow() }
                    tagsShown = true
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Drucken oder PDF …", systemImage: "printer") {
                    if editing { saveMarkdownNow() }
                    printEntry()
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Stimme und Tempo …", systemImage: "waveform") { speechSettings = true }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(editing ? "Suchen und Ersetzen" : "Im Eintrag suchen", systemImage: "text.magnifyingglass") {
                    if isRich {
                        NotificationCenter.default.post(name: .phoneFindInEntry, object: url)
                    } else {
                        editing = true
                        findShown = true
                    }
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Umbenennen", systemImage: "pencil.line") {
                    newTitle = library.entries.first { $0.url == url }?.title ?? ""
                    renaming = true
                }
            }
            if !status.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .alert("Eintrag umbenennen", isPresented: $renaming) {
            TextField("Titel", text: $newTitle)
            Button("OK") { _ = try? library.renameEntry(url, to: newTitle) }
            Button("Abbrechen", role: .cancel) {}
        }
        .onAppear {
            if !isRich { loadMarkdown() }
            if library.justCreated == url {
                editing = true
                library.justCreated = nil
            }
        }
        .onChange(of: markdown) { _, _ in scheduleMarkdownSave() }
        .onChange(of: dictation.transcript) { _, text in
            guard dictation.target == url else { return }
            if isRich {
                NotificationCenter.default.post(name: .phoneDictationText, object: url, userInfo: ["text": text])
            } else {
                let gap = dictationBase.isEmpty || dictationBase.hasSuffix("\n") || dictationBase.hasSuffix(" ") ? "" : " "
                markdown = dictationBase + gap + text
            }
        }
        .onChange(of: dictation.target) { old, new in
            guard old == url, new != url else { return }
            if isRich {
                NotificationCenter.default.post(name: .phoneDictationText, object: url, userInfo: ["done": true])
            } else {
                saveMarkdownNow()
            }
        }
        .alert("Diktieren", isPresented: Binding(get: { dictation.problem != nil }, set: { if !$0 { dictation.problem = nil } })) {
            Button("OK") { dictation.problem = nil }
        } message: { Text(dictation.problem ?? "") }
        .onChange(of: library.externalRevision) { _, _ in
            if !isRich && markdown == savedMarkdown { loadMarkdown() }
        }
        .onDisappear {
            if dictation.target == url { dictation.stop() }
            saveMarkdownNow()
            if speaker.speaking == url { speaker.stop() }
        }
    }

    /// Druckvorschau von iOS; dort lässt sich der Eintrag auch als PDF teilen oder sichern (Teilen-Knopf).
    private func printEntry() {
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = library.entries.first { $0.url == url }?.title ?? url.lastPathComponent
        info.outputType = .general
        let formatter = UISimpleTextPrintFormatter(attributedText: library.printableText(url))
        formatter.perPageContentInsets = UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50)
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = formatter
        controller.present(animated: true)
    }

    // MARK: Markdown

    private func loadMarkdown() {
        let text = library.read(url)
        markdown = text
        savedMarkdown = text
    }

    private func scheduleMarkdownSave() {
        guard !isRich, markdown != savedMarkdown else { return }
        status = "Ungespeichert …"
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await MainActor.run { saveMarkdownNow() }
        }
    }

    private func saveMarkdownNow() {
        guard !isRich, markdown != savedMarkdown else { return }
        do {
            try library.save(markdown, to: url)
            savedMarkdown = markdown
            status = "Gespeichert"
        } catch {
            status = "Speichern fehlgeschlagen"
        }
    }
}

/// RTF/RTFD in einer UITextView: Schriften, Farben, Bilder, Listen wie am Mac.
/// iOS liest Mac-RTF schon um 4/3 größer (12 pt → 16 pt) und vermerkt das beim Speichern (\cocoatextscaling1),
/// der Mac rechnet es zurück. Darüber hinaus wird nach der Schriftgröße-Einstellung vergrößert und beim Speichern
/// zurückgerechnet (auf halbe Punkte gerundet, damit keine krummen Größen entstehen).
struct PhoneRichTextView: UIViewRepresentable {
    let url: URL
    let library: Library
    let editing: Bool
    let zoom: Double
    let highlight: String
    let revision: Int
    @Binding var status: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        // Ältere Textdarstellung (TextKit 1), wie am Mac: zeigt RTF-Listen richtig.
        let textView = UITextView(usingTextLayoutManager: false)
        textView.isFindInteractionEnabled = true  // Suchen (und beim Bearbeiten Ersetzen)
        textView.backgroundColor = .white  // RTF hat meist feste schwarze Schrift
        textView.allowsEditingTextAttributes = true  // fett, kursiv, unterstrichen im Bearbeiten-Menü
        textView.dataDetectorTypes = [.link]
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.load()
        context.coordinator.observeSpeech()
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.find(_:)),
                                               name: .phoneFindInEntry, object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.dictated(_:)),
                                               name: .phoneDictationText, object: nil)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let c = context.coordinator
        let editingChanged = c.parent.editing != editing
        let needsReload = c.parent.zoom != zoom || c.parent.highlight != highlight || (c.revision != revision && !c.dirty)
        c.parent = self
        c.revision = revision
        if editingChanged {
            if !editing { c.saveNow() }
            textView.isEditable = editing
            c.load()  // ohne Suchmarkierung zum Schreiben, mit Markierung zum Lesen
            if editing { textView.becomeFirstResponder() }
        } else if needsReload {
            c.load()
        }
    }

    static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
        coordinator.saveNow()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PhoneRichTextView
        weak var textView: UITextView?
        var revision: Int
        var dirty = false
        private var pending: DispatchWorkItem?

        init(_ parent: PhoneRichTextView) {
            self.parent = parent
            self.revision = parent.revision
        }

        /// Wo der diktierte Text steht (wird bei jedem neuen Stück ersetzt); nil = kein Diktat.
        private var dictationRange: NSRange?

        /// Diktierten Text an der Cursor-Stelle einsetzen und laufend aktualisieren.
        @objc func dictated(_ note: Notification) {
            guard note.object as? URL == parent.url, let textView, let storage = textView.textStorage as NSTextStorage? else { return }
            if note.userInfo?["done"] as? Bool == true {
                dictationRange = nil
                return
            }
            guard let text = note.userInfo?["text"] as? String, !text.isEmpty else { return }
            if dictationRange == nil {
                var start = textView.isFirstResponder ? textView.selectedRange : NSRange(location: storage.length, length: 0)
                start.location = min(start.location, storage.length)
                start.length = min(start.length, storage.length - start.location)
                dictationRange = start
            }
            guard var range = dictationRange, NSMaxRange(range) <= storage.length else { dictationRange = nil; return }
            // Leerzeichen davor, wenn direkt an ein Wort angeschlossen würde.
            let before = range.location > 0 ? (storage.string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) : "\n"
            let gap = before == " " || before == "\n" || before == "\t" ? "" : " "
            let inserted = NSAttributedString(string: gap + text, attributes: textView.typingAttributes)
            storage.replaceCharacters(in: range, with: inserted)
            range.length = inserted.length
            dictationRange = range
            textView.selectedRange = NSRange(location: NSMaxRange(range), length: 0)
            textView.scrollRangeToVisible(textView.selectedRange)
            textViewDidChange(textView)
        }

        @objc func find(_ note: Notification) {
            guard note.object as? URL == parent.url, let textView else { return }
            textView.findInteraction?.presentFindNavigator(showingReplace: textView.isEditable)
        }

        func load() {
            guard let textView, let doc = Library.readRich(parent.url) else { return }
            let shown = NSMutableAttributedString(attributedString: Self.scaled(doc.text, by: parent.zoom))
            fitImages(in: shown, width: textView.bounds.width > 0 ? textView.bounds.width - 24 : UIScreen.main.bounds.width - 24)
            if !parent.highlight.isEmpty { mark(parent.highlight, in: shown) }
            textView.attributedText = shown
            textView.isEditable = parent.editing
            textView.typingAttributes = shown.length > 0
                ? shown.attributes(at: 0, effectiveRange: nil)
                : Self.scaledAttributes(Library.richTypingAttributes, by: parent.zoom)
            dirty = false
            spokenRange = nil
            showSpoken(Speaker.shared.currentRange)
        }

        private var speechWatch: AnyCancellable?
        private var spokenRange: NSRange?

        /// Beim Vorlesen den gerade gelesenen Absatz hinterlegen und hinrollen (nur beim Lesen, nicht beim Schreiben).
        func observeSpeech() {
            speechWatch = Speaker.shared.$currentRange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] range in self?.showSpoken(range) }
        }

        private func showSpoken(_ range: NSRange?) {
            guard let textView, !parent.editing else { return }
            let storage = textView.textStorage
            if let old = spokenRange, NSMaxRange(old) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: old)
                if !parent.highlight.isEmpty { mark(parent.highlight, in: storage) }
            }
            spokenRange = nil
            guard Speaker.shared.speaking == parent.url, let range, NSMaxRange(range) <= storage.length else { return }
            storage.addAttribute(.backgroundColor, value: UIColor.tintColor.withAlphaComponent(0.2), range: range)
            spokenRange = range
            textView.scrollRangeToVisible(range)
        }

        /// Alle Schriften um einen Faktor vergrößern/verkleinern.
        static func scaled(_ text: NSAttributedString, by factor: Double, roundToHalf: Bool = false) -> NSAttributedString {
            let result = NSMutableAttributedString(attributedString: text)
            result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { value, range, _ in
                let font = (value as? UIFont) ?? UIFont(name: "Helvetica", size: 16)!
                var size = font.pointSize * factor
                if roundToHalf { size = (size * 2).rounded() / 2 }
                result.addAttribute(.font, value: font.withSize(size), range: range)
            }
            return result
        }

        static func scaledAttributes(_ attributes: [NSAttributedString.Key: Any], by factor: Double) -> [NSAttributedString.Key: Any] {
            var result = attributes
            if let font = attributes[.font] as? UIFont { result[.font] = font.withSize(font.pointSize * factor) }
            return result
        }

        /// Große Bilder auf Bildschirmbreite verkleinern (nur Anzeige).
        private func fitImages(in text: NSMutableAttributedString, width: CGFloat) {
            var badges: [(NSRange, FileBadgeAttachment)] = []
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                let image = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap(UIImage.init(data:))
                guard let image, image.size.width > 0 else {
                    // Kein Bild (z. B. Word-Datei): Symbol mit Dateinamen, wie MacJournal. Antippen öffnet die Vorschau.
                    // Eigene Anhang-Art, weil iOS beim Setzen eines Bildes die Datei durch „Attachment.png“ ersetzt.
                    if let wrapper = attachment.fileWrapper, let name = Self.fileName(of: attachment) {
                        let badge = FileBadgeAttachment(original: wrapper)
                        let shown = Self.fileBadge(name: name, file: parent.url.appendingPathComponent(name))
                        badge.image = shown
                        badge.bounds = CGRect(origin: CGPoint(x: 0, y: -6), size: shown.size)
                        badges.append((range, badge))
                    }
                    return
                }
                let scale = min(1, width / image.size.width)
                let bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
                if attachment.image == nil, let wrapper = attachment.fileWrapper {
                    // Bild aus der Datei: ebenfalls eigene Anhang-Art, damit die Datei ihren Namen behält.
                    let shown = FileBadgeAttachment(original: wrapper)
                    shown.image = image
                    shown.bounds = bounds
                    badges.append((range, shown))
                } else {
                    attachment.bounds = bounds
                }
            }
            for (range, badge) in badges { text.addAttribute(.attachment, value: badge, range: range) }
        }

        /// Vor dem Speichern: Datei-Anhänge wieder mit der Originaldatei statt dem Anzeigebild.
        private static func restoringFiles(_ text: NSAttributedString) -> NSAttributedString {
            let result = NSMutableAttributedString(attributedString: text)
            var originals: [(NSRange, NSTextAttachment)] = []
            result.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.length)) { value, range, _ in
                guard let badge = value as? FileBadgeAttachment else { return }
                let attachment = NSTextAttachment()
                attachment.fileWrapper = badge.original
                originals.append((range, attachment))
            }
            for (range, attachment) in originals { result.addAttribute(.attachment, value: attachment, range: range) }
            return result
        }

        private func mark(_ query: String, in text: NSMutableAttributedString) {
            let string = text.string as NSString
            for word in query.split(separator: " ") where !word.isEmpty {
                var search = NSRange(location: 0, length: string.length)
                while true {
                    let found = string.range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive], range: search)
                    guard found.location != NSNotFound else { break }
                    text.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.6), range: found)
                    search = NSRange(location: NSMaxRange(found), length: string.length - NSMaxRange(found))
                }
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            dirty = true
            parent.status = "Ungespeichert …"
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.saveNow() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }

        func saveNow() {
            pending?.cancel()
            guard dirty, let text = textView?.attributedText else { return }
            do {
                try parent.library.saveRich(Self.restoringFiles(Self.scaled(text, by: 1 / parent.zoom, roundToHalf: true)), to: parent.url)
                dirty = false
                parent.status = "Gespeichert"
            } catch {
                parent.status = "Speichern fehlgeschlagen"
            }
        }

        static func fileName(of attachment: NSTextAttachment) -> String? {
            let wrapper = (attachment as? FileBadgeAttachment)?.original ?? attachment.fileWrapper
            return wrapper?.preferredFilename ?? wrapper?.filename
        }

        /// Bild für einen Datei-Anhang: Symbol der Dateiart, darunter der Name als Link.
        static func fileBadge(name: String, file: URL) -> UIImage {
            let icon = UIDocumentInteractionController(url: file).icons.last
                ?? UIImage(systemName: "doc.fill")!.withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingMiddle
            let label = NSAttributedString(string: name, attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.link,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .paragraphStyle: style,
            ])
            let iconSize: CGFloat = 40
            let textHeight = ceil(label.size().height)
            let width = min(240, max(iconSize, ceil(label.size().width) + 4))
            let size = CGSize(width: width, height: iconSize + 4 + textHeight)
            return UIGraphicsImageRenderer(size: size).image { _ in
                icon.draw(in: CGRect(x: (width - iconSize) / 2, y: 0, width: iconSize, height: iconSize))
                label.draw(with: CGRect(x: 0, y: iconSize + 4, width: width, height: textHeight),
                           options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            }
        }

        /// Datei eines Anhangs zeigen (Vorschau; von dort „Teilen“ → in anderer App öffnen).
        private func preview(_ attachment: NSTextAttachment) {
            guard let name = Self.fileName(of: attachment), let textView else { return }
            var file = parent.url.appendingPathComponent(name)
            // Im verschlüsselten Eintrag ist die Datei im Ordner verschlüsselt: die entschlüsselte aus dem Text nehmen.
            if !FileManager.default.fileExists(atPath: file.path) || Vault.isEncrypted(parent.url),
               let wrapper = (attachment as? FileBadgeAttachment)?.original ?? attachment.fileWrapper {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                file = dir.appendingPathComponent(name)
                guard (try? wrapper.write(to: file, options: [], originalContentsURL: nil)) != nil else { return }
            }
            var top = textView.window?.rootViewController
            while let next = top?.presentedViewController { top = next }
            let controller = QLPreviewController()
            let source = PreviewSource(file)
            controller.dataSource = source
            previewSource = source
            top?.present(controller, animated: true)
        }

        private var previewSource: PreviewSource?

        /// Anhang antippen: Datei-Anhänge und Bilder in der Vorschau öffnen. Links auf andere
        /// MacJournal-Einträge (macjournal://<id>) in der App öffnen.
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            if case .textAttachment(let attachment) = textItem.content, !parent.editing {
                return UIAction { [weak self] _ in self?.preview(attachment) }
            }
            guard case .link(let url) = textItem.content, url.scheme?.lowercased() == "macjournal" else { return defaultAction }
            let id = url.host ?? url.lastPathComponent
            return UIAction { _ in NotificationCenter.default.post(name: .openMacJournalEntry, object: id) }
        }
    }
}

/// Liefert der Vorschau (QuickLook) genau eine Datei.
final class PreviewSource: NSObject, QLPreviewControllerDataSource {
    let url: URL
    init(_ url: URL) { self.url = url }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
}

/// Anhang in der Anzeige: zeigt ein Bild (Foto oder Symbol mit Namen), merkt sich aber die Originaldatei.
/// iOS ersetzt sonst beim Setzen des Bildes die Datei durch „Attachment.png“.
final class FileBadgeAttachment: NSTextAttachment {
    let original: FileWrapper
    init(original: FileWrapper) {
        self.original = original
        super.init(data: nil, ofType: nil)
    }
    required init?(coder: NSCoder) { fatalError("nicht benutzt") }
}
