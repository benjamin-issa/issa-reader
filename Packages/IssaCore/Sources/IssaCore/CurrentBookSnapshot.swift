import Foundation

/// The small record the app writes and the widget reads.
///
/// Deliberately a plain file in the shared App Group container rather than the
/// library database. A widget extension is held to roughly 30 MB and must not
/// open a SQLite connection that a background download task may be writing to;
/// reading one small JSON file is bounded, predictable work.
public struct CurrentBookSnapshot: Codable, Sendable, Hashable {
    public var bookID: String
    public var title: String
    public var author: String
    public var chapter: String?
    /// 0...1 through the whole book.
    public var progress: Double
    /// Seconds of narration left, when the book has audio.
    public var remaining: TimeInterval?
    public var isPlaying: Bool
    /// Which book the cover file on disk actually belongs to.
    ///
    /// The cover is one shared file with no identity of its own, so without
    /// this the widget cannot tell that it is drawing the previous book's
    /// jacket under this book's title — and the publisher cannot tell whether
    /// it still needs to fetch. Kept beside the snapshot rather than in memory
    /// so it survives a cold launch, which in-memory state did not.
    public var coverBookID: String?
    /// Whether the cover beside this snapshot is the square audiobook art.
    ///
    /// The widget has one cover file and no other way to know its shape, so
    /// without this it sized every cover to the portrait aspect — which crops
    /// away a third of a square jacket on the medium family and more than half
    /// on the large one.
    public var coverIsSquare: Bool
    /// Other books in progress, most recently opened first, for the families
    /// with room to show them (medium draws the first, large up to four).
    /// Absent in a file 1.6.x wrote, which decodes to none.
    public var others: [OtherBook]
    public var updatedAt: Date

    public init(
        bookID: String, title: String, author: String, chapter: String? = nil,
        progress: Double, remaining: TimeInterval? = nil, isPlaying: Bool = false,
        coverBookID: String? = nil, coverIsSquare: Bool = false,
        others: [OtherBook] = [],
        updatedAt: Date = .now,
    ) {
        self.others = others
        self.coverBookID = coverBookID
        self.bookID = bookID
        self.title = title
        self.author = author
        self.chapter = chapter
        self.progress = progress
        self.remaining = remaining
        self.isPlaying = isPlaying
        self.coverIsSquare = coverIsSquare
        self.updatedAt = updatedAt
    }

    /// The line under the title on a small widget: "2h 18m left · Part 3",
    /// dropping whichever half is unknown, and the author when both are.
    ///
    /// The chapter is filtered rather than trusted. `ReaderModel.chapterTitle`
    /// falls back to the book's own title when no navigation entry matches the
    /// spine document — which is every plain EPUB — so an unfiltered chapter
    /// printed the title twice. An empty one is reachable too, from a table of
    /// contents anchor with no text, and left a dangling separator.
    /// Whether the cover file on disk belongs to this snapshot's book.
    public var hasMatchingCover: Bool { coverBookID == bookID }

    /// Rounded, once, for every surface. Truncating showed 99% beside a ring
    /// that had visibly closed.
    public var percent: Int { ReadingProgress.percent(progress) }

    /// The chapter worth showing, or nil. See `subtitle` for why it is filtered.
    public var displayChapter: String? {
        guard let chapter else { return nil }
        let trimmed = chapter.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == title ? nil : trimmed
    }

    /// "2h 18m left", or nil when there is less than a minute of it — below
    /// which `DurationText` floors to "0m".
    public var remainingText: String? {
        guard let remaining, remaining.isFinite, remaining >= 60 else { return nil }
        return DurationText.text(remaining) + " left"
    }

    public var subtitle: String {
        let parts = [remainingText, displayChapter].compactMap { $0 }
        return parts.isEmpty ? author : parts.joined(separator: " · ")
    }

    // Spelled out because the decoder below names them.
    enum CodingKeys: String, CodingKey {
        case bookID, title, author, chapter, progress, remaining, isPlaying
        case coverBookID, coverIsSquare, others, updatedAt
    }

