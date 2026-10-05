import Foundation
import IssaCore
import Testing
import UIKit

@testable import IssaPlayback
@testable import IssaReader_iOS

/// The screen going dark in the middle of a page.
///
/// 1.1.1 held the display only while a read-along was playing with its own
/// page on screen, so a reader with no narration — or a read-along paused to
/// take a page in at their own pace — watched the phone lock at the device's
/// Auto-Lock interval, thirty seconds at its shortest. A page turn is a touch
/// and resets the idle timer, so it struck exactly the pages that took longest
/// to read.
///
/// The reader asked for Storyteller's behaviour: the display stays awake for as
/// long as a book is open, and the sleep timer running out is what lets it go.
/// On the phone and the iPad only. The television keeps the narrower rule,
/// which is also Storyteller's own there, and its screen saver keeps a paused
/// page off the panel.
///
/// A held assertion nobody gives back is a flat battery, so most of what follows
/// is about the rows that must not hold and each named route out of the ones
/// that do.
@Suite("When the display may be held awake")
@MainActor
struct ScreenAwakeTests {
    private static let bothWays: [Bool] = [false, true]

    /// Every row of one policy that holds the display, as
    /// `[isPlaying, isReaderVisible, followsText, isForeground, sleepTimerRanOut]`.
    /// Stated as the rows that hold rather than by recomputing the same
    /// conjunction the function computes, which would pass whatever it did.
    private static func holdingRows(_ policy: ScreenAwake.Policy) -> [[Bool]] {
        var holding: [[Bool]] = []
        for isPlaying in bothWays {
            for isReaderVisible in bothWays {
                for followsText in bothWays {
                    for isForeground in bothWays {
                        for sleepTimerRanOut in bothWays {
                            guard ScreenAwake.shouldKeepAwake(
                                policy: policy,
                                isPlaying: isPlaying,
                                isReaderVisible: isReaderVisible,
                                followsText: followsText,
                                isForeground: isForeground,
                                sleepTimerRanOut: sleepTimerRanOut,
                            ) else { continue }
                            holding.append([
                                isPlaying, isReaderVisible, followsText, isForeground, sleepTimerRanOut,
                            ])
                        }
                    }
                }
            }
        }
        return holding
    }

    /// Thirty-two rows. The four that hold are a book on screen in the
    /// foreground with the sleep timer not run out — playing or paused,
    /// narrated or not, which is the whole of the request.
    @Test("on the phone, a book on screen in the foreground holds the display, whatever is playing")
    func readerOpenTruthTable() {
        let holding = Self.holdingRows(.whileReaderOpen)
        #expect(holding.count == 4, "thirty-two rows, and only four of them may hold the display awake")
        for row in holding {
            #expect(row[1] && row[3] && !row[4], "\(row) holds without a page on screen, in front, before the timer ran out")
        }
    }

    /// The television's rule is the 1.1.1 rule, unchanged: of thirty-two rows,
    /// only narration playing for its own page, in front, holds.
    @Test("on the television, only narration playing for its own page holds the display")
    func narratingTruthTable() {
        #expect(Self.holdingRows(.whileNarrating) == [[true, true, true, true, false]])
    }

    @Test("this platform keeps the display awake for as long as a book is open")
    func thePhoneUsesTheReaderOpenPolicy() {
        #expect(ScreenAwake.platformPolicy == .whileReaderOpen)
    }

