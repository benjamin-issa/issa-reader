import Foundation

/// What a control does when pressed.
///
/// The brief asks for the phone's own forward/back controls, and a car's
/// steering-wheel buttons, to be reassignable. Everything a control can do is
/// enumerated here so the mapping is data rather than scattered branches.
public enum PlaybackAction: String, Codable, Sendable, CaseIterable, Hashable {
    case playPause
    case skipForward
    case skipBackward
    case nextSentence
    case previousSentence
    case nextParagraph
    case previousParagraph
    case nextChapter
    case previousChapter
    case speedUp
    case speedDown
    case sleepTimer
    case none

    public var title: String {
        switch self {
        case .playPause: "Play / pause"
        case .skipForward: "Skip forward"
        case .skipBackward: "Skip back"
        case .nextSentence: "Next sentence"
        case .previousSentence: "Previous sentence"
        case .nextParagraph: "Next paragraph"
        case .previousParagraph: "Previous paragraph"
        case .nextChapter: "Next chapter"
        case .previousChapter: "Previous chapter"
        case .speedUp: "Speed up"
        case .speedDown: "Slow down"
        case .sleepTimer: "Sleep timer"
        case .none: "Nothing"
        }
    }

    /// Whether this action moves the listener a whole chapter.
    ///
    /// Named rather than compared inline because it is the thing a default must
    /// never be: a chapter jump that nobody asked for loses a listener's place
    /// far more thoroughly than any number of seconds can.
    public var isChapterJump: Bool {
        self == .nextChapter || self == .previousChapter
    }
}

/// A physical control that can be bound to an action.
///
/// `doubleTapForward`/`doubleTapBackward`/`holdForward`/`holdBackward` are
/// defined and Codable, but **`RemoteCommandCenter` never fires them**, so a
/// binding on one of these has no effect anywhere and they are not offered in
/// `ControlsSettingsView`. Kept rather than removed outright so a stored
/// `CommandMap` from an earlier build — which may still carry a binding on one
/// — decodes without special-casing; see `CommandMap.migrated(_:)`.
///
/// `MPRemoteCommandCenter` has no event distinct from a double tap: AirPods'
/// double/triple press arrives as `nextTrack`/`previousTrack`, already covered
/// by `wheelNext`/`wheelPrevious`. A real "hold" *is* reachable —
/// `seekForwardCommand`/`seekBackwardCommand` deliver `MPSeekCommandEvent` with
/// `.beginSeeking`/`.endSeeking` — but that command's contract is a continuous,
/// accelerating scrub while held, not a single discrete action, so wiring it to
/// fire a `PlaybackAction` once would answer the wrong question. Building the
/// genuine feature is future work, not this fix.
public enum PlaybackControl: String, Codable, Sendable, CaseIterable, Hashable {
    case tapForward
    case tapBackward
    case doubleTapForward
    case doubleTapBackward
    case holdForward
    case holdBackward
    /// The head unit's next/previous track buttons, which is also where a
    /// steering wheel's `»` and `«` are routed by CarPlay — and where AirPods'
    /// double- and triple-press land.
    case wheelNext
    case wheelPrevious

    public var title: String {
        switch self {
        case .tapForward: "Tap forward"
        case .tapBackward: "Tap back"
        case .doubleTapForward: "Double-tap forward"
        case .doubleTapBackward: "Double-tap back"
        case .holdForward: "Hold forward"
        case .holdBackward: "Hold back"
        case .wheelNext: "Wheel »"
        case .wheelPrevious: "Wheel «"
        }
    }
}

/// Where a control lives. The same physical gesture can mean different things
/// in the car than it does on headphones, which is the point of separating them.
public enum ControlSurface: String, Codable, Sendable, CaseIterable, Hashable {
    case phone
    case carPlay
    case headphones

    public var title: String {
        switch self {
        case .phone: "Phone"
        case .carPlay: "CarPlay"
        case .headphones: "Headphones"
        }
    }
}

/// The user's control assignments, per surface.
public struct CommandMap: Codable, Sendable, Hashable {
    public typealias Bindings = [ControlSurface: [PlaybackControl: PlaybackAction]]

    public var bindings: Bindings
    /// Seconds for the skip actions, shown on the buttons themselves.
    public var skipForwardInterval: TimeInterval
    public var skipBackwardInterval: TimeInterval
    /// Which generation of `defaultBindings` a stored map was seeded from.
    ///
    /// Without it a change to the shipped defaults is invisible to everyone who
    /// has already launched the app, because their choices — including the ones
    /// they never actually made — are already on disk.
    public private(set) var bindingsVersion: Int

    /// Bumped whenever `defaultBindings` changes in a way existing installs must
    /// pick up. 1: forward and back stopped meaning "chapter".
    public static let currentBindingsVersion = 1

    public init(
        bindings: Bindings = CommandMap.defaultBindings,
        skipForwardInterval: TimeInterval = 30,
        skipBackwardInterval: TimeInterval = 15,
        bindingsVersion: Int = CommandMap.currentBindingsVersion,
    ) {
        self.bindings = bindings
        self.skipForwardInterval = skipForwardInterval
        self.skipBackwardInterval = skipBackwardInterval
        self.bindingsVersion = bindingsVersion
    }

    public func action(for control: PlaybackControl, on surface: ControlSurface) -> PlaybackAction {
        bindings[surface]?[control] ?? .none
    }

    public mutating func bind(_ action: PlaybackAction, to control: PlaybackControl, on surface: ControlSurface) {
        bindings[surface, default: [:]][control] = action
        bindingsVersion = Self.currentBindingsVersion
    }

