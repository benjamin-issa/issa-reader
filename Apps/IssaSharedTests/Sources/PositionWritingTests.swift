import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// The rules around a reader's place, which is the one thing this app cannot
/// recover once it is wrong.
@Suite("Reading position")
@MainActor
struct PositionWritingTests {
    static let uuid = "11111111-1111-4111-8111-111111111111"

    /// The guard for this book's *reading* position.
    ///
    /// Guards are keyed by book and by clock — the reader's text progression
    /// and the audiobook's audio progression are separate high-water marks,
    /// because they are fractions of different timelines. Through the
    /// production helper, so a change to the key cannot leave these green while
    /// `reseedGuards` quietly matches nothing.
    static var textGuardKey: String {
        AppModel.positionGuardKey(uuid, isAudioScaled: false)
    }

    /// `PositionGuard` does re-baseline — but only on `.chosen`. Nothing
    /// re-seeded it when a refresh legitimately adopted a *lower* server
    /// position, so every `.derived` write afterwards was refused for the rest
    /// of the process and the reader's progress was persisted nowhere.
    ///
    /// Through `AppModel.reseedGuards`, the production function. The first
    /// version of this test built a fresh `PositionGuard(highWater: 0.02)` by
    /// hand and asserted on it — so emptying `reseedGuards` left it green,
    /// which the second review demonstrated.
    @Test("a guard whose book moved backwards on the server stops refusing")
    func guardFollowsTheServerBackwards() throws {
        let app = AppModel()
        app.positionGuards[Self.textGuardKey] = PositionGuard(highWater: 0.85, duration: 40 * 3600)

        // Where it was before: a derived write from chapter one is refused.
        var before = try #require(app.positionGuards[Self.textGuardKey])
        #expect(before.decide(0.02, origin: .derived).isRefusal)

        // The server now says 0.02 — the book was restarted elsewhere.
        app.reseedGuards(against: [SharedFixtures.book("Dracula", uuid: Self.uuid, progress: 0.02)])

        var after = try #require(app.positionGuards[Self.textGuardKey])
        #expect(abs(after.highWater - 0.02) < 0.0001, "the guard was not re-seeded from the server")
        #expect(!after.decide(0.03, origin: .derived).isRefusal, "reading on must be recordable")
    }

    /// Only a move *backwards* re-seeds. A server that is further ahead is the
    /// ordinary case — this device is behind — and the high-water mark must
    /// keep refusing the stale derived writes it exists to refuse.
    @Test("a guard whose book moved forwards on the server is left alone")
    func forwardMoveDoesNotReseed() throws {
        let app = AppModel()
        app.positionGuards[Self.textGuardKey] = PositionGuard(highWater: 0.85, duration: 40 * 3600)

        app.reseedGuards(against: [SharedFixtures.book("Dracula", uuid: Self.uuid, progress: 0.90)])

        let after = try #require(app.positionGuards[Self.textGuardKey])
        #expect(abs(after.highWater - 0.85) < 0.0001, "a forward move must not lower the mark")
    }

    /// The tolerance is the smaller of five per cent and five minutes, so a long
    /// audiobook is held to the tighter bound.
    @Test("a small step back is still allowed, a large one is not")
    func toleranceBehaviour() {
        var state = PositionGuard(highWater: 0.5, duration: 3600)
        #expect(!state.decide(0.499, origin: .derived).isRefusal)

        var strict = PositionGuard(highWater: 0.5, duration: 40 * 3600)
        #expect(strict.decide(0.2, origin: .derived).isRefusal)
    }

    /// A chosen write re-baselines downwards by design — restarting a finished
    /// book must not measure every page against the ending.
    @Test("an explicitly chosen position always wins")
    func chosenAlwaysWins() {
        var state = PositionGuard(highWater: 0.99, duration: 3600)
        #expect(!state.decide(0.01, origin: .chosen).isRefusal)
        #expect(!state.decide(0.02, origin: .derived).isRefusal, "and the mark moved with it")
    }

    // MARK: - An audiobook that could not be resumed

    /// The guard for this book's *listening* position.
    static var audioGuardKey: String {
        AppModel.positionGuardKey(uuid, isAudioScaled: true)
    }

    /// What the audiobook's fifteen-second writer produces: an audio track's
    /// href, and a fraction of the audio clock.
    static func audioLocator(
        _ progress: Double, href: String = "OEBPS/Audio/00000-00085.mp3",
    ) -> ReadiumLocator {
        ReadiumLocator(
            href: href, type: "audio/mpeg",
            locations: .init(progression: progress, totalProgression: progress))
    }

