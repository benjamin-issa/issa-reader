import Foundation
import IssaCore
import IssaPlayback
import Testing

@testable import IssaReader_iOS

/// A sleep timer set at bedtime, and the engine changing hands underneath it.
///
/// `attach` rebuilds `SleepTimer` unconditionally, and a rebuilt timer is a
/// disarmed one. The automatic hand-off at the end of a drive replaces the
/// audiobook coordinator with the reader's read-along for the *same book* —
/// `narrationDidStart` attaches the new one — so a timer the listener had set
/// was silently cancelled: `mode` read `.off`, the moon in the player went
/// hollow, and the book read itself aloud all night. The discarded timer could
/// not save it either, because its `onExpire` captures the old coordinator
/// weakly and its expiry paused nothing at all.
///
/// Nothing anywhere called `attach` in a test before this, which is most of how
/// it came to be the one method in this file with no identity check.
@Suite("Attaching a book to Now Playing")
@MainActor
struct NowPlayingAttachTests {
    /// An engine with nothing behind it: what is under test is which
    /// coordinator the timer is wired to, not what comes out of the speaker.
    ///
    /// Two audiobook coordinators rather than an audiobook and a read-along.
    /// The carry-over is engine-agnostic by construction — it reads `mode` and
    /// `remaining` and nothing else — and both kinds are wired to the timer
    /// through the same pair of lines.
    static func engine(_ title: String = "Dracula") -> AudiobookCoordinator {
        AudiobookCoordinator(
            manifest: AudiobookManifest(
                metadata: .init(title: ["und": title]),
                readingOrder: [.init(href: "track1.mp3", type: "audio/mpeg", duration: 3_600)]),
            source: .files([:]))
    }

    static func book(_ title: String = "Dracula", uuid: String = "now-playing-uuid") -> Book {
        SharedFixtures.book(title, uuid: uuid)
    }

    /// Forty-five minutes set in the car, five minutes of driveway left, and
    /// the phone picked up. The clock does not start again because the engine
    /// did, so what transfers is what is left rather than what was asked for.
    @Test("a duration timer carries its remaining time to the new engine")
    func aDurationTimerCarriesOver() throws {
        let controller = NowPlayingController()
        let book = Self.book()
        controller.attach(coordinator: Self.engine(), book: book)
        let armed = try #require(controller.sleepTimer)
        armed.start(.duration(45 * 60))
        #expect(armed.remaining == 45 * 60, "the setup has to have armed something")

        controller.attach(coordinator: Self.engine(), book: book)

        #expect(controller.sleepTimer?.mode == .duration(45 * 60),
                "the hand-off silently disarmed a timer the listener had set")
        #expect(controller.sleepTimer?.remaining == 45 * 60)
        #expect(controller.sleepTimer !== armed, "a new engine gets a timer of its own")
    }

    /// The half that matters more than the moon being filled in: the carried
    /// timer has to stop the engine that is *now* playing. The discarded one
    /// could not — it holds the old coordinator weakly, so its expiry reached
    /// nothing.
    @Test("an end-of-chapter timer carried over stops the engine that took the book")
    func anEndOfChapterTimerStopsTheNewEngine() throws {
        let controller = NowPlayingController()
        let book = Self.book()
        controller.attach(coordinator: Self.engine(), book: book)
        try #require(controller.sleepTimer).start(.endOfChapter)

        let reader = Self.engine()
        controller.attach(coordinator: reader, book: book)
        #expect(controller.sleepTimer?.mode == .endOfChapter)

        reader.player.play()
        #expect(reader.player.isPlaying, "there has to be something to stop")
        reader.onChapterChangeObserved?()

        #expect(reader.player.isPlaying == false, "the book read itself aloud all night")
        #expect(controller.sleepTimer?.mode == .off, "and an expiry resets, as any expiry does")
    }

    /// A different novel starting is the listener choosing something else.
    /// Inheriting the last book's timer would be a decision nobody made.
    @Test("a different book does not inherit the last one's timer")
    func adifferentBookStartsUnarmed() throws {
        let controller = NowPlayingController()
        controller.attach(coordinator: Self.engine(), book: Self.book())
        try #require(controller.sleepTimer).start(.duration(10 * 60))

        controller.attach(
            coordinator: Self.engine("Frankenstein"),
            book: Self.book("Frankenstein", uuid: "another-book-uuid"))

        #expect(controller.sleepTimer?.mode == .off)
        #expect(controller.sleepTimer?.remaining == nil)
    }

    /// The guard itself, which the carry-over would otherwise hide. Re-attaching
    /// the same engine for the same book is not a new attachment at all — it is
    /// the same one, and rebuilding the timer, cancelling the refresh loop and
    /// refetching the cover for it is work nobody asked for.
    @Test("re-attaching the same engine for the same book changes nothing")
    func reAttachingTheSamePairIsANoOp() throws {
        let controller = NowPlayingController()
        let book = Self.book()
        let engine = Self.engine()
        controller.attach(coordinator: engine, book: book)
        let timer = try #require(controller.sleepTimer)
        timer.start(.duration(15 * 60))

        // The same book value re-decoded, as a position write produces one.
        controller.attach(coordinator: engine, book: Self.book())

        #expect(controller.sleepTimer === timer, "the same pair is the same attachment")
        #expect(controller.sleepTimer?.mode == .duration(15 * 60))
    }

    /// `SleepTimer.cancel()` is the only caller of `fade(1)`, so an outgoing
    /// timer dropped rather than cancelled left `player.volume` wherever the
    /// eight-second fade had got to — a book that plays on at a fifth of its
    /// volume, with nothing on any screen to say why.
    @Test("the outgoing engine gets its volume back")
    func theOutgoingEngineIsNotLeftFaded() throws {
        let controller = NowPlayingController()
        let book = Self.book()
        let car = Self.engine()
        controller.attach(coordinator: car, book: book)
        try #require(controller.sleepTimer).start(.duration(60))
        // Where the fade had reached when the book changed hands.
        car.player.volume = 0.2

        controller.attach(coordinator: Self.engine(), book: book)

        #expect(car.player.volume == 1, "the engine that handed the book over was left faded")
    }
}
