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
}

/// A physical control that can be bound to an action.
public enum PlaybackControl: String, Codable, Sendable, CaseIterable, Hashable {
    case tapForward
    case tapBackward
    case doubleTapForward
    case doubleTapBackward
    case holdForward
    case holdBackward
    /// The head unit's next/previous track buttons, which is also where a
    /// steering wheel's `»` and `«` are routed by CarPlay.
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
    public var bindings: [ControlSurface: [PlaybackControl: PlaybackAction]]
    /// Seconds for the skip actions, shown on the buttons themselves.
    public var skipForwardInterval: TimeInterval
    public var skipBackwardInterval: TimeInterval

    public init(
        bindings: [ControlSurface: [PlaybackControl: PlaybackAction]] = CommandMap.defaultBindings,
        skipForwardInterval: TimeInterval = 30,
        skipBackwardInterval: TimeInterval = 15,
    ) {
        self.bindings = bindings
        self.skipForwardInterval = skipForwardInterval
        self.skipBackwardInterval = skipBackwardInterval
    }

    public func action(for control: PlaybackControl, on surface: ControlSurface) -> PlaybackAction {
        bindings[surface]?[control] ?? .none
    }

    public mutating func bind(_ action: PlaybackAction, to control: PlaybackControl, on surface: ControlSurface) {
        bindings[surface, default: [:]][control] = action
    }

    /// Defaults chosen to match what the design shows, and what an audiobook
    /// listener expects: taps skip by an interval, holds move by chapter, and in
    /// the car the wheel moves by paragraph — a useful unit while driving, where
    /// a chapter is too coarse and a sentence too fine.
    public static let defaultBindings: [ControlSurface: [PlaybackControl: PlaybackAction]] = [
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
}