    /// Whether the system's next/previous **track** commands should be
    /// registered at all on this surface.
    ///
    /// This is what decides which transport iOS draws. With the track commands
    /// enabled it shows `⏮ ⏭` and hides the interval skips entirely; with them
    /// disabled it shows `⏪15` and `⏩30`. Since nothing on the phone or on
    /// headphones is bound to the wheel by default, the lock screen now draws
    /// the skips — and a listener who deliberately binds the wheel to chapter,
    /// or to anything else, gets the track buttons back along with it.
    public func usesTrackCommands(on surface: ControlSurface) -> Bool {
        action(for: .wheelNext, on: surface) != .none
            || action(for: .wheelPrevious, on: surface) != .none
    }

    /// Whether any default on any surface moves a whole chapter.
    ///
    /// Exists so the requirement — never a chapter by default, anywhere — can be
    /// asserted directly rather than restated as a list of expected values that
    /// the next edit to the table would quietly outgrow.
    public static var defaultsIncludeAChapterJump: Bool {
        defaultBindings.values.contains { $0.values.contains(where: \.isChapterJump) }
    }

    /// Defaults chosen for what an audiobook listener expects: **every**
    /// forward/back control moves by an interval of time.
    ///
    /// Moving by a chapter stays available on every control — it is one pick in
    /// Settings → Controls — but it is never what a button does unasked. A
    /// chapter is tens of minutes; a control that jumps one by accident, on a
    /// lock screen or a steering wheel, loses a listener's place outright.
    ///
    /// The wheel is deliberately unbound on the phone and on headphones. That is
    /// not an omission: it is what keeps `⏪15`/`⏩30` on the lock screen instead
    /// of `⏮`/`⏭`. See `usesTrackCommands(on:)`.
    public static let defaultBindings: Bindings = [
        .phone: [
            .tapForward: .skipForward,
            .tapBackward: .skipBackward,
            .doubleTapForward: .nextSentence,
            .doubleTapBackward: .previousSentence,
            .holdForward: .nextParagraph,
            .holdBackward: .previousParagraph,
        ],
        .carPlay: [
            .tapForward: .skipForward,
            .tapBackward: .skipBackward,
            // Bound, because in the car the wheel is the control that matters
            // and an unbound one is a dead button at 70mph. CarPlay draws its
            // own transport, so enabling the track commands here costs nothing
            // on the lock screen.
            .wheelNext: .skipForward,
            .wheelPrevious: .skipBackward,
            .holdForward: .nextParagraph,
            .holdBackward: .previousParagraph,
        ],
        .headphones: [
            .tapForward: .playPause,
            .doubleTapForward: .skipForward,
            .doubleTapBackward: .skipBackward,
        ],
    ]

    /// The table shipped before version 1.
    ///
    /// Kept only so migration can tell a binding a reader chose from one they
    /// merely inherited. Re-seeding wholesale would throw away real choices;
    /// leaving stored values alone would mean the fix reached nobody who had
    /// already opened the app.
    static let legacyBindings: Bindings = [
        .phone: [
            .tapForward: .skipForward,
            .tapBackward: .skipBackward,
            .doubleTapForward: .nextSentence,
            .doubleTapBackward: .previousSentence,
            .holdForward: .nextChapter,
            .holdBackward: .previousChapter,
            .wheelNext: .nextChapter,
            .wheelPrevious: .previousChapter,
        ],
        .carPlay: [
            .tapForward: .skipForward,
            .tapBackward: .skipBackward,
            .wheelNext: .nextParagraph,
            .wheelPrevious: .previousParagraph,
            .holdForward: .nextChapter,
            .holdBackward: .previousChapter,
        ],
        .headphones: [
            .tapForward: .playPause,
            .doubleTapForward: .skipForward,
            .doubleTapBackward: .skipBackward,
            .wheelNext: .nextChapter,
            .wheelPrevious: .previousChapter,
        ],
    ]

    /// Moves a stored table onto the current defaults, one control at a time.
    ///
    /// A control still sitting on the value it shipped with is replaced; one the
    /// reader changed is left exactly as they left it, chapter jumps included.
    static func migrated(_ stored: Bindings) -> Bindings {
        var result = stored
        for surface in ControlSurface.allCases {
            for control in PlaybackControl.allCases {
                let inherited = legacyBindings[surface]?[control] ?? PlaybackAction.none
                let current = stored[surface]?[control] ?? PlaybackAction.none
                guard current == inherited else { continue }
                if let replacement = defaultBindings[surface]?[control] {
                    result[surface, default: [:]][control] = replacement
                } else {
                    result[surface]?.removeValue(forKey: control)
                }
            }
        }
        return result
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case bindings, skipForwardInterval, skipBackwardInterval, bindingsVersion
    }

    /// Decoding is where migration happens, because this type is read back from
    /// App Group defaults on every launch and there is no other choke point.
    /// Every field is optional on the way in: a value stored by an older build
    /// is missing `bindingsVersion` entirely, and throwing on that would reset a
    /// reader's whole configuration.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decodeIfPresent(Bindings.self, forKey: .bindings)
            ?? Self.defaultBindings
        skipForwardInterval = try container.decodeIfPresent(
            TimeInterval.self, forKey: .skipForwardInterval) ?? 30
        skipBackwardInterval = try container.decodeIfPresent(
            TimeInterval.self, forKey: .skipBackwardInterval) ?? 15
        let version = try container.decodeIfPresent(Int.self, forKey: .bindingsVersion) ?? 0
        bindings = version < Self.currentBindingsVersion ? Self.migrated(stored) : stored
        bindingsVersion = Self.currentBindingsVersion
    }
}
