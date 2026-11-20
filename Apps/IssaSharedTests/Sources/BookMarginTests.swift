import Foundation
import IssaRender
import SwiftUI
import Testing

@testable import IssaReader_iOS

/// The page margin as a global default a book can override, and the small
/// logic behind the Margins control.
@Suite("The page margin setting")
@MainActor
struct BookMarginTests {
    private func withSuite(_ body: (String) -> Void) {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        body(suite)
    }

    @Test("a book with its own margin resolves to it, and others to the default")
    func resolvesPerBook() {
        withSuite { suite in
            let settings = PlaybackSettings(suiteName: suite)
            settings.setOverride(ReaderStyleOverride(pageMargin: 4), for: "book-b")
            #expect(settings.style(for: "book-a").pageMargin == 24)
            #expect(settings.style(for: "book-b").pageMargin == 4)
            #expect(settings.style(for: "book-c").pageMargin == 24)
        }
    }

    @Test("a book without its own margin follows the global one, including after it changes")
    func followsTheGlobalMargin() {
        withSuite { suite in
            let settings = PlaybackSettings(suiteName: suite)
            settings.setOverride(ReaderStyleOverride(fontSize: 22), for: "book-a")
            settings.setOverride(ReaderStyleOverride(pageMargin: 48), for: "book-b")
            settings.readerStyle.pageMargin = 12
            #expect(settings.style(for: "book-a").pageMargin == 12)
            #expect(settings.style(for: "book-b").pageMargin == 48, "its own stays")
        }
    }

    @Test("editing only the margin in a book's sheet stores only the margin")
    func sheetEditStoresTheDifference() {
        withSuite { suite in
            let settings = PlaybackSettings(suiteName: suite)
            var edited = settings.style(for: "book-a")
            edited.pageMargin = 4
            settings.setOverride(settings.readerStyle.difference(to: edited), for: "book-a")
            #expect(settings.override(for: "book-a") == ReaderStyleOverride(pageMargin: 4))
        }
    }

    @Test("resetting a book removes its margin and it follows the default again")
    func resetClearsIt() {
        withSuite { suite in
            let settings = PlaybackSettings(suiteName: suite)
            settings.setOverride(ReaderStyleOverride(pageMargin: 4), for: "book-a")
            settings.setOverride(nil, for: "book-a")
            #expect(settings.override(for: "book-a") == nil)
            #expect(settings.style(for: "book-a").pageMargin == 24)
        }
    }

    @Test("a book's margin survives a relaunch")
    func persists() {
        withSuite { suite in
            PlaybackSettings(suiteName: suite).setOverride(ReaderStyleOverride(pageMargin: 48), for: "book-a")
            #expect(PlaybackSettings(suiteName: suite).style(for: "book-a").pageMargin == 48)
        }
    }

    // MARK: The control's logic

    @Test("the presets are Wide 48, Standard 24 (the real default), Narrow 12 and Edge 4")
    func presets() {
        #expect(MarginPreset.allCases.map(\.points) == [48, 24, 12, 4])
        #expect(MarginPreset.standard.points == ReaderStyle().pageMargin)
    }

    @Test("a margin shows as the preset it equals, and as none between them")
    func selectedPreset() {
        #expect(MarginControlModel.preset(for: 12) == .narrow)
        #expect(MarginControlModel.preset(for: 24) == .standard)
        #expect(MarginControlModel.preset(for: 30) == nil)
        #expect(MarginControlModel.preset(for: 100) == nil)
    }

    @Test("a stored margin above the slider's end shows at the end, labelled as stored")
    func beyondTheTrack() {
        #expect(MarginControlModel.sliderValue(for: 100) == 64)
        #expect(MarginControlModel.displayedPoints(for: 100) == 100)
        #expect(MarginControlModel.sliderValue(for: 0) == 0)
        #expect(MarginControlModel.sliderValue(for: 30) == 30)
    }

