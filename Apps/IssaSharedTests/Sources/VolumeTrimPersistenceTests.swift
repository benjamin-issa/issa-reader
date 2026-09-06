import Foundation
import IssaPlayback
import Testing

@testable import IssaReader_iOS

/// What the reader hears next launch, and what an account leaves behind.
///
/// The trim is device-local per-book state keyed by a book uuid, which is
/// exactly the shape that outlives the account it belonged to: `bookStyles`
/// needed a sign-out hook for the same reason, and clearing only the stored
/// blob would leave the live dictionary in memory for the rest of the process.
@Suite("Persisting a book's volume trim", .serialized)
@MainActor
struct VolumeTrimPersistenceTests {
    @Test("a trim survives the relaunch that reads it back")
    func trimRoundTrips() {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings(suiteName: suite)
        settings.setVolumeTrim(-15, for: "book-a")
        settings.setVolumeTrim(20, for: "book-b")

        let relaunched = PlaybackSettings(suiteName: suite)
        #expect(relaunched.volumeTrim(for: "book-a") == -15)
        #expect(relaunched.volumeTrim(for: "book-b") == 20)
        #expect(relaunched.volumeTrim(for: "never-touched") == 0)
    }

    /// The slider steps by five, but a nudge and a restored preference do not
    /// have to. Snapping on the way in is what stops a level the control cannot
    /// draw from being stored and restored forever.
    @Test("a trim off the detents is snapped before it is stored")
    func snappedOnTheWayIn() {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings(suiteName: suite)
        // 53 snaps up to 55, which is past the +50 end of the range, so it
        // lands on the end rather than five percent past it.
        settings.setVolumeTrim(53, for: "book")
        #expect(settings.volumeTrim(for: "book") == 50)
        // 33 → 35 is the same snap with nothing to clamp: an ordinary detent
        // since the range grew.
        settings.setVolumeTrim(33, for: "book")
        #expect(settings.volumeTrim(for: "book") == 35)
        settings.setVolumeTrim(23, for: "book")
        #expect(settings.volumeTrim(for: "book") == 25)
        #expect(PlaybackSettings(suiteName: suite).volumeTrim(for: "book") == 25,
                "the live value was snapped but the stored one was not")
    }

    @Test("returning a book to the recorded level removes it rather than storing a zero")
    func zeroRemovesTheKey() {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings(suiteName: suite)
        settings.setVolumeTrim(10, for: "book")
        #expect(settings.bookVolumeTrims["book"] == 10)

        settings.setVolumeTrim(0, for: "book")
        #expect(settings.bookVolumeTrims["book"] == nil, "a zero is not a preference")
        #expect(settings.bookVolumeTrims.isEmpty)
        #expect(PlaybackSettings(suiteName: suite).bookVolumeTrims.isEmpty)
    }

    @Test("signing out clears the live dictionary, not only the stored one")
    func signOutClearsTheTrims() async {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings(suiteName: suite)
        settings.setVolumeTrim(-20, for: "book")
        #expect(settings.bookVolumeTrims.isEmpty == false)

        NotificationCenter.default.post(name: PlaybackSettings.signOutNotification, object: nil)
        // The observer is delivered on the main queue; we are on it.
        await Task.yield()

        #expect(settings.bookVolumeTrims.isEmpty, "the next account inherits this book's level")
        #expect(PlaybackSettings(suiteName: suite).bookVolumeTrims.isEmpty)
    }
}
