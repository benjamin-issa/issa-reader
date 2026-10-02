import Foundation
import IssaEPUB
import Testing

@testable import IssaPlayback

/// An extraction that has been revoked has to stop, and stop having happened.
///
/// The reader and the car can both be extracting one book's narration at the
/// moment the reader deletes it, and `removeExtractedAudio` deletes the very
/// directory `extractAudio` writes into. Serialising the two is only half a fix:
/// it turns a torn directory into an all-or-nothing one, and the losing run
/// still wins, because `extract` opens by creating the directory and then writes
/// every chunk into it. A book deleted mid-extraction came straight back, in
/// full, and stayed — uncounted by the storage screen and unreachable from the
/// interface, which is where PRIVACY.md's promise about deleted downloads goes
/// to die.
///
/// Nothing here asserts on the lock itself. Two threads arriving in a chosen
/// order is a race dressed up as an assertion; what can be stated is what an
/// extraction does once it has been told to stand down, which is the half that
/// decides the outcome either way.
@Suite("Revoking an extraction")
struct AudioExtractionTests {
    static func fixture() throws -> (EPUBPackage, SMILTimeline) {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/readalong", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        return (package, SMILParser.timeline(for: package))
    }

    static func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-revoke-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// A long read-along is a hundred and seventy-six files and several hundred
    /// megabytes. An extraction revoked at chunk three must not go on to write
    /// the remaining hundred and seventy-three — that is the difference between
    /// a removal that frees the disk and one that quietly does not.
    ///
    /// `after: 2` is the two questions asked before the second chunk: one before
    /// the directory is created, one at the top of the first file. So exactly
    /// one file is written and the second is where it gives up.
    @Test("an extraction revoked between chunks writes no more files")
    func revokedBetweenChunksStopsWriting() throws {
        let (package, timeline) = try Self.fixture()
        let hrefs = Set(timeline.entries.map(\.audioHref))
        try #require(hrefs.count > 1, "one track cannot show a stop between two")
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let revoked = Revoked(after: 2)

        #expect(throws: CancellationError.self) {
            try AudioExtraction.extractAudio(
                from: package, timeline: timeline, bookID: "book", into: directory,
                isCancelled: { revoked.isCancelled })
        }

        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(written.count == 1, "it carried on through a book it had been told to drop")
    }

    /// The line that used to undo a removal outright.
    ///
    /// `extract` opens with `createDirectory(withIntermediateDirectories: true)`,
    /// so an extraction that had been waiting behind a removal woke up and
    /// re-made the folder the removal had just deleted — and then filled it.
    /// Asked before anything is created, the revoked run leaves the disk exactly
    /// as the removal left it.
    @Test("a revoked extraction leaves nothing behind it created")
    func revokedBeforeStartingCreatesNothing() throws {
        let (package, timeline) = try Self.fixture()
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = AudioExtraction.defaultDirectory(for: "book", in: root)
        // A book already extracted, which is what a removal finds.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("narration".utf8).write(to: directory.appending(path: "already.mp3"))

        AudioExtraction.removeExtractedAudio(for: "book", in: root)
        try #require(
            !FileManager.default.fileExists(atPath: directory.path),
            "the removal has to have happened for this to mean anything")

        let revoked = Revoked(after: 0)
        #expect(throws: CancellationError.self) {
            try AudioExtraction.extractAudio(
                from: package, timeline: timeline, bookID: "book", into: directory,
                isCancelled: { revoked.isCancelled })
        }

        #expect(
            !FileManager.default.fileExists(atPath: directory.path),
            "the extraction put back the directory the removal had just deleted")
    }

    /// One book's removal and another book's extraction share nothing on disk,
    /// so they must not share a lock either.
    ///
    /// The lock was process-wide, and the removal takes it synchronously on the
    /// main actor: removing book Y from Downloads while book X's narration was
    /// being inflated froze the app for the rest of X's extraction, and the
    /// only cancellations that could cut that short were for X itself.
    ///
    /// X is held inside its lock — `isCancelled` is asked under it — for up to
    /// eight seconds, released on a timer so a regression fails rather than
    /// hangs.
    @Test("removing one book's narration does not wait for another book's extraction")
    func removingOneBookDoesNotWaitForAnother() throws {
        let (package, timeline) = try Self.fixture()
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate()
        // Released on every path, a thrown `#require` included: a gate left
        // shut parks X's extraction inside its lock for good, and with a lock
        // shared by every book that took the whole test process with it.
        //
        // The deadline release runs on a thread of its own, not a dispatch
        // queue: with every book behind one lock, the other extraction suites
        // running beside this one park the shared pools on it, and a release
        // queued there never ran.
        defer { gate.release() }
        Thread {
            Thread.sleep(forTimeInterval: 8)
            gate.release()
        }.start()
        let finished = DispatchSemaphore(value: 0)
        let extraction = Thread {
            _ = try? AudioExtraction.extractAudio(
                from: package, timeline: timeline, bookID: "book-x",
                into: AudioExtraction.defaultDirectory(for: "book-x", in: root),
                isCancelled: {
                    gate.holdOnce()
                    return false
                })
            finished.signal()
        }
        extraction.start()
        try #require(gate.waitUntilHeld(timeout: 5), "book X's extraction never reached its lock")

        let started = Date()
        AudioExtraction.removeExtractedAudio(for: "book-y", in: root)
        let waited = Date().timeIntervalSince(started)
        gate.release()

        #expect(waited < 1, "removing book Y waited \(waited) s on book X's extraction")
        #expect(finished.wait(timeout: .now() + 10) == .success, "book X's extraction never finished")
    }

    /// The default, and every caller in the app relies on it: both of them run
    /// inside `Task.detached`, and nothing passes a closure of its own. An
    /// extraction on a live task must extract.
    @Test("an extraction nobody revoked writes the whole book")
    func anUnrevokedExtractionWritesEverything() throws {
        let (package, timeline) = try Self.fixture()
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "book", into: directory)

        #expect(files.count == Set(timeline.entries.map(\.audioHref)).count)
        for url in files.values {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}

/// Holds the first thread that reaches it until released, and lets another
/// thread wait — with a deadline — for that to have happened.
private final class Gate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = false
    private var released = false

    /// Blocks the first caller until `release()`; every later call passes.
    func holdOnce() {
        condition.lock()
        defer { condition.unlock() }
        guard !held else { return }
        held = true
        condition.broadcast()
        while !released { condition.wait() }
    }

    func waitUntilHeld(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !held {
            if !condition.wait(until: deadline) { return held }
        }
        return true
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

/// A cancellation that arrives at a named moment: false until it has been asked
/// `after` times, true from then on.
///
/// A counter rather than a real `Task.isCancelled`, because what is under test
/// is where the question is asked — before the directory exists, and again
/// between chunks — and a cancelled task cannot say which of those it reached.
private final class Revoked: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = 0
    private let after: Int

    init(after: Int) { self.after = after }

    var isCancelled: Bool {
        lock.withLock {
            asked += 1
            return asked > after
        }
    }
}
