import Foundation
import GRDB
import IssaCore
import IssaEPUB
import IssaRender

/// One book's searchable text, on disk, bounded by where the reader has got to.
///
/// A per-book SQLite file rather than rows in `LibraryStore`: the index is
/// derived, disposable and large (a novel is a few megabytes of passages and
/// their FTS index), it is deleted with the download, and keeping it out of the
/// catalogue means a rebuild can never corrupt the shelf. `<uuid>.sqlite` under
/// `StorageRoot/Ask`, excluded from backup for the same reason the books are:
/// it is rebuildable from a file the device already has.
///
/// An actor because the build is long and the reader may ask, cancel, ask again
/// and delete the book while it runs; serialising every touch of the file is
/// the cheapest way to make that safe. The per-chapter parsing itself is a
/// `nonisolated static` worker, so a 250,000-word book does not park on this
/// actor's executor while it inflates and parses.
public actor AskIndexStore {
    /// Where the index files live.
    public static func defaultDirectory() -> URL { StorageRoot.directory("Ask") }

    private let directory: URL
    /// Open handles, keyed by book. A reader asks several questions in a row
    /// about one book; re-opening the file each time is pure cost.
    private var open: [String: DatabaseQueue] = [:]

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    // MARK: - Locations

    /// The one place an index file is named.
    ///
    /// The uuid is validated before it names anything, exactly as
    /// `BookContentService.localURL(in:bookUUID:format:)` explains: a catalogue
    /// entry whose uuid is `../../Library/Preferences/x` would otherwise choose
    /// the path this writes to. A malformed one is hashed rather than stripped,
    /// so it still names the same file every time without being able to escape
    /// the directory.
    public static func indexURL(in directory: URL, bookUUID: String) -> URL {
        let component = bookUUID.isBareUUID ? bookUUID : "unsafe-\(digest(bookUUID))"
        return directory.appending(path: "\(component).sqlite")
    }

    static func buildingURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("building.sqlite")
    }

    private static func digest(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Data(value.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    public nonisolated func indexURL(for bookUUID: String) -> URL {
        Self.indexURL(in: directory, bookUUID: bookUUID)
    }

    // MARK: - Preparing

    /// Makes sure the index for this book exists and describes the file on
    /// disk, building it if it does not.
    ///
    /// - Parameter progress: called on the caller's executor for each chapter,
    ///   so the sheet can say "Reading what you've read… 6 of 14" instead of
    ///   spinning for fifteen seconds on a long illustrated book.
    /// - Returns: whether a build actually ran, which is what the caller shows
    ///   a progress bar for.
    @discardableResult
    public func prepare(
        source: BookSource,
        progress: (@Sendable (AskPhase) -> Void)? = nil,
    ) async throws -> Bool {
        let url = indexURL(for: source.bookUUID)
        let key = source.indexKey

        if let queue = try? existingQueue(at: url, bookUUID: source.bookUUID),
           try Self.storedKey(in: queue) == key {
            return false
        }

        // Stale, corrupt or absent — all three are the same repair.
        open[source.bookUUID] = nil
        preparedBookUUID = nil
        try await build(source: source, key: key, destination: url, progress: progress)
        // Opened here so a question asked immediately afterwards finds a handle
        // rather than silently retrieving nothing.
        _ = try existingQueue(at: url, bookUUID: source.bookUUID)
        return true
    }

    /// Whether a usable, current index already exists — the question the sheet
    /// asks before deciding to show a progress bar at all.
    public func isPrepared(source: BookSource) -> Bool {
        let url = indexURL(for: source.bookUUID)
        guard let queue = try? existingQueue(at: url, bookUUID: source.bookUUID) else { return false }
        return (try? Self.storedKey(in: queue)) == source.indexKey
    }

    /// Builds into `<uuid>.building.sqlite` and renames.
    ///
    /// Never into the live file: a build that is cancelled — the reader closes
    /// the sheet, iOS suspends the app, the book is deleted mid-parse — would
    /// otherwise leave a half-written index that looks current, and every later
    /// question would be answered from a fraction of the book with no sign that
    /// anything was wrong. The rename is atomic; either the whole index arrives
    /// or none of it does.
    private func build(
        source: BookSource,
        key: IndexKey,
        destination: URL,
        progress: (@Sendable (AskPhase) -> Void)?,
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let building = Self.buildingURL(for: destination)
        try? FileManager.default.removeItem(at: building)

        let total = source.package.spine.count
        do {
            let queue = try Self.openQueue(at: building)
            try Self.migrator.migrate(queue)

            for (index, item) in source.package.spine.enumerated() {
                // Between chapters, not inside one: a chapter is a few
                // milliseconds and a half-parsed one has nothing to keep.
                try Task.checkCancellation()
                progress?(.preparingIndex(done: index, total: total))

                let parsed = Self.parseChapter(
                    archive: source.package.archive, href: item.href, spineIndex: index,
                )
                guard let parsed else { continue }
                try Self.insert(parsed, into: queue)
            }
            try Task.checkCancellation()
            try Self.stamp(key, into: queue)
            // Close before renaming: SQLite keeps -wal and -shm beside the file
            // and a rename with the handle open strands them under the old name.
            try queue.close()
            progress?(.preparingIndex(done: total, total: total))
        } catch {
            try? FileManager.default.removeItem(at: building)
            try? FileManager.default.removeItem(at: building.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: building.appendingPathExtension("shm"))
            throw error
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: building, to: destination)
        Self.excludeFromBackup(destination)
        IssaLog.info("ask index built", ["chapters": String(total)])
    }

    // MARK: - Chapter parsing

    /// One chapter's passages and names.
    struct ParsedChapter: Sendable {
        var spineIndex: Int
        var href: String
        var length: Int
        var passages: [Passage]
        var names: [NameFinder.Name]
    }

    /// Parses one chapter off this actor.
    ///
    /// `nonisolated static` for the reason `ReaderModel.hits` gives: parsing
    /// every spine item of a novel on one actor's executor blocks everything
    /// else that actor owns, and none of this work touches the store's state.
    ///
    /// Parsed with `ArchiveImageSource` and a plain `ReaderStyle()`. The images
    /// are not decorative here: each plate contributes an object-replacement
    /// character and a newline to the rendered string, so a parse without them
    /// computes offsets that drift ahead of the reader's — and the reading
    /// boundary is a comparison of exactly those offsets. The style, by
    /// contrast, changes nothing in `.string`: typeface, size and spacing are
    /// attributes, so any `ReaderStyle` yields the same characters.
    nonisolated static func parseChapter(
        archive: EPUBArchive, href: String, spineIndex: Int,
    ) -> ParsedChapter? {
        let images = ArchiveImageSource(archive: archive)
        guard let data = try? archive.read(href),
              let parsed = try? HTMLContentParser(
                  style: ReaderStyle(), loadImage: { images.image(for: $0) },
              ).parse(xhtml: data, baseHref: href)
        else { return nil }

        let text = parsed.text.string
        let passages = PassageChunker.chunk(text: text, spineIndex: spineIndex)
        let names = NameFinder.names(in: text, spineIndex: spineIndex)
        return ParsedChapter(
            spineIndex: spineIndex,
            href: href,
            length: (text as NSString).length,
            passages: passages,
            names: names,
        )
    }

    /// Writes one chapter's rows.
    ///
    /// Synchronous on purpose. GRDB gives `read` and `write` both a synchronous
    /// and an asynchronous overload, and inside an `async` function Swift picks
    /// the asynchronous one — which puts a suspension point in the middle of the
    /// build loop, where an actor is reentrant: a `remove(bookUUID:)` arriving
    /// there would delete the file the next chapter is about to be written to.
    /// A synchronous helper selects the synchronous overload, which is also what
    /// `LibraryStore` uses throughout.
    private static func insert(_ chapter: ParsedChapter, into queue: DatabaseQueue) throws {
        try queue.write { db in try insert(chapter, into: db) }
    }

    /// Stamps the fingerprint, which is the last thing a build writes: until
    /// this row exists the file is not a current index, and `prepare` rebuilds.
    private static func stamp(_ key: IndexKey, into queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO meta(key, value) VALUES ('indexKey', ?)",
                arguments: [key.storedValue],
            )
        }
    }

    private static func insert(_ chapter: ParsedChapter, into db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO chapter(spineIndex, href, length) VALUES (?, ?, ?)",
            arguments: [chapter.spineIndex, chapter.href, chapter.length],
        )
        for passage in chapter.passages {
            try db.execute(
                sql: """
                    INSERT INTO passage(spineIndex, ordinal, start, end, words, text)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    passage.spineIndex, passage.ordinal, passage.start,
                    passage.end, passage.words, passage.text,
                ],
            )
        }
        for name in chapter.names {
            // Summed rather than replaced: a character appears in many chapters
            // and the suggestion chip wants the total, while `firstOffset` must
            // stay the earliest so the boundary can hide someone not yet met.
            //
            // `nameKey` is what "VIN" and "Vin" have in common. Stored rather
            // than folded at query time so the grouping is indexed.
            try db.execute(
                sql: """
                    INSERT INTO name(name, nameKey, spineIndex, firstOffset, mentions)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    name.name, name.key, name.spineIndex, name.firstOffset, name.mentions,
                ],
            )
        }
    }

    // MARK: - Retrieval

    /// Passages matching these terms, from before the boundary and nowhere else.
    ///
    /// The boundary lives in the WHERE clause rather than in a filter after the
    /// fact, because a filter is a thing that can be forgotten at one call site.
    /// Two parts: every passage that ends at or before the position, and the one
    /// passage the position falls inside, truncated to the characters actually
    /// read. Nothing later in the book can match, whatever the query says.
    public func retrieve(
        terms: QueryTerms, before boundary: ReadingBoundary, limit: Int = 40,
    ) throws -> [RetrievedPassage] {
        guard let queue = currentQueue() else { return [] }
        return try Self.retrieve(terms: terms, before: boundary, limit: limit, in: queue)
    }

    /// The book the store is currently answering about.
    ///
    /// Set by `prepare` and by any successful open; retrieval is always about
    /// one book at a time, because the reader has one book open. Keeping it
    /// here rather than passing a uuid to every query is what stops a stale
    /// handle from a previously-read book answering a question about this one.
    private var preparedBookUUID: String?

    private func currentQueue() -> DatabaseQueue? {
        preparedBookUUID.flatMap { open[$0] }
    }

    static func retrieve(
        terms: QueryTerms, before boundary: ReadingBoundary, limit: Int, in queue: DatabaseQueue,
    ) throws -> [RetrievedPassage] {
        let tokens = terms.searchTokens
        guard !tokens.isEmpty else { return [] }
        guard let pattern = FTS5Pattern(matchingAnyTokenIn: tokens.joined(separator: " ")) else {
            return []
        }
        return try passages(
            matching: pattern, before: boundary, order: .relevance, limit: limit, in: queue,
        )
    }

    /// Every passage matching this pattern from before the boundary, in the
    /// order the caller needs them.
    ///
    /// The one bounded query. Everything else in this file that reads passages
    /// goes through it, so the boundary clause and the truncation of the
    /// straddling passage exist in exactly one place — a second copy of them
    /// is a second thing that can be got wrong, and getting it wrong shows the
    /// reader a page they have not read.
    public func passages(
        matching pattern: FTS5Pattern,
        before boundary: ReadingBoundary,
        order: PassageOrder = .relevance,
        limit: Int,
    ) throws -> [RetrievedPassage] {
        guard let queue = currentQueue() else { return [] }
        return try Self.passages(
            matching: pattern, before: boundary, order: order, limit: limit, in: queue,
        )
    }

    static func passages(
        matching pattern: FTS5Pattern,
        before boundary: ReadingBoundary,
        order: PassageOrder,
        limit: Int,
        in queue: DatabaseQueue,
    ) throws -> [RetrievedPassage] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT passage.spineIndex AS spineIndex, passage.ordinal AS ordinal,
                       passage.start AS start, passage.end AS end,
                       passage.words AS words, passage.text AS text,
                       bm25(passage_fts) AS score
                FROM passage
                JOIN passage_fts ON passage_fts.rowid = passage.rowid
                WHERE passage_fts MATCH :pattern
                  AND (passage.spineIndex < :spine
                       OR (passage.spineIndex = :spine AND passage.start < :offset))
                ORDER BY \(order.clause)
                LIMIT :limit
                """, arguments: [
                "pattern": pattern, "spine": boundary.spineIndex,
                "offset": boundary.charOffset, "limit": limit,
            ])
            return rows.compactMap { truncated($0, at: boundary) }
        }
    }

    /// Turns a row into a passage, cutting the straddling one to what has
    /// actually been read.
    ///
    /// `start < :offset` in the clause above is the whole boundary: `start` is
    /// always below `end`, so it admits exactly the passages that end at or
    /// before the position plus the single one the position falls inside, and
    /// nothing later in the book whatever the query says. That one is then cut
    /// here to `offset - start` UTF-16 units — measured against the same
    /// rendered string the reader's page was laid out from, which is why the
    /// index parses with `ArchiveImageSource`. A passage cut to nothing is
    /// dropped rather than sent empty.
    static func truncated(_ row: Row, at boundary: ReadingBoundary) -> RetrievedPassage? {
        let spineIndex: Int = row["spineIndex"]
        let start: Int = row["start"]
        let end: Int = row["end"]
        let text: String = row["text"]
        let passage = Passage(
            spineIndex: spineIndex, ordinal: row["ordinal"],
            start: start, end: end, words: row["words"], text: text,
        )
        guard spineIndex == boundary.spineIndex, end > boundary.charOffset else {
            return RetrievedPassage(passage: passage, bm25: row["score"] ?? 0, isTruncated: false)
        }
        let visible = boundary.charOffset - start
        let stored = text as NSString
        guard visible > 0 else { return nil }
        let cut = stored.substring(to: min(visible, stored.length))
        guard !cut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var truncatedPassage = passage
        truncatedPassage.text = cut
        truncatedPassage.end = boundary.charOffset
        truncatedPassage.words = PassageChunker.wordCount(cut)
        return RetrievedPassage(
            passage: truncatedPassage, bm25: row["score"] ?? 0, isTruncated: true,
        )
    }

    /// The last passages before the boundary, for a "what has happened so far"
    /// question, which has no search terms to match on.
    public func recapPassages(before boundary: ReadingBoundary, limit: Int = 6) throws
        -> [RetrievedPassage] {
        guard let queue = currentQueue() else { return [] }
        return try Self.recapPassages(before: boundary, limit: limit, in: queue)
    }

    static func recapPassages(
        before boundary: ReadingBoundary, limit: Int, in queue: DatabaseQueue,
    ) throws -> [RetrievedPassage] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT spineIndex, ordinal, start, end, words, text, 0.0 AS score
                FROM passage
                WHERE spineIndex < :spine
                   OR (spineIndex = :spine AND start < :offset)
                ORDER BY spineIndex DESC, ordinal DESC
                LIMIT :limit
                """, arguments: [
                "spine": boundary.spineIndex, "offset": boundary.charOffset, "limit": limit,
            ])
            // Back into reading order: a recap read backwards is a worse recap.
            return rows.compactMap { truncated($0, at: boundary) }
                .sorted { ($0.passage.spineIndex, $0.passage.ordinal)
                    < ($1.passage.spineIndex, $1.passage.ordinal) }
        }
    }

    /// Which of these words the book has not used yet.
    ///
    /// The short-circuit's evidence. A reader at the end of Chapter I asking
    /// about the Cheshire Cat has met no Cheshire and no Cat by that name, and
    /// the honest answer is that the story has not revealed it — but the model,
    /// handed six excerpts that mention neither, will describe the Cat from
    /// memory anyway. So the question is answered here, in SQL, before the model
    /// is given the chance.
    ///
    /// One indexed lookup per word, and a question has three or four at most.
    /// Truncation is not applied: a word that occurs only in the unread half of
    /// the straddling passage is vanishingly rare, and counting it as met is the
    /// conservative direction — it lets the question through to retrieval, which
    /// is itself bounded.
    public func unmetWords(_ words: [String], before boundary: ReadingBoundary) throws -> [String] {
        guard let queue = currentQueue() else { return words }
        return try Self.unmetWords(words, before: boundary, in: queue)
    }

    static func unmetWords(
        _ words: [String], before boundary: ReadingBoundary, in queue: DatabaseQueue,
    ) throws -> [String] {
        try queue.read { db in
            try words.filter { word in
                guard let pattern = FTS5Pattern(matchingAnyTokenIn: word) else { return false }
                let found = try Int.fetchOne(db, sql: """
                    SELECT 1
                    FROM passage
                    JOIN passage_fts ON passage_fts.rowid = passage.rowid
                    WHERE passage_fts MATCH :pattern
                      AND (passage.spineIndex < :spine
                           OR (passage.spineIndex = :spine AND passage.start < :offset))
                    LIMIT 1
                    """, arguments: [
                    "pattern": pattern, "spine": boundary.spineIndex,
                    "offset": boundary.charOffset,
                ])
                return found == nil
            }
        }
    }

    /// The people this book has introduced before the boundary, most mentioned
    /// first — the suggestion chip's whole input.
    public func topNames(before boundary: ReadingBoundary, limit: Int = 5) throws -> [String] {
        guard let queue = currentQueue() else { return [] }
        return try Self.topNames(before: boundary, limit: limit, in: queue)
    }

    static func topNames(
        before boundary: ReadingBoundary, limit: Int, in queue: DatabaseQueue,
    ) throws -> [String] {
        // Grouped by the folded key in SQL, then folded to one spelling in
        // Swift. The SQL alone cannot do the second half: choosing between
        // "VIN" and "Vin" is a judgement about which the book prints more
        // often, and — on a tie — about which of them is a heading shouting.
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT name, nameKey, SUM(mentions) AS mentions FROM name
                WHERE spineIndex < :spine
                   OR (spineIndex = :spine AND firstOffset < :offset)
                GROUP BY nameKey, name
                """, arguments: [
                "spine": boundary.spineIndex, "offset": boundary.charOffset,
            ])
        }
        let names = rows.map {
            NameFinder.Name(
                name: $0["name"], spineIndex: 0, firstOffset: 0, mentions: $0["mentions"] ?? 0,
            )
        }
        return NameFinder.merge(names).prefix(limit).map(\.name)
    }

    // MARK: - Deletion

    /// Drops one book's index. Called when its download is removed: the index
    /// is derived from a file that is no longer there, and keeping it would
    /// leave the text of a deleted book on disk.
    public func remove(bookUUID: String) {
        open[bookUUID] = nil
        if preparedBookUUID == bookUUID { preparedBookUUID = nil }
        let url = indexURL(for: bookUUID)
        for candidate in [url, Self.buildingURL(for: url)] {
            try? FileManager.default.removeItem(at: candidate)
            try? FileManager.default.removeItem(at: candidate.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: candidate.appendingPathExtension("shm"))
        }
    }

    /// Everything. Called on sign-out when the reader asks for downloads to go.
    public func removeAll() {
        open.removeAll()
        preparedBookUUID = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Opening

    private func existingQueue(at url: URL, bookUUID: String) throws -> DatabaseQueue? {
        if let queue = open[bookUUID] {
            preparedBookUUID = bookUUID
            return queue
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let queue = try Self.openQueue(at: url)
        open[bookUUID] = queue
        preparedBookUUID = bookUUID
        return queue
    }

    static func openQueue(at url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        // A build writes while the reader's previous question is still reading.
        configuration.busyMode = .timeout(5)
        return try DatabaseQueue(path: url.path, configuration: configuration)
    }

    /// Synchronous for the same reason `insert(_:into:)` is.
    static func storedKey(in queue: DatabaseQueue) throws -> IndexKey? {
        try queue.read { db in try storedKey(db) }
    }

    static func storedKey(_ db: Database) throws -> IndexKey? {
        guard let raw = try String.fetchOne(
            db, sql: "SELECT value FROM meta WHERE key = 'indexKey'",
        ) else { return nil }
        return IndexKey(storedValue: raw)
    }

    static func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.create(table: "chapter") { t in
                t.primaryKey("spineIndex", .integer)
                t.column("href", .text).notNull()
                /// UTF-16 length of the rendered chapter, so a boundary can be
                /// clamped without re-parsing.
                t.column("length", .integer).notNull()
            }
            try db.create(table: "passage") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("spineIndex", .integer).notNull()
                t.column("ordinal", .integer).notNull()
                t.column("start", .integer).notNull()
                t.column("end", .integer).notNull()
                t.column("words", .integer).notNull()
                t.column("text", .text).notNull()
            }
            // Book order is every query's ORDER BY and the boundary's WHERE.
            try db.create(
                index: "passage_on_position", on: "passage", columns: ["spineIndex", "start"],
            )
            // External-content FTS, synchronised with `passage`: one copy of
            // the text, and the triggers keep the index honest. Diacritics
            // removed to match `QueryTerms.tokens`, which folds them — a
            // question about "Bronte" has to reach a book that writes "Brontë".
            try db.create(virtualTable: "passage_fts", using: FTS5()) { t in
                t.synchronize(withTable: "passage")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("text")
            }
            try db.create(table: "name") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("spineIndex", .integer).notNull()
                t.column("firstOffset", .integer).notNull()
                t.column("mentions", .integer).notNull()
            }
            try db.create(index: "name_on_position", on: "name", columns: ["spineIndex", "firstOffset"])
        }
        // One spelling per person. Without this a book that shouts "VIN" in a
        // chapter heading and prints "Vin" in the prose keeps two rows, splits
        // the mention count between them, and drops its own protagonist out of
        // the top of the name table — which is the list that promotes a token
        // `NLTagger` missed. `IndexKey.currentSchemaVersion` is bumped with it,
        // so every index built before this rebuilds on the next `prepare`.
        migrator.registerMigration("v2") { db in
            try db.alter(table: "name") { t in
                t.add(column: "nameKey", .text).notNull().defaults(to: "")
            }
            try db.create(index: "name_on_key", on: "name", columns: ["nameKey"])
        }
        return migrator
    }
}

// MARK: -

/// How a bounded search hands back what it found.
public enum PassageOrder: Sendable, Hashable {
    /// SQLite's bm25, best first. What a general question wants.
    case relevance
    /// Reading order, earliest first.
    ///
    /// The order the evidence scan uses, and the reason its `LIMIT 300` is not
    /// a lottery: a novel introduces a character in the first paragraphs that
    /// mention them, so keeping the *earliest* hits keeps the sentences that
    /// say who somebody is. Relevance order under the same cap keeps whichever
    /// three hundred paragraphs repeat the name most, which is the opposite.
    case bookOrder

    var clause: String {
        switch self {
        case .relevance: "bm25(passage_fts)"
        case .bookOrder: "passage.spineIndex, passage.start"
        }
    }
}

// MARK: -

/// A passage that came back from a search, with what the search thought of it.
public struct RetrievedPassage: Sendable, Hashable {
    public var passage: Passage
    /// SQLite's bm25, which is *negative* and better the lower it is. The
    /// ranker negates it; nothing else should.
    public var bm25: Double
    /// Whether this is the passage the reader is standing in, cut short.
    public var isTruncated: Bool

    public init(passage: Passage, bm25: Double, isTruncated: Bool) {
        self.passage = passage
        self.bm25 = bm25
        self.isTruncated = isTruncated
    }
}
