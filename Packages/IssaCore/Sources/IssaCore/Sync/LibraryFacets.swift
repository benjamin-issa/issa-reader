import Foundation

/// How many books sit on each shelf, counted once.
///
/// The library's shelf chips each carry a number, and computing those the
/// obvious way — asking `arrangedBooks` per chip — is ruinous: `arrangedBooks`
/// builds a `BookContentService` on every access, and the downloaded shelf then
/// asks the filesystem once per book *per format*. Six chips reading their
/// counts in a view body is thousands of syscalls per scrolled frame.
///
/// So: one pass, no filesystem, no network. The on-disk answer is injected as a
/// set gathered from a single directory read.
public struct LibraryFacets: Sendable, Equatable {
    /// The whole library, not the filtered view. "142 books" means the library;
    /// each shelf's own number is on its chip.
    public let total: Int
    public let shelfCounts: [LibraryArrangement.Shelf: Int]
    /// Sorted by count descending, then name — the same order the tag menu
    /// already used.
    public let tagCounts: [TagCount]

    public struct TagCount: Sendable, Hashable {
        public let name: String
        public let count: Int

        public init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

    public static let empty = LibraryFacets(books: [], downloadedUUIDs: [])

    public init(books: [Book], downloadedUUIDs: Set<String>) {
        total = books.count

        var shelves: [LibraryArrangement.Shelf: Int] = [.all: books.count]
        var tags: [String: Int] = [:]

        for book in books {
            // Once per book, not once per shelf: the three stage filters each
            // called this separately.
            switch LibraryArrangement.stage(of: book) {
            case .reading: shelves[.reading, default: 0] += 1
            case .toRead: shelves[.toRead, default: 0] += 1
            case .finished: shelves[.finished, default: 0] += 1
            }
            // The same predicate the shelf filter uses, so a chip's number can
            // never disagree with the grid beneath it.
            if book.hasReadalong || book.audiobook != nil {
                shelves[.withNarration, default: 0] += 1
            }
            if downloadedUUIDs.contains(book.uuid) {
                shelves[.downloaded, default: 0] += 1
            }
            for tag in book.tags { tags[tag.name, default: 0] += 1 }
        }

        shelfCounts = shelves
        tagCounts = tags
            .map { TagCount(name: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    public func count(_ shelf: LibraryArrangement.Shelf) -> Int {
        shelfCounts[shelf] ?? 0
    }
}
