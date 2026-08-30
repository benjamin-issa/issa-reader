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
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(model: ReaderModel, onSelect: @escaping (Int) -> Void) {
        self.model = model
        self.onSelect = onSelect
    }

    private struct Entry: Identifiable {
        let spineIndex: Int
        let title: String
        let depth: Int
        var id: Int { spineIndex }
    }

    private var entries: [Entry] {
        guard let package = model.package else { return [] }
        var seen = Set<Int>()
        var result: [Entry] = []

        for point in package.navigation {
            guard let index = package.spine.firstIndex(where: { $0.href == point.href }),
                  !seen.contains(index)
            else { continue }
            seen.insert(index)
            result.append(Entry(
                spineIndex: index,
                title: point.title.isEmpty ? "Chapter \(index + 1)" : point.title,
                depth: point.depth,
            ))
        }

        // A book with no usable navigation still needs a way to move around.
        if result.isEmpty {
            result = package.spine.indices.map {
                Entry(spineIndex: $0, title: "Section \($0 + 1)", depth: 0)
            }
        }
        return result
    }

    public var body: some View {
        List(entries) { entry in
            Button {
                onSelect(entry.spineIndex)
                dismiss()
            } label: {
                HStack {
                    Text(entry.title)
                        .font(entry.depth == 0 ? Typography.callout : Typography.footnote)
                        .foregroundStyle(entry.spineIndex == model.chapterIndex ? Palette.tangerine : Palette.ink)
                        .padding(.leading, CGFloat(entry.depth) * Metrics.spacing16)
                        .lineLimit(2)
                    Spacer()
                    if entry.spineIndex == model.chapterIndex {
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