    /// The case the request was made about, stated on its own so the change
    /// cannot be reduced to "only while narrating" and still pass.
    @Test("a book with no narration holds the display while its page is on screen")
    func plainReadingHolds() {
        #expect(ScreenAwake.shouldKeepAwake(
            policy: .whileReaderOpen, isPlaying: false, isReaderVisible: true, followsText: false,
            isForeground: true, sleepTimerRanOut: false,
        ))
    }

    @Test("a read-along paused on its page still holds the display")
    func pausedReadalongHolds() {
        #expect(ScreenAwake.shouldKeepAwake(
            policy: .whileReaderOpen, isPlaying: false, isReaderVisible: true, followsText: true,
            isForeground: true, sleepTimerRanOut: false,
        ))
    }

    /// A reader who set a sleep timer has said in as many words that they want
    /// the device to stop, so its running out lets the phone lock even with the
    /// page still up — Storyteller's one exception, and the answer to a book
    /// left open on the nightstand.
    @Test("the sleep timer running out lets the screen sleep with the book still open", arguments: [
        ScreenAwake.Policy.whileReaderOpen, .whileNarrating,
    ])
    func anExpiredSleepTimerReleases(policy: ScreenAwake.Policy) {
        #expect(!ScreenAwake.shouldKeepAwake(
            policy: policy, isPlaying: false, isReaderVisible: true, followsText: true,
            isForeground: true, sleepTimerRanOut: true,
        ))
    }

    /// The reader is a full-screen cover on iOS, and being backgrounded does
    /// not dismiss it — the same fact `flushOpenReaders()` exists for. Without
    /// this leg a phone pocketed mid-chapter would hold its own display awake
    /// for the rest of the book.
    @Test("a phone put in a pocket mid-chapter stops holding its display awake", arguments: [
        ScreenAwake.Policy.whileReaderOpen, .whileNarrating,
    ])
    func leavingTheForegroundReleasesTheHold(policy: ScreenAwake.Policy) {
        #expect(!ScreenAwake.shouldKeepAwake(
            policy: policy, isPlaying: true, isReaderVisible: true, followsText: true,
            isForeground: false, sleepTimerRanOut: false,
        ))
    }

    /// Audio outliving its screen is the point of this app's player, so the
    /// reader closing is not the audio stopping — and the display must go back
    /// to sleeping normally the moment there is no page on screen.
    @Test("dismissing the reader lets the screen sleep while the book plays on", arguments: [
        ScreenAwake.Policy.whileReaderOpen, .whileNarrating,
    ])
    func dismissingTheReaderReleasesTheHold(policy: ScreenAwake.Policy) {
        #expect(!ScreenAwake.shouldKeepAwake(
            policy: policy, isPlaying: true, isReaderVisible: false, followsText: true,
            isForeground: true, sleepTimerRanOut: false,
        ))
    }

    /// The whole point of an audiobook is that it plays with the screen off.
    /// The player sheet, the Lock Screen and CarPlay all reach playback with no
    /// page anywhere, and none of them may hold the display.
    @Test("listening to an audiobook with no page on screen never holds the display", arguments: [
        ScreenAwake.Policy.whileReaderOpen, .whileNarrating,
    ])
    func audioOnlyPlaybackHoldsNothing(policy: ScreenAwake.Policy) {
        #expect(!ScreenAwake.shouldKeepAwake(
            policy: policy, isPlaying: true, isReaderVisible: false, followsText: false,
            isForeground: true, sleepTimerRanOut: false,
        ))
    }

    /// The television's rule: narration stopping is what gives the display
    /// back, by every route — the sleep timer, the end of the book, a pause.
    @Test("on the television, narration stopping lets the screen sleep")
    func onTheTelevisionStoppingReleases() {
        #expect(!ScreenAwake.shouldKeepAwake(
            policy: .whileNarrating, isPlaying: false, isReaderVisible: true, followsText: true,
            isForeground: true, sleepTimerRanOut: false,
        ))
    }
}

/// That the decision above actually reaches `UIApplication`, and lets go again.
///
/// A tested function nothing calls is not a fix. `ScreenAwakeAssertion` is the
/// only thing in the app that writes `isIdleTimerDisabled`, so this is the
/// whole platform half of the change.
@Suite("The one holder of the display assertion", .serialized)
@MainActor
struct ScreenAwakeAssertionTests {
    @Test("taking the assertion and giving it back moves the system's own idle timer")
    func theAssertionReachesUIKit() {
        let hold = ScreenAwakeAssertion()
        #expect(!hold.isHeld, "nothing is held until something asks")

        hold.apply(true)
        #expect(hold.isHeld)
        #expect(UIApplication.shared.isIdleTimerDisabled)

        hold.apply(false)
        #expect(!hold.isHeld)
        #expect(
            !UIApplication.shared.isIdleTimerDisabled,
            "an idle timer left disabled is the flat battery this is scoped to avoid")
    }

    /// `apply(_:)` is driven by a rate observer that fires on every play,
    /// pause, rate change and chapter boundary. Re-asserting an unchanged value
    /// at UIKit on each of those is work for nothing.
    @Test("re-applying a decision that has not changed does nothing")
    func applyingTheSameValueTwiceIsHarmless() {
        let hold = ScreenAwakeAssertion()
        hold.apply(true)
        hold.apply(true)
        #expect(hold.isHeld)

        hold.apply(false)
        hold.apply(false)
        #expect(!hold.isHeld)
        #expect(!UIApplication.shared.isIdleTimerDisabled)
    }
}

/// That `AppModel` — the one object that can see every input — holds the
/// display while a book is on screen, and that each way out lets it go.
///
/// Driven against the real `UIApplication`, because the assertion is a global
/// there and a release that only moved `keepsScreenAwake` would still leave
/// the phone unable to sleep.
@Suite("The app model holds the display while a book is open", .serialized)
@MainActor
struct AppModelScreenAwakeTests {
    private static let bookUUID = "11111111-1111-4111-8111-111111111111"

