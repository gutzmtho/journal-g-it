import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Eintrag als formatierter Text zum Drucken und für PDF: Titel, Datum (und Schlagwörter), dann der Text.
extension Library {
    func printableText(_ url: URL) -> NSAttributedString {
        let raw = read(url)
        let entry = entries.first { $0.url == url }
            ?? (Self.isRich(url) ? Self.parseRich(raw, url: url, title: Self.readRich(url)?.title) : Self.parse(raw, url: url))
        let base = PlatformFont.systemFont(ofSize: 12)
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: entry.title + "\n", attributes: [
            .font: PlatformFont.boldSystemFont(ofSize: 18), .foregroundColor: PlatformColor.black]))
        var meta = Self.longDayFormat.string(from: entry.date)
        if !entry.tags.isEmpty { meta += "  ·  " + entry.tags.joined(separator: ", ") }
        result.append(NSAttributedString(string: meta + "\n\n", attributes: [
            .font: PlatformFont.systemFont(ofSize: 10), .foregroundColor: PlatformColor.darkGray]))
        if Self.isRich(url) {
            if let text = Self.readRich(url)?.text { result.append(text) }
        } else {
            result.append(Self.markdownForPrint(raw, skipTitle: entry.title, base: base))
        }
        return result
    }

    /// Markdown schlicht gesetzt: Überschriften fett und größer, Listen mit •, fett/kursiv/Code im Text.
    /// Ohne Kopf (--- … ---) und ohne die Titel-Überschrift (die steht schon oben).
    static func markdownForPrint(_ raw: String, skipTitle: String, base: PlatformFont) -> NSAttributedString {
        var lines = raw.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...end) }
        if let i = lines.firstIndex(of: "# " + skipTitle) { lines.remove(at: i) }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }

        let black = PlatformColor.black
        let mono = PlatformFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular)
        let out = NSMutableAttributedString()
        var inCode = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || trimmed.hasPrefix("|") {
                out.append(NSAttributedString(string: line + "\n", attributes: [.font: mono, .foregroundColor: black]))
                continue
            }
            if ["---", "***", "___"].contains(trimmed) {
                out.append(NSAttributedString(string: "\n", attributes: [.font: base]))
                continue
            }
            var text = line
            var font = base
            var prefix = ""
            if line.hasPrefix("### ") {
                text = String(line.dropFirst(4)); font = .boldSystemFont(ofSize: base.pointSize + 1)
            } else if line.hasPrefix("## ") {
                text = String(line.dropFirst(3)); font = .boldSystemFont(ofSize: base.pointSize + 3)
            } else if line.hasPrefix("# ") {
                text = String(line.dropFirst(2)); font = .boldSystemFont(ofSize: base.pointSize + 5)
            } else if let r = line.range(of: #"^\s*[-*+] "#, options: .regularExpression) {
                let indent = String(line[r].prefix { $0 == " " || $0 == "\t" })
                prefix = indent + "•  "
                text = String(line[r.upperBound...])
            }
            out.append(NSAttributedString(string: prefix, attributes: [.font: font, .foregroundColor: black]))
            let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
            for run in parsed.runs {
                let intent = run.inlinePresentationIntent ?? []
                let runFont = Self.font(intent.contains(.code) ? mono : font,
                                   bold: intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized))
                out.append(NSAttributedString(string: String(parsed[run.range].characters),
                                              attributes: [.font: runFont, .foregroundColor: black]))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        }
        return out
    }
}
