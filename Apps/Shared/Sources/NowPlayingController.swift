import Foundation
import IssaCore
import IssaPlayback
import MediaPlayer
import Observation
#if canImport(UIKit)
import UIKit
private typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
private typealias PlatformImage = NSImage
#endif

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
    /// Owned here rather than by the player sheet: a sleep timer that dies when
    /// the sheet is dismissed is a sleep timer that never once worked, since
    /// the whole point is to put the phone down.
    public private(set) var sleepTimer: SleepTimer?
    /// Cover art for the Lock Screen, CarPlay and AirPlay receivers.
    private var artwork: MPMediaItemArtwork?
    private var session: Session?

    private let remote = RemoteCommandCenter()
    private var settings: PlaybackSettings?
    private var refreshTask: Task<Void, Never>?

    public init() {}

    public func configure(settings: PlaybackSettings) {
        self.settings = settings
        remote.commandMap = settings.commandMap
        remote.onAction = { [weak self] action in
            guard let self, let coordinator, let settings = self.settings else { return }
            Task {
                await coordinator.perform(action, using: settings.commandMap)
                self.publish()
            }
        }
        remote.onSeek = { [weak self] seconds in
            guard let self, let coordinator, coordinator.totalDuration > 0 else { return }
            Task {
                await coordinator.seek(toBookProgress: seconds / coordinator.totalDuration)
                self.publish()
            }
        }
        remote.onRateChange = { [weak self] rate in
            self?.coordinator?.player.rate = rate
            self?.settings?.playbackRate = Double(rate)
        }
        remote.activate()
    }

    /// Called when a book starts playing, and again when it stops.
    public func attach(
        coordinator: ReadalongCoordinator?,
        book: Book?,
        session: Session? = nil,
        chapterTitle: @escaping () -> String? = { nil },
    ) {
        self.coordinator = coordinator
        self.book = book
        self.session = session
        currentChapterTitle = chapterTitle
        refreshTask?.cancel()
        artwork = nil

        guard let coordinator, let book else {
            sleepTimer = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        // The timer pauses playback and fades the last seconds rather than
        // cutting off mid-word.
        let timer = SleepTimer(
            onExpire: { [weak coordinator] in coordinator?.player.pause() },
            fade: { [weak coordinator] level in coordinator?.player.volume = level },
        )
        sleepTimer = timer
        // "End of chapter" is driven by the narration crossing a boundary, not
        // by a clock, so it has to be told.
        coordinator.onChapterChangeObserved = { [weak timer] in timer?.chapterDidEnd() }
        // Publish the moment anything changes, rather than waiting up to five
        // seconds for the poll — a lock screen that lags a play tap looks broken.
        coordinator.player.onRateChange = { [weak self] _ in self?.publish() }

        loadArtwork(for: book)
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

    private var currentChapterTitle: () -> String? = { nil }

    public func publish() {
        guard let coordinator, let book else { return }
        let total = coordinator.totalDuration
        remote.updateNowPlaying(
            title: book.title,
            author: book.byline,
            // The real chapter, not the book title a second time.
            chapter: currentChapterTitle(),
            elapsed: total * coordinator.bookProgress,
            duration: total,
            rate: coordinator.player.isPlaying ? coordinator.player.rate : 0,
            artwork: artwork,
        )
    }

    /// Fetches the square audiobook cover for the Lock Screen.
    ///
    /// Storyteller keeps two covers; the square one is the right shape for a
    /// Now Playing tile, where the portrait ebook cover would be letterboxed.
    private func loadArtwork(for book: Book) {
        guard let session else { return }
        Task { [weak self] in
            guard let data = try? await LibraryService(client: session.client)
                .coverData(for: book.uuid, shape: .square, pixelWidth: 600),
                let image = PlatformImage(data: data) else { return }
            let size = image.size
            self?.artwork = MPMediaItemArtwork(boundsSize: size) { _ in image }
            self?.publish()
        }
    }
}
