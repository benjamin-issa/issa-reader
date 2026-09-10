import CoreGraphics
import Foundation
import Testing

@testable import IssaReader_iOS

/// How far down its window the Mac reader's first line of text may begin.
///
/// The arithmetic is trivial; which window it is about is the whole bug. A book
/// opens in its own `WindowGroup`, and the reader asked `NSApplication.keyWindow`
/// — which at first layout is as often the library or the Now Playing panel, a
/// bare titlebar of about 28 points with no toolbar at all. The page then began
/// 28 points down under a 52-point toolbar, and nothing ever re-measured it, so
/// the first line of every book sat half under the chrome for as long as it was
/// open.
///
/// These run on the iOS host, which is why the rule is a pure function outside
/// the `#if os(macOS)` branch rather than a few lines inline in the branch. A
/// helper the shared suite cannot reach is how this survived a release.
@Suite("Where the Mac reader's page begins")
struct ReaderInsetsTests {
    @Test("this window's own safe area beats a measurement taken from another")
    func thisWindowsSafeAreaBeatsAMeasurementFromAnother() {
        // 52 is the reader's titlebar and toolbar, reported by its own geometry
        // proxy. 28 is the library window's bare titlebar, which is what AppKit
        // handed back while the reader was still opening.
        #expect(ReaderInsets.mac(safeAreaTop: 52, measured: 28) == 52)
    }

    @Test("the AppKit measurement stands in until the safe area has an answer")
    func theMeasurementStandsInUntilTheSafeAreaHasAnAnswer() {
        // SwiftUI reports nothing for a layout pass or two, and the measurement
        // is exact whenever it happens to be about the right window. Dropping
        // it would trade a wrong number for a guessed one.
        #expect(ReaderInsets.mac(safeAreaTop: 0, measured: 28) == 28)
    }

    @Test("with no window to ask, the page falls back to a titlebar's height")
    func withNoWindowToAskThePageFallsBackToATitlebarsHeight() {
        // The very first pass, before there is a key window or a laid-out
        // proxy. A starting value, corrected on the next pass.
        #expect(ReaderInsets.mac(safeAreaTop: 0, measured: nil) == ReaderInsets.macTitlebarFallback)
    }

    @Test("a negative inset is clamped rather than passed on")
    func aNegativeInsetIsClampedRatherThanPassedOn() {
        // A negative reserve would pull the page up *over* the toolbar, which
        // is worse than the bug being fixed. Neither source is trusted to be
        // positive: the safe area has been seen negative mid-transition, and
        // `contentLayoutRect` can exceed the frame while a window is resizing.
        #expect(ReaderInsets.mac(safeAreaTop: -12, measured: 28) == 28)
        #expect(ReaderInsets.mac(safeAreaTop: -12, measured: -4) == ReaderInsets.macTitlebarFallback)
        #expect(ReaderInsets.mac(safeAreaTop: -12, measured: nil) >= 0)
    }
}
