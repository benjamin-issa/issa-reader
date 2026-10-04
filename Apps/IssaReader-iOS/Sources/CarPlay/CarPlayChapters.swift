import Foundation
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

    /// The row being read: the last entry in the reader's spine item that
    /// starts at or before the page.
    ///
    /// By offset, the way `ReaderModel.title(inSpineItem:atOffset:)` names
    /// the chapter on screen, not by spine index alone. The rows are one per
    /// nav point, and a book that packs several chapters into one file
    /// distinguishes them only by fragment, so matching the spine index put
    /// the "now playing" mark on the file's first chapter whichever of them
    /// was being narrated.
    ///
    /// - Parameters:
    ///   - offset: where the page starts in the spine item's text.
    ///   - location: where a fragment starts in the laid-out spine item, or
    ///     nil when it is not laid out or not found. An entry with no
    ///     fragment starts at the top of its file.
    static func currentIndex(
        in entries: [Entry], spineIndex: Int, offset: Int,
        location: (String) -> Int?,
    ) -> Int? {
        var best: (index: Int, location: Int)?
        var first: Int?
        for (index, entry) in entries.enumerated() where entry.spineIndex == spineIndex {
            if first == nil { first = index }
            let start: Int? = entry.fragment.map(location) ?? 0
            guard let start, start <= offset else { continue }
            // `>=`, so of two entries at one place the later wins, as it does
            // in the reader's own title.
            if start >= (best?.location ?? -1) { best = (index, start) }
        }
        return best?.index ?? first
    }
}
