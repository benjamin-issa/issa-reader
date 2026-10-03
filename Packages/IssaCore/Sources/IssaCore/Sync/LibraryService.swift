import Foundation

/// Reads the catalogue, and the covers that go with it.
///
/// On the 2.14.21 baseline `GET /api/v2/books` takes no parameters and returns
/// the whole library in one array, including this user's position and status.
/// The client therefore fetches once and does all searching, filtering and
/// shelf-building locally — which is faster than round-tripping and works
/// offline. On a 3.x server the same data is available piecemeal, but there is
/// no reason to prefer it, and the one array is still served whole.
///
/// Covers are where the two generations part. 2.x serves them by book uuid;
/// 3.x keeps them by content hash under `/api/v2/images`, names that hash in
/// the book's own JSON, and answers the old uuid route with a redirect there.
/// `coverData(for:shape:pixelWidth:pixelHeight:fallback:)` takes the direct
/// route whenever the book says where its cover is.
public struct LibraryService: Sendable {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    public func allBooks() async throws -> [Book] {
        Self.refusingUnsafeIdentifiers(try await client.get(Endpoint.books))
    }

    /// Drops catalogue entries whose uuid could not safely name a path.
    ///
    /// The boundary, so nothing downstream has to remember. A uuid reaches four
    /// filesystem sinks and every `/books/{uuid}/…` route, and none of that
    /// interpolation escapes anything — so one malformed entry is enough to let
    /// a hostile or compromised server pick where a download lands. Dropping
    /// the row loses one book from the shelf; keeping it risks the container.
    ///
    /// Logged rather than silent: a book vanishing from the library with no
    /// explanation is its own support problem.
    ///
    /// And the boundary for `localCopy` too, which marks a book as one the
    /// reader added from their own files. No server sends it; one that did
    /// would have its book drawn as a file on this device, opened from a
    /// folder it does not own and kept out of the account's own reset. So it
    /// is dropped from every book here, whatever it says.
    static func refusingUnsafeIdentifiers(_ books: [Book]) -> [Book] {
        var kept: [Book] = []
        kept.reserveCapacity(books.count)
        for var book in books {
            if book.uuid.isBareUUID {
                book.localCopy = nil
                kept.append(book)
            } else {
                IssaLog.warning("catalogue entry refused: uuid is not a uuid", [
                    "title": book.title,
                ])
            }
        }
        return kept
    }

    public func statuses() async throws -> [Status] {
        try await client.get(Endpoint.statuses)
    }

    /// This user's ratings, as book uuid to score.
    ///
    /// One request for the whole library rather than one per book — the detail
    /// screen and the library grid both want them.
    ///
    /// Each put on the five-star scale here, where it arrives: from this
    /// dictionary a rating is persisted, reloaded at every launch and handed
    /// to every surface that draws stars. See `StarRating`.
    public func myRatings() async throws -> [String: Double] {
        struct Row: Decodable { let bookUuid: String?; let rating: Double? }
        let rows: [Row] = try await client.get(Endpoint.userRatings)
        return rows.reduce(into: [:]) { result, row in
            if let uuid = row.bookUuid, let rating = row.rating.flatMap(StarRating.clamped) {
                result[uuid] = rating
            }
        }
    }

    public func book(_ uuid: String) async throws -> Book {
        try Self.refusingUnsafeIdentifier(try await client.get(Endpoint.book(uuid)))
    }

    /// One book, under the same two rules as the catalogue: a uuid that is a
    /// uuid, and no `localCopy` — see `refusingUnsafeIdentifiers`.
    static func refusingUnsafeIdentifier(_ book: Book) throws -> Book {
        guard book.uuid.isBareUUID else {
            IssaLog.warning("book refused: uuid is not a uuid", ["title": book.title])
            throw StorytellerError.notFound
        }
        var book = book
        book.localCopy = nil
        return book
    }

    /// Storyteller keeps two covers per book: one for the text, one for the audio.
    public enum CoverShape: Sendable {
        /// The portrait ebook cover, for shelves and the book hero.
        case portrait
        /// The square audiobook cover, for the player, Now Playing and widgets,
        /// where a portrait image would be letterboxed.
        case square
    }

