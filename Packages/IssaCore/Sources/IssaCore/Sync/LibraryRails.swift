import Foundation

/// A series as the library can show it: a name, and its books in reading order.
public struct SeriesGroup: Sendable, Hashable, Identifiable {
    public let name: String
    /// In `position` order, fractional positions between their neighbours and
    /// unpositioned books last — the order `LibraryDerivation.bySeries` builds.
    public let books: [Book]

    public var id: String { name }

    public init(name: String, books: [Book]) {
        self.name = name
        self.books = books
    }

    /// Where a book sits in *this* series. A book can belong to two, so the
    /// membership is looked up by name rather than taken from `series.first`.
    public func position(of book: Book) -> Double? {
        book.series.first { $0.name == name }?.position
    }
}

/// The rails the Library's Browse screen and the Reading tab show, derived from
/// the catalogue in one pass and memoised by the app model.
///
/// Every rule that decides what is on a rail lives here rather than in a view:
/// a view body is evaluated more than once per frame, and nothing in the app
/// targets is under test. Built the way `LibraryFacets` is — one value, one
/// pass, `Equatable`, `.empty` — and rebuilt only when the catalogue changes.
public struct LibraryRails: Sendable, Equatable {
    /// How many covers a rail holds. The "See all" route shows the rest.
    public static let railLength = 12
    /// How many tag rails Browse shows; the tag menu caps itself the same way.
    public static let tagRailCount = 4

    /// Newest arrivals first, by the server's `createdAt`. Undated books are
    /// left out: they cannot be "recent" in any order.
    public let recentlyAdded: [Book]
    /// Every series with more than one book, by name. A standalone book is not
    /// a one-book series, whatever the metadata says.
    public let series: [SeriesGroup]
    /// The `.withNarration` shelf's own predicate, so the rail and the shelf
    /// its "See all" opens can never disagree about a book.
    public let withAudio: [Book]
    /// The most-used tags, each with the books that carry it. Tags on a single
    /// book are skipped — a rail of one is a label, not a place to look around.
    public let tagRails: [TagRail]
    /// Books not yet started, newest arrivals first — the Reading tab's
    /// "Up next".
    public let toRead: [Book]
    /// Books in progress by status, most recently positioned first and the
    /// ones never opened last. Uncapped: the Reading tab lists them all.
    public let reading: [Book]

    public struct TagRail: Sendable, Equatable, Identifiable {
        public let tag: String
        public let books: [Book]
        public var id: String { tag }
    }

    public static let empty = LibraryRails(books: [])

    public init(books: [Book]) {
        recentlyAdded = Array(Self.byArrival(books.filter { $0.createdAt?.value != nil })
            .prefix(Self.railLength))

        series = LibraryDerivation(books: books).bySeries
            .filter { $0.value.count > 1 }
            .map { SeriesGroup(name: $0.key, books: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        withAudio = Array(books.filter { $0.hasReadalong || $0.audiobook != nil }
            .prefix(Self.railLength))

        var byTag: [String: [Book]] = [:]
        for book in books {
            for tag in book.tags { byTag[tag.name, default: []].append(book) }
        }
        tagRails = byTag
            .filter { $0.value.count > 1 }
            .sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }
            .prefix(Self.tagRailCount)
            .map { TagRail(tag: $0.key, books: Array($0.value.prefix(Self.railLength))) }

        var toRead: [Book] = []
        var reading: [Book] = []
        for book in books {
            switch LibraryArrangement.stage(of: book) {
            case .toRead: toRead.append(book)
            case .reading: reading.append(book)
            case .finished: break
            }
        }
        self.toRead = Array(Self.byArrival(toRead).prefix(Self.railLength))
        self.reading = Self.byRecency(reading)
    }

    /// Newest first; undated books keep their catalogue order at the end.
    static func byArrival(_ books: [Book]) -> [Book] {
        books.sorted { left, right in
            switch (left.createdAt?.value, right.createdAt?.value) {
            case let (l?, r?): l > r
            case (nil, _?): false
            case (_?, nil): true
            case (nil, nil): false
            }
        }
    }

    /// Most recently positioned first; never-opened books at the end.
    static func byRecency(_ books: [Book]) -> [Book] {
        books.sorted { left, right in
            switch (left.position?.timestamp, right.position?.timestamp) {
            case let (l?, r?): l > r
            case (nil, _?): false
            case (_?, nil): true
            case (nil, nil): false
            }
        }
    }
}

/// What the Reading tab shows: the book to continue, the others in progress,
/// and what comes next.
public struct ReadingHome: Sendable, Equatable {
    /// The Continue card. The book with the most recent position, whatever
    /// its status — the promise is "where you left off", and it is the same
    /// book the widget shows. Only when nothing has a position does a book
    /// merely *marked* as being read lead, and then without a progress line.
    public let hero: Book?
    /// Every other book in progress by status, most recent first. Empty when
    /// the hero is the only one.
    public let alsoReading: [Book]
    /// The To-read queue, newest arrivals first.
    public let upNext: [Book]

    public static let empty = ReadingHome(books: [], rails: .empty)

    public init(books: [Book], rails: LibraryRails) {
        let hero = LibraryDerivation(books: books).continueReading.first ?? rails.reading.first
        self.hero = hero
        alsoReading = rails.reading.filter { $0.uuid != hero?.uuid }
        upNext = rails.toRead
    }

    /// Nothing to continue and nothing queued: the tab shows its prompt.
    public var isEmpty: Bool { hero == nil && upNext.isEmpty }
}
