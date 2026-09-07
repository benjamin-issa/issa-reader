import Foundation
import GRDB
import IssaEPUB
import IssaRender
import Testing

@testable import IssaAsk

/// The book every suite in here asks questions about.
///
/// A real Gutenberg EPUB rather than a hand-built one, because the assertions
/// that matter are about offsets in a *rendered* chapter — images, entities,
/// headings and all — and a synthetic fixture would test the assertion rather
/// than the book.
enum AskFixture {
    /// *Alice's Adventures in Wonderland*, Gutenberg #11 — the book almost
    /// every suite in here is written against.
    static let alice = AskBook(
        resource: "Fixtures/alice", bookUUID: "0f0f0f0f-1111-4222-8333-444444444444",
    )

    /// *Autobiography of Benjamin Franklin*, Gutenberg #20203 — non-fiction,
    /// with an editor's introduction and a letter from the author to his son.
    ///
    /// A second book because *Alice* cannot express the shape the reported bug
    /// arrived in. "What happened to the author's son?" needs a book that has
    /// an author *in* it — a first person who is also the subject, a preface
    /// written by somebody else, and a Gutenberg header printing "Author:
    /// Benjamin Franklin" for the word `author` to match on. Every one of those
    /// is absent from a children's novel, and the retrieval bug in
    /// `QueryTerms.bookRoles` is invisible without them.
    static let franklin = AskBook(
        resource: "Fixtures/franklin", bookUUID: "2b2b2b2b-3333-4444-8555-666666666666",
    )

    /// A bare uuid, so the store names the index file rather than hashing it.
    static let bookUUID = alice.bookUUID

    /// A second book on the same shelf. One store serves every book the reader
    /// owns, so "which book is this query about" is a thing tests have to be
    /// able to get wrong.
    static let otherBookUUID = "1a1a1a1a-2222-4333-8444-555555555555"

    /// Spine indices, read off the fixture's own manifest and spine order.
    ///
    /// The two wrappers in front (the SVG cover and Gutenberg's header page)
    /// are why Chapter I is index 2 and not 0 — and are exactly the sort of
    /// thing that makes a hard-coded "chapter 1 is spine 0" test pass on a
    /// hand-built book and fail on every real one.
    enum Spine {
        static let chapterI = 2
        static let chapterII = 3
        /// "Pig and Pepper" — where the Cheshire Cat first appears.
        static let chapterVI = 7
    }

    static func url() throws -> URL { try alice.url() }

    static func package() throws -> EPUBPackage { try alice.package() }

    static func source() throws -> BookSource { try alice.source() }

    /// A source whose fingerprint is taken from a file the test can change,
    /// while the book itself stays the pristine fixture.
    static func source(
        fingerprintedAt fileURL: URL, bookUUID: String = AskFixture.bookUUID,
    ) throws -> BookSource {
        try BookSource(bookUUID: bookUUID, fileURL: fileURL, package: package())
    }

    /// One chapter's rendered string, parsed exactly as the reader parses it.
    static func text(spine: Int, style: ReaderStyle = ReaderStyle()) throws -> String {
        try alice.text(spine: spine, style: style)
    }

    /// The reader has finished this chapter and nothing after it.
    static func endOf(spine: Int) throws -> ReadingBoundary { try alice.endOf(spine: spine) }

    // MARK: - Temporary directories

