import Foundation
import IssaCore
import IssaPlayback
import MediaPlayer
import Observation

/// Connects whatever is playing to the system's Now Playing surfaces.
///
/// One controller owns the remote-command registrations for the whole app, so
/// the lock screen, headphone buttons, CarPlay transport and a car's
/// steering-wheel controls all resolve through the same CommandMap. It is
/// deliberately not owned by a view: playback outlives the reader screen.
@Observable
@MainActor
public final class NowPlayingController {
    public private(set) var coordinator: ReadalongCoordinator?
    public private(set) var book: Book?

    private let remote = RemoteCommandCenter()
    private var settings: PlaybackSettings?
    private var refreshTask: Task<Void, Never>?

    public init() {}

    public func configure(settings: PlaybackSettings) {
        self.settings = settings
        remote.commandMap = settings.commandMap
        remote.onAction = { [weak self] action in
            guard let self, let coordinator, let settings = self.settings else { return }
            Task { await coordinator.perform(action, using: settings.commandMap) }
        }
        remote.activate()
    }

    /// Called when a book starts playing, and again when it stops.
    public func attach(coordinator: ReadalongCoordinator?, book: Book?) {
        self.coordinator = coordinator
        self.book = book
        refreshTask?.cancel()
        guard coordinator != nil, book != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        // The system reads Now Playing on a pull, but the elapsed time it shows
        // is extrapolated from the last value and rate — so a periodic refresh
        // keeps the scrubber honest without publishing on every tick.
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.publish()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Bindings resolve against the surface the command came from, so the wheel
    /// can mean one thing in the car and another on the sofa.
    public func setSurface(_ surface: ControlSurface) {
        remote.activeSurface = surface
    }

    public func syncCommandMap() {
        guard let settings else { return }
        remote.commandMap = settings.commandMap
        // Skip intervals are baked into the system's buttons, so they have to be
        // re-declared when the user changes them.
        remote.activate()
    }

    private func publish() {
        guard let coordinator, let book else { return }
        let total = coordinator.totalDuration
        remote.updateNowPlaying(
            title: book.title,
            author: book.byline,
            chapter: coordinator.activeEntry.map { _ in book.title },
            elapsed: total * coordinator.bookProgress,
            duration: total,
            rate: coordinator.player.isPlaying ? coordinator.player.rate : 0,
            artwork: nil,
        )
    }
}
