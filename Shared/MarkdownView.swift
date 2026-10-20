import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#else
import UIKit
typealias PlatformImage = UIImage
extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#endif

/// Leseansicht: zeigt Markdown schön an — Überschriften groß, **fett** als fett, Listen mit Punkten,
/// Tabellen als Tabelle. Der Kopf (`---` … `---`) wird nicht gezeigt.
/// Bewusst einfach gehalten: Zeilenweise Blöcke, innerhalb einer Zeile hilft `AttributedString(markdown:)`.
struct MarkdownView: View {
    let text: String
    var fontSize: Double = 16
    /// Suchbegriffe (durch Leerzeichen getrennt), gelb hinterlegt.
    var highlight = ""
    /// Block, der gerade vorgelesen wird: leicht hinterlegt, und die Ansicht rollt mit.
    var activeBlock: Int? = nil

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: fontSize * 0.6) {
                ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { number, block in
                    view(for: block)
                        .padding(.horizontal, number == activeBlock ? 6 : 0)
                        .background(number == activeBlock ? Color.accentColor.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .id(number)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .textSelection(.enabled)
        }
        .onChange(of: activeBlock) { _, block in
            guard let block else { return }
            withAnimation { proxy.scrollTo(block, anchor: .center) }
        }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let s):
            Text(inline(s))
                .font(.system(size: fontSize * [1.7, 1.35, 1.15, 1.05][min(level, 4) - 1], weight: level == 1 ? .bold : .semibold))
                .padding(.top, level <= 2 ? fontSize * 0.5 : fontSize * 0.2)
        case .paragraph(let s):
            Text(inline(s))
                .font(.system(size: fontSize))
                .lineSpacing(fontSize * 0.25)
        case .item(let marker, let indent, let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16, alignment: .trailing)
                Text(inline(s))
                    .lineSpacing(fontSize * 0.25)
            }
            .font(.system(size: fontSize))
            .padding(.leading, CGFloat(indent) * 18)
        case .quote(let s):
            Text(inline(s))
                .font(.system(size: fontSize))
                .italic()
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.tertiary).frame(width: 3)
                }
        case .rule:
            Divider().padding(.vertical, 4)
        case .image(let alt, let url):
            if url.isFileURL, let image = PlatformImage(contentsOfFile: url.path) {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: min(image.size.width, 760), alignment: .leading)
                    .help(alt)
                    #if os(macOS)
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                    #endif
            } else {
                Text(inline("[Bild: \(alt)](\(url.absoluteString))"))
                    .font(.system(size: fontSize))
            }
        case .code(let s):
            // Code nicht umbrechen (Spalten bleiben gerade); lange Zeilen seitlich scrollen.
            ScrollView(.horizontal) {
                Text(marked(AttributedString(s)))
                    .font(.system(size: fontSize * 0.9, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell))
                                .fontWeight(i == 0 ? .semibold : .regular)
                        }
                    }
                    if i == 0 { Divider() }
                }
            }
            .font(.system(size: fontSize * 0.95))
        }
    }

    /// Fett, kursiv, durchgestrichen, `Code` und Links innerhalb einer Zeile.
    private func inline(_ s: String) -> AttributedString {
        marked((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s))
    }

    /// Fundstellen der Suche gelb hinterlegen.
    private func marked(_ text: AttributedString) -> AttributedString {
        var text = text
        for word in highlight.split(separator: " ") where !word.isEmpty {
            var start = text.startIndex
            while start < text.endIndex,
                  let found = text[start...].range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive]) {
                text[found].backgroundColor = .yellow.opacity(0.6)
                start = found.upperBound
            }
        }
        return text
    }
}

enum MarkdownBlock {
    case heading(Int, String)
    case paragraph(String)
    case item(marker: String, indent: Int, String)
    case quote(String)
    case rule
    case code(String)
    case table([[String]])
    /// Bild in eigener Zeile: `![Text](file:///…)`. Nur lokale Dateien werden gezeigt, sonst ein Link.
    case image(String, URL)

    static func parse(_ raw: String) -> [MarkdownBlock] {
        var lines = raw.components(separatedBy: "\n")
        // Kopf mit datum usw. ausblenden.
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            lines.removeSubrange(0...end)
        }

        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))  // Zeilenumbruch bleibt Zeilenumbruch
                paragraph = []
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = (line.prefix { $0 == " " || $0 == "\t" }.count) / 2

            if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("```") {
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
            } else if let level = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level, trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if ["---", "***", "___"].contains(trimmed) {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("|") {
                flush()
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let cells = lines[i].trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                        .components(separatedBy: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    // Trennzeile |---|---| überspringen.
                    if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { rows.append(cells) }
                    i += 1
                }
                blocks.append(.table(rows))
                continue
            } else if trimmed.hasPrefix("!["), trimmed.hasSuffix(")"), let mid = trimmed.range(of: "]("),
                      let url = URL(string: String(trimmed[mid.upperBound..<trimmed.index(before: trimmed.endIndex)])) {
                flush()
                blocks.append(.image(String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<mid.lowerBound]), url))
            } else if trimmed.hasPrefix("> ") {
                flush()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flush()
                var rest = String(trimmed.dropFirst(2))
                var marker = "•"
                if rest.hasPrefix("[ ] ") { marker = "☐"; rest.removeFirst(4) }
                if rest.lowercased().hasPrefix("[x] ") { marker = "☑"; rest.removeFirst(4) }
                blocks.append(.item(marker: marker, indent: indent, rest))
            } else if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
                      trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.item(marker: String(trimmed[...dot]), indent: indent,
                                    String(trimmed[trimmed.index(dot, offsetBy: 2)...])))
            } else {
                paragraph.append(trimmed)
            }
            i += 1
        }
        flush()
        return blocks
    }

    private static func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), s.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return min(hashes, 4)
    }
}
