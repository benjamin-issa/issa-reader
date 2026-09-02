import AVFoundation
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
    ///
    /// Only `.carPlay` and `.phone` are ever assigned here — the CarPlay bridge
    /// is the one caller. `.headphones` is not assigned but *inferred*, per
    /// control, from the audio route; see `surface(for:active:headphonesRouted:)`.
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
        observeRoute()
    }

    deinit {
        routeObserver.tearDown()
    }

    /// Which surface a control's binding resolves against right now.
    ///
    /// The command centre never says where a command physically came from, so
    /// this is inference, stated plainly. In the car, everything belongs to the
    /// car. Otherwise the *wheel* controls are attributed to headphones while a
    /// headphone-class device is the audio route — `nextTrack`/`previousTrack`
    /// is how AirPods' double- and triple-press arrive — and the tap controls
    /// stay with the phone, because the skip commands only ever come from a
    /// screen; no headphone sends one. Before this, nothing anywhere set
    /// `.headphones`, so every binding made on that settings tab was silently
    /// discarded and the wheel resolved against the phone instead.
    static func surface(
        for control: PlaybackControl, active: ControlSurface, headphonesRouted: Bool,
    ) -> ControlSurface {
        guard active != .carPlay else { return .carPlay }
        switch control {
        case .wheelNext, .wheelPrevious:
            return headphonesRouted ? .headphones : active
        default:
            return active
        }
    }

    /// Whether the current output route is a headphone-class device.
    ///
    /// `.carAudio` — a plain Bluetooth head unit — is deliberately not counted:
    /// its buttons keep resolving against the phone surface, as they always
    /// have. The headphones tab is for the things worn on a head.
    private var headphonesRouted: Bool {
        #if os(iOS) || os(tvOS)
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            Self.headphonePorts.contains($0.portType)
        }
        #else
        return false
        #endif
    }

    #if os(iOS) || os(tvOS)
    private static let headphonePorts: Set<AVAudioSession.Port> = [
        .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
    ]
    #endif

    /// What `headphonesRouted` read at the last registration, so a route change
    /// only re-registers when it actually moved the wheel to another surface.
    private var headphonesWereRouted = false

    /// Re-registers when a headphone-class device comes or goes: which surface
    /// the wheel resolves against — and therefore whether the track commands
    /// exist at all — depends on it, exactly as it does for the car.
    private func observeRoute() {
        #if os(iOS) || os(tvOS)
        routeObserver.token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.headphonesRouted != self.headphonesWereRouted else { return }
                self.activate()
            }
        }
        #endif
    }

    /// The token lives outside the actor so `deinit` — nonisolated under
    /// Swift 6 — can still remove it; the same shape `AudioPlayer` uses.
    private let routeObserver = RouteObserverToken()

    public func activate() {
        tearDown()
        headphonesWereRouted = headphonesRouted

        // Play and pause are discrete on purpose, never the toggle. The system
        // decides which button to draw from the published rate, and during a
        // buffering stall — or the instant after play(), while AVPlayer is
        // still `waitingToPlayAtSpecifiedRate` — that rate is 0 while
        // `isPlaying` is true. iOS draws ▶, the listener taps it, and a
        // toggled `.playPause` *paused* the stalled book. The system already
        // says which one it means; believe it.
        register(center.playCommand) { [weak self] in self?.onAction?(.play) }
        register(center.pauseCommand) { [weak self] in self?.onAction?(.pause) }
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
        // Against the surface the wheel belongs to right now — with AirPods
        // routed that is `.headphones`, so a binding made on that tab is what
        // brings the track commands into being.
        let wheelSurface = Self.surface(
            for: .wheelNext, active: activeSurface, headphonesRouted: headphonesWereRouted)
        let usesTrack = commandMap.usesTrackCommands(on: wheelSurface)
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
        let surface = Self.surface(
            for: control, active: activeSurface, headphonesRouted: headphonesRouted)
        let action = commandMap.action(for: control, on: surface)
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
        #if os(macOS)
        // iOS and tvOS infer playback state from the audio session; macOS has
        // no AVAudioSession and waits to be told. Left at its default
        // `.unknown`, the Mac never treated this as the Now Playing app —
        // Control Center stayed empty and the keyboard's play/pause key was
        // never routed to the handlers registered above.
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
        #endif
    }
}

/// Holds the route-change token outside the main actor.
///
/// A `@MainActor` type's `deinit` is nonisolated, so it cannot read isolated
/// stored properties; keeping the token here lets teardown happen wherever the
/// object is released.
private final class RouteObserverToken: @unchecked Sendable {
    var token: (any NSObjectProtocol)?

    func tearDown() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}
