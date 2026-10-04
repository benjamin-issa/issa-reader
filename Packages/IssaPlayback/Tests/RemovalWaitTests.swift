import Foundation
import Testing

@testable import IssaPlayback

/// What a removal of extracted narration may wait for, and what may put it
/// back.
///
/// The removal runs on the main actor — a local book's undo window closing, a
/// download removed — and took the extraction's lock synchronously. Cancelling
/// the extraction first is only noticed between archive members, and a member
/// is now streamed whole however large it is, so the interface froze for the
/// rest of one member: several seconds for a narration cut into a couple of
/// gigabyte-sized files. And the chunk-duration cache, written at the end of a
/// first listen, re-created the folder a removal had just deleted.
@Suite("Removing narration while it is still being written")
struct RemovalWaitTests {
    static func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-removal-wait-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// R-53. The extraction is inside one member's write, holding the lock,
    /// for up to eight seconds — released on a timer, so a regression fails
    /// rather than hangs.
    @Test("a removal does not wait for the member an extraction is writing, and is not undone by it")
    func removalDoesNotWaitForAMember() throws {
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "Audio", directoryHint: .isDirectory)
        let gate = MemberGate()
        defer { gate.release() }
        Thread {
            Thread.sleep(forTimeInterval: 8)
            gate.release()
        }.start()
        let finished = DispatchSemaphore(value: 0)
        let extraction = Thread {
            // The production lock around the production loop, with a write
            // that stands in for `EPUBArchive.extract`: it is mid-member until
            // the gate opens, then writes where its destination says — which
            // fails, as the real one's rename does, once the folder has gone.
            _ = try? AudioExtraction.locks.lock(for: directory).withLock {
                try AudioExtraction.extract(
                    hrefs: ["OEBPS/Audio/one.mp3", "OEBPS/Audio/two.mp3"],
                    write: { _, destination in
                        gate.holdOnce()
                        try Data("narration".utf8).write(to: destination)
                    },
                    into: directory, isCancelled: { false })
            }
            finished.signal()
        }
        extraction.start()
        try #require(gate.waitUntilHeld(timeout: 5), "the extraction never reached its first member")
        try #require(FileManager.default.fileExists(atPath: directory.path))

        let started = Date()
        AudioExtraction.removeExtractedAudio(at: directory, asideIn: root)
        let waited = Date().timeIntervalSince(started)
        gate.release()

        #expect(waited < 1, "the removal waited \(waited) s for the member being written")
        #expect(!FileManager.default.fileExists(atPath: directory.path), "the removal did not happen")
        #expect(finished.wait(timeout: .now() + 10) == .success, "the extraction never finished")
        #expect(!FileManager.default.fileExists(atPath: directory.path),
                "the extraction finishing put back the folder the removal took")
        // And what was set aside is deleted, off the caller's thread.
        let deadline = Date().addingTimeInterval(5)
        var leftovers = Self.contents(of: root)
        while !leftovers.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            leftovers = Self.contents(of: root)
        }
        #expect(leftovers.isEmpty, "set-aside narration was left on disk: \(leftovers)")
    }

    /// A removal with nothing extracting is the same removal it always was:
    /// done by the time it returns.
    @Test("a removal with nothing extracting is done when it returns")
    func anIdleRemovalIsImmediate() throws {
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "Audio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("narration".utf8).write(to: directory.appending(path: "one.mp3"))

        AudioExtraction.removeExtractedAudio(at: directory)

        #expect(Self.contents(of: root).isEmpty)
    }

    static func contents(of directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    // MARK: - The duration cache

    /// R-54. A read-along removed during its first listen: the measurement
    /// ran on, and its save made the folder again to write `durations.json`
    /// into — a cache the next extraction of that book would trust without
    /// checking.
    @Test("saving durations does not re-create narration that has been removed")
    func aSaveDoesNotRecreateTheFolder() {
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = AudioExtraction.defaultDirectory(for: "book", in: root)

        try? ChunkDurations.save(["OEBPS/Audio/one.mp3": 12], bookID: "book", in: root)

        #expect(!FileManager.default.fileExists(atPath: directory.path),
                "the cache re-made the folder of a removed book")
    }

    /// The other half: a measurement that was cancelled — its book removed,
    /// its listen stopped — writes nothing, even into a folder still there.
    @Test("a cancelled measurement saves nothing")
    func aCancelledSaveWritesNothing() async throws {
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = AudioExtraction.defaultDirectory(for: "book", in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let task = Task.detached {
            try? await Task.sleep(for: .seconds(30))
            try? ChunkDurations.save(["OEBPS/Audio/one.mp3": 12], bookID: "book", in: root)
        }
        task.cancel()
        await task.value

        #expect(!FileManager.default.fileExists(
            atPath: ChunkDurations.cacheURL(bookID: "book", in: root).path),
            "a cancelled measurement wrote its partial answer")
    }
}

/// Holds the first writer until released, and says when one is held.
private final class MemberGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = false
    private var released = false

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
