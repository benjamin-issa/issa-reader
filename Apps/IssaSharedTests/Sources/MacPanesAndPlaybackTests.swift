import Foundation
import IssaCore
import Testing

@testable import IssaReader_iOS

/// Settings' Account pane, Playback › Play and the tag filter's name, as
/// decisions the Mac code calls.
@Suite("Mac panes and playback, as decisions")
@MainActor
struct MacPanesAndPlaybackTests {
    // MARK: - F6

    @Test("Sign Out… only with a session to leave")
    func signOutNeedsASession() {
        #expect(AccountPane.offersSignOut(hasSession: true, isSigningOut: false))
        #expect(AccountPane.offersSignOut(hasSession: false, isSigningOut: true),
                "the session goes part-way through; the disabled button stays until it ends")
        #expect(!AccountPane.offersSignOut(hasSession: false, isSigningOut: false))
    }

    // MARK: - F10

    @Test("Play is offered over a narrated reader before narration has started")
    func playWithoutAPlayer() {
        #expect(KeyReaderNarration.playEnabled(hasCoordinator: true, narratedReaderIsKey: false))
        #expect(KeyReaderNarration.playEnabled(hasCoordinator: false, narratedReaderIsKey: true))
        #expect(!KeyReaderNarration.playEnabled(hasCoordinator: false, narratedReaderIsKey: false))
    }

    @Test("the key narrated reader is the last to say so, whatever order windows report in")
    func keyReaderOrder() {
        let tracker = KeyReaderNarration()
        let first = UUID(), second = UUID()
        tracker.update(token: first, isKey: true, isNarrated: true)
        #expect(tracker.owner == first)
        // The second window gains the key and says so before the first says
        // it lost it.
        tracker.update(token: second, isKey: true, isNarrated: true)
        tracker.update(token: first, isKey: false, isNarrated: true)
        #expect(tracker.owner == second)
        // A plain ebook in front: nothing to play.
        tracker.update(token: first, isKey: true, isNarrated: false)
        tracker.update(token: second, isKey: false, isNarrated: true)
        #expect(!tracker.narratedReaderIsKey)
        tracker.update(token: second, isKey: true, isNarrated: true)
        tracker.left(first)
        #expect(tracker.owner == second)
        tracker.left(second)
        #expect(!tracker.narratedReaderIsKey)
    }

    @Test("the tag filter says one tag, singular")
    func tagFilterLabel() {
        #expect(LibraryHeader.tagFilterLabel(selectedCount: 0) == "Filter by tag")
        #expect(LibraryHeader.tagFilterLabel(selectedCount: 1) == "1 tag selected")
        #expect(LibraryHeader.tagFilterLabel(selectedCount: 3) == "3 tags selected")
    }
}
