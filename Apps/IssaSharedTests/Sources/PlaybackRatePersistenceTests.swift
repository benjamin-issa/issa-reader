import Foundation
import IssaPlayback
import Testing

@testable import IssaReader_iOS

/// The rate the reader sees and the rate on disk are the same rate.
///
/// `playbackRate`'s observer clamps out-of-range values — a 5.0× reached by the
/// stepper, a rate from `MPChangePlaybackRateCommandEvent` — and the first
/// version of that clamp did `playbackRate = legal; return`. Assigning to a
/// property inside its own observer does not re-enter the observer, so the
/// `return` skipped the write: the live rate was legal and the stored one was
/// not, and the next launch restored the one nobody could see.
@Suite("Persisting a clamped playback rate", .serialized)
@MainActor
struct PlaybackRatePersistenceTests {
    @Test("a rate clamped on the way in is the rate a relaunch restores")
    func clampedRateIsPersisted() {
        let suite = "test.\(UUID().uuidString)"
        let settings = PlaybackSettings(suiteName: suite)
        settings.playbackRate = 9.0
        #expect(settings.playbackRate == PlaybackRate.maximum, "the clamp itself")

        // What a relaunch reads.
        let relaunched = PlaybackSettings(suiteName: suite)
        #expect(relaunched.playbackRate == PlaybackRate.maximum,
                "the live rate was \(settings.playbackRate) but \(relaunched.playbackRate) was stored")
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test("a legal rate is persisted as itself")
    func legalRateIsPersisted() {
        let suite = "test.\(UUID().uuidString)"
        let settings = PlaybackSettings(suiteName: suite)
        settings.playbackRate = 1.5
        #expect(PlaybackSettings(suiteName: suite).playbackRate == 1.5)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}
