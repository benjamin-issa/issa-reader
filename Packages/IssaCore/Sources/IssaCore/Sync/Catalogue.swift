import Foundation

/// `GET /api/v2/books`, read one book at a time.
///
/// The endpoint answers with the whole library in one array, and a `[Book]`
/// decode is all or nothing: one row the model cannot read throws the rest
/// away. That is not a theory. `restartPending` was declared a `Bool` while
/// every server sends a string during a re-alignment, so a library stopped
/// loading for as long as one book's job ran, which can be hours, and since
/// positions and statuses arrive in this same answer, nothing synced either.
/// This client follows a beta line, so the next surprise is a matter of time.
///
/// So a row that cannot be read costs that row. It does not mean the book has
/// gone: the server listed it. `unreadable` says which books those were, and
/// whoever replaces a catalogue keeps what it already has for them
/// (`AppModel.refreshLibrary`, `LibraryStore.replaceCatalogue`).
public struct Catalogue: Decodable, Sendable {
    /// A row that could not be read.
    public struct Failure: Sendable {
        /// The book it was, if the row could at least say. Nil means it could
        /// not, so nothing can be said about any book's absence from this
        /// answer: see `hasUnnamedRows`.
        public let uuid: String?
        public let error: any Error
        /// Where in the answer it was listed, so a copy kept for it stays there.
        public let row: Int
    }

    public var books: [Book]
    public var failures: [Failure]

    /// The books the server listed that this client could not read.
    public var unreadable: Set<String> { Set(failures.compactMap(\.uuid)) }

    /// Whether a row could not say which book it was. One that could be any
    /// book means a book missing from `books` may not have left the server.
    public var hasUnnamedRows: Bool { failures.contains { $0.uuid == nil } }

    /// Whether this is every book the server listed.
    public var isComplete: Bool { failures.isEmpty }

    /// The shelf this answer makes.
    ///
    /// `fresh` is one book for each row that was read, in order. Around them go
    /// the books held here that the answer cannot be taken to replace, each
    /// back where it was listed, so a book being re-aligned does not jump to
    /// the end of a grid for as long as the job runs. Those are the rows it
    /// could not read. And when a row could not say which book it was, every
    /// book it left out, any one of which that row could be: the same reason
    /// `LibraryStore.replaceCatalogue` deletes nothing on such an answer, so
    /// that the shelf and the store tell one story.
    public func shelf(fresh: [Book], previous: [Book]) -> [Book] {
        guard !failures.isEmpty else { return fresh }
        let held = Dictionary(previous.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        var shelf = fresh
        var present = Set(fresh.map(\.uuid))
        for failure in failures {
            guard let uuid = failure.uuid, !present.contains(uuid), let book = held[uuid] else { continue }
            shelf.insert(book, at: min(failure.row, shelf.count))
            present.insert(uuid)
        }
        if hasUnnamedRows {
            shelf += previous.filter { present.insert($0.uuid).inserted }
        }
        return shelf
    }

    public init(from decoder: any Decoder) throws {
        // A body that is not an array throws: that is not a row to skip but an
        // answer that is not a catalogue.
        var rows = try decoder.unkeyedContainer()
        var books: [Book] = []
        var failures: [Failure] = []
        while !rows.isAtEnd {
            // `Row` never throws, and that is what moves this on. A `try?` on a
            // `Book` here would not: an unkeyed container stays where it is
            // when a decode fails, so the loop would spin on the bad row for
            // ever.
            let position = rows.currentIndex
            let row = try rows.decode(Row.self)
            switch row.book {
            case let .success(book): books.append(book)
            case let .failure(error): failures.append(Failure(uuid: row.uuid, error: error, row: position))
            }
        }
        self.books = books
        self.failures = failures
    }

    private struct Row: Decodable {
        let uuid: String?
        let book: Result<Book, any Error>

        private enum CodingKeys: String, CodingKey { case uuid }

        init(from decoder: any Decoder) {
            // On its own, so a row that fails as a book can still say which
            // book it was.
            uuid = try? decoder.container(keyedBy: CodingKeys.self)
                .decodeIfPresent(String.self, forKey: .uuid)
            do {
                book = .success(try Book(from: decoder))
            } catch {
                book = .failure(error)
            }
        }
    }
}
