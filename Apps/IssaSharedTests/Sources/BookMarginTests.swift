import Foundation
import IssaRender
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
