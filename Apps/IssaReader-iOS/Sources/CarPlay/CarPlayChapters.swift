import IssaEPUB

/// Chapter titles and jump targets for CarPlay's Up Next list, derived from an
/// EPUB's own navigation document.
///
/// A separate, small derivation from `ChapterListView`'s rather than a shared
/// one: `ChapterListView` is hand-verified SwiftUI serving the in-app Contents
/// sheet, and reusing its logic here would mean touching that file for a
/// CarPlay-only need. Duplication of a dozen lines costs less than the risk of
/// changing behaviour already working on screen.
enum CarPlayChapters {
    struct Entry {
        let spineIndex: Int
        let fragment: String?
        let title: String
    }

    /// One row per nav point, matched back to its spine item — not one row per
    /// spine item — because a book that packs many chapters into a few large
    /// files (Gutenberg's do) distinguishes them only by fragment, and rows per
    /// file would collapse a seventeen-chapter book to four that all open on
    /// page one.
    static func entries(for package: EPUBPackage) -> [Entry] {
        var result: [Entry] = []
        for point in package.navigation {
            guard let index = package.spine.firstIndex(where: { $0.href == point.href }) else { continue }
            result.append(Entry(
                spineIndex: index, fragment: point.fragment,
                title: point.title.isEmpty ? "Chapter \(result.count + 1)" : point.title,
            ))
        }
        // A book with no usable navigation still needs a way to move around.
        if result.isEmpty {
            result = package.spine.indices.map {
                Entry(spineIndex: $0, fragment: nil, title: "Section \($0 + 1)")
            }
        }
        return result
    }
}
