import CoreGraphics
import Foundation
import Testing

@testable import IssaReader_iOS

/// How far down its window the Mac reader's first line of text may begin.
///
/// The arithmetic is trivial; knowing which number to trust is the whole bug.
/// Measured from a running build, at the instant the reader lays out: the
/// book's own window reports a 32-point gap between its frame and its content
/// because the toolbar is not attached yet, and 52 once it is;
/// `NSApplication.keyWindow` is as often nil, or the library window, or the
/// 28-point Now Playing panel. Reserving any of the small numbers put the first
/// line under a toolbar that was about to appear, which is why the same book
/// opened cleanly one time and half under the chrome the next.
///
/// Full screen is the exception, and the mirror image of the same mistake. There
/// the titlebar and the toolbar are genuinely gone, the window measures 0 and
/// means it, and the floor's assumption — that a small number is a window not
/// yet finished making itself — is wrong. Believing it put 52 points of nothing
/// above the first line on the one layout a reader picks to be alone with the
/// page.
///
/// These run on the iOS host, which is why the rule is a pure function outside
/// the `#if os(macOS)` branch rather than a few lines inline in the branch. A
/// helper the shared suite cannot reach is how this survived a release.
@Suite("Where the Mac reader's page begins")
struct ReaderInsetsTests {
    @Test("a window that has not shown its toolbar yet cannot shrink the reserve")
    func aWindowWithoutItsToolbarYetCannotShrinkTheReserve() {
        // 32 is the reader's own window, measured before its toolbar attaches.
        // Taking it at its word is what put the first line under the chrome.
        #expect(ReaderInsets.mac(measured: 32) == ReaderInsets.macChromeMinimum)
        // 28 is the Now Playing panel's bare titlebar — the wrong window
        // entirely, and the one `keyWindow` hands back most often.
        #expect(ReaderInsets.mac(measured: 28) == ReaderInsets.macChromeMinimum)
    }

    @Test("a taller chrome than we assume is believed")
    func aTallerChromeThanWeAssumeIsBelieved() {
        // The floor is a floor, not a constant. A toolbar grown by an
        // accessibility text size, or by a later macOS, has to be cleared too —
        // and over-reserving only ever costs air above the first line.
        #expect(ReaderInsets.mac(measured: 76) == 76)
    }

    @Test("with no window to ask, a titlebar and a toolbar are still reserved")
    func withNoWindowToAskATitlebarAndAToolbarAreStillReserved() {
        // The first layout pass, before there is a key window at all. This is
        // the common case, not the corner: the reader lays out while the window
        // it belongs to is still being made key.
        #expect(ReaderInsets.mac(measured: nil) == ReaderInsets.macChromeMinimum)
    }

    @Test("a negative measurement is a floor away from the page, not a hole in it")
    func aNegativeMeasurementIsAFloorAwayFromThePage() {
        // `contentLayoutRect` can exceed the frame while a window is resizing.
        // A negative reserve would pull the page up *over* the toolbar, which
        // is worse than the fault being fixed.
        #expect(ReaderInsets.mac(measured: -4) == ReaderInsets.macChromeMinimum)
        #expect(ReaderInsets.mac(measured: -4) > 0)
    }

    @Test("in full screen a window that measures no chrome is believed")
    func inFullScreenAWindowThatMeasuresNoChromeIsBelieved() {
        // macOS hides the titlebar and the toolbar in full screen, so 0 here is
        // the truth rather than a window that has not attached its toolbar yet.
        // Floored to 52 it became a band of blank paper above the first line, on
        // the layout chosen to get rid of exactly that.
        #expect(ReaderInsets.mac(measured: 0, isFullScreen: true) == 0)
    }

    @Test("full screen lifts the floor, not the measurement")
    func fullScreenLiftsTheFloorRatherThanTheMeasurement() {
        // Full screen is not "reserve nothing". A window still reporting chrome
        // — a toolbar the reader has revealed, a later macOS that keeps one — is
        // believed here for the same reason it is believed anywhere else.
        #expect(ReaderInsets.mac(measured: 52, isFullScreen: true) == 52)
        #expect(ReaderInsets.mac(measured: 76, isFullScreen: true) == 76)
    }

    @Test("full screen cannot turn a negative measurement into a negative reserve")
    func fullScreenCannotTurnANegativeMeasurementIntoANegativeReserve() {
        // The floor used to be what caught this. With the floor gone the clamp
        // has to be its own step, or a window mid-resize would pull the page up
        // over the menu bar.
        #expect(ReaderInsets.mac(measured: -4, isFullScreen: true) == 0)
    }

    @Test("a window with chrome is still floored, which is what the default means")
    func aWindowWithChromeIsStillFlooredWhichIsWhatTheDefaultMeans() {
        // The parameter defaults to false so that every existing caller keeps
        // the windowed rule. Stated as a test because the default is the whole
        // safety of adding it: a caller that forgets to ask about full screen
        // gets the conservative answer, not the bare measurement.
        #expect(ReaderInsets.mac(measured: 0) == ReaderInsets.macChromeMinimum)
        #expect(ReaderInsets.mac(measured: 0, isFullScreen: false)
            == ReaderInsets.mac(measured: 0))
    }
}
