import Foundation
import IssaCore
import IssaEPUB
import IssaPlayback
import Testing

@testable import IssaReader_iOS

/// The anchor is the more durable half of a position, and it has the same rule.
///
/// A `ReadiumLocator` is a fraction of a clock; an `AudioAnchor` is a file and
/// an offset. `ListeningResume`'s first rung starts the car from the anchor and
/// `ReaderModel.resolveLanding` opens the book from it, so a refused position
/// that still landed its anchor cost nothing on the way in and everything on
/// the way out: the next car start resolved to precisely the place the guard
/// had just refused, reported success, and released the hold as it went past.
/// `AppModel.watchListeningProgress` has had that rule since it was written;
/// the reader's own save is its twin and never got it.
@Suite("Writing an anchor")
@MainActor
struct AnchorWritingTests {
    /// The test bundle, found through a class in it rather than `Bundle.module`:
    /// this is an app-hosted unit test target, not a package one.
    private final class BundleMarker {}

    static let uuid = "anchor-writing-uuid"
    static let chapterTwo = "OEBPS/ch02.xhtml"

    static func fixtureURL() throws -> URL {
        let bundle = Bundle(for: BundleMarker.self)
        return try #require(bundle.url(forResource: "readalong", withExtension: "epub"),
                            "the fixture is not in the test bundle")
    }

    static func session() throws -> Session {
        Session(
            serverURL: URL(string: "https://library.example")!,
            keychain: InMemoryAnchorTokens(),
            session: URLSession(configuration: .ephemeral),
        )
    }

    /// A reader with a sentence of the fixture's narration prepared, so
    /// `readalong.currentAnchor` names a real file and a real offset.
    ///
    /// Real bytes on disk, because `prepare(at:)` refuses an entry whose audio
    /// it cannot find — and a model that never narrated has no anchor to
    /// withhold, which would leave both rows below green for the wrong reason.
    static func narrating(_ model: ReaderModel) async throws -> URL {
        model.package = try EPUBPackage.open(url: fixtureURL())
        let package = try #require(model.package)
        let timeline = SMILParser.timeline(for: package)
        // `resize` before `go`: it records the page size, and its own relayout
        // is a no-op while there is no layout yet.
        await model.resize(to: CGSize(width: 340, height: 560))
        await model.go(toChapter: 0)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-anchor-writing-\(UUID().uuidString)")
        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "anchor-writing", into: directory)
        model.attachNarration(timeline: timeline, audioFiles: files)
        let entry = try #require(timeline.firstEntry(inDocument: chapterTwo))
        let narrated = await model.resumeNarration(at: entry, playing: false)
        #expect(narrated, "the fixture's narration has to be reachable")
        return directory
    }

    /// The guard refusing a page turn — a stale `.derived` write below the high
    /// water mark, or a held clock — and the anchor going out behind its back.
    /// `publishSnapshot` was already gated on the same answer a few lines up;
    /// this half was written unconditionally.
    @Test("a refused reading position does not leave its anchor behind")
    func aRefusedPositionWritesNoAnchor() async throws {
        let model = ReaderModel(
            book: SharedFixtures.book("Fixture", uuid: Self.uuid), session: try Self.session())
        let directory = try await Self.narrating(model)
        defer { try? FileManager.default.removeItem(at: directory) }
        let anchors = AnchorCapture()
        model.recordAudioAnchor = { anchors.record($0) }
        model.enqueuePosition = { _, _, _ in false }

        await model.saveProgress()

        #expect(anchors.count == 0, "a place the guard refused must not be stored anyway")
    }

    /// And the other direction, so the fix cannot be "never write an anchor":
    /// an accepted position still lands the half the car reads, which is the
    /// whole reason switching to the car mid-book finds the same sentence.
    @Test("an accepted reading position still writes its anchor")
    func anAcceptedPositionWritesItsAnchor() async throws {
        let model = ReaderModel(
            book: SharedFixtures.book("Fixture", uuid: Self.uuid), session: try Self.session())
        let directory = try await Self.narrating(model)
        defer { try? FileManager.default.removeItem(at: directory) }
        let anchors = AnchorCapture()
        model.recordAudioAnchor = { anchors.record($0) }
        model.enqueuePosition = { _, _, _ in true }

        await model.saveProgress()

        #expect(anchors.count == 1)
        #expect(anchors.last?.audioHref.isEmpty == false, "and it names the file it narrated")
    }
}