    /// What the reader's own save produces: a chapter document, and a fraction
    /// of the *text*. The twin of `audioLocator`, and the pair is the whole
    /// point — the two differ only in the type, and only the type says which
    /// clock the identical-looking fraction belongs to.
    static func textLocator(
        _ progress: Double, href: String = "OEBPS/ch41.xhtml",
    ) -> ReadiumLocator {
        ReadiumLocator(
            href: href, type: "application/xhtml+xml",
            locations: .init(progression: progress, totalProgression: progress))
    }

    /// With a notification centre of its own: swift-testing runs suites in
    /// parallel and sign-out broadcasts process-wide, so a default centre lets
    /// one suite clear another's state mid-run.
    private static func model() -> AppModel {
        AppModel(notificationCentre: NotificationCenter())
    }

    /// The 2026-09-09 report. Reading position 0.5363 on the text clock, an
    /// audiobook that could not be resumed — so playback began at zero, and
    /// fifteen seconds later the writer offered 0.0001 on the *audio* clock,
    /// which had no mark of its own to be measured against. It was accepted,
    /// `recordPosition` replaced the stored locator, and the book came back at
    /// chapter one.
    @Test("the report: an unresolved start over a reading position holds the audio clock")
    func theOutsiderReplay_anUnresolvedStartOverAReadingPositionHoldsTheAudioClock() {
        let app = Self.model()
        let book = SharedFixtures.book(
            "A Novel", uuid: Self.uuid, progress: 0.5363, readaloud: true, audiobook: true)
        app.books = [book]

        app.prepareListeningGuard(for: book, trusted: false)

        let held = app.admitPosition(Self.audioLocator(0.0001), origin: .derived, for: Self.uuid)
        #expect(held == .awaitChoice(candidate: 0.0001))

        // The listener scrubbing is the way out, and the only one.
        #expect(!app.admitPosition(Self.audioLocator(0.45), origin: .chosen, for: Self.uuid).isRefusal)
        #expect(!app.admitPosition(Self.audioLocator(0.46), origin: .derived, for: Self.uuid).isRefusal,
                "listening on from where they steered must be recordable")