    /// Fetches a cover by book uuid, letting the server do the resizing.
    ///
    /// The 2.x route, and still the one to use when there is no `Book` to hand
    /// — CarPlay can ask for a book the catalogue no longer holds. Prefer
    /// `coverData(for:shape:pixelWidth:pixelHeight:fallback:)`
    /// wherever there is one: on 3.x this route is deprecated and answers
    /// with a redirect, which `APIClient.getData` follows but a direct request
    /// never needs.
    ///
    /// Asking for the size actually needed saves both the transfer and the
    /// decode: a 3 MB 2000px cover drawn into a 108pt grid cell is most of what
    /// makes a library scroll badly. `version` is the book's `updatedAt` in
    /// epoch milliseconds — supplying it makes the response immutably
    /// cacheable, and changes the URL when a cover is replaced.
    ///
    /// - Parameter fallback: whether a missing portrait cover may be answered
    ///   with the square one. The default suits a shelf, where any art beats a
    ///   letter tile; a caller that needs to know which shape it was given —
    ///   the widget frames the two differently — turns it off and asks for the
    ///   other shape itself.
    public func coverData(
        for uuid: String,
        shape: CoverShape = .portrait,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        version: Date? = nil,
        fallback: Bool = true,
    ) async throws -> Data {
        var query: [URLQueryItem] = []
        if shape == .square { query.append(URLQueryItem(name: "audio", value: "")) }
        if let pixelWidth { query.append(URLQueryItem(name: "w", value: String(pixelWidth))) }
        if let pixelHeight { query.append(URLQueryItem(name: "h", value: String(pixelHeight))) }
        if let version {
            query.append(URLQueryItem(name: "v", value: String(Int(version.timeIntervalSince1970 * 1000))))
        }

        do {
            return try await client.getData(Endpoint.cover(uuid), query: query)
        } catch StorytellerError.notFound where shape == .portrait && fallback {
            // An audiobook-only book has no text cover. Falling back is the
            // difference between artwork and a letter tile forever.
            return try await coverData(
                for: uuid, shape: .square,
                pixelWidth: pixelWidth, pixelHeight: pixelHeight, version: version,
            )
        }
    }

    /// Fetches a book's cover by the route the book itself says to take.
    ///
    /// In order:
    ///
    /// 1. The book names a usable cover for this shape — or, for a portrait
    ///    that may fall back, a square one: fetched straight from
    ///    `/api/v2/images/{sha256}`. Chosen by `Book.coverReference(for:fallback:)`,
    ///    the function `CoverCache` names the file after, so the two cannot
    ///    disagree about which image this is.
    /// 2. The book names art for some shape, but not this one: `.notFound`,
    ///    without a request. Only a 3.x catalogue writes cover references, so
    ///    the book's silence about this shape is the server's own answer, and
    ///    the deprecated uuid route would only 404. See `Book.namesAnyCover`.
    /// 3. The book names none: the uuid route, versioned by `updatedAt`
    ///    exactly as the app has always asked for it. That is every book on
    ///    2.x, asked for byte for byte as before. On 3.x it is a row cached by
    ///    1.2.0, which 3.x redirects to the same image — hence `getData`
    ///    following the redirect with the bearer intact — and a book that
    ///    truly has no art, which costs the one request that 404s, as it did
    ///    in 1.2.0.
    ///
    /// Nothing here asks which generation the server was detected as. That
    /// says nothing about the `Book` in hand, and a book is often held from
    /// before the refresh that brings its references — the one playback began
    /// with, the widget's, an open reader's — and is never handed the
    /// refreshed row. Answering such a book `.notFound` because the server is
    /// 3.x kept the Lock Screen, CarPlay, the player and the widget blank for
    /// the whole session.
    ///
    /// The images route is sent no `v=`. Its URL is the content's own hash, so
    /// a replaced cover arrives under a new URL by construction, and the
    /// server marks the response immutable. `s` is the longest edge wanted:
    /// the server rounds it up to its next size bucket and fits the image
    /// inside, never cropping, so `max(width, height)` asks for at least what
    /// either dimension needs. Omitted at zero, which the server reads as the
    /// original size.
    public func coverData(
        for book: Book,
        shape: CoverShape = .portrait,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        fallback: Bool = true,
    ) async throws -> Data {
        let longestEdge = max(pixelWidth ?? 0, pixelHeight ?? 0)
        if let reference = book.coverReference(for: shape, fallback: fallback) {
            return try await imageData(reference, longestEdge: longestEdge)
        }
        if book.namesAnyCover { throw StorytellerError.notFound }
        return try await coverData(
            for: book.uuid, shape: shape,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            version: book.updatedAt?.value, fallback: fallback,
        )
    }

    private func imageData(_ reference: CoverReference, longestEdge: Int) async throws -> Data {
        let query = longestEdge > 0 ? [URLQueryItem(name: "s", value: String(longestEdge))] : []
        return try await client.getData(Endpoint.V3.image(reference.sha256), query: query)
    }
}

