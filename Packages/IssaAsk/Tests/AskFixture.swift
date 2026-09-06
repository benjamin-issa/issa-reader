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
    /// A bare uuid, so the store names the index file rather than hashing it.
    static let bookUUID = "0f0f0f0f-1111-4222-8333-444444444444"

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

    static func url() throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures/alice", withExtension: "epub"))
    }

    static func package() throws -> EPUBPackage {
        try EPUBPackage.open(url: url())
    }

    static func source() throws -> BookSource {
        try BookSource(bookUUID: bookUUID, fileURL: url())
    }

    /// A source whose fingerprint is taken from a file the test can change,
    /// while the book itself stays the pristine fixture.
    static func source(fingerprintedAt fileURL: URL) throws -> BookSource {
        try BookSource(bookUUID: bookUUID, fileURL: fileURL, package: package())
    }

    /// One chapter's rendered string, parsed exactly as the reader parses it.
    static func text(spine: Int, style: ReaderStyle = ReaderStyle()) throws -> String {
        let package = try package()
        let href = package.spine[spine].href
        let images = ArchiveImageSource(archive: package.archive)
        let data = try package.archive.read(href)
        let parsed = try HTMLContentParser(style: style, loadImage: { images.image(for: $0) })
            .parse(xhtml: data, baseHref: href)
        return parsed.text.string
    }

    /// The reader has finished this chapter and nothing after it.
    static func endOf(spine: Int) throws -> ReadingBoundary {
        ReadingBoundary(
            spineIndex: spine, charOffset: try (text(spine: spine) as NSString).length,
        )
    }

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
        let directory = try temporaryDirectory()
        let store = AskIndexStore(directory: directory)
        let source = try source()
        try await store.prepare(source: source)
        return (store, source, directory)
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