    /// Holding and the platform agreeing, said once so every step below reads
    /// as one line.
    private static func held(_ app: AppModel) -> Bool {
        app.keepsScreenAwake && UIApplication.shared.isIdleTimerDisabled
    }

    private static func released(_ app: AppModel) -> Bool {
        !app.keepsScreenAwake && !UIApplication.shared.isIdleTimerDisabled
    }

    @Test("a reader on screen holds the display, and every way out of it lets go")
    func aVisibleReaderHoldsTheDisplay() {
        let app = AppModel()
        #expect(Self.released(app))

        app.setReaderVisible(Self.bookUUID, true)
        #expect(app.visibleReaderUUID == Self.bookUUID, "the reader has to be up for this to mean anything")
        #expect(Self.held(app), "a page on screen is being read, narrated or not")

        app.setForeground(false)
        #expect(Self.released(app), "a phone put away lets go")
        app.setForeground(true)
        #expect(Self.held(app), "and picked up again, on the same page, holds again")

        app.sleepTimerDidExpire()
        #expect(Self.released(app), "the sleep timer running out lets the phone lock with the book open")
        app.setForeground(false)
        app.setForeground(true)
        #expect(Self.held(app), "the phone picked up again after the timer is back to normal")

        app.sleepTimerDidExpire()
        app.setReaderVisible(Self.bookUUID, false)
        #expect(Self.released(app))
        app.setReaderVisible(Self.bookUUID, true)
        #expect(Self.held(app), "a book opened after the timer ran out holds again")

        app.setReaderVisible(Self.bookUUID, false)
        #expect(Self.released(app), "closing the book lets go")
    }

    /// A sign-out clears the visible reader directly rather than through
    /// `setReaderVisible`, and with visibility alone now holding the display,
    /// any writer that did not recompute left the phone unable to sleep
    /// behind the sign-in screen.
    @Test("signing out with a book on screen lets the display go")
    func signingOutReleases() async {
        let app = AppModel(keychain: LocalTestTokens(), notificationCentre: NotificationCenter())
        app.setReaderVisible(Self.bookUUID, true)
        #expect(Self.held(app))

        await app.signOut(keepDownloads: true)
        #expect(app.visibleReaderUUID == nil)
        #expect(Self.released(app))
    }