/// Derives the rails and facets the design's Library and Explore screens show.
///
/// All of this is computed from the single catalogue fetch, which is why a 2.x
/// server loses nothing next to 3.x's server-side home sections.
public struct LibraryDerivation: Sendable {
    public let books: [Book]

    public init(books: [Book]) {
        self.books = books
    }

    /// Books with progress, most recently positioned first — the design's
    /// "Continue" card and rail.
    public var continueReading: [Book] {
        books
            .filter { ($0.position?.locator.totalProgression ?? 0) > 0 }
            .sorted { ($0.position?.timestamp ?? 0) > ($1.position?.timestamp ?? 0) }
    }

    public var readalongs: [Book] {
        books.filter(\.hasReadalong)
    }

    /// Author name to their books, for the design's "More by…" rail.
    public var byAuthor: [String: [Book]] {
        grouped { $0.authors.map(\.name) }
    }

    public var byNarrator: [String: [Book]] {
        grouped { $0.narrators.map(\.name) }
    }

    /// Series name to its books in reading order.
    public var bySeries: [String: [Book]] {
        var ordered: [String: [Book]] = [:]
        for (name, members) in grouped(by: { $0.series.map(\.name) }) {
            // The ordinal must come from the series being grouped, not
            // `series.first`: a book in two series has two positions, and
            // ordering one series by the other's numbers shuffles it.
            ordered[name] = members.sorted { lhs, rhs in
                let l = lhs.series.first { $0.name == name }?.position ?? .greatestFiniteMagnitude
                let r = rhs.series.first { $0.name == name }?.position ?? .greatestFiniteMagnitude
                return l < r
            }
        }
        return ordered
    }

    /// Tag name to the books that carry it, in catalogue order: the Browse
    /// screen's tag rails, and anything else that lists a tag's books.
    public var byTag: [String: [Book]] {
        grouped { $0.tags.map(\.name) }
    }

    /// Each name a book gives, to the books that give it — every book once.
    ///
    /// A catalogue row can name the same creator, series or tag twice: an
    /// EPUB whose metadata repeats a `dc:creator` is enough. Grouped once per
    /// mention, the book went into the group twice — two cells with one
    /// identity in a rail, "3 books" for two on a series screen, another book
    /// listed twice in a "More by" rail, and a tag or series on one book
    /// passing the "more than one book" test for a rail of its own.
    private func grouped(by names: (Book) -> [String]) -> [String: [Book]] {
        var groups: [String: [Book]] = [:]
        var members: [String: Set<String>] = [:]
        for book in books {
            for name in names(book) {
                guard members[name, default: []].insert(book.uuid).inserted else { continue }
                groups[name, default: []].append(book)
            }
        }
        return groups
    }

    /// Tag counts, for the filter UI a 3.x server would serve from /library/facets.
    ///
    /// Books per tag, each once, as the tag filter counts them.
    ///
    /// Written out rather than chained: the inferred tuple type made this one of
    /// the slowest expressions in the package to type-check.
    public var tagCounts: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for (name, tagged) in byTag {
            counts[name] = tagged.count
        }
        let pairs: [(name: String, count: Int)] = counts.map { (name: $0.key, count: $0.value) }
        return pairs.sorted { left, right in
            left.count == right.count ? left.name < right.name : left.count > right.count
        }
    }

    /// Case- and diacritic-insensitive match across title, authors and narrators.
    /// Replaced by an FTS5 query once the local store lands; this keeps the
    /// behaviour identical in the meantime.
    public func search(_ query: String) -> [Book] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return books }
        return books.filter { book in
            let haystack = ([book.title, book.subtitle ?? ""]
                + book.authors.map(\.name)
                + book.narrators.map(\.name)
                + book.series.map(\.name)).joined(separator: " ")
            return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

/// A reader's rating on the five stars there are.
///
/// The server's rating is any `Double` — nothing stops a client, or a request
/// straight to the API, storing `1e300` — and `Int(1e300)` is not a wrong
/// answer but a trap. `LibraryService.myRatings()` clamps each one as it
/// arrives, and the surfaces that turn a rating into whole stars go through
/// `wholeStars(_:)`, so a value persisted before the clamp is safe too.
public enum StarRating {
    /// The scale: no stars to five.
    public static let scale: ClosedRange<Double> = 0 ... 5

    /// The rating on the scale, or nil for one that is not a number at all.
    public static func clamped(_ rating: Double) -> Double? {
        guard rating.isFinite else { return nil }
        return min(max(rating, scale.lowerBound), scale.upperBound)
    }

    /// Whole stars, 0 to 5, for any `Double` whatever.
    public static func wholeStars(_ rating: Double) -> Int {
        guard let clamped = clamped(rating.rounded()) else { return 0 }
        return Int(clamped)
    }
}
