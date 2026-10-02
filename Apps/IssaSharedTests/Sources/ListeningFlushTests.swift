import Foundation
import IssaPlayback
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// The way out writes where the audiobook is, and flushes the log before it
/// can be held up by the network.
///
/// `flushOpenReaders` is every platform's exit: the Mac's quit
/// (`TerminationDelegate`), the phone's trip to the background and the
/// television's. It saved every reader model and drained the queue. An
/// audiobook has no reader model — its position was written only by the
/// fifteen-second writer, a task that dies with the process — so ⌘Q while
/// listening lost everything since the last tick, up to most of a minute on
/// a long book where a tick writes only once the book has moved. And the log
/// was flushed only after the drain, whose first request to an unreachable
/// server waits out URLSession's sixty seconds while the Mac answers its quit
/// after three.
///
/// With a real store and queue; the audiobook is driven by its clock, with
/// the same unplayable source `ListeningWriterCancellationTests` uses.
@Suite("Flushing on the way out", .serialized)
@MainActor
struct ListeningFlushTests {
    static let uuid = "55555555-5555-4555-8555-555555555555"

    struct Fixture {
        let app: AppModel
        let store: LibraryStore
        let directory: URL
        let book: Book
        let coordinator: AudiobookCoordinator

        @MainActor
        func queuedPositions() async throws -> [MutationDrain.PositionPayload] {
            try await MutationQueue(store: store).pending()
                .filter { $0.kind == .position && $0.bookUUID == ListeningFlushTests.uuid }
                .map { try JSONDecoder().decode(MutationDrain.PositionPayload.self, from: $0.payload) }
        }

        @MainActor
        func tearDown() {
            app.stopListening(nowPlaying: nil)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Three tracks of a thousand seconds, half a track in, with the writer
    /// armed as `attachListening` arms it — on an interval this test never
    /// reaches, so every write seen here is the flush's.
    static func listening() throws -> Fixture {
        let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "listening-flush-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try LibraryStore(serverKey: "listening-flush", directory: directory)
        app.useStore(store)
        let book = SharedFixtures.book("A Book", uuid: uuid, audiobook: true)
        app.books = [book]
        app.rebuildDerived()
        let coordinator = AudiobookCoordinator(
            manifest: AudiobookManifest(
                metadata: .init(title: ["und": "A Book"]),
                readingOrder: (0 ..< 3).map { index in
                    .init(href: "t\(index).mp3", type: "audio/mpeg", duration: 1_000)
                },
            ),
            source: .local(URL(fileURLWithPath: "/dev/null")),
        )
        app.installListening(coordinator, book: book, reading: .audiobook)
        app.watchListeningProgress(book: book, coordinator: coordinator, every: .seconds(3_600))
        // Half a track of listening since the writer was armed.
        coordinator.player.onTimeUpdate?(500)
        return Fixture(
            app: app, store: store, directory: directory, book: book, coordinator: coordinator)
    }

    @Test("quitting while listening writes the audiobook's position")
    func theFlushWritesTheListeningPosition() async throws {
        let fixture = try Self.listening()
        defer { fixture.tearDown() }
        let progress = fixture.coordinator.bookProgress
        try #require(progress > 0.1, "the clock has to have moved for there to be anything to lose")

        await fixture.app.flushOpenReaders()

        let written = try await fixture.queuedPositions()
        #expect(written.count == 1, "the listening position was written nowhere")
        let locator = try #require(written.first?.locator)
        #expect(locator.isAudioScaled, "on the audio clock, as the writer writes it")
        let total = try #require(locator.totalProgression)
        #expect(abs(total - progress) < 0.0001)
        let shown = fixture.app.bookByUUID[Self.uuid]?.progress
        #expect(shown.map { abs($0 - progress) < 0.0001 } == true)
    }

    /// The writer's own rule: a book that has not moved since the last write
    /// is not written again. A paused book written on every trip to the
    /// background would put an old place under a new time, and the server
    /// would take it over a later place read on another device.
    @Test("a book that has not moved since the last write is not written again")
    func aBookThatHasNotMovedIsNotWrittenAgain() async throws {
        let fixture = try Self.listening()
        defer { fixture.tearDown() }

        await fixture.app.flushOpenReaders()
        let first = try #require(try await fixture.queuedPositions().first)
        // Long enough for the clock a write is stamped with to have moved on.
        try await Task.sleep(for: .milliseconds(50))
        await fixture.app.flushOpenReaders()
        let second = try #require(try await fixture.queuedPositions().first)

        #expect(second.timestamp == first.timestamp, "a paused book was stamped with a new time")
    }

    /// Only while the writer is armed. A hand-off cancels it before handing
    /// the book to the read-along, whose clock the position is on from then;
    /// writing the audio clock's place there flips the stored locator out
    /// from under the reader.
    @Test("nothing is written for a book whose writer is not armed")
    func nothingIsWrittenWithoutAnArmedWriter() async throws {
        let fixture = try Self.listening()
        defer { fixture.tearDown() }
        // The engine still installed, its writer gone: what a hand-off leaves
        // while it waits on the read-along.
        fixture.app.stopListening(nowPlaying: nil)
        fixture.app.installListening(fixture.coordinator, book: fixture.book, reading: .audiobook)
        try #require(!fixture.app.isWritingListeningPosition)

        await fixture.app.flushOpenReaders()

        #expect(try await fixture.queuedPositions().isEmpty)
    }
}
