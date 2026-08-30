import CryptoKit
import Foundation
import GRDB

/// The on-device copy of the library.
///
/// Three jobs, and the shape follows from them:
///
/// 1. **Survive a cold start with no network.** The catalogue is written on
///    every successful fetch and read before any request is made, so the shelf
///    is populated instantly and the fetch reconciles behind it.
/// 2. **Search without asking the server.** Storyteller 2.14.21's book endpoint
///    takes no query parameters at all, so search has to be local. FTS5 does it
///    in microseconds where a substring scan over every title and creator does
///    not.
/// 3. **Hold writes that have not reached the server yet.** See `MutationQueue`.
///
/// Books are stored as their JSON with a few columns lifted out for querying.
/// A fully normalised schema would buy nothing here — the client never queries
/// across books by tag or series in SQL, it derives those rails in memory from
/// the whole catalogue, which it already has.
public actor LibraryStore {
    private let dbQueue: DatabaseQueue
    public let url: URL

    /// Opens, or creates, the store for one server.
    ///
    /// Keyed by server so signing into a different one does not inherit a
    /// stranger's shelves.
    public init(serverKey: String, directory: URL? = nil) throws {
        let base = directory ?? Self.defaultDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appending(path: "library-\(Self.filename(for: serverKey)).sqlite")

        var configuration = Configuration()
        // The widget and any extension may read while a download task writes.
        configuration.busyMode = .timeout(5)
        dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
        try Self.migrator.migrate(dbQueue)
    }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Store", directoryHint: .isDirectory)
    }

    /// A server URL is not a filename; hash it rather than trying to sanitise.
    ///
    /// SHA-256, not `hashValue`: Swift seeds string hashing randomly *per
    /// process*, so a `hashValue`-derived filename is different on every launch
    /// — the store is written, and then never found again. That is invisible in
    /// tests, which stay in one process, and fatal in the app.
    static func filename(for serverKey: String) -> String {
        let digest = SHA256.hash(data: Data(serverKey.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "book") { t in
                t.primaryKey("uuid", .text)
                t.column("title", .text).notNull()
                t.column("byline", .text).notNull()
                t.column("updatedAt", .double)
                t.column("createdAt", .double)
                t.column("progress", .double)
                t.column("positionTimestamp", .double)
                t.column("statusName", .text)
                t.column("hasReadalong", .boolean).notNull().defaults(to: false)
                t.column("hasAudio", .boolean).notNull().defaults(to: false)
                // The full payload, so nothing the server sends is lost to a
                // column list that has fallen behind.
                t.column("json", .blob).notNull()
            }
            try db.create(index: "book_on_positionTimestamp", on: "book", columns: ["positionTimestamp"])

            // External-content FTS: the index mirrors `book` rather than
            // duplicating the text, so there is one source of truth.
            try db.create(virtualTable: "bookSearch", using: FTS5()) { t in
                t.synchronize(withTable: "book")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("title")
                t.column("byline")
            }

            try db.create(table: "mutation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bookUUID", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("payload", .blob).notNull()
                t.column("createdAt", .double).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "mutation_on_book_kind", on: "mutation", columns: ["bookUUID", "kind"])
        }
        return migrator
    }

    // MARK: - Catalogue

    /// Replaces the stored catalogue.
    ///
    /// A whole-library replace rather than a merge, because that is exactly what
    /// the server's endpoint returns — anything missing from it has been deleted
    /// server-side and should disappear here too.
    public func replaceCatalogue(_ books: [Book]) throws {
        let rows = try books.map { try BookRow(book: $0) }
        try dbQueue.write { db in
            try Book.deletedRowsCleanup(db, keeping: rows.map(\.uuid))
            for row in rows { try row.save(db) }
        }
    }

    public func allBooks() throws -> [Book] {
        try dbQueue.read { db in
            try BookRow
                .order(Column("title").asc)
                .fetchAll(db)
                .compactMap { try? $0.decoded() }
        }
    }

    public func book(_ uuid: String) throws -> Book? {
        try dbQueue.read { db in
            try BookRow.filter(key: uuid).fetchOne(db).flatMap { try? $0.decoded() }
        }
    }

    public func upsert(_ book: Book) throws {
        let row = try BookRow(book: book)
        try dbQueue.write { db in try row.save(db) }
    }

    public var isEmpty: Bool {
        get throws { try dbQueue.read { try BookRow.fetchCount($0) == 0 } }
    }

    /// Full-text search over titles and creators.
    ///
    /// Falls back to a LIKE scan when the query has no usable tokens — a lone
    /// apostrophe or a single letter produces an FTS pattern that matches
    /// nothing, and returning nothing for "a" reads as a broken search box.
    public func search(_ query: String) throws -> [Book] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try allBooks() }

        return try dbQueue.read { db in
            if let pattern = FTS5Pattern(matchingAllPrefixesIn: trimmed) {
                let rows = try BookRow.fetchAll(db, sql: """
                    SELECT book.* FROM book
                    JOIN bookSearch ON bookSearch.rowid = book.rowid
                    WHERE bookSearch MATCH ?
                    ORDER BY bm25(bookSearch), book.title
                    """, arguments: [pattern])
                if !rows.isEmpty { return rows.compactMap { try? $0.decoded() } }
            }
            let like = "%\(trimmed)%"
            return try BookRow
                .filter(sql: "title LIKE ? OR byline LIKE ?", arguments: [like, like])
                .order(Column("title").asc)
                .fetchAll(db)
                .compactMap { try? $0.decoded() }
        }
    }
}

/// One catalogue row: queryable columns plus the untouched payload.
struct BookRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "book"

    var uuid: String
    var title: String
    var byline: String
    var updatedAt: Double?
    var createdAt: Double?
    var progress: Double?
    var positionTimestamp: Double?
    var statusName: String?
    var hasReadalong: Bool
    var hasAudio: Bool
    var json: Data

    init(book: Book) throws {
        uuid = book.uuid
        title = book.title
        byline = book.byline
        updatedAt = book.updatedAt?.value.timeIntervalSince1970
        createdAt = book.createdAt?.value.timeIntervalSince1970
        progress = book.progress
        positionTimestamp = book.position?.timestamp
        statusName = book.status?.name
        hasReadalong = book.hasReadalong
        hasAudio = book.audiobook != nil || book.hasReadalong
        json = try JSONEncoder().encode(book)
    }

    func decoded() throws -> Book {
        try JSONDecoder().decode(Book.self, from: json)
    }
}

extension Book {
    /// Removes rows the server no longer lists.
    static func deletedRowsCleanup(_ db: Database, keeping uuids: [String]) throws {
        guard !uuids.isEmpty else { return }
        try db.execute(
            sql: "DELETE FROM book WHERE uuid NOT IN (\(uuids.map { _ in "?" }.joined(separator: ",")))",
            arguments: StatementArguments(uuids),
        )
    }
}
