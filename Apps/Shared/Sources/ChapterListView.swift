import IssaEPUB
import IssaUI
import SwiftUI

/// The table of contents, with where you are in it.
///
/// Built from the EPUB's own navigation document, falling back to the NCX for
/// older books. Entries whose target is not in the spine are dropped rather than
/// shown as dead rows.
public struct ChapterListView: View {
    let model: ReaderModel
    let onSelect: (Int, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(model: ReaderModel, onSelect: @escaping (Int, String?) -> Void) {
        self.model = model
        self.onSelect = onSelect
    }

    private struct Entry: Identifiable {
        let spineIndex: Int
        let fragment: String?
        let title: String
        let depth: Int
        let id: Int
    }

    private var entries: [Entry] {
        guard let package = model.package else { return [] }
        var result: [Entry] = []

        // One row per nav point, not per spine item. Books that pack many
        // chapters into a few large files distinguish them only by fragment, so
        // deduping by spine index collapses a seventeen-chapter book to four
        // rows that all open on page one.
        for point in package.navigation {
            guard let index = package.spine.firstIndex(where: { $0.href == point.href }) else { continue }
            result.append(Entry(
                spineIndex: index,
                fragment: point.fragment,
                title: point.title.isEmpty ? "Chapter \(result.count + 1)" : point.title,
                depth: point.depth,
                id: result.count,
            ))
        }

        // A book with no usable navigation still needs a way to move around.
        if result.isEmpty {
            result = package.spine.indices.map {
                Entry(spineIndex: $0, fragment: nil, title: "Section \($0 + 1)", depth: 0, id: $0)
            }
        }
        return result
    }

    /// Which row to mark. With several rows per spine item, the marker belongs
    /// on the one the reader is actually inside, not on every row for the file.
    private func isCurrent(_ entry: Entry) -> Bool {
        guard entry.spineIndex == model.chapterIndex else { return false }
        let siblings = entries.filter { $0.spineIndex == model.chapterIndex }
        guard siblings.count > 1 else { return true }

        let visible = model.visibleFragments()
        if let match = siblings.last(where: { row in
            row.fragment.map { visible.contains($0) } ?? false
        }) {
            return match.id == entry.id
        }
        return siblings.first?.id == entry.id
    }

    public var body: some View {
        List(entries) { entry in
            Button {
                onSelect(entry.spineIndex, entry.fragment)
                dismiss()
            } label: {
                HStack {
                    Text(entry.title)
                        .font(entry.depth == 0 ? Typography.callout : Typography.footnote)
                        .foregroundStyle(isCurrent(entry) ? Palette.tangerine : Palette.ink)
                        .padding(.leading, CGFloat(entry.depth) * Metrics.spacing16)
                        .lineLimit(2)
                    Spacer()
                    if isCurrent(entry) {
                        Image(systemName: "book.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.tangerine)
                    }
                }
            }
            .buttonStyle(.plain)
            .listRowBackground(Palette.surface)
        }
        .paperListBackground()
        .navigationTitle("Contents")
    }
}