        #expect(app.positionGuards[Self.textGuardKey] == nil,
                "the reading clock is a different guard and must be untouched")
    }

    /// A pure audiobook opened for the first time has no position anywhere, so
    /// there is nothing for a hold to protect — and holding it would mean the
    /// book recorded no progress at all until the listener touched the scrubber.
    @Test("an audiobook never opened writes from the start")
    func anAudiobookNeverOpenedWritesFromTheStart() {
        let app = Self.model()
        let book = SharedFixtures.book("A Novel", uuid: Self.uuid, audiobook: true, ebook: false)
        app.books = [book]

        app.prepareListeningGuard(for: book, trusted: false)
        #expect(app.positionGuards[Self.audioGuardKey] == nil, "nothing to hold")
        #expect(!app.admitPosition(Self.audioLocator(0.0001), origin: .derived, for: Self.uuid).isRefusal)
    }

    /// Once the ladder finds a place, playback is honest again and the clock
    /// runs normally — without the listener having to touch anything.
    @Test("a resolved start releases an earlier hold")
    func aResolvedStartReleasesAnEarlierHold() {
        let app = Self.model()
        let book = SharedFixtures.book(
            "A Novel", uuid: Self.uuid, progress: 0.30,
            positionHref: "The Outsider.mp3", positionType: "audio/mpeg", audiobook: true)
        app.books = [book]

        app.prepareListeningGuard(for: book, trusted: false)
        #expect(app.admitPosition(Self.audioLocator(0.31), origin: .derived, for: Self.uuid).isRefusal)

        app.prepareListeningGuard(for: book, trusted: true)
        #expect(!app.admitPosition(Self.audioLocator(0.31), origin: .derived, for: Self.uuid).isRefusal)
    }

    /// Releasing the hold must not re-baseline to wherever the resume landed. A
    /// stale anchor can resolve to somewhere earlier than a good same-clock
    /// position, and lowering the mark to it would hand the regression straight
    /// back.
    @Test("a resolved start does not lower the mark")
    func aResolvedStartDoesNotLowerTheMark() {
        let app = Self.model()
        let book = SharedFixtures.book(
            "A Novel", uuid: Self.uuid, progress: 0.5181,
            positionHref: "The Outsider.mp3", positionType: "audio/mpeg", audiobook: true)
        app.books = [book]

        app.prepareListeningGuard(for: book, trusted: false)
        app.prepareListeningGuard(for: book, trusted: true)

        let decision = app.admitPosition(Self.audioLocator(0.0004), origin: .derived, for: Self.uuid)
        #expect(decision.isRefusal)
        #expect(abs((decision.heldMark ?? -1) - 0.5181) < 0.0001,
                "the release must keep the mark the stored position gave it, not take the resume's")
    }

    /// A catalogue refresh answers "where is this book on the server", which is
    /// a different question from "does this app know where the listener was".
    /// The re-seed moves the mark; the hold stays.
    @Test("a server re-seed keeps the hold")
    func aServerReseedKeepsTheHold() throws {
        let app = Self.model()
        let book = SharedFixtures.book(
            "A Novel", uuid: Self.uuid, progress: 0.5181,
            positionHref: "The Outsider.mp3", positionType: "audio/mpeg", audiobook: true)
        app.books = [book]

        app.prepareListeningGuard(for: book, trusted: false)
        app.reseedGuards(against: [SharedFixtures.book(
            "A Novel", uuid: Self.uuid, progress: 0.30,
            positionHref: "The Outsider.mp3", positionType: "audio/mpeg", audiobook: true)])

        let after = try #require(app.positionGuards[Self.audioGuardKey])
        #expect(abs(after.highWater - 0.30) < 0.0001, "the guard was not re-seeded from the server")
        #expect(app.admitPosition(Self.audioLocator(0.31), origin: .derived, for: Self.uuid)
            == .awaitChoice(candidate: 0.31),
            "a re-seed is not the listener saying where they are")
    }

    // MARK: - A steer on one clock, and what the other is owed

    /// The hours that persisted nowhere. The reader read to 0.60 of the text;
    /// in the car the listener scrubbed, which re-baselines `uuid#audio` and,
    /// before this, told `uuid#text` nothing at all. The drive ends somewhere
    /// around 0.30 of the text, the reader hands that back — and it was
    /// measured against a 0.60 the listener had invalidated hours earlier, so
    /// it was refused, and `ReaderModel`'s `if accepted, let anchor` dropped the
    /// anchor with it. There is no arithmetic from the scrub to the page, which
    /// is the whole reason the clocks are keyed apart; what there is, is the
    /// fact that the stale mark is no longer true.
    @Test("a drive the listener steered lets the page that follows it be saved")
    func aSteeredDriveLetsThePageThatFollowsItBeSaved() {
        let app = Self.model()
        let book = SharedFixtures.book(
            "A Novel", uuid: Self.uuid, progress: 0.60,
            readaloud: true, audiobook: true)
        app.books = [book]

        // Before the drive: reading to 0.60, deliberately.
        #expect(!app.admitPosition(Self.textLocator(0.60), origin: .chosen, for: Self.uuid).isRefusal)
        // The drive: a scrub in the car, named on the audio clock and nowhere
        // else — the only news the text clock ever gets about those hours.
        #expect(!app.admitPosition(Self.audioLocator(0.55), origin: .chosen, for: Self.uuid).isRefusal)
        // After the drive: the book comes back to the reader further back in the
        // text than it was left, because the two fractions never agreed.
        #expect(!app.admitPosition(Self.textLocator(0.30), origin: .derived, for: Self.uuid).isRefusal,
                "a whole drive has to be able to land somewhere")
    }

    /// The safety rail on the test above, and the one that matters more. A place
    /// named is a place named *on a clock*: it re-baselines that clock's mark,
    /// and it invalidates the other clock's — but invalidating a mark is not the
    /// same act as answering "where was this listener", which is the question a
    /// hold is waiting on. A page turn in the reader must therefore leave a
    /// held audio clock exactly as held as it found it, or the 2026-09-09 loss
    /// walks back in behind an unrelated write.
    @Test("a place named on one clock does not release a hold on the other")
    func aPlaceNamedOnOneClockDoesNotReleaseAHoldOnTheOther() {
        let app = Self.model()
        let book = SharedFixtures.book(
            "A Novel", uuid: Self.uuid, progress: 0.5363,
            readaloud: true, audiobook: true)
        app.books = [book]

        app.prepareListeningGuard(for: book, trusted: false)
        // The reader turning a page is the listener naming a place — on the
        // text clock. It says nothing whatever about where the car was.
        #expect(!app.admitPosition(Self.textLocator(0.54), origin: .chosen, for: Self.uuid).isRefusal)

        #expect(app.admitPosition(Self.audioLocator(0.0001), origin: .derived, for: Self.uuid)
            == .awaitChoice(candidate: 0.0001),
            "the app still cannot say where the listener was, so it still must not guess")
    }
}

private extension PositionGuard.Decision {
    /// Anything that is not an allow. There are two ways to be refused now —
    /// below the high-water mark, and a clock held because the app could not
    /// resolve where the listener was — and a helper that only knew the first
    /// would have read a hold as a pass.
    var isRefusal: Bool { !isAllowed }

    /// The mark a high-water refusal was measured against. Read out rather
    /// than compared for equality on the whole case, because the mark comes
    /// from a decoded JSON double and two of those are not worth asserting are
    /// bit-identical.
    var heldMark: Double? {
        if case let .refuse(held, _) = self { return held }
        return nil
    }
}
