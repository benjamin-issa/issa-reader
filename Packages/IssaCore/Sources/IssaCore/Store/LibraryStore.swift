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
    let dbQueue: DatabaseQueue
    public let url: URL
    /// Whose annotations this store is currently reading and writing.
    ///
    /// The file is per server, and a server serves more than one reader: on a
    /// shared device a second account used to be handed the first one's
    /// highlights and quoted excerpts, because `clearAccountData` keeps the
    /// annotations (rightly — they exist nowhere else) and nothing scoped
    /// them. Nil until the app says who is signed in; rows written before
    /// then carry no account and are adopted by the next one named.
    private var account: String?

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

    /// Rebuilds the flattened search columns from each row's stored payload.
    ///
    /// Shared by the migration and its test, so the thing under test is the
    /// thing that ships. Reads `json`, which holds the whole encoded `Book`,
    /// so it needs no network.
    static func backfillSearchFields(_ db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT rowid, json FROM book") {
            guard let data: Data = row["json"],
                  let book = try? JSONDecoder().decode(Book.self, from: data)
            else { continue }
            try db.execute(
                sql: """
                    UPDATE book SET subtitle = ?, narrators = ?, series = ?, tags = ?
                    WHERE rowid = ?
                    """,
                arguments: [
                    book.subtitle ?? "",
                    BookRow.joined(book.narrators.map(\.name)),
                    BookRow.joined(book.series.map(\.name)),
                    BookRow.joined(book.tags.map(\.name)),
                    row["rowid"] as Int64?,
                ],
            )
        }
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

        // Annotations are device-local: the server has no endpoint for them in
        // any version, so this is the only copy.
        migrator.registerMigration("v2-annotations") { db in
            try db.create(table: "annotation") { t in
                t.primaryKey("id", .text)
                t.column("bookUUID", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("progression", .double)
                t.column("excerpt", .text).notNull()
                t.column("json", .blob).notNull()
            }
            try db.create(index: "annotation_on_book", on: "annotation", columns: ["bookUUID"])
        }

        // Searching a narrator, a series or a tag returned nothing at all: the
        // index carried `title` and `byline` only, and `byline` is authors —
        // narrators only when a book has no author whatsoever.
        //
        // No catalogue refresh is needed to repair existing installs. `json`
        // holds the whole encoded `Book`, so the new columns are backfilled by
        // decoding what is already on disk. Search is correct offline, on the
        // first launch after upgrading.
        migrator.registerMigration("v3-search-fields") { db in
            // Order matters. The synchronisation triggers hard-code the column
            // list they were created with, so they have to go before the table
            // they feed; and the columns have to exist before the new virtual
            // table names them.
            try db.dropFTS5SynchronizationTriggers(forTable: "bookSearch")
            try db.drop(table: "bookSearch")

            for column in ["subtitle", "narrators", "series", "tags"] {
                try db.alter(table: "book") { t in
                    t.add(column: column, .text).notNull().defaults(to: "")
                }
            }

            try backfillSearchFields(db)

            // Recreating the table re-emits the triggers and issues its own
            // 'rebuild', so the index repopulates from `book` on its own.
            try db.create(virtualTable: "bookSearch", using: FTS5()) { t in
                t.synchronize(withTable: "book")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("title")
                t.column("byline")
                t.column("subtitle")
                t.column("narrators")
                t.column("series")
                t.column("tags")
            }
        }

        migrator.registerMigration("v4-mutation-ordering") { db in
            // Lets the queue collapse positions monotonically. `createdAt` is
            // wall clock at enqueue time, which is not the value the server
            // compares, so it cannot answer "is this write newer".
            try db.alter(table: "mutation") { t in
                t.add(column: "ordering", .double)
            }
        }

        // Annotations belong to the reader who made them, not to the server
        // they were made against. Nullable: every row already here was made
        // before accounts were recorded, and `setAccount` claims them for the
        // first account that signs in after the upgrade.
        migrator.registerMigration("v5-annotation-account") { db in
            try db.alter(table: "annotation") { t in
                t.add(column: "account", .text)
            }
            try db.create(index: "annotation_on_account", on: "annotation", columns: ["account"])
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
            // The same field set the FTS index carries, so the two paths cannot
            // disagree about what is searchable. (They still differ in *how*:
            // FTS matches token prefixes, LIKE matches any substring.)
            let columns = ["title", "byline", "subtitle", "narrators", "series", "tags"]
            let clause = columns.map { "\($0) LIKE ?" }.joined(separator: " OR ")
            return try BookRow
                .filter(sql: clause, arguments: StatementArguments(columns.map { _ in like }))
                .order(Column("title").asc)
                .fetchAll(db)
                .compactMap { try? $0.decoded() }
        }
    }

    /// Drops the account's catalogue, leaving the reader's own annotations.
    ///
    /// Called on sign-out. Books and queued writes belong to the account and
    /// must not outlive it; highlights and bookmarks are device-local and are
    /// the only copy there is, so deleting those would be data loss rather
    /// than cleanup.
    public func clearAccountData() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM book")
            try db.execute(sql: "DELETE FROM mutation")
        }
    }

    // MARK: - Test hooks

    /// Blanks the flattened search columns, standing in for a row written
    /// before they existed.
    func eraseSearchFieldsForTesting() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE book SET subtitle = '', narrators = '', series = '', tags = ''")
        }
    }

    /// Runs the migration's own backfill against the current contents.
    func backfillSearchFieldsForTesting() async throws {
        try await dbQueue.write { db in try Self.backfillSearchFields(db) }
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
    // Flattened for the search index. `byline` is authors, so without these a
    // narrator, a series or a tag was unreachable.
    var subtitle: String
    var narrators: String
    var series: String
    var tags: String
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
        subtitle = book.subtitle ?? ""
        narrators = Self.joined(book.narrators.map(\.name))
        series = Self.joined(book.series.map(\.name))
        tags = Self.joined(book.tags.map(\.name))
        json = try JSONEncoder().encode(book)
    }

    /// Joins names for the index. A newline rather than a comma, so a query
    /// cannot match across two adjacent names.
    static func joined(_ names: [String]) -> String {
        names.joined(separator: "\n")
    }

    func decoded() throws -> Book {
        try JSONDecoder().decode(Book.self, from: json)
    }
}

