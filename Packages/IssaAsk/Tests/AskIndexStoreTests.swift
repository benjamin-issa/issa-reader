import Foundation
import Testing

@testable import IssaAsk

struct AskIndexStoreTests {
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

    @Test("Alice is the book's most-mentioned person")
    func findsTheTopName() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let names = try await store.topNames(
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
        #expect(seen.allSatisfy { $0.isPreparing })
        #expect(seen.count == source.package.spine.count + 1)
        #expect(seen.last == .preparingIndex(
            done: source.package.spine.count, total: source.package.spine.count,
        ))
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
