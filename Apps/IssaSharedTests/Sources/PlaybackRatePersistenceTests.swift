import Foundation
import IssaCore
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

    /// A wheel, headphone or CarPlay button bound to "speed up". Every other
    /// way of picking a speed — the player's menu, the lock screen, CarPlay's
    /// cycle, the Mac's menu — saved it; this one changed the player and
    /// nothing else, so the speed reverted at the next book, the next launch,
    /// and the car-to-reader hand-off, which builds the read-along at the
    /// saved rate.
    @Test("a speed chosen from a bound control is the speed a relaunch restores")
    func boundSpeedControlIsPersisted() async {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings(suiteName: suite)
        let controller = NowPlayingController()
        controller.configure(settings: settings)
        let engine = AudiobookCoordinator(
            manifest: AudiobookManifest(
                metadata: .init(title: ["und": "Dracula"]),
                readingOrder: [.init(href: "track1.mp3", type: "audio/mpeg", duration: 3_600)]),
            source: .files([:]))
        engine.player.rate = Float(settings.playbackRate)
        controller.attach(coordinator: engine, book: SharedFixtures.book("Dracula", uuid: "rate-uuid"))

        await engine.perform(.speedUp, using: settings.commandMap)

        #expect(engine.player.rate == 1.25)
        #expect(settings.playbackRate == 1.0 + PlaybackRate.step, "the setting never heard of it")
        #expect(PlaybackSettings(suiteName: suite).playbackRate == 1.25, "and a relaunch went back to 1×")
        controller.attach(coordinator: nil, book: nil)
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