    @Test("bands sit at the page's sides, and at a spread's outer text edges")
    func bandPlacement() {
        #expect(MarginBands.page(width: 400, margin: 24) == [0 ... 24, 376 ... 400])
        #expect(MarginBands.page(width: 400, margin: 999) == [0 ... 200, 200 ... 400])
        #expect(
            MarginBands.spread(leftX: 40, rightX: 460, pageWidth: 380, margin: 24)
                == [16 ... 40, 840 ... 864])
    }

    @Test("the preview shows while dragging and for a moment after, then goes")
    func previewLingers() async throws {
        let preview = MarginPreview(lingerFor: .milliseconds(60))
        #expect(!preview.isShowing)
        preview.dragging(true)
        #expect(preview.isShowing)
        preview.dragging(false)
        #expect(preview.isShowing, "still up just after letting go")
        try await Task.sleep(for: .milliseconds(300))
        #expect(!preview.isShowing)
    }

    @Test("a preset tap shows the bands, and a second tap restarts the wait")
    func presetTapLingers() async throws {
        let preview = MarginPreview(lingerFor: .milliseconds(200))
        preview.linger()
        try await Task.sleep(for: .milliseconds(120))
        preview.linger()
        try await Task.sleep(for: .milliseconds(120))
        #expect(preview.isShowing, "the second tap restarted it")
        try await Task.sleep(for: .milliseconds(400))
        #expect(!preview.isShowing)
    }

    @Test("closing the sheet puts the bands away at once")
    func resetHides() {
        let preview = MarginPreview()
        preview.dragging(true)
        preview.reset()
        #expect(!preview.isShowing)
    }
}

/// "Fill the screen with text" as a global default a book can override.
@Suite("The fill-the-screen setting")
@MainActor
struct BookFillScreenTests {
    private func withSuite(_ body: (String) -> Void) {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        body(suite)
    }

    @Test("one book overriding it on leaves the default and the others off, until reset")
    func perBook() {
        withSuite { suite in
            let settings = PlaybackSettings(suiteName: suite)
            var edited = settings.style(for: "book-b")
            edited.fillsScreen = true
            settings.setOverride(settings.readerStyle.difference(to: edited), for: "book-b")
            #expect(settings.override(for: "book-b") == ReaderStyleOverride(fillsScreen: true))
            #expect(settings.style(for: "book-b").fillsScreen)
            #expect(!settings.style(for: "book-a").fillsScreen)
            #expect(!settings.style(for: "book-c").fillsScreen)
            #expect(!settings.readerStyle.fillsScreen, "the global default stays off")

            settings.setOverride(nil, for: "book-b")
            #expect(settings.override(for: "book-b") == nil)
            #expect(!settings.style(for: "book-b").fillsScreen)
        }
    }

    @Test("a book follows the default when it has no opinion, and keeps its own when it has")
    func followsTheDefault() {
        withSuite { suite in
            let settings = PlaybackSettings(suiteName: suite)
            settings.setOverride(ReaderStyleOverride(fontSize: 22), for: "book-a")
            settings.setOverride(ReaderStyleOverride(fillsScreen: false), for: "book-b")
            settings.readerStyle.fillsScreen = true
            #expect(settings.style(for: "book-a").fillsScreen)
            #expect(!settings.style(for: "book-b").fillsScreen, "its own stays")
            #expect(settings.style(for: "book-c").fillsScreen)
        }
    }

    @Test("the setting survives a relaunch, per book and as the default")
    func persists() {
        withSuite { suite in
            let first = PlaybackSettings(suiteName: suite)
            first.setOverride(ReaderStyleOverride(fillsScreen: true), for: "book-a")
            first.readerStyle.fillsScreen = true
            let second = PlaybackSettings(suiteName: suite)
            #expect(second.override(for: "book-a") == ReaderStyleOverride(fillsScreen: true))
            #expect(second.readerStyle.fillsScreen)
        }
    }

    @Test("the Apple TV never fills the screen")
    func tvIgnoresIt() {
        var style = ReaderStyle()
        style.fillsScreen = true
        #expect(!TVReaderStyle.derive(from: style, publisherFamily: nil).fillsScreen)
    }

    // MARK: Top and bottom

    @Test("a book's own top and bottom margin is its own, and the others follow the side margin")
    func verticalMarginPerBook() {
        withSuite { suite in
            let settings = PlaybackSettings(suiteName: suite)
            var edited = settings.style(for: "book-b")
            edited.verticalMargin = 0
            settings.setOverride(settings.readerStyle.difference(to: edited), for: "book-b")
            #expect(settings.override(for: "book-b") == ReaderStyleOverride(verticalMargin: 0))
            #expect(settings.style(for: "book-b").effectiveVerticalMargin == 0)
            #expect(settings.style(for: "book-a").effectiveVerticalMargin == 24)
            #expect(settings.style(for: "book-a").verticalMargin == nil)
            #expect(settings.readerStyle.verticalMargin == nil, "the default stays unset")
        }
    }