/// What a cancelled listening writer must not still do.
///
/// The loop is a fifteen-second sleep in a `while !Task.isCancelled`, and the
/// sleep is `try?` — so the `CancellationError` was swallowed and the whole
/// body ran anyway, because the loop condition is only tested at the top. That
/// matters because the body *spends* things rather than merely repeating them:
/// `consumeSteering()` is read-and-clear, so a stray tick could label its write
/// `.chosen`, which re-baselines the high-water mark and clears any hold. The
/// hand-off cancels this task and then suspends at `resumeNarration` for as
/// long as an audio load takes, which is exactly the window the stray tick
/// lands in.
@Suite("Cancelling the listening position writer")
@MainActor
struct ListeningWriterCancellationTests {
    static let uuid = "listening-writer-uuid"

    /// Three tracks of a thousand seconds, driven by a real (if unplayable)
    /// `AudioPlayer` — the same `/dev/null` `BookClockTests` uses.
    static func coordinator() -> AudiobookCoordinator {
        let subject = AudiobookCoordinator(
            manifest: AudiobookManifest(
                metadata: .init(title: ["und": "A Book"]),
                readingOrder: (0 ..< 3).map { index in
                    .init(href: "t\(index).mp3", type: "audio/mpeg", duration: 1_000)
                },
            ),
            source: .local(URL(fileURLWithPath: "/dev/null")),
        )
        // The periodic observer fires on its own with a time of zero and would
        // walk the arrangement back between the scrub and the assertion;
        // `ChapterClockTests` documents the same hazard.
        subject.player.onTimeUpdate = nil
        return subject
    }

    /// A book somewhere worth writing about, with a scrub the listener made.
    static func armed(_ app: AppModel) async -> (book: Book, coordinator: AudiobookCoordinator) {
        let book = SharedFixtures.book(
            "A Book", uuid: Self.uuid, progress: 0.4, audiobook: true)
        app.books = [book]
        let coordinator = Self.coordinator()
        await coordinator.seek(toBookTime: 1_500)
        await coordinator.skip(by: 30)
        app.installListening(coordinator, book: book)
        return (book, coordinator)
    }

    @Test("a writer cancelled while it sleeps spends nothing when it wakes")
    func aCancelledTickSpendsNothing() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        let (book, coordinator) = await Self.armed(app)

        app.watchListeningProgress(
            book: book, coordinator: coordinator, every: .milliseconds(200))
        #expect(app.isWritingListeningPosition, "a writer has to be armed to be cancelled")

        // Inside the sleep, not before it: cancelling in the same synchronous
        // stretch that armed the writer would be caught by the loop's own
        // condition and prove nothing about the tick that wakes up cancelled.
        try await Task.sleep(for: .milliseconds(50))
        app.stopListening(nowPlaying: nil)
        try await Task.sleep(for: .milliseconds(500))

        #expect(!app.isWritingListeningPosition)
        // The scrub, still unspent. This is the write that would have gone out
        // labelled `.chosen` — the one origin `PositionGuard` never refuses,
        // and the one that clears a hold protecting a part-read novel.
        #expect(coordinator.consumeSteering(),
                "a cancelled tick must not spend the listener's scrub")
    }

    /// The other direction, so the guard cannot be "never run at all": left
    /// alone, the tick does exactly what an hour of listening needs it to.
    @Test("a writer left alone still does its work")
    func anUncancelledTickStillRuns() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        let (book, coordinator) = await Self.armed(app)
        defer { app.stopListening(nowPlaying: nil) }

        app.watchListeningProgress(
            book: book, coordinator: coordinator, every: .milliseconds(100))
        try await Task.sleep(for: .milliseconds(500))

        #expect(coordinator.consumeSteering() == false, "the tick read the scrub and spent it")
    }
}

/// The anchors a save handed over, kept out of the closure so the assertion
/// reads a value rather than a captured variable.
@MainActor
private final class AnchorCapture {
    private(set) var count = 0
    private(set) var last: AudioAnchor?
    func record(_ anchor: AudioAnchor) {
        count += 1
        last = anchor
    }
}

/// Per file, as every other suite in here keeps it: a shared one would make the
/// suites' keychains a shared mutable box under a parallel run.
private final class InMemoryAnchorTokens: TokenPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]

    func read(account: String) -> String? { lock.withLock { stored[account] } }

    @discardableResult
    func write(_ token: String, account: String) -> Bool {
        lock.withLock { stored[account] = token }
        return true
    }

    @discardableResult
    func delete(account: String) -> Bool {
        lock.withLock { _ = stored.removeValue(forKey: account) }
        return true
    }
}