extension Book {
    /// Removes rows the server no longer lists.
    static func deletedRowsCleanup(_ db: Database, keeping uuids: [String]) throws {
        // An empty list is not "nothing to do" — it means the server lists
        // nothing, so everything held here is stale. Returning early kept
        // every deleted book on the shelf, and in search, forever.
        guard !uuids.isEmpty else {
            try db.execute(sql: "DELETE FROM book")
            return
        }
        try db.execute(
            sql: "DELETE FROM book WHERE uuid NOT IN (\(uuids.map { _ in "?" }.joined(separator: ",")))",
            arguments: StatementArguments(uuids),
        )
    }
}

// MARK: - Annotations

public extension LibraryStore {
    /// Names the signed-in account, and claims for it every annotation made
    /// before accounts were recorded.
    ///
    /// The claim is deliberate: those rows are the device's own highlights
    /// from before the upgrade, and the first reader to sign in afterwards is
    /// who made them. Leaving them unowned would show them to everyone, which
    /// is the leak this closes.
    func setAccount(_ id: String) throws {
        account = id
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE annotation SET account = ? WHERE account IS NULL", arguments: [id])
        }
    }

    /// The clause that scopes a query to the current account. With none named
    /// yet — an offline launch before any sign-in was recorded — only rows
    /// that predate accounts qualify, which is everything the device had.
    private var accountClause: (sql: String, arguments: StatementArguments) {
        if let account { return ("account = ?", [account]) }
        return ("account IS NULL", [])
    }

    /// Inserts or replaces one annotation.
    func save(_ annotation: Annotation) throws {
        let json = try JSONEncoder().encode(annotation)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO annotation (id, bookUUID, kind, createdAt, progression, excerpt, json, account)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    kind = excluded.kind, progression = excluded.progression,
                    excerpt = excluded.excerpt, json = excluded.json
                """,
                arguments: [
                    annotation.id, annotation.bookUUID, annotation.kind.rawValue,
                    annotation.createdAt.timeIntervalSince1970,
                    annotation.locator.locations?.totalProgression
                        ?? annotation.locator.locations?.progression,
                    annotation.excerpt, json, account,
                ],
            )
        }
    }

    func annotations(for bookUUID: String) throws -> [Annotation] {
        let scope = accountClause
        let rows: [Data] = try dbQueue.read { db in
            try Data.fetchAll(
                db,
                sql: "SELECT json FROM annotation WHERE bookUUID = ? AND \(scope.sql) ORDER BY progression",
                arguments: [bookUUID] + scope.arguments,
            )
        }
        let decoder = JSONDecoder()
        return rows.compactMap { try? decoder.decode(Annotation.self, from: $0) }
    }

    /// Every annotation this account has made, newest first, for a single list.
    func allAnnotations(limit: Int = 500) throws -> [Annotation] {
        let scope = accountClause
        let rows: [Data] = try dbQueue.read { db in
            try Data.fetchAll(
                db,
                sql: "SELECT json FROM annotation WHERE \(scope.sql) ORDER BY createdAt DESC LIMIT ?",
                arguments: scope.arguments + [limit],
            )
        }
        let decoder = JSONDecoder()
        return rows.compactMap { try? decoder.decode(Annotation.self, from: $0) }
    }

    func deleteAnnotation(id: String) throws {
        _ = try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM annotation WHERE id = ?", arguments: [id])
        }
    }

    /// Removes every annotation this account made on a book, for when the
    /// book is deleted server-side. Scoped: a book gone from one account's
    /// library may only be hidden from it, and another reader's marks on it
    /// are not this account's to delete.
    func deleteAnnotations(forBook bookUUID: String) throws {
        let scope = accountClause
        _ = try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM annotation WHERE bookUUID = ? AND \(scope.sql)",
                arguments: [bookUUID] + scope.arguments,
            )
        }
    }
}
