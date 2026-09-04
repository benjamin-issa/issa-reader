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

    /// Built once, from the package, rather than recomputed inside `body`.
    ///
    /// It used to be a computed property — and `isCurrent(_:)` called it again,
    /// twice per rendered row. Opening the contents of a book with 400 nav
    /// points meant 800 rebuilds of a 400-entry array, each one scanning the
    /// whole spine per entry, and 800 calls to `visibleFragments()`, which
    /// walks the current page's attributes. On the main actor, while the list
    /// was trying to appear.
    @State private var entries: [Entry] = []

    public init(model: ReaderModel, onSelect: @escaping (Int, String?) -> Void) {
        self.model = model
        self.onSelect = onSelect
    }

    /// What has to change for the rows to be rebuilt.
    private struct Key: Equatable {
        let book: String
        let spine: Int
    }

    struct Entry: Identifiable {
        let spineIndex: Int
        let fragment: String?
        let title: String
        let depth: Int
        let id: Int
    }

    /// - Parameter package: the open book, or nil before it opens.
    static func build(from package: EPUBPackage?) -> [Entry] {
        guard let package else { return [] }

        // href → first spine index, built once. `firstIndex(where:)` per nav
        // point made this quadratic, and books that pack many chapters into a
        // few files have the most nav points of all.
        var spineIndexByHref: [String: Int] = [:]
        spineIndexByHref.reserveCapacity(package.spine.count)
        for (index, item) in package.spine.enumerated() where spineIndexByHref[item.href] == nil {
            spineIndexByHref[item.href] = index
        }

        var result: [Entry] = []
        // One row per nav point, not per spine item. Books that pack many
        // chapters into a few large files distinguish them only by fragment, so
        // deduping by spine index collapses a seventeen-chapter book to four
        // rows that all open on page one.
        for point in package.navigation {
            guard let index = spineIndexByHref[point.href] else { continue }
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
    ///
    /// Resolved once per body rather than once per row: the answer is a single
    /// id, and asking it of each row separately is what made
    /// `visibleFragments()` run hundreds of times per appearance.
    private var currentID: Int? {
        let siblings = entries.filter { $0.spineIndex == model.chapterIndex }
        guard siblings.count > 1 else { return siblings.first?.id }

        let visible = model.visibleFragments()
        if let match = siblings.last(where: { row in
            row.fragment.map { visible.contains($0) } ?? false
        }) {
            return match.id
        }
        return siblings.first?.id
    }

    public var body: some View {
        let current = currentID
        List(entries) { entry in
            Button {
                onSelect(entry.spineIndex, entry.fragment)
                dismiss()
            } label: {
                HStack {
                    Text(entry.title)
                        .font(entry.depth == 0 ? Typography.callout : Typography.footnote)
                        .foregroundStyle(entry.id == current ? Palette.tangerine : Palette.ink)
                        .padding(.leading, CGFloat(entry.depth) * Metrics.spacing16)
                        .lineLimit(2)
                    Spacer()
                    if entry.id == current {
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
        // Keyed rather than `onAppear`, and on the spine as well as the book.
        // The sheet outlives a chapter change, so a reader who opens a
        // different book through it must not be shown the previous book's
        // chapters — and someone who opens the contents while the book is
        // still being read off disk must not be left with the empty list they
        // would get from a one-shot build that ran before `package` arrived.
        .task(id: Key(book: model.book.uuid, spine: model.package?.spine.count ?? 0)) {
            entries = Self.build(from: model.package)
        }
    }
}
