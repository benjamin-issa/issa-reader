import CoreGraphics
import Foundation
import IssaRender
import Testing

@testable import IssaReader_iOS

/// The "Show book title" choice: on unless the reader turned it off, kept
/// across launches, and costing the open book nothing when it changes.
@Suite("The book title setting")
@MainActor
struct BookTitleSettingTests {
    private func withSuite(_ body: (String) -> Void) {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        body(suite)
    }

    /// And nothing is written for them: moving the default later moves
    /// everyone who never chose.
    @Test("a reader who never chose sees the title, and nothing is stored for them")
    func onByDefault() {
        withSuite { suite in
            #expect(PlaybackSettings(suiteName: suite).showsBookTitle)
            #expect(UserDefaults(suiteName: suite)?.object(forKey: "issa.showBookTitle") == nil)
        }
    }

    @Test("the choice is the choice a relaunch restores", arguments: [true, false])
    func persists(shown: Bool) {
        withSuite { suite in
            let settings = PlaybackSettings(suiteName: suite)
            settings.showsBookTitle = shown
            #expect(UserDefaults(suiteName: suite)?.object(forKey: "issa.showBookTitle") as? Bool == shown)
            #expect(PlaybackSettings(suiteName: suite).showsBookTitle == shown)
        }
    }

    /// Kept out of the reading style on purpose: a change there re-paginates
    /// the open book.
    @Test("changing it leaves the reading style alone")
    func notAStyle() {
        withSuite { suite in
            let settings = PlaybackSettings(suiteName: suite)
            let style = settings.readerStyle
            settings.showsBookTitle = false
            #expect(settings.readerStyle == style)
            #expect(PlaybackSettings(suiteName: suite).readerStyle == style)
        }
    }

    /// The page is sized from the same chrome whatever the title does: nothing
    /// in `ReaderChrome` takes it as an input, so the band under the footer is
    /// the home indicator's and the title only ever draws into it.
    @Test("the page is the same size with or without a title")
    func pageSizeIgnoresTheTitle() {
        let chrome = ReaderChrome(safeAreaTop: 59, safeAreaBottom: 34, margin: 24)
        let window = CGSize(width: 402, height: 874)
        #expect(chrome.bottomReserve == 34 + ReaderChrome.barHeight + 24)
        #expect(chrome.pageSize(in: window).height == 874 - chrome.topReserve - chrome.bottomReserve)
    }

    @Test("only a band the home indicator leaves room in can hold the title")
    func bandNeedsRoom() {
        #expect(!ReaderView.bandFitsBookTitle(0), "a home-button phone has no band")
        #expect(!ReaderView.bandFitsBookTitle(20), "an iPad's band is the indicator's")
        #expect(!ReaderView.bandFitsBookTitle(21), "and so is a phone turned on its side")
        #expect(!ReaderView.bandFitsBookTitle(ReaderView.bookTitleBandMinimum - 1))
        #expect(ReaderView.bandFitsBookTitle(ReaderView.bookTitleBandMinimum))
        #expect(ReaderView.bandFitsBookTitle(34), "a notched phone in portrait")
    }
}
