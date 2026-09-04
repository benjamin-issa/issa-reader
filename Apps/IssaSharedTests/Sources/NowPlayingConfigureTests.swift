import Foundation
import IssaPlayback
import Testing

@testable import IssaReader_iOS

/// Configuring the Now Playing controller more than once.
///
/// Four scenes call `configure(settings:)` — three on macOS, one each on iOS and
/// tvOS — and the macOS reader window calls it again for every book opened. Each
/// call re-registered the whole `MPRemoteCommandCenter` set and installed a
/// fresh `observeCommandMap()` chain that re-arms itself forever and that
/// nothing removed, so with a dozen books open one nudge of the skip interval
/// fired fourteen teardown-and-re-register cycles.
///
/// `remoteActivations` counts those cycles, which is the finding's own unit.
///
/// `.serialized` because every case here builds a `PlaybackSettings`, which
/// reads and writes the App Group defaults.
@Suite("Configuring Now Playing twice", .serialized)
@MainActor
struct NowPlayingConfigureTests {
    /// A settings object of its own per case, so one case's persisted command
    /// map is not another's starting state.
    static func settings() -> PlaybackSettings {
        PlaybackSettings(suiteName: "test.\(UUID().uuidString)")
    }

    /// Settling time for the observation callback, which runs on the next turn
    /// of the main actor — `withObservationTracking` fires *before* the value
    /// changes, so the controller deliberately reads it back afterwards.
    static func settle() async {
        for _ in 0 ..< 4 { await Task.yield() }
    }

    @Test("configuring with the same settings again does nothing")
    func repeatedConfigureIsIdempotent() {
        let controller = NowPlayingController()
        let settings = Self.settings()

        controller.configure(settings: settings)
        controller.configure(settings: settings)
        controller.configure(settings: settings)

        #expect(controller.remoteActivations == 1,
                "each scene and each reader window re-registered the whole command set")
    }

    /// The point of the counter: one change to the skip interval must produce
    /// one re-registration, not one per call that ever configured.
    @Test("one settings change produces one re-registration")
    func oneChangeOneActivation() async {
        let controller = NowPlayingController()
        let settings = Self.settings()
        for _ in 0 ..< 5 { controller.configure(settings: settings) }
        let before = controller.remoteActivations

        settings.commandMap.skipForwardInterval = 45
        await Self.settle()

        #expect(controller.remoteActivations == before + 1,
                "\(controller.remoteActivations - before) cycles for one change")
    }

    /// The orphaned chains, which the idempotence guard alone would not catch.
    /// Pointing the controller at a *different* settings object is real work, so
    /// it re-registers — but the first object's observation chain must be dead
    /// afterwards, not still re-arming itself and republishing its own values.
    @Test("the previous settings object stops being observed")
    func supersededObservationStops() async {
        let controller = NowPlayingController()
        let first = Self.settings()
        let second = Self.settings()

        controller.configure(settings: first)
        controller.configure(settings: second)
        #expect(controller.remoteActivations == 2, "a different object is a real reconfiguration")

        let before = controller.remoteActivations
        first.commandMap.skipForwardInterval = 45
        await Self.settle()

        #expect(controller.remoteActivations == before,
                "the superseded settings object was still driving the lock screen")
    }
}
