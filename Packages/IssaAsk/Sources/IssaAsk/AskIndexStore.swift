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
    /// Open handles, keyed by book, each remembering the file it was opened
    /// for. A reader asks several questions in a row about one book;
    /// re-opening the file each time is pure cost.
    private var open: [String: OpenIndex] = [:]

    /// One cached handle, and which file on disk it is a handle *to*.
    ///
    /// The pair is the whole point. A `DatabaseQueue` holds a descriptor, and a
    /// descriptor outlives the name it was opened under: `build` publishes by
    /// renaming `<uuid>.building.sqlite` over `<uuid>.sqlite`, which unlinks
    /// the inode any handle opened beforehand is still pointing at. Keeping the
    /// identity beside the handle is what lets `queue(for:)` notice, and
    /// noticing is the difference between one stale read and every read for
    /// that book throwing `SQLite error 10: disk I/O error` until the next
    /// `prepare`.
    private struct OpenIndex {
        let queue: DatabaseQueue
        let identity: FileIdentity
    }

    /// Which file, as the file system means it — not which path.
    ///
    /// Device and inode together, because an inode number is only unique
    /// within a volume and the Ask directory is not promised to stay on one.
    struct FileIdentity: Equatable {
        let device: Int
        let inode: UInt64

        /// The file at this URL, or nil where there is none. One `stat`, which
        /// also answers the "does it exist" question `queue(for:)` used to ask
        /// separately.
        static func of(_ url: URL) -> FileIdentity? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let device = (attributes[.systemNumber] as? NSNumber)?.intValue
            else { return nil }
            return FileIdentity(device: device, inode: inode)
        }
    }

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
    /// the directory. `String.safePathComponent` is that rule, shared with every
    /// other place a book id names something on disk.
    public static func indexURL(in directory: URL, bookUUID: String) -> URL {
        directory.appending(path: "\(bookUUID.safePathComponent).sqlite")
    }

    static func buildingURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("building.sqlite")
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

        // `try?`, matching `isPrepared` twelve lines down. A bare `try` threw
        // straight past the repair three lines below — and `queue(for:)` had
        // already cached the handle to the broken file, so the next attempt read
        // the same broken index and failed identically, for ever. A zero-length
        // `.sqlite` is the case: SQLite opens it happily as an empty database
        // and `storedKey` then throws "no such table: meta".
        if let queue = try? queue(for: source.bookUUID),
           (try? Self.storedKey(in: queue)) == key {
            return false
        }

        // Stale, corrupt or absent — all three are the same repair.
        open[source.bookUUID] = nil
        try await build(source: source, key: key, destination: url, progress: progress)
        // Opened here so a question asked immediately afterwards finds a handle
        // rather than silently retrieving nothing.
        _ = try queue(for: source.bookUUID)
        return true
    }

    /// Whether a usable, current index already exists — the question the sheet
    /// asks before deciding to show a progress bar at all.
    ///
    /// Read-only, which it once was not: it opened the file through a helper
    /// that also recorded the book as the one the store was answering about, so
    /// merely drawing a second book's suggestion chips redirected the first
    /// book's question. See `queue(for:)`.
    public func isPrepared(source: BookSource) -> Bool {
        guard let queue = try? queue(for: source.bookUUID) else { return false }
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
        // Read once, off the package the caller already opened: the manifest
        // and the contents are parsed when the EPUB is opened, and asking per
        // chapter would build the same two sets fifteen times.
        let navigation = Navigation(package: source.package)
        do {
            let queue = try Self.openQueue(at: building)
            try Self.migrator.migrate(queue)

            for (index, item) in source.package.spine.enumerated() {
                // Between chapters, not inside one: a chapter is a few
                // milliseconds and a half-parsed one has nothing to keep.
                try Task.checkCancellation()
                progress?(.preparingIndex(done: index, total: total))

                let parsed = await Self.parsedChapter(
                    archive: source.package.archive, href: item.href, spineIndex: index,
                    navigation: navigation,
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
        // The excluded count, because a landmarks parse that silently finds
        // nothing fails no test while still charging every reader a reindex —
        // this line is the only way to tell "shipped and working" from "shipped
        // and inert" on a device.
        IssaLog.info("ask index built", [
            "chapters": String(total),
            "frontMatter": String(navigation.frontMatter.count),
        ])
    }

    // MARK: - Chapter parsing

    /// What the book says about which of its documents are not story, so the
    /// index can leave them out.
    ///
    /// Every signal comes out of the OPF and the navigation document
    /// `EPUBPackage` has already parsed, so nothing here reads the archive.
    /// They are needed together because none alone covers a real book:
    /// Gutenberg declares a nav document and an NCX and puts *neither* in the
    /// spine, printing its contents table inside the header page instead — so
    /// the exact signal fires on nothing at all in either fixture, while the
    /// header page it misses is the one that was caught citing "CHAPTER XII.
    /// Alice's Evidence" as evidence.
    struct Navigation: Sendable {
        /// Archive paths the manifest declares as navigation. Exact, and
        /// skipped whole: a document that *is* the table of contents has no
        /// evidence anywhere in it.
        var documents: Set<String> = []
        /// The contents' own entry titles, which is what tells a list of
        /// chapter headings from a poem of equally short lines.
        var titles: [String] = []
        /// Archive paths the book's own landmarks or guide call apparatus. On a
        /// real novel this is what stops the dedication, the copyright notice
        /// and the acknowledgments being served to the model as story — sixteen
        /// such passages were measured reaching it, and it answered from them.
        var frontMatter: Set<String> = []

        init(package: EPUBPackage) {
            documents = package.navigationDocuments
            titles = package.navigation.map(\.title)
            frontMatter = package.frontMatter
        }

        init(
            documents: Set<String> = [], titles: [String] = [],
            frontMatter: Set<String> = [],
        ) {
            self.documents = documents
            self.titles = titles
            self.frontMatter = frontMatter
        }

        /// Whether this document contributes nothing to the index — because it
        /// *is* the navigation, or because the book calls it apparatus.
        func excludes(_ href: String) -> Bool {
            documents.contains(href) || frontMatter.contains(href)
        }
    }

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
    /// The same parse, off this actor for real.
    ///
    /// `parseChapter` is `nonisolated`, but `build` called it *synchronously*
    /// from an isolated function, and a synchronous call does not hop anywhere
    /// — so every chapter of a 250,000-word book inflated, parsed and chunked
    /// inline on the store's own executor, which is the opposite of what both
    /// that function's doc and this type's header claim. The actor also has to
    /// answer `remove(bookUUID:)` when a download goes, and that call sat
    /// behind the whole build.
    ///
    /// `nonisolated async` runs on the global executor, so awaiting it is the
    /// hop. The suspension it adds is *between* chapters, where the loop
    /// already checks for cancellation: a `remove` arriving there deletes the
    /// `.building.sqlite` file, the rename that publishes the index then fails,
    /// and `prepare` reports a failed build — which is the same outcome as the
    /// cancellation the reader could have caused a line earlier, and not a
    /// half-written index, because nothing is published until the rename.
    nonisolated static func parsedChapter(
        archive: EPUBArchive, href: String, spineIndex: Int,
        navigation: Navigation = Navigation(),
    ) async -> ParsedChapter? {
        parseChapter(
            archive: archive, href: href, spineIndex: spineIndex, navigation: navigation,
        )
    }

    nonisolated static func parseChapter(
        archive: EPUBArchive, href: String, spineIndex: Int,
        navigation: Navigation = Navigation(),
    ) -> ParsedChapter? {
        let images = ArchiveImageSource(archive: archive)
        guard let data = try? archive.read(href),
              let parsed = try? HTMLContentParser(
                  style: ReaderStyle(), loadImage: { images.image(for: $0) },
              ).parse(xhtml: data, baseHref: href)
        else { return nil }

        let text = parsed.text.string
        // The row is still written, with its real length and no passages: the
        // chapter exists, the reader can be standing in it — a dedication is a
        // page they turn past — and it simply has nothing to retrieve. A
        // missing row would say the spine item does not exist, which is a
        // different and untrue thing.
        let passages = navigation.excludes(href) ? [] : PassageChunker.indexable(
            text: text, spineIndex: spineIndex, navigationTitles: navigation.titles,
        )
        return ParsedChapter(
            spineIndex: spineIndex,
            href: href,
            length: (text as NSString).length,
            passages: passages,
            // Only the people in the text that survived. A table of contents
            // introduces nobody — its names are chapter titles, and one of them
            // ("Alice's Evidence") would tell the boundary the reader had met
            // Alice on the contents page — and Gutenberg's credits block
            // introduces its transcribers, which is how "Who is David Widger?"
            // came to sit beside "Who is Alice?" under the question field.
            //
            // Filtered by where the *first* mention falls, not re-tagged over
            // each passage: `NLTagger` costs far more per call than per
            // character, and running it two dozen times a chapter to save one
            // row is the wrong trade on a 250,000-word book. The cost is that a
            // name introduced in the boilerplate loses this chapter's row
            // entirely — which for the author's name on a Gutenberg header page
            // is the outcome wanted anyway.
            names: NameFinder.names(in: text, spineIndex: spineIndex).filter { name in
                passages.contains { $0.start <= name.firstOffset && name.firstOffset < $0.end }
            },
        )
    }

    /// Writes one chapter's rows.
    ///
    /// Synchronous on purpose. GRDB gives `read` and `write` both a synchronous
    /// and an asynchronous overload, and inside an `async` function Swift picks
    /// the asynchronous one — which suspends in the middle of writing one
    /// chapter, where an actor is reentrant: a `remove(bookUUID:)` arriving
    /// there would delete the file this write is halfway through. A synchronous
    /// helper selects the synchronous overload, which is also what
    /// `LibraryStore` uses throughout.
    ///
    /// The loop around this does suspend, once per chapter, to parse the next
    /// one off the actor — but *between* chapters, next to the cancellation
    /// check, where a `remove` costs a failed rename and a build that reports
    /// itself failed rather than a half-written row. `parsedChapter` says so.
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

    static func insert(_ chapter: ParsedChapter, into db: Database) throws {
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
            // `nameKey` is what "RYN" and "Ryn" have in common. Stored rather
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
    ///
    /// - Parameter bookUUID: which book to answer for. Named at every call
    ///   rather than remembered, for the reason `queue(for:)` gives.
    public func retrieve(
        terms: QueryTerms, in bookUUID: String, before boundary: ReadingBoundary, limit: Int = 40,
    ) throws -> [RetrievedPassage] {
        guard let queue = try queue(for: bookUUID) else { return [] }
        return try Self.retrieve(terms: terms, before: boundary, limit: limit, in: queue)
    }

    static func retrieve(
        terms: QueryTerms, before boundary: ReadingBoundary, limit: Int, in queue: DatabaseQueue,
    ) throws -> [RetrievedPassage] {
        // `FTSQuery.any`, not `FTS5Pattern(matchingAnyTokenIn:)`, which runs the
        // ASCII tokeniser over what it is handed: "jean'luc" went in as one
        // token and came out as `jean OR luc`, matching every paragraph with
        // either half in it. `FTSQuery` quotes each token, so a token carrying
        // an apostrophe or a hyphen is a phrase rather than an accident.
        guard let pattern = FTSQuery.any(terms.searchTokens) else { return [] }
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
        in bookUUID: String,
        before boundary: ReadingBoundary,
        order: PassageOrder = .relevance,
        limit: Int,
    ) throws -> [RetrievedPassage] {
        guard let queue = try queue(for: bookUUID) else { return [] }
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
                       \(order.score) AS score
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
    ///
    /// `limit` has no default on purpose. It had one of six, and the recap
    /// branch of `AskRetriever` quietly took it while every other branch was
    /// being tuned — so a caller that forgets the excerpt count now fails to
    /// compile rather than silently answering with a stale one.
    public func recapPassages(
        in bookUUID: String, before boundary: ReadingBoundary, limit: Int,
    ) throws -> [RetrievedPassage] {
        guard let queue = try queue(for: bookUUID) else { return [] }
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
    /// - Parameter bookUUID: which book to probe. No index for it means every
    ///   word is unmet — the conservative direction, and the opposite of the
    ///   one the other retrieval methods take: unknown means unmet means refuse.
    public func unmetWords(
        _ words: [String], in bookUUID: String, before boundary: ReadingBoundary,
    ) throws -> [String] {
        guard let queue = try queue(for: bookUUID) else { return words }
        return try Self.unmetWords(words, before: boundary, in: queue)
    }

    static func unmetWords(
        _ words: [String], before boundary: ReadingBoundary, in queue: DatabaseQueue,
    ) throws -> [String] {
        try queue.read { db in
            // One preparation, N probes. Prepared inside the filter, SQLite
            // parsed and planned the same statement once per candidate — and
            // the answer-side guard now offers it more candidates than it used
            // to, because the sentence-opener exemption became conditional.
            let statement = try db.cachedStatement(sql: """
                SELECT 1
                FROM passage
                JOIN passage_fts ON passage_fts.rowid = passage.rowid
                WHERE passage_fts MATCH :pattern
                  AND (passage.spineIndex < :spine
                       OR (passage.spineIndex = :spine AND passage.start < :offset))
                LIMIT 1
                """)
            return try words.filter { word in
                // `FTSQuery.all`, not `FTS5Pattern(matchingAnyTokenIn:)`, which
                // probed "jean'luc" as `jean OR luc` and called the name met
                // when only one half of it had appeared — an unmet name walking
                // straight past the spoiler guard. Quoted, it is a phrase, and
                // only the whole name counts as met.
                guard let pattern = FTSQuery.all([word]) else { return false }
                let found = try Int.fetchOne(statement, arguments: [
                    "pattern": pattern, "spine": boundary.spineIndex,
                    "offset": boundary.charOffset,
                ])
                return found == nil
            }
        }
    }

    /// The people this book has introduced before the boundary, most mentioned
    /// first — the suggestion chip's whole input.
    public func topNames(
        in bookUUID: String, before boundary: ReadingBoundary, limit: Int = 5,
    ) throws -> [String] {
        guard let queue = try queue(for: bookUUID) else { return [] }
        return try Self.topNames(before: boundary, limit: limit, in: queue)
    }

    static func topNames(
        before boundary: ReadingBoundary, limit: Int, in queue: DatabaseQueue,
    ) throws -> [String] {
        // Grouped by the folded key in SQL, then folded to one spelling in
        // Swift. The SQL alone cannot do the second half: choosing between
        // "RYN" and "Ryn" is a judgement about which the book prints more
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
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Opening

    /// This book's handle, opening the file if it exists and is not open yet.
    ///
    /// Caching a handle is all this does. It used to *also* record the book as
    /// the one the store was answering about, and five retrieval methods took
    /// no uuid at all and read whichever book was recorded last — so on one
    /// phone, with one question in flight: ask about *Alice*, dismiss the sheet
    /// (the job deliberately outlives it), open another book, and its sheet
    /// calls `prepare` and `isPrepared`. *Alice*'s next hop then resolved to the
    /// other book's queue while still carrying *Alice*'s spine index and
    /// character offset — the other book's unread text, cut at a page number
    /// from a different book, shown to a reader of *Alice*.
    ///
    /// The uuid is now a parameter of every query, matching `remove(bookUUID:)`
    /// and `indexURL(for:)`, which already key on it.
    ///
    /// **The cached handle is checked against the file it was opened for, every
    /// time.** Without that, a handle outlived its file. `prepare` clears the
    /// entry, then awaits `build` — which suspends once per spine item at
    /// `parsedChapter`, and an actor is reentrant at every one of those. Any
    /// isolated read landing in one of those windows (`isPrepared`, `topNames`,
    /// `retrieve`, `recapPassages`, `unmetWords`) found the *old*
    /// `<uuid>.sqlite` still on disk — `build` writes to
    /// `<uuid>.building.sqlite` — opened it, and cached it. `build` then
    /// renamed over it, unlinking the inode that handle holds, and every
    /// subsequent read for that book threw `SQLite error 10: disk I/O error`
    /// until the next `prepare`. Reproduced on the *Alice* fixture with a stale
    /// index seeded; `IndexKey.currentParserVersion = 2` arms it for every
    /// already-indexed book on first launch, because that forces a rebuild of
    /// all of them.
    ///
    /// Comparing paths would not have caught it — the path is identical either
    /// side of the rename. It is the same file *name* and a different file, so
    /// the identity is device and inode.
    private func queue(for bookUUID: String) throws -> DatabaseQueue? {
        let url = indexURL(for: bookUUID)
        guard let identity = FileIdentity.of(url) else {
            // No file, so nothing a handle could still be valid for. Dropping
            // it here is what makes `remove(bookUUID:)` safe to race with, too.
            open[bookUUID] = nil
            return nil
        }
        if let cached = open[bookUUID], cached.identity == identity { return cached.queue }
        let queue = try Self.openQueue(at: url)
        open[bookUUID] = OpenIndex(queue: queue, identity: identity)
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
        // One spelling per person. Without this a book that shouts "RYN" in a
        // chapter heading and prints "Ryn" in the prose keeps two rows, splits
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

    /// What goes in the SELECT for the score.
    ///
    /// Zero for a book-ordered scan, because `bm25()` is not free: it is
    /// computed per returned row, and three hundred of them was two thirds of
    /// the whole evidence scan's time on a 300,000-word book. Nothing
    /// downstream of the evidence path reads the score — the sentences decide.
    var score: String {
        switch self {
        case .relevance: "bm25(passage_fts)"
        case .bookOrder: "0.0"
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
