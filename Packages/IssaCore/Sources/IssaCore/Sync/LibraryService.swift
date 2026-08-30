import Foundation

/// Reads the catalogue.
///
/// On the 2.14.21 baseline `GET /api/v2/books` takes no parameters and returns
/// the whole library in one array, including this user's position and status.
/// The client therefore fetches once and does all searching, filtering and
/// shelf-building locally — which is faster than round-tripping and works
/// offline. On a 3.x server the same data is available piecemeal, but there is
/// no reason to prefer it.
public struct LibraryService: Sendable {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    public func allBooks() async throws -> [Book] {
        try await client.get(Endpoint.books)
    }

    public func statuses() async throws -> [Status] {
        try await client.get(Endpoint.statuses)
    }

    public func book(_ uuid: String) async throws -> Book {
        try await client.get(Endpoint.book(uuid))
    }

    public func coverData(for uuid: String) async throws -> Data {
        try await client.getData(Endpoint.cover(uuid))
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

    public var recentlyAdded: [Book] {
        books.sorted {
            ($0.createdAt?.value ?? .distantPast) > ($1.createdAt?.value ?? .distantPast)
        }
    }

    public var readalongs: [Book] {
        books.filter(\.hasReadalong)
    }

    /// Author name to their books, for the design's "More by…" rail.
    public var byAuthor: [String: [Book]] {
        Dictionary(grouping: books.flatMap { book in book.authors.map { ($0.name, book) } },
                   by: \.0)
            .mapValues { $0.map(\.1) }
    }

    public var byNarrator: [String: [Book]] {
        Dictionary(grouping: books.flatMap { book in book.narrators.map { ($0.name, book) } },
                   by: \.0)
            .mapValues { $0.map(\.1) }
    }

    /// Series name to its books in reading order.
    public var bySeries: [String: [Book]] {
        Dictionary(grouping: books.flatMap { book in book.series.map { ($0.name, book) } },
                   by: \.0)
            .mapValues { pairs in
                pairs.map(\.1).sorted { lhs, rhs in
                    let l = lhs.series.first?.position ?? .greatestFiniteMagnitude
                    let r = rhs.series.first?.position ?? .greatestFiniteMagnitude
                    return l < r
                }
            }
    }

    /// Tag counts, for the filter UI a 3.x server would serve from /library/facets.
    public var tagCounts: [(name: String, count: Int)] {
        Dictionary(grouping: books.flatMap(\.tags), by: \.name)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.count > $1.count || ($0.count == $1.count && $0.0 < $1.0) }
    }

    public var formatCounts: [BookFormat: Int] {
        var counts: [BookFormat: Int] = [:]
        for book in books {
            for format in book.availableFormats { counts[format, default: 0] += 1 }
        }
        return counts
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
