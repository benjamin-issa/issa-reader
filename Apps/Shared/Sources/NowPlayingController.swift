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
    public private(set) var coordinator: (any PlaybackDriving)?
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
        coordinator: (any PlaybackDriving)?,
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
        // "End of chapter" is only meaningful where chapters are observable.
        // A readaloud knows when narration crosses a boundary; an audiobook
        // knows when a track ends.
        if let readalong = coordinator as? ReadalongCoordinator {
            readalong.onChapterChangeObserved = { [weak timer] in timer?.chapterDidEnd() }
        } else if let audiobook = coordinator as? AudiobookCoordinator {
            audiobook.onChapterChange = { [weak timer, weak self] _ in
                timer?.chapterDidEnd()
                self?.publish()
            }
        }
        // Publish the moment anything changes, rather than waiting up to five
        // seconds for the poll — a lock screen that lags a play tap looks broken.
        coordinator.player.setRateObserver(for: self) { [weak self] _ in self?.publish() }

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
        let elapsed = total * coordinator.bookProgress
        // Never hand iOS a number it cannot hold. It stores a non-finite
        // elapsed as zero and then extrapolates from there at the published
        // rate — which is exactly the lock screen counting 0:01, 0:02 while the
        // listener is four hours into the book. Publishing nothing leaves the
        // last good value in place, which is always closer to the truth.
        guard total.isFinite, total > 0, elapsed.isFinite else { return }

        remote.updateNowPlaying(
            title: book.title,
            author: book.byline,
            // The real chapter, not the book title a second time.
            chapter: currentChapterTitle(),
            elapsed: elapsed,
            duration: total,
            // From the player, not from intent: `isPlaying` stays true through a
            // buffering stall, and telling iOS the rate is 1 while the audio is
            // stopped makes its clock run away from the sound.
            rate: coordinator.player.effectiveRate,
            artwork: artwork,
        )
    }

    /// Fetches the square audiobook cover for the Lock Screen.
    ///
    /// Storyteller keeps two covers; the square one is the right shape for a
    /// Now Playing tile, where the portrait ebook cover would be letterboxed.
    /// Wraps a cover for the Now Playing centre.
    ///
    /// Nonisolated deliberately: MediaPlayer invokes this request handler on its
    /// own serial queue whenever it rebuilds the info dictionary, so a closure
    /// formed in main-actor context traps the moment the lock screen, CarPlay or
    /// a Bluetooth head unit asks for the artwork. The closure touches nothing
    /// but the image it was handed.
    private nonisolated static func artwork(from image: PlatformImage, size: CGSize) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: size) { _ in image }
    }

    private func loadArtwork(for book: Book) {
        guard let session else { return }
        Task { [weak self] in
            guard let data = try? await LibraryService(client: session.client)
                .coverData(for: book.uuid, shape: .square, pixelWidth: 600),
                let image = PlatformImage(data: data) else { return }
            let size = image.size
            self?.artwork = Self.artwork(from: image, size: size)
            self?.publish()
        }
    }
}