    /// Decoded field by field, so a snapshot written by an older build still
    /// reads. The widget is a separate process and can be running against a
    /// file the previous version left behind; the synthesised decoder would
    /// fail the whole thing over one absent key and the widget would show its
    /// placeholder instead of the book.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookID = try container.decode(String.self, forKey: .bookID)
        title = try container.decode(String.self, forKey: .title)
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        chapter = try container.decodeIfPresent(String.self, forKey: .chapter)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        remaining = try container.decodeIfPresent(TimeInterval.self, forKey: .remaining)
        isPlaying = try container.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        coverBookID = try container.decodeIfPresent(String.self, forKey: .coverBookID)
        coverIsSquare = try container.decodeIfPresent(Bool.self, forKey: .coverIsSquare) ?? false
        // A file the previous version left has no list; a list with one
        // unreadable entry is no list, rather than no book.
        others = (try? container.decodeIfPresent([OtherBook].self, forKey: .others)) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
    }
}

/// A book in progress other than the current one, as the widget draws it:
/// medium's "Also reading" card and large's "Also in progress" row.
///
/// Its cover is not here. Each lives in its own file in the App Group named by
/// `bookID` (`CurrentBookSnapshotStore.otherCoverURL`), so the file's name is
/// its identity and a cover can never be drawn under another book's title —
/// the race the single shared cover needs `coverBookID` to guard against.
public struct OtherBook: Codable, Sendable, Hashable {
    public var bookID: String
    public var title: String
    public var author: String?
    /// 0...1 through the whole book.
    public var progress: Double
    public var coverIsSquare: Bool
    /// Whether the portrait cover has been asked for. These books are drawn
    /// only in portrait slots, so the portrait cover is asked for first; a
    /// square one stored by an earlier build was fetched without asking, and
    /// is looked for again once. Set when that ask has been answered, so a
    /// book with no portrait art is not asked again at every update. Absent
    /// in a snapshot written before this existed, which is what says "ask".
    public var portraitChecked: Bool?

    /// The most the snapshot carries: large's row.
    public static let limit = 4

    public init(
        bookID: String, title: String, author: String? = nil, progress: Double,
        coverIsSquare: Bool = false,
    ) {
        self.bookID = bookID
        self.title = title
        self.author = author
        self.progress = progress
        self.coverIsSquare = coverIsSquare
    }

    /// Whether a cover stored for this book is square and the book may have a
    /// portrait one that has not been asked for.
    public var needsPortraitCover: Bool { coverIsSquare && portraitChecked != true }

    /// Rounded the way the current book's is.
    public var percent: Int { ReadingProgress.percent(progress) }

    /// The books worth listing beside `currentID`: started, still on the
    /// Reading shelf (a finished book, or one a status moved to To read, is
    /// not "in progress"), never the reader's own files (the widget is
    /// outside the app, and PRIVACY.md says those go nowhere), most recently
    /// positioned first, at most `limit`.
    ///
    /// `existing` lends a book its known cover shape: the cover's real shape
    /// is learnt when it is fetched, and a rebuilt list must not forget it.
    /// A book not known yet is seeded portrait, and square only where an
    /// audiobook is all it has.
    public static func selection(
        from books: [Book], excluding currentID: String?, existing: [OtherBook] = [],
        limit: Int = OtherBook.limit,
    ) -> [OtherBook] {
        let known = Dictionary(existing.map { ($0.bookID, $0) }, uniquingKeysWith: { first, _ in first })
        // The first of a repeated uuid wins, in order: the widget's rows are
        // identified by book id, and a repeat would be a duplicate id.
        var seen = Set<String>()
        return LibraryDerivation(books: books).continueReading
            .filter {
                !$0.isLocal && $0.uuid != currentID
                    && LibraryArrangement.stage(of: $0) == .reading
            }
            .filter { seen.insert($0.uuid).inserted }
            .prefix(limit)
            .map {
                var other = OtherBook(
                    bookID: $0.uuid, title: $0.title, author: $0.byline.isEmpty ? nil : $0.byline,
                    progress: $0.position?.locator.totalProgression ?? 0,
                    // Drawn only in portrait slots, so the text's portrait art
                    // is what is asked for first; square is the fallback, and
                    // the first guess only for an audiobook with no text.
                    coverIsSquare: known[$0.uuid]?.coverIsSquare ?? !$0.mayHavePortraitCover)
                other.portraitChecked = known[$0.uuid]?.portraitChecked
                return other
            }
    }

    /// Whether `next` is worth a snapshot write and a widget reload over
    /// `old`: a different list (ids, in order, or a title) or any progress
    /// that moved by `threshold` (a fifth of a percent — under a page of a
    /// novel), mirroring the current book's rule.
    public static func worthWriting(
        old: [OtherBook], next: [OtherBook], threshold: Double = 0.002,
    ) -> Bool {
        guard old.map(\.bookID) == next.map(\.bookID) else { return true }
        return zip(old, next).contains {
            $0.title != $1.title || abs($0.progress - $1.progress) >= threshold
        }
    }
}