    /// Removing a book from the reader's own files closes its reader by
    /// clearing the visible slot directly, and that has to give the display
    /// back too.
    @Test("removing a local book whose page is on screen lets the display go")
    func removingAVisibleLocalBookReleases() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("readalong"))
        let book = try #require(local.library.books.first)
        let app = AppModel()
        _ = app.reader(for: book, persistence: local.library)
        app.setReaderVisible(book.uuid, true)
        #expect(Self.held(app))

        app.releaseLocalBook(book.uuid)
        #expect(app.visibleReaderUUID == nil)
        #expect(Self.released(app))
    }

    /// A tested function nothing calls is not a fix. The sleep timer is built
    /// inside `NowPlayingController.attach`, so this drives the real one to
    /// expiry and asserts the app model heard it.
    @Test("the real sleep timer running out reaches the app model")
    func theSleepTimerReachesTheAppModel() throws {
        let app = AppModel()
        let controller = NowPlayingController()
        app.nowPlayingController = controller
        let engine = NowPlayingSessionEndTests.engine()
        controller.attach(coordinator: engine, book: SharedFixtures.book("Dracula", uuid: Self.bookUUID))
        defer { controller.attach(coordinator: nil, book: nil) }
        app.setReaderVisible(Self.bookUUID, true)
        #expect(Self.held(app))

        engine.player.play()
        try #require(controller.sleepTimer).start(.endOfChapter)
        engine.onChapterChangeObserved?()

        #expect(Self.released(app), "the timer stopped the book, so the phone may lock")
        app.setReaderVisible(Self.bookUUID, false)
    }

    /// One flag for the process, written by a handler that runs once per
    /// **scene**.
    ///
    /// `Info.plist` sets `UIApplicationSupportsMultipleScenes` and `RootView`
    /// lives inside a `WindowGroup`, so an iPad with two windows on this app
    /// has two of these handlers. Each wrote `phase != .background` straight
    /// into the one `AppModel.isForeground`, so sending one window to the
    /// background — or closing it — released the display assertion the *other*
    /// window's read-along was relying on, with the reader still looking at it,
    /// and nothing put it back until that window's own phase happened to move.
    ///
    /// Derived from every scene now. The table below is the whole decision.
    @Test("the flag follows any window being on screen, not the last one to move", arguments: [
        ([UIScene.ActivationState.foregroundActive], true),
        ([.foregroundInactive], true),
        ([.background], false),
        ([.unattached], false),
        ([], false),
        // The reported case: two windows, one of them going away.
        ([.background, .foregroundActive], true),
        ([.foregroundActive, .background], true),
        ([.background, .foregroundInactive], true),
        ([.background, .background], false),
        // A window that has been disconnected must not hold the assertion open
        // on its own — that is the flat battery, which is the worse bug.
        ([.background, .unattached], false),
        ([.unattached, .foregroundActive], true),
    ])
    func anyWindowOnScreen(states: [UIScene.ActivationState], expected: Bool) {
        #expect(SceneForeground.isAnyForeground(states) == expected)
    }

    /// `.inactive` is still the foreground, and the old handler said so with
    /// `!= .background`. An app switcher glance or a Control Centre pull is not
    /// the iPad going into a bag, and the reader is looking at the screen
    /// throughout — so the derivation has to keep that, and does.
    @Test("an inactive window is still a window on screen")
    func inactiveIsStillForeground() {
        #expect(SceneForeground.isAnyForeground([.foregroundInactive]))
        #expect(!SceneForeground.isAnyForeground([.background]))
    }

    /// A car is not a face.
    ///
    /// The table above is about *which window speaks for the process*. This is
    /// a different question the same fold was answering by accident: whether
    /// the scene is one a person could be looking at at all. `connectedScenes`
    /// is every scene this process has, and on a drive that includes CarPlay's
    /// — which stays `.foregroundActive` for the whole journey, phone locked in
    /// a pocket or not. With no scene-class filter the OR could not go false
    /// while the cable was in, and `setForeground` no-ops on an unchanged
    /// value, so nothing put it right afterwards either.
    ///
    /// So `ListeningHandoff.decide`'s `guard isForeground` rung was dead at the
    /// one moment it exists for: the driver parks with the phone still locked
    /// in a pocket, the car goes away, `carDisconnected` fires, every rung
    /// passes — and the book is handed to a read-along reading itself aloud
    /// into a pocket, off a page nobody can see.
    ///
    /// `CPTemplateApplicationScene`, `CPTemplateApplicationDashboardScene` and
    /// `CPTemplateApplicationInstrumentClusterScene` all derive from `UIScene`
    /// **directly** rather than from `UIWindowScene`, so "is this a window" is
    /// an exact test rather than an approximation — which is what these rows
    /// are stated in.
    @Test("a screen in the dashboard is not a screen anybody is looking at", arguments: [
        // A drive with the phone locked: the only scene claiming the foreground
        // is the one bolted to the dashboard.
        ([SceneForeground.SceneState.car(.foregroundActive)], false),
        // The reported case, with the phone's own window in the set as well.
        ([.car(.foregroundActive), .window(.background)], false),
        // The phone picked up at the lights, or the drive over and the app
        // reopened: a window is on screen, so the car is beside the point.
        ([.car(.background), .window(.foregroundActive)], true),
        // And a window merely inactive is still a window being looked at — the
        // rule the table above sets, which the car must not bend either way.
        ([.car(.foregroundActive), .window(.foregroundInactive)], true),
    ])
    func aDashboardSceneIsNotAWindow(
        scenes: [SceneForeground.SceneState], expected: Bool,
    ) {
        #expect(SceneForeground.isAnyForeground(scenes) == expected)
    }

    /// The signal each target's scene-phase handler pushes in. `AppModel` has
    /// no `scenePhase` of its own, so this is the one input it cannot see for
    /// itself — and the one whose absence would leave a pocketed phone holding
    /// its display awake.
    @Test("the app model is told when the app leaves and returns to the foreground")
    func foregroundIsReportedAndReleases() {
        let app = AppModel()
        app.setReaderVisible(Self.bookUUID, true)

        app.setForeground(false)
        #expect(!app.keepsScreenAwake)

        app.setForeground(true)
        #expect(app.keepsScreenAwake, "coming back to the same page holds again")
        app.setReaderVisible(Self.bookUUID, false)
        #expect(!app.keepsScreenAwake)
    }
}

/// The two kinds of scene this app can have, named the way the failure is
/// described rather than by the flag that tells them apart.
private extension SceneForeground.SceneState {
    /// A CarPlay template scene. Not a `UIWindowScene`, which is the whole
    /// point: it is a display in a dashboard, not one in anybody's hand.
    static func car(_ state: UIScene.ActivationState) -> Self {
        Self(isOnThisDevice: false, state: state)
    }

    static func window(_ state: UIScene.ActivationState) -> Self {
        Self(isOnThisDevice: true, state: state)
    }
}