    @Test("a book's top and bottom margin survives a relaunch, as does the default's")
    func verticalMarginPersists() {
        withSuite { suite in
            let first = PlaybackSettings(suiteName: suite)
            first.setOverride(ReaderStyleOverride(verticalMargin: 8), for: "book-a")
            first.readerStyle.verticalMargin = 16
            let second = PlaybackSettings(suiteName: suite)
            #expect(second.override(for: "book-a") == ReaderStyleOverride(verticalMargin: 8))
            #expect(second.style(for: "book-a").verticalMargin == 8)
            #expect(second.style(for: "book-c").verticalMargin == 16)
        }
    }

    @Test("using the defaults clears a book's top and bottom margin")
    func verticalMarginReset() {
        withSuite { suite in
            let settings = PlaybackSettings(suiteName: suite)
            settings.setOverride(ReaderStyleOverride(verticalMargin: 8), for: "book-a")
            settings.setOverride(nil, for: "book-a")
            #expect(settings.override(for: "book-a") == nil)
            #expect(settings.style(for: "book-a").verticalMargin == nil)
        }
    }

    @Test("the Apple TV never uses it")
    func tvIgnoresVerticalMargin() {
        var style = ReaderStyle()
        style.fillsScreen = true
        style.verticalMargin = 40
        let derived = TVReaderStyle.derive(from: style, publisherFamily: nil)
        #expect(derived.verticalMargin == nil)
        #expect(derived.effectiveVerticalMargin == derived.pageMargin)
    }

    @Test("edges are built only for an upright phone with a housing, an indicator and no rail")
    func fillEdgesConditions() {
        let portrait = CGSize(width: 402, height: 874)
        let island = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
        #expect(ReaderInsets.fillEdges(isPhone: true, window: portrait, insets: island, railWidth: 0) != nil)
        #expect(ReaderInsets.fillEdges(isPhone: false, window: portrait, insets: island, railWidth: 0) == nil)
        #expect(ReaderInsets.fillEdges(isPhone: true, window: CGSize(width: 874, height: 402), insets: island, railWidth: 0) == nil)
        #expect(ReaderInsets.fillEdges(isPhone: true, window: portrait, insets: island, railWidth: 84) == nil)
        // No rail, but the window reports a fold or an occlusion: the Duo's
        // inner display held tall.
        #expect(ReaderInsets.fillEdges(
            isPhone: true, window: portrait, insets: island, railWidth: 0, hasFoldOrOcclusion: true) == nil)
        let homeButton = EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 0)
        #expect(ReaderInsets.fillEdges(isPhone: true, window: portrait, insets: homeButton, railWidth: 0) == nil)
        let notch = EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0)
        #expect(ReaderInsets.fillEdges(isPhone: true, window: portrait, insets: notch, railWidth: 0)?.sensorClearance == 0.8 * 47 + 4)
    }

    @Test("the sides are cleared only by a phone on its side, with no rail and no fold")
    func sideClearanceConditions() {
        let landscape = CGSize(width: 874, height: 402)
        let island = EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62)
        let sides = ReaderInsets.sideClearance(isPhone: true, window: landscape, insets: island, railWidth: 0)
        #expect(sides.leading == 62 && sides.trailing == 62)

        let upright = CGSize(width: 402, height: 874)
        let portraitInsets = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
        let portrait = ReaderInsets.sideClearance(isPhone: true, window: upright, insets: portraitInsets, railWidth: 0)
        #expect(portrait.leading == 0 && portrait.trailing == 0, "upright, the page is unchanged")
        // Even with side insets reported, an upright window is not on its side.
        let oddPortrait = ReaderInsets.sideClearance(isPhone: true, window: upright, insets: island, railWidth: 0)
        #expect(oddPortrait.leading == 0 && oddPortrait.trailing == 0)

        let tablet = ReaderInsets.sideClearance(isPhone: false, window: landscape, insets: island, railWidth: 0)
        #expect(tablet.leading == 0 && tablet.trailing == 0)
        let duoRail = ReaderInsets.sideClearance(
            isPhone: true, window: landscape, insets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 84), railWidth: 84)
        #expect(duoRail.leading == 0 && duoRail.trailing == 0, "the Duo's rail takes its own side")
        let folded = ReaderInsets.sideClearance(
            isPhone: true, window: landscape, insets: island, railWidth: 0, hasFoldOrOcclusion: true)
        #expect(folded.leading == 0 && folded.trailing == 0)
    }
}
