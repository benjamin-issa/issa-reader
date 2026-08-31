import Foundation
import MediaPlayer

/// Routes every external control through one place.
///
/// The lock screen, headphone buttons, CarPlay's transport and a car's
/// steering-wheel controls all arrive as `MPRemoteCommandCenter` commands.
/// Funnelling them here is what makes the design's per-surface remapping
/// possible: the binding is consulted at the moment a command fires, so
/// changing it takes effect everywhere without re-registering anything.
///
/// The mapping from hardware to command is worth stating plainly, because it is
/// the part people get wrong: a steering wheel's `»` and `«` are delivered as
/// `nextTrack` / `previousTrack`, **not** as skip commands. Registering only
/// skip handlers leaves the wheel buttons dead. Registering *both* sets makes
/// iOS draw the track buttons and hide the interval skips. So the track pair is
/// registered per surface, from the bindings — dead on the phone, where nothing
/// is bound to the wheel and the lock screen should read `⏪15` / `⏩30`, and
/// live in the car, where the wheel is the control that matters.
@MainActor
public final class RemoteCommandCenter {
    private let center = MPRemoteCommandCenter.shared()
    private var handlers: [MPRemoteCommand] = []

    public var commandMap: CommandMap
    /// Which surface a command should be interpreted as coming from.
    ///
    /// Re-registers on change, because which commands exist at all depends on
    /// it: connecting to a car brings the wheel's track buttons into being and
    /// disconnecting takes them away again. Registering once at launch left the
    /// car with whichever set the sofa happened to need.
    public var activeSurface: ControlSurface = .phone {
        didSet {
            guard oldValue != activeSurface else { return }
            activate()
        }
    }
    public var onAction: ((PlaybackAction) -> Void)?
    /// Absolute seek in seconds, from the Lock Screen or CarPlay scrubber.
    public var onSeek: ((TimeInterval) -> Void)?
    /// Rate chosen from the system's own speed control.
    public var onRateChange: ((Float) -> Void)?

    public init(commandMap: CommandMap = CommandMap()) {
        self.commandMap = commandMap
    }

    public func activate() {
        tearDown()

        register(center.playCommand) { [weak self] in self?.onAction?(.playPause) }
        register(center.pauseCommand) { [weak self] in self?.onAction?(.playPause) }
        register(center.togglePlayPauseCommand) { [weak self] in self?.onAction?(.playPause) }

        // Skip intervals must be declared, or the system draws no skip buttons.
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: commandMap.skipForwardInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: commandMap.skipBackwardInterval)]
        register(center.skipForwardCommand) { [weak self] in
            self?.fire(.tapForward)
        }
        register(center.skipBackwardCommand) { [weak self] in
            self?.fire(.tapBackward)
        }

        // Steering wheel and head-unit next/previous — registered only when
        // this surface actually binds them.
        //
        // This is the switch between the two transports iOS will draw. Enabled,
        // it shows the track buttons and hides the interval skips; disabled, it
        // shows the skips. Registering them unconditionally is what made every
        // remote control on the phone jump a whole chapter, and made the lock
        // screen advertise that as the only thing it could do.
        let usesTrack = commandMap.usesTrackCommands(on: activeSurface)
        // Set explicitly, because tearDown removes targets but leaves isEnabled
        // where it was: a stale `true` keeps the track buttons on screen with
        // nothing behind them.
        center.nextTrackCommand.isEnabled = usesTrack
        center.previousTrackCommand.isEnabled = usesTrack
        if usesTrack {
            register(center.nextTrackCommand) { [weak self] in self?.fire(.wheelNext) }
            register(center.previousTrackCommand) { [weak self] in self?.fire(.wheelPrevious) }
        }

        center.changePlaybackRateCommand.supportedPlaybackRates =
            [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0].map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.isEnabled = true
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.onRateChange?(event.playbackRate) }
            return .success
        }
        // Recorded so tearDown can remove it. These two were added directly and
        // never tracked, so every activate() stacked another target: one
        // scrubber drag fired a seek per accumulated registration.
        handlers.append(center.changePlaybackRateCommand)

        // Without this the Lock Screen scrubber is a read-only progress bar;
        // with it, dragging seeks. CarPlay surfaces the same control.
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.onSeek?(event.positionTime) }
            return .success
        }
        handlers.append(center.changePlaybackPositionCommand)
    }

    private func fire(_ control: PlaybackControl) {
        let action = commandMap.action(for: control, on: activeSurface)
        guard action != .none else { return }
        onAction?(action)
    }

    private func register(_ command: MPRemoteCommand, handler: @escaping () -> Void) {
        command.isEnabled = true
        command.addTarget { _ in
            MainActor.assumeIsolated { handler() }
            return .success
        }
        handlers.append(command)
    }

    public func tearDown() {
        for command in handlers { command.removeTarget(nil) }
        handlers.removeAll()
    }

    /// Publishes what is playing, for the lock screen and CarPlay.
    public func updateNowPlaying(
        title: String, author: String, chapter: String?,
        elapsed: TimeInterval, duration: TimeInterval, rate: Float, artwork: MPMediaItemArtwork?,
    ) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: author,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPMediaItemPropertyPlaybackDuration: duration,
            // Without an explicit rate the lock screen shows a frozen scrubber.
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let chapter { info[MPMediaItemPropertyAlbumTitle] = chapter }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
