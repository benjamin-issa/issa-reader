import Foundation
import Testing
import UIKit

@testable import IssaReader_iOS

/// The screen going dark in the middle of a read-along.
///
/// `isIdleTimerDisabled` appeared **nowhere** in this app, so a reader
/// following the narration down a page watched the screen dim and lock at the
/// device's Auto-Lock interval — thirty seconds at its shortest setting.
/// Nothing about a read-along touches the screen, so the one thing the reader
/// was actually doing never reset the idle timer once.
///
/// The fix is a held assertion, and a held assertion nobody gives back is a
/// flat battery — a worse bug than the one being fixed. So this suite is not
/// about the row that holds the display awake; it is about the fifteen that
/// must not, and about each named route out of the one that does.
@Suite("When the display may be held awake for a read-along")
@MainActor
struct ScreenAwakeTests {
    private static let bothWays: [Bool] = [false, true]

    /// Sixteen rows, one of which may hold the display. Asserted as "exactly
    /// one", rather than by recomputing the same conjunction the function
    /// computes — which would pass whatever the function did.
    @Test("the display is held only when all four conditions hold at once")
    func exhaustiveTruthTable() {
        var holding: [[Bool]] = []
        for isPlaying in Self.bothWays {
            for isReaderVisible in Self.bothWays {
                for followsText in Self.bothWays {
                    for isForeground in Self.bothWays {
                        guard ScreenAwake.shouldKeepAwake(
                            isPlaying: isPlaying,
                            isReaderVisible: isReaderVisible,
                            followsText: followsText,
                            isForeground: isForeground,
                        ) else { continue }
                        holding.append([isPlaying, isReaderVisible, followsText, isForeground])
                    }
                }
            }
        }
        #expect(
            holding.count == 1,
            "sixteen rows, and only one of them may hold the display awake")
        #expect(holding.first == [true, true, true, true])
    }

    /// The one row that holds, stated on its own so the fix cannot be reduced
    /// to "never keep the screen awake" and still pass.
    @Test("narration playing with its own page on screen in the foreground holds the display")
    func theReadingCaseHolds() {
        #expect(ScreenAwake.shouldKeepAwake(
            isPlaying: true, isReaderVisible: true, followsText: true, isForeground: true,
        ))
    }

    /// Three different mechanisms, one input: the audio stopped. The sleep
    /// timer is the one that matters most — a reader who set one has said in as
    /// many words that they want the device to stop — and it reaches this by
    /// calling `AudioPlayer.pause()`, which notifies the rate observer
    /// `AppModel` recomputes from.
    @Test(
        "every way narration stops lets the screen sleep again",
        arguments: [
            "the reader pressed pause",
            "the sleep timer ran out and faded the book down",
            "playback reached the end of the book",
            "a phone call interrupted the audio session",
        ],
    )
    func stoppingReleasesTheHold(route: String) {
        #expect(
            !ScreenAwake.shouldKeepAwake(
                isPlaying: false, isReaderVisible: true, followsText: true, isForeground: true,
            ),
            "\(route): the hold has to go with the audio")
    }

    /// The reader is a full-screen cover on iOS, and being backgrounded does
    /// not dismiss it — the same fact `flushOpenReaders()` exists for. Without
    /// this leg a phone pocketed mid-chapter would hold its own display awake
    /// for the rest of the book.
    @Test("a phone put in a pocket mid-chapter stops holding its display awake")
    func leavingTheForegroundReleasesTheHold() {
        #expect(!ScreenAwake.shouldKeepAwake(
            isPlaying: true, isReaderVisible: true, followsText: true, isForeground: false,
        ))
    }

    /// Audio outliving its screen is the point of this app's player, so the
    /// reader closing is not the audio stopping — and the display must go back
    /// to sleeping normally the moment there is no text to follow.
    @Test("dismissing the reader lets the screen sleep while the book plays on")
    func dismissingTheReaderReleasesTheHold() {
        #expect(!ScreenAwake.shouldKeepAwake(
            isPlaying: true, isReaderVisible: false, followsText: true, isForeground: true,
        ))
    }

    /// The whole point of an audiobook is that it plays with the screen off.
    /// The player sheet, the Lock Screen and CarPlay all reach playback with no
    /// page anywhere, and none of them may hold the display.
    @Test("listening to an audiobook never holds the display awake")
    func audioOnlyPlaybackHoldsNothing() {
        for isReaderVisible in Self.bothWays {
            #expect(!ScreenAwake.shouldKeepAwake(
                isPlaying: true,
                isReaderVisible: isReaderVisible,
                followsText: false,
                isForeground: true,
            ))
        }
    }

    /// macOS can have several reader windows open at once, and only one book
    /// narrates. A page nobody's narration belongs to is not being read along
    /// with, whatever else is audible.
    @Test("one book's narration does not hold the display for another book's page")
    func narrationForAnotherBookHoldsNothing() {
        #expect(!ScreenAwake.shouldKeepAwake(
            isPlaying: true, isReaderVisible: true, followsText: false, isForeground: true,
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

/// That `AppModel` — the one object that can see all four inputs — is wired to
/// the decision at all.
///
/// It cannot be driven as far as *holding* the display from here: that needs a
/// live `ReadalongCoordinator`, which needs a downloaded book. What it can be
/// driven to is the half that matters more, which is releasing.
@Suite("The app model holds the display awake for nothing else", .serialized)
@MainActor
struct AppModelScreenAwakeTests {
    private static let bookUUID = "11111111-1111-4111-8111-111111111111"

    @Test("a reader merely being on screen does not hold the display awake")
    func aVisibleReaderWithNoNarrationHoldsNothing() {
        let app = AppModel()
        #expect(!app.keepsScreenAwake)

        app.setReaderVisible(Self.bookUUID, true)
        #expect(app.visibleReaderUUID == Self.bookUUID, "the reader has to be up for this to mean anything")
        #expect(
            !app.keepsScreenAwake,
            "a page with no narration running behind it is an ordinary page")

        app.setReaderVisible(Self.bookUUID, false)
        #expect(!app.keepsScreenAwake)
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
        #expect(!app.keepsScreenAwake, "coming back does not invent narration that was never playing")
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
