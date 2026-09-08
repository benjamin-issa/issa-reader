import Foundation
import GRDB
import IssaEPUB
import Testing

@testable import IssaAsk

struct AskIndexStoreTests {
    // MARK: - Names, folded

    /// A scratch index with nothing in it but the name rows a test writes.
    static func nameTable(_ rows: [(String, Int, Int, Int)]) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AskIndexStore.migrator.migrate(queue)
        try queue.write { db in
            for (name, spine, offset, mentions) in rows {
                try db.execute(
                    sql: """
                        INSERT INTO name(name, nameKey, spineIndex, firstOffset, mentions)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [name, NameFinder.Name.key(for: name), spine, offset, mentions],
                )
            }
        }
        return queue
    }

    @Test("two spellings of one character are one row, spelled the way the book spells it")
    func topNamesFoldCase() throws {
        // The measured failure on a real book: the chapter headings shout
        // "RYN" and the prose prints "Ryn", so the protagonist held two rows,
        // split her mentions between them, and fell out of the two hundred
        // names a question is read against — which is the list that promotes a
        // token `NLTagger` missed.
        let queue = try Self.nameTable([
            ("RYN", 0, 0, 40), ("Ryn", 1, 10, 90), ("Marek", 1, 20, 100),
            ("Halvi", 2, 5, 30),
        ])
        let names = try AskIndexStore.topNames(
            before: ReadingBoundary(spineIndex: 9, charOffset: 0), limit: 5, in: queue,
        )
        #expect(names == ["Ryn", "Marek", "Halvi"])
        // 130 together beats Marek's 100; apart, neither half does.
        #expect(names.first == "Ryn")
    }

    @Test("a tie between two spellings is broken away from the shouted one")
    func topNamesPreferTheQuietSpelling() throws {
        let queue = try Self.nameTable([("RYN", 0, 0, 50), ("Ryn", 1, 0, 50)])
        let names = try AskIndexStore.topNames(
            before: ReadingBoundary(spineIndex: 9, charOffset: 0), limit: 5, in: queue,
        )
        // An all-capitals spelling is a heading; the character is the other one.
        #expect(names == ["Ryn"])
    }

    @Test("the folded name table is still bounded by the reading position")
    func topNamesStayBounded() throws {
        let queue = try Self.nameTable([("RYN", 0, 0, 5), ("Ryn", 4, 0, 90)])
        let early = try AskIndexStore.topNames(
            before: ReadingBoundary(spineIndex: 2, charOffset: 0), limit: 5, in: queue,
        )
        // Only the shout has been reached, so only its count is there — the
        // fold must not drag a later chapter's mentions back over the boundary.
        #expect(early == ["RYN"])
    }

    // MARK: - Matching words the reader has met

    @Test("a word met in another case is still met")
    func unmetWordsIgnoreCase() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        // `unicode61` case-folds, so the guard is case-insensitive without
        // doing anything about it — asserted rather than assumed, because a
        // tokeniser change here would silently start refusing every question
        // whose name the reader typed in lower case.
        let unmet = try await store.unmetWords(
            ["alice", "ALICE", "Alice", "dinah"],
            in: AskFixture.bookUUID,
            before: AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )
        #expect(unmet.isEmpty)
    }

    // MARK: - Building

    @Test("a build produces one file, and reports that it built")
    func buildsOnce() async throws {
        let directory = try AskFixture.temporaryDirectory()
        defer { AskFixture.remove(directory) }
        let store = AskIndexStore(directory: directory)
        let source = try AskFixture.source()

        let before = await store.isPrepared(source: source)
        #expect(!before)
        let built = try await store.prepare(source: source)
        #expect(built)
        let after = await store.isPrepared(source: source)
        #expect(after)

        let url = store.indexURL(for: AskFixture.bookUUID)
        #expect(FileManager.default.fileExists(atPath: url.path))
        // The scratch file must not survive: it looks exactly like a current
        // index to anything that only checks for a file.
        #expect(!FileManager.default.fileExists(
            atPath: AskIndexStore.buildingURL(for: url).path,
        ))
        // Asked again, it does not rebuild.
        let rebuilt = try await store.prepare(source: source)
        #expect(!rebuilt)
    }

    // MARK: - Navigation documents

    /// The exact signal, which no fixture can exercise on its own.
    ///
    /// Both Gutenberg books declare a nav document and an NCX and put neither
    /// in the spine — so the declaration fires on nothing at all in either
    /// fixture, while the edition the bug was screenshotted on *does* page to
    /// its own contents. Driving `parseChapter` with Chapter I declared as
    /// navigation is the only way to assert that half without shipping a third
    /// book.
    @Test("a document the manifest calls navigation contributes nothing to the index")
    func aDeclaredNavigationDocumentIsSkipped() throws {
        let package = try AskFixture.package()
        let href = package.spine[AskFixture.Spine.chapterI].href
        let navigation = AskIndexStore.Navigation(documents: [href])

        let skipped = try #require(AskIndexStore.parseChapter(
            archive: package.archive, href: href,
            spineIndex: AskFixture.Spine.chapterI, navigation: navigation,
        ))
        #expect(skipped.passages.isEmpty)
        // A table of contents introduces nobody: its names are chapter titles,
        // and "Alice's Evidence" would tell the boundary the reader had met
        // Alice on the contents page.
        #expect(skipped.names.isEmpty)
        // The row itself is still written, with its real length. A missing one
        // would say the spine item does not exist, which is a different and
        // untrue thing — the reader can be standing in it.
        #expect(skipped.length > 0)

        let kept = try #require(AskIndexStore.parseChapter(
            archive: package.archive, href: href, spineIndex: AskFixture.Spine.chapterI,
        ))
        #expect(!kept.passages.isEmpty)
        #expect(kept.length == skipped.length)
    }

    // MARK: - Front matter

    @Test("a document the book's own landmarks call front matter is skipped too")
    func frontMatterContributesNothingToTheIndex() throws {
        // Measured on a published novel: sixteen front-matter passages reached
        // the model as story — the dedication, the acknowledgments, the author's
        // preface — and it answered from them. Neither Gutenberg fixture has
        // landmarks, so Chapter I stands in for the dedication here.
        let package = try AskFixture.package()
        let href = package.spine[AskFixture.Spine.chapterI].href
        let navigation = AskIndexStore.Navigation(frontMatter: [href])

        let skipped = try #require(AskIndexStore.parseChapter(
            archive: package.archive, href: href,
            spineIndex: AskFixture.Spine.chapterI, navigation: navigation,
        ))
        #expect(skipped.passages.isEmpty)
        #expect(skipped.names.isEmpty)
        // The row still exists with its real length: the reader pages through
        // the dedication like any other page, and a missing row would say the
        // spine item is not there.
        #expect(skipped.length > 0)
    }

    /// The fragment guard, against the fixture that motivated it.
    ///
    /// Franklin's EPUB 2 guide points `toc` at
    /// `…20203-h-0.htm.html#pgepubid00004`, and that document also holds the
    /// editor's Introduction *and* Chapter I. `EPUBPackage.resolve` strips
    /// fragments, so a guide read without the guard deletes about 46 KB of the
    /// book — every question about the introduction answered from nothing.
    @Test("a guide entry pointing into a chapter cannot delete it")
    func theGuideCannotDeleteAChapter() throws {
        let package = try AskFixture.franklin.package()
        // The cover wrapper, whose reference has no fragment. Nothing else.
        #expect(package.frontMatter == ["OEBPS/wrap0000.html"])
        #expect(!package.frontMatter.contains { $0.hasSuffix("20203-h-0.htm.html") })
    }

    /// What keeps `PassageChunkerTests.dropsTheContentsList` and
    /// `IndexOffsetTests.theContentsTableIsNotStored` honest: neither Gutenberg
    /// book declares landmarks or a guide, so this rule must change nothing
    /// about either of them, and those two suites are asserting on exact sets of
    /// spine indices that would move if it did.
    @Test("a book that names no front matter loses nothing")
    func aBookWithoutLandmarksNamesNothing() throws {
        let package = try AskFixture.package()
        #expect(package.frontMatter.isEmpty)
        #expect(!AskIndexStore.Navigation(package: package)
            .excludes(package.spine[AskFixture.Spine.chapterI].href))
    }

    @Test("Alice is the book's most-mentioned person")
    func findsTheTopName() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let names = try await store.topNames(
            in: AskFixture.bookUUID,
            before: AskFixture.endOf(spine: AskFixture.Spine.chapterVI), limit: 5,
        )
        // The whole suggestion chip rests on this. A capital-letter heuristic
        // offers "Who is Chapter?"; `NLTagger` with `.personalName` does not.
        #expect(names.first == "Alice")
        #expect(!names.contains { $0.lowercased().contains("chapter") })
        #expect(!names.contains { $0.lowercased().contains("wonderland") })
    }

    @Test("progress is reported per chapter, ending at the total")
    func reportsProgress() async throws {
        let directory = try AskFixture.temporaryDirectory()
        defer { AskFixture.remove(directory) }
        let store = AskIndexStore(directory: directory)
        let source = try AskFixture.source()

        let phases = Recorder()
        try await store.prepare(source: source) { phase in phases.append(phase) }
        let seen = phases.value
        // A long illustrated book takes fifteen seconds to index; an indefinite
        // spinner for that long reads as a hang.
        #expect(seen.allSatisfy { if case .preparingIndex = $0 { true } else { false } })
        #expect(seen.count == source.package.spine.count + 1)
        #expect(seen.last == .preparingIndex(
            done: source.package.spine.count, total: source.package.spine.count,
        ))
    }

    // MARK: - Repairing a broken index

    /// A file that exists, opens, and is not an index.
    ///
    /// Zero-length rather than garbage: garbage is the easy case, because
    /// SQLite refuses to open it and `prepare` falls through to the repair on
    /// its own. A zero-length file *is* a valid empty database, so it opens,
    /// and it is `storedKey` that fails — three lines past the repair.
    @Test(
        "an index that opens but holds nothing is rebuilt, not failed for ever",
        arguments: [Data(), Data("not a database at all, just bytes".utf8)],
    )
    func aBrokenIndexIsRepaired(contents: Data) async throws {
        let directory = try AskFixture.temporaryDirectory()
        defer { AskFixture.remove(directory) }
        let store = AskIndexStore(directory: directory)
        let source = try AskFixture.source()
        try contents.write(
            to: AskIndexStore.indexURL(in: directory, bookUUID: AskFixture.bookUUID),
        )

        #expect(!(await store.isPrepared(source: source)))
        #expect(try await store.prepare(source: source), "a broken index has to be rebuilt")
        #expect(await store.isPrepared(source: source))

        // And the rebuilt one answers, rather than being a handle to the file
        // that was there before: the broken handle was cached by the open that
        // failed, so every later attempt read it again and failed identically.
        let hits = try await store.retrieve(
            terms: QueryTerms.extract(from: "What did Alice follow down the hole?"),
            in: AskFixture.bookUUID,
            before: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )
        #expect(hits.contains { $0.passage.text.lowercased().contains("rabbit") })
    }

    // MARK: - Invalidation

    @Test("a changed file invalidates the index rather than answering from the old one")
    func invalidatesOnFingerprintChange() async throws {
        let directory = try AskFixture.temporaryDirectory()
        defer { AskFixture.remove(directory) }
        let store = AskIndexStore(directory: directory)

        // The fingerprint is taken from a file the test can change while the
        // book stays the pristine fixture — the fingerprint is what is under
        // test, not the parser.
        let copy = directory.appending(path: "book.epub")
        try FileManager.default.copyItem(at: try AskFixture.url(), to: copy)
        let source = try AskFixture.source(fingerprintedAt: copy)
        let built = try await store.prepare(source: source)
        #expect(built)
        let current = await store.isPrepared(source: source)
        #expect(current)

        let handle = try FileHandle(forWritingTo: copy)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0, count: 64))
        try handle.close()

        // A re-downloaded or re-encoded book moves every offset in the index,
        // and an offset that has moved puts the spoiler boundary in the wrong
        // place.
        let changed = try AskFixture.source(fingerprintedAt: copy)
        let stillCurrent = await store.isPrepared(source: changed)
        #expect(!stillCurrent)
        let rebuilt = try await store.prepare(source: changed)
        #expect(rebuilt)
    }

    /// A handle that outlived the file it was opened for.
    ///
    /// `prepare` clears the cached handle and then awaits `build` — which
    /// suspends once per spine item at `parsedChapter`, and an actor is
    /// reentrant at every one of those. Any isolated read landing in one of
    /// those windows found the *old* `<uuid>.sqlite` still on disk, because
    /// `build` writes to `<uuid>.building.sqlite`, opened it and cached it.
    /// `build` then renamed over it, unlinking the inode that handle holds, and
    /// **every** later read for that book threw `SQLite error 10: disk I/O
    /// error` until the next `prepare` — one mistimed suggestion chip and the
    /// book could not be asked about again.
    ///
    /// Armed for every existing reader by `IndexKey.currentParserVersion = 2`,
    /// which makes the first launch on this branch rebuild every book that has
    /// already been indexed.
    ///
    /// The read is fired from the progress callback, which runs inside `build`,
    /// so the task it starts is enqueued behind the actor and runs at the next
    /// chapter's suspension — the window itself, rather than a sleep that hopes
    /// to land in one. Whether those reads succeed is not the assertion; they
    /// are reading an index that is on its way out. The assertion is that the
    /// reads *after* the rename do.
    @Test("a read landing in the middle of a build does not strand the handle")
    func aReadDuringABuildDoesNotStrandTheHandle() async throws {
        let directory = try AskFixture.temporaryDirectory()
        defer { AskFixture.remove(directory) }
        let store = AskIndexStore(directory: directory)

        // A stale index, which is what every already-indexed book is on this
        // branch's first launch.
        let copy = directory.appending(path: "book.epub")
        try FileManager.default.copyItem(at: try AskFixture.url(), to: copy)
        #expect(try await store.prepare(source: AskFixture.source(fingerprintedAt: copy)))
        let handle = try FileHandle(forWritingTo: copy)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0, count: 64))
        try handle.close()
        let stale = try AskFixture.source(fingerprintedAt: copy)
        #expect(!(await store.isPrepared(source: stale)))

        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterVI)
        let probes = MidBuildProbes(store: store, boundary: boundary)
        let rebuilt = try await store.prepare(source: stale) { phase in
            guard case .preparingIndex = phase else { return }
            probes.probe()
        }
        #expect(rebuilt)
        await probes.finish()
        #expect(probes.count > 0, "no read was fired into the build, so nothing was tested")

        // The reads that matter: the ones after the rename, through the
        // cache-first accessor the mid-build reads went through.
        #expect(await store.isPrepared(source: stale))
        let names = try await store.topNames(
            in: AskFixture.bookUUID, before: boundary, limit: 5)
        #expect(names.contains("Alice"), "the rebuilt index answered with \(names)")
        let hits = try await store.retrieve(
            terms: QueryTerms.extract(from: "What did Alice follow down the hole?"),
            in: AskFixture.bookUUID, before: boundary,
        )
        #expect(hits.contains { $0.passage.text.lowercased().contains("rabbit") })
        #expect(try await store.recapPassages(
            in: AskFixture.bookUUID, before: boundary, limit: AskRetriever.Limits.excerpts,
        ).count > 0)
        #expect(try await store.unmetWords(
            ["zzzunlikelyword"], in: AskFixture.bookUUID, before: boundary) == ["zzzunlikelyword"])
    }

    @Test("the fingerprint round-trips through its stored form")
    func fingerprintRoundTrips() {
        let key = IndexKey(fileSize: 12_345, modified: 1_700_000_000, spineCount: 15)
        #expect(IndexKey(storedValue: key.storedValue) == key)
        #expect(IndexKey(storedValue: "nonsense") == nil)
        // A parser change moves every offset, so it must not match an old index.
        var older = key
        older.parserVersion -= 1
        #expect(older != key)
    }

    // MARK: - Deleting

    @Test("removing a book takes its index and its side files with it")
    func removesOneBook() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let url = store.indexURL(for: AskFixture.bookUUID)
        await store.remove(bookUUID: AskFixture.bookUUID)
        // The index is the text of a book that is no longer on the device.
        for suffix in ["", "-wal", "-shm"] {
            #expect(!FileManager.default.fileExists(atPath: url.path + suffix))
        }
        let gone = await store.isPrepared(source: source)
        #expect(!gone)
    }

    @Test("removing everything takes the directory")
    func removesAll() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        await store.removeAll()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Cancellation

    @Test("a cancelled build leaves no file behind")
    func cancelledBuildLeavesNothing() async throws {
        let directory = try AskFixture.temporaryDirectory()
        defer { AskFixture.remove(directory) }
        let store = AskIndexStore(directory: directory)
        let source = try AskFixture.source()

        let task = Task { try await store.prepare(source: source) }
        // Cancelled before it runs, so the first chapter's check trips: the
        // point is what is left on disk, and the loop checks between chapters.
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        // A half-written index looks current and answers every later question
        // from a fraction of the book with no sign that anything is wrong.
        let url = store.indexURL(for: AskFixture.bookUUID)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(
            atPath: AskIndexStore.buildingURL(for: url).path,
        ))
        let prepared = await store.isPrepared(source: source)
        #expect(!prepared)
    }

    // MARK: - Naming

    @Test("a uuid that is not a uuid cannot choose the path")
    func refusesToBuildAPathFromAnything() {
        let directory = URL(filePath: "/tmp/ask")
        let safe = AskIndexStore.indexURL(
            in: directory, bookUUID: "0f0f0f0f-1111-4222-8333-444444444444",
        )
        #expect(safe.lastPathComponent == "0f0f0f0f-1111-4222-8333-444444444444.sqlite")

        // A catalogue entry whose uuid escapes the directory would otherwise let
        // the server choose the path this writes to.
        let hostile = AskIndexStore.indexURL(
            in: directory, bookUUID: "../../Library/Preferences/x",
        )
        #expect(hostile.deletingLastPathComponent().path == directory.path)
        #expect(hostile.lastPathComponent.hasPrefix("unsafe-"))
        // Hashed, not stripped, so it still names the same file every time.
        #expect(hostile == AskIndexStore.indexURL(
            in: directory, bookUUID: "../../Library/Preferences/x",
        ))
    }
}

// MARK: -

/// Collects progress callbacks, which arrive from the store's executor.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [AskPhase] = []

    func append(_ phase: AskPhase) {
        lock.lock()
        defer { lock.unlock() }
        phases.append(phase)
    }

    var value: [AskPhase] {
        lock.lock()
        defer { lock.unlock() }
        return phases
    }
}

/// Reads fired from inside a build, which is what a sheet drawing its
/// suggestion chips does while the progress bar is still moving.
///
/// Started from the progress callback, which runs on the store's own executor
/// inside `build`: the task is therefore enqueued behind the actor and runs at
/// the next chapter's suspension point, which is the reentrancy window the
/// stranded-handle bug lives in. A sleep would only hope to land there.
///
/// Whether these reads succeed is not asserted — they are reading an index that
/// is being replaced underneath them, and either answer is honest. What they
/// are here to do is populate the handle cache while the old file is still on
/// disk, so that the reads *after* the rename have something to get wrong.
private final class MidBuildProbes: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private let store: AskIndexStore
    private let boundary: ReadingBoundary

    init(store: AskIndexStore, boundary: ReadingBoundary) {
        self.store = store
        self.boundary = boundary
    }

    func probe() {
        let task = Task { [store, boundary] in
            _ = try? await store.topNames(in: AskFixture.bookUUID, before: boundary, limit: 5)
            _ = try? await store.recapPassages(in: AskFixture.bookUUID, before: boundary, limit: 3)
        }
        lock.lock()
        defer { lock.unlock() }
        tasks.append(task)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return tasks.count
    }

    /// Synchronous, because `NSLock.lock()` is unavailable from an async
    /// context — the await below has to happen outside the lock anyway.
    private func pending() -> [Task<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        return tasks
    }

    func finish() async {
        for task in pending() { await task.value }
    }
}
