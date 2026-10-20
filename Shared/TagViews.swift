import SwiftUI

/// Dialog „Schlagwörter“: vorhandene entfernen (×), neue eintippen oder aus den schon benutzten wählen.
struct TagSheet: View {
    let title: String
    /// Alle schon benutzten Schlagwörter (zum Antippen).
    let known: [String]
    @State var tags: [String]
    let done: ([String]?) -> Void
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Schlagwörter").font(.headline)
            Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)

            if tags.isEmpty {
                Text("Noch keine Schlagwörter.").foregroundStyle(.secondary)
            } else {
                FlowLayout {
                    ForEach(tags, id: \.self) { tag in
                        Button { tags.removeAll { $0 == tag } } label: {
                            HStack(spacing: 4) {
                                Text(tag)
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                        .help("„\(tag)“ entfernen")
                        .accessibilityLabel("\(tag), entfernen")
                    }
                }
            }

            HStack {
                TextField("Neues Schlagwort", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Hinzufügen", action: add)
                    .disabled(Library.cleanTag(newTag).isEmpty)
            }

            let unused = known.filter { k in !tags.contains { $0.caseInsensitiveCompare(k) == .orderedSame } }
                .filter { newTag.isEmpty || $0.localizedCaseInsensitiveContains(newTag) }
            if !unused.isEmpty {
                Text("Schon benutzt – antippen zum Hinzufügen:").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    FlowLayout {
                        ForEach(unused, id: \.self) { tag in
                            Button { tags.append(tag); newTag = "" } label: {
                                Text(tag)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().stroke(Color.secondary.opacity(0.5)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Sichern") {
                    add()
                    done(tags)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 380, idealWidth: 440)
    }

    private func add() {
        let tag = Library.cleanTag(newTag)
        newTag = ""
        guard !tag.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        // Schon benutzte Schreibweise übernehmen („lubeca“ → „Lubeca“).
        tags.append(known.first { $0.caseInsensitiveCompare(tag) == .orderedSame } ?? tag)
    }
}

/// Wofür der Schlagwort-Dialog offen ist.
struct TagRequest: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Einfaches Fließ-Layout: Elemente nebeneinander, bei Platzmangel in die nächste Zeile.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map { $0.height }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