    /// A directory that exists for the duration of one test.
    ///
    /// Under the process's own temporary directory rather than `StorageRoot`:
    /// a suite that wrote to the real one would delete the index of a book the
    /// developer is reading.
    static func temporaryDirectory() throws -> URL {
        let url = URL.temporaryDirectory
            .appending(path: "issa-ask-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// A store with a freshly built index, and the directory to delete after.
    static func preparedStore() async throws -> (AskIndexStore, BookSource, URL) {
        try await alice.preparedStore()
    }

    // MARK: - An index the test wrote

    /// A store whose index holds text the test chose, and a source whose
    /// fingerprint matches it so nothing rebuilds over the top.
    ///
    /// The kinship fast path has to be driven by sentences that do not occur in
    /// *Alice* — nobody in it has a named brother — and writing an EPUB to hold
    /// four sentences would be testing the EPUB writer. The rows go in through
    /// the store's own writer, so the passages, offsets and name table are the
    /// ones a real build would have produced.
    ///
    /// - Returns: the store, a source that reports the index as current, the
    ///   boundary at the end of the last chapter, and the directory to delete.
    static func syntheticStore(
        chapters: [[String]],
    ) throws -> (AskIndexStore, BookSource, ReadingBoundary, URL) {
        let directory = try temporaryDirectory()
        let (source, boundary) = try writeSyntheticIndex(chapters: chapters, in: directory)
        return (AskIndexStore(directory: directory), source, boundary, directory)
    }

    /// The same index, written into a directory the caller already has.
    ///
    /// Split out of `syntheticStore` so a test can put *two* books in one
    /// store, which is all that opening a second book's Ask sheet does — and
    /// the case the store's per-book routing has to survive. `syntheticStore`'s
    /// own signature is untouched, so the suites that use it do not move.
    ///
    /// - Returns: a source that reports the index as current, and the boundary
    ///   at the end of the last chapter.
    static func writeSyntheticIndex(
        chapters: [[String]],
        bookUUID: String = AskFixture.bookUUID,
        in directory: URL,
    ) throws -> (BookSource, ReadingBoundary) {
        let fingerprint = directory.appending(path: "book-\(bookUUID).epub")
        try Data("synthetic".utf8).write(to: fingerprint)
        let source = try source(fingerprintedAt: fingerprint, bookUUID: bookUUID)

        let url = AskIndexStore.indexURL(in: directory, bookUUID: bookUUID)
        let queue = try AskIndexStore.openQueue(at: url)
        try AskIndexStore.migrator.migrate(queue)
        var lastLength = 0
        try queue.write { db in
            for (spine, paragraphs) in chapters.enumerated() {
                let text = paragraphs.joined(separator: "\n")
                lastLength = (text as NSString).length
                try AskIndexStore.insert(
                    AskIndexStore.ParsedChapter(
                        spineIndex: spine,
                        href: "synthetic-\(spine).xhtml",
                        length: lastLength,
                        passages: PassageChunker.chunk(text: text, spineIndex: spine),
                        names: NameFinder.names(in: text, spineIndex: spine),
                    ),
                    into: db,
                )
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO meta(key, value) VALUES ('indexKey', ?)",
                arguments: [source.indexKey.storedValue],
            )
        }
        try queue.close()

        return (
            source,
            ReadingBoundary(spineIndex: max(0, chapters.count - 1), charOffset: lastLength)
        )
    }

    // MARK: - Reading the index back

    /// Every passage the store wrote for one chapter, in order.
    ///
    /// Read straight out of SQLite rather than through the store, so the offset
    /// tests compare a fresh parse against the rows that actually shipped —
    /// an accessor could be wrong in the same way the writer was.
    static func storedPassages(spine: Int, indexURL: URL) throws -> [Passage] {
        let queue = try AskIndexStore.openQueue(at: indexURL)
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT spineIndex, ordinal, start, end, words, text FROM passage
                WHERE spineIndex = ? ORDER BY ordinal
                """, arguments: [spine])
                .map {
                    Passage(
                        spineIndex: $0["spineIndex"], ordinal: $0["ordinal"],
                        start: $0["start"], end: $0["end"], words: $0["words"],
                        text: $0["text"],
                    )
                }
        }
    }
}

// MARK: -

/// One bundled EPUB a suite can ask questions about.
///
/// A value rather than a second `enum` of statics, because there are now two
/// books and every helper below differs between them in exactly one thing: the
/// resource it opens. Copying the file for *Franklin* would have been six more
/// functions that could drift from *Alice*'s in ways no test would notice —
/// which is the same argument `AskFixture` makes for using a real Gutenberg
/// book at all.
struct AskBook: Sendable {
    /// The bundled resource, without its extension.
    var resource: String
    /// A bare uuid, so the store names the index file rather than hashing it.
    var bookUUID: String

    func url() throws -> URL {
        try #require(Bundle.module.url(forResource: resource, withExtension: "epub"))
    }

    func package() throws -> EPUBPackage {
        try EPUBPackage.open(url: url())
    }

    func source() throws -> BookSource {
        try BookSource(bookUUID: bookUUID, fileURL: url())
    }

    /// One chapter's rendered string, parsed exactly as the reader parses it.
    func text(spine: Int, style: ReaderStyle = ReaderStyle()) throws -> String {
        let package = try package()
        let href = package.spine[spine].href
        let images = ArchiveImageSource(archive: package.archive)
        let data = try package.archive.read(href)
        let parsed = try HTMLContentParser(style: style, loadImage: { images.image(for: $0) })
            .parse(xhtml: data, baseHref: href)
        return parsed.text.string
    }

    /// The reader has finished this chapter and nothing after it.
    func endOf(spine: Int) throws -> ReadingBoundary {
        ReadingBoundary(
            spineIndex: spine, charOffset: try (text(spine: spine) as NSString).length,
        )
    }

    /// A store with a freshly built index, and the directory to delete after.
    func preparedStore() async throws -> (AskIndexStore, BookSource, URL) {
        let directory = try AskFixture.temporaryDirectory()
        let store = AskIndexStore(directory: directory)
        let source = try source()
        try await store.prepare(source: source)
        return (store, source, directory)
    }
}
