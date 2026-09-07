#if os(iOS) || os(tvOS)
import UIKit
#endif

/// Whether the display may be held awake while a book reads itself aloud.
///
/// `isIdleTimerDisabled` appeared **nowhere** in this app, so a reader
/// following the highlight down a page watched the screen dim and lock at the
/// device's Auto-Lock interval — thirty seconds at its shortest setting — with
/// the narration carrying on underneath and the page they were reading gone.
/// Nothing about a read-along touches the screen, so the idle timer never once
/// got reset by the thing the reader was actually doing.
///
/// Four conditions and no more, because the failure mode of getting this wrong
/// is worse than the bug it fixes: an idle timer left disabled never lets the
/// phone sleep again, and a flat battery is a larger complaint than a dimmed
/// screen. Each of the four is therefore also a release path — pause, stop, the
/// sleep timer expiring, the reader being dismissed, and the app being
/// backgrounded all take one of them away.
///
/// Pure, and in `Apps/Shared` for the reason `NarrationReach` and
/// `TVReaderStyle` are: the assertion itself is owned by `AppModel` and is only
/// reachable through a live narrating coordinator, which no test can build, and
/// the screens that supply the inputs are SwiftUI views the test bundle cannot
/// see at all. The truth table is the part of this that can be asserted.
enum ScreenAwake {
    /// Whether the display should be kept awake right now.
    ///
    /// - Parameters:
    ///   - isPlaying: whether audio is genuinely running. Read from
    ///     `AudioPlayer.isPlaying`, which every route into playback moves — the
    ///     reader's own button, a tapped sentence, the player sheet, a remote
    ///     command, an interruption, and the sleep timer's `pause()`.
    ///   - isReaderVisible: whether a reader screen is on screen. False for the
    ///     player sheet, the Lock Screen and CarPlay, and false again the
    ///     moment the reader is dismissed.
    ///   - followsText: whether what is audible is the narration belonging to
    ///     *that* reader. This is the distinction the request drew with
    ///     "actively reading with text": an audiobook has no text to follow, so
    ///     listening with the screen off goes on working, which is the whole
    ///     point of an audiobook. A read-along playing for one book while
    ///     another book's reader is open is not something anybody is reading
    ///     along with either.
    ///   - isForeground: whether the app is frontmost. The reader is a
    ///     full-screen cover on iOS and backgrounding does not dismiss it, so
    ///     without this a phone put in a pocket mid-read-along would hold its
    ///     own display awake for the rest of the book.
    static func shouldKeepAwake(
        isPlaying: Bool, isReaderVisible: Bool, followsText: Bool, isForeground: Bool,
    ) -> Bool {
        isPlaying && isReaderVisible && followsText && isForeground
    }
}

/// The single holder of the "keep the display awake" assertion.
///
/// One instance, owned by `AppModel`, because the state it guards is a global
/// on `UIApplication`: two screens each setting `isIdleTimerDisabled` for
/// themselves means whichever leaves second decides, and the reader that is
/// still open loses its hold — or worse, the reader that closed clears a flag
/// the still-open one is relying on. `AppModel` already owns both inputs that
/// change most often (`visibleReaderUUID` and which book is narrating), so it
/// is the only object that can see the whole decision at once.
///
/// Idempotent on purpose: `apply(_:)` is called from a rate observer that fires
/// on every play, pause, rate change and chapter boundary, and touching UIKit
/// on each of those for a value that has not moved is work for nothing.
@MainActor
final class ScreenAwakeAssertion {
    /// Whether the display is being held awake. Not merely for tests: it is
    /// what makes `apply(_:)` idempotent, and it is the value `AppModel`
    /// exposes so a sign-out or a background can be shown to have released.
    private(set) var isHeld = false

    /// Applies a decision, doing nothing when it has not changed.
    func apply(_ shouldKeepAwake: Bool) {
        guard shouldKeepAwake != isHeld else { return }
        isHeld = shouldKeepAwake
        #if os(iOS) || os(tvOS)
        // iOS is the platform the complaint was made about. tvOS gets the same
        // treatment because the television is the worst case of the two: this
        // app draws its page with TextKit and plays audio through a bare
        // `AVQueuePlayer`, so there is no video layer for tvOS to recognise and
        // suppress its screen saver against — and nobody touches a remote while
        // reading, which is precisely the condition the screen saver waits for.
        // An Apple TV is also mains-powered, so the battery objection that
        // makes the scope above so tight does not apply to it at all.
        //
        // macOS is deliberately left out; see the comment below.
        UIApplication.shared.isIdleTimerDisabled = shouldKeepAwake
        #endif
        // Nothing on macOS. The Mac's spelling would be
        // `ProcessInfo.beginActivity(options: .idleDisplaySleepDisabled, ...)`, and
        // holding one is easy; releasing it on the terms the rest of this file
        // insists on is not. SwiftUI's `scenePhase` does not go `.background`
        // on macOS when the app is merely hidden or its window occluded — which
        // is why `TerminationWatcher` exists at all — so the "released when the
        // app leaves the foreground" leg of the decision has no signal behind
        // it there, and an activity assertion nothing releases is exactly the
        // flat battery this is scoped to avoid, on the one platform in the list
        // that runs on a battery for a working day. The Mac also has a real
        // Energy Saver setting its owner controls. If this is wanted on the
        // Mac, the missing piece is a foreground signal — `NSApplication`'s
        // `didHideNotification`/`didUnhideNotification` plus window occlusion —
        // not another branch here.
    }
}
