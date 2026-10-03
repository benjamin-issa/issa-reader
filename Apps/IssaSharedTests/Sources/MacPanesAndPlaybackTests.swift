import Foundation
import IssaCore
import Testing

@testable import IssaReader_iOS

/// Settings' Account pane, as a decision the Mac code calls.
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
}