public enum CurrentBookSnapshotStore {
    /// Must match the App Group in every target's entitlements.
    public static let appGroup = "group.com.benjaminissa.issareader"
    /// The widget's kind, which the app has to name to reload it. A bare
    /// literal in two targets is a typo waiting to stop the widget updating.
    public static let widgetKind = "CurrentBook"
    private static let filename = "current-book.json"
    private static let coverFilename = "current-cover.jpg"

    /// A directory standing in for the App Group, for tests: `swift test` has
    /// no entitlement, so the real container does not exist there.
    nonisolated(unsafe) static var directoryOverride: URL?

    private static func containerURL(_ name: String) -> URL? {
        if let directoryOverride { return directoryOverride.appending(path: name) }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: name)
    }

    private static var url: URL? { containerURL(filename) }
    /// Where the app leaves a small cover for the widget to draw.
    ///
    /// A file rather than bytes inside the snapshot: JSON with a base64 image
    /// in it would be re-read and re-decoded on every timeline request, and the
    /// widget's memory ceiling is the scarce resource here.
    public static var coverURL: URL? { containerURL(coverFilename) }

    public static func writeCover(_ data: Data) {
        guard let coverURL else { return }
        try? data.write(to: coverURL, options: .atomic)
    }

    /// The same write, off the main thread. A JPEG landing in the App Group
    /// container is a temp-file create, a write and a rename; doing that on the
    /// thread laying out pages is what the detached wrapper here was for.
    public static func writeCoverOffMain(_ data: Data) async {
        await Task.detached(priority: .utility) { writeCover(data) }.value
    }

    public static func readCover() -> Data? {
        guard let coverURL else { return nil }
        return try? Data(contentsOf: coverURL)
    }

    public static func write(_ snapshot: CurrentBookSnapshot) {
        guard let url, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func read() -> CurrentBookSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CurrentBookSnapshot.self, from: data)
    }

    // MARK: Covers of the other books

    private static let otherCoverPrefix = "widget-cover-"

    /// Where one other book's cover lives. The book id is the file's name, so
    /// the file *is* its identity: whatever is there belongs to that book.
    public static func otherCoverURL(bookID: String) -> URL? {
        // A book id is a uuid, but this names a file: nothing that could
        // climb out of the container is let through.
        guard !bookID.isEmpty, !bookID.contains("/"), !bookID.contains("..") else { return nil }
        return containerURL("\(otherCoverPrefix)\(bookID).jpg")
    }

    public static func hasOtherCover(bookID: String) -> Bool {
        guard let url = otherCoverURL(bookID: bookID) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public static func writeOtherCover(_ data: Data, bookID: String) {
        guard let url = otherCoverURL(bookID: bookID) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Off the main thread, as `writeCoverOffMain`.
    public static func writeOtherCoverOffMain(_ data: Data, bookID: String) async {
        await Task.detached(priority: .utility) { writeOtherCover(data, bookID: bookID) }.value
    }

    public static func readOtherCover(bookID: String) -> Data? {
        guard let url = otherCoverURL(bookID: bookID) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Removes every other book's cover whose id is not in `keeping`, so a book
    /// that left the list does not leave its file in the container for good.
    public static func pruneOtherCovers(keeping: Set<String>) {
        guard let directory = containerURL("") else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(otherCoverPrefix) && name.hasSuffix(".jpg") {
            let id = String(name.dropFirst(otherCoverPrefix.count).dropLast(".jpg".count))
            if !keeping.contains(id) {
                try? FileManager.default.removeItem(at: directory.appending(path: name))
            }
        }
    }

    public static func clear() {
        if let url { try? FileManager.default.removeItem(at: url) }
        if let coverURL { try? FileManager.default.removeItem(at: coverURL) }
        pruneOtherCovers(keeping: [])
    }

    /// The URL that opens a book from a widget, a Spotlight result or Handoff.
    ///
    /// A custom scheme rather than a universal link: this app talks to whatever
    /// server its owner runs, so there is no domain to associate with.
    public static func deepLink(bookID: String) -> URL? {
        URL(string: "issareader://book/\(bookID)")
    }
}

public extension Book {
    /// Whether the book may have a portrait cover: any book but one whose
    /// only edition is the audiobook, whose art is square and nothing else.
    var mayHavePortraitCover: Bool {
        let formats = servableFormats
        return !(formats.contains(.audiobook) && !formats.contains(.ebook) && !formats.contains(.readaloud))
    }
}
