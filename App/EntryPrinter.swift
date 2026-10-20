import AppKit
import UniformTypeIdentifiers

/// Drucken und PDF am Mac: der Eintrag in einer Text-Ansicht, über die Seiten verteilt.
enum EntryPrinter {
    /// Druckdialog zeigen.
    static func print(_ url: URL, library: Library) {
        run(url, library: library, pdf: nil)
    }

    /// Erst fragen, wohin; dann als PDF sichern (ohne Druckdialog).
    static func savePDF(_ url: URL, library: Library) {
        let title = library.entries.first { $0.url == url }?.title ?? url.deletingPathExtension().lastPathComponent
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".pdf"
        panel.message = "Eintrag als PDF sichern"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        run(url, library: library, pdf: target)
    }

    private static func run(_ url: URL, library: Library, pdf: URL?) {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        for margin in [\NSPrintInfo.topMargin, \.bottomMargin, \.leftMargin, \.rightMargin] { info[keyPath: margin] = 50 }
        if let pdf {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = pdf
        }
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.backgroundColor = .white
        view.textStorage?.setAttributedString(library.printableText(url))
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            view.setFrameSize(NSSize(width: width, height: ceil(layout.usedRect(for: container).height) + 10))
        }
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = library.entries.first { $0.url == url }?.title ?? url.lastPathComponent
        operation.showsPrintPanel = pdf == nil
        operation.showsProgressPanel = pdf == nil
        operation.run()
    }
}
