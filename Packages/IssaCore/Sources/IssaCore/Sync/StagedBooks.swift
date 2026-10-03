import Foundation

public extension LibraryRails {
    /// How many books a tag needs before it is a place to go.
    ///
    /// A tag on one book is a label, not a shelf: its page would hold the
    /// book the reader came from and nothing else. The same floor decides
    /// which tags get a Browse rail and which chips on a book's page link to
    /// the tag's page, so the two can never disagree about a tag.
    static let minimumBooksPerTag = 2
}

/// A cut of the library grouped by reading stage: what the tag page and the
/// "More by" page show.
///
/// In-progress first, then unread, then finished — the order a reader decides
/// what to pick up next in, which is what a page of books sharing a tag or an
/// author is for. The stages are the library's own (`LibraryArrangement.stage`),
/// so a book is in the same section here as on the Reading, To read and
/// Finished shelves, and each section is named with the server's label for
/// its status, so a status renamed on the server reads renamed here.
///
/// Built from whatever books it is given, live, every time: nothing here is a
/// copy that can go stale when a status or a position changes.
public struct StagedBooks: Equatable, Sendable {
    /// The library's own stages, not a copy: a book is in the same section
    /// here as on the shelves because it is the same function that files it.
    public typealias Stage = LibraryArrangement.Stage

    /// In-progress first, then unread, then finished.
    static let order: [Stage] = [.reading, .toRead, .finished]

    public struct Section: Equatable, Sendable, Identifiable {
        public let stage: Stage
        /// The server's name for the stage, as the reader sees it.
        public let title: String
        public let books: [Book]
        public var id: Stage { stage }

        /// "Reading · 3", for the overline (which uppercases it).
        public var overline: String { "\(title) · \(books.count)" }
        /// "Reading, 3 books", for VoiceOver.
        public var spokenOverline: String { "\(title), \(StagedBooks.count(books.count))" }
    }

    /// Non-empty sections in display order.
    public let sections: [Section]
    public let count: Int
    /// Books in the Reading stage.
    public let inProgress: Int
    /// Books with audio the server can serve: read-alongs and audiobooks.
    public let withNarration: Int

    public var isEmpty: Bool { count == 0 }

    /// Section headings are drawn only when there is more than one section:
    /// one heading over every book repeats the count the summary just gave.
    public var showsOverlines: Bool { sections.count > 1 }

    /// "Show in Library" leads to the full grid with every sort and shelf;
    /// for one book that is a longer way to the same single cover.
    public var offersShowInLibrary: Bool { count >= 2 }

    public init(books: [Book], statuses: [Status]) {
        // By uuid, once each: a catalogue can list a book twice under one tag
        // or author, and a book drawn twice gives two cells one identity.
        var seen: Set<String> = []
        let unique = books.filter { seen.insert($0.uuid).inserted }

        var byStage: [Stage: [Book]] = [:]
        for book in unique {
            byStage[LibraryArrangement.stage(of: book), default: []].append(book)
        }
        sections = Self.order.compactMap { stage in
            guard let books = byStage[stage], !books.isEmpty else { return nil }
            return Section(
                stage: stage, title: Self.title(of: stage, statuses: statuses, books: books),
                books: Self.ordered(books, in: stage))
        }
        count = unique.count
        inProgress = byStage[.reading]?.count ?? 0
        // The predicate the With narration shelf and its chip use, so the
        // header can never count audio differently from them.
        withNarration = unique.filter(\.hasServableAudio).count
    }

    /// "24 books · 3 in progress · 7 with narration". A clause is dropped when
    /// its count is zero, and a single book is only "1 book".
    public var summary: String {
        clauses.joined(separator: " · ")
    }

    /// The header as one spoken element: "Gothic, tag. 24 books, 3 in
    /// progress, 7 with narration."
    public func spokenHeader(name: String, kind: String) -> String {
        "\(name), \(kind). \(clauses.joined(separator: ", "))."
    }

    private var clauses: [String] {
        var parts = [Self.count(count)]
        guard count >= 2 else { return parts }
        if inProgress > 0 { parts.append("\(inProgress) in progress") }
        if withNarration > 0 { parts.append("\(withNarration) with narration") }
        return parts
    }

    static func count(_ n: Int) -> String { n == 1 ? "1 book" : "\(n) books" }

    /// The status the server calls this stage, by its built-in name first —
    /// 3.x keeps those fixed and puts any rewording in the label — then any
    /// status that files under the stage. Before the server's list has loaded,
    /// or when it fails to, the section's own books still carry their status,
    /// so theirs is the next best word; the built-in name is the last.
    static func title(of stage: Stage, statuses: [Status], books: [Book] = []) -> String {
        let builtIn = switch stage {
        case .reading: Status.readingName
        case .toRead: Status.toReadName
        case .finished: Status.readName
        }
        let carried = books.compactMap(\.status)
        let status = statuses.first { $0.name == builtIn }
            ?? statuses.first { LibraryArrangement.stage(ofStatusNamed: $0.name) == stage }
            ?? carried.first { $0.name == builtIn }
            ?? carried.first { LibraryArrangement.stage(ofStatusNamed: $0.name) == stage }
        return status?.displayName ?? builtIn
    }

    /// Reading by recency — the one to resume is the one last opened — and
    /// the rest by title the way the library's Title sort files them, leading
    /// articles ignored.
    static func ordered(_ books: [Book], in stage: Stage) -> [Book] {
        switch stage {
        case .reading:
            return LibraryRails.byRecency(books)
        case .toRead, .finished:
            return books.sorted {
                LibraryArrangement.sortKey($0.title)
                    .localizedCaseInsensitiveCompare(LibraryArrangement.sortKey($1.title))
                    == .orderedAscending
            }
        }
    }

    /// What the "More by" page says under a cover, where the author's name
    /// would repeat the page's title: the series and number, else the year.
    ///
    /// The series is `primarySeries`, the one with a number where there is
    /// one. The year is read in UTC: the server stores a bare year as its
    /// first midnight in UTC, and read in a zone west of Greenwich that is the
    /// last evening of the year before.
    public static func authorCaption(for book: Book) -> String? {
        if let series = book.primarySeries {
            guard let position = series.position else { return series.name }
            return "\(series.name) · \(SeriesText.ordinal(position))"
        }
        guard let published = book.publicationDate?.value else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return String(calendar.component(.year, from: published))
    }
}
