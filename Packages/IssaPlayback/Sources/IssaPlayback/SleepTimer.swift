import Foundation
import Observation

/// Stops playback after a set time, or at the end of the current chapter.
///
/// Fades out over the last few seconds rather than cutting off mid-word, which
/// is the difference between falling asleep to a book and being jolted by
/// silence.
@Observable
@MainActor
public final class SleepTimer {
    public enum Mode: Hashable, Sendable {
        case off
        case duration(TimeInterval)
        /// Stop when the chapter being narrated finishes.
        case endOfChapter

        public var title: String {
            switch self {
            case .off: "Off"
            case let .duration(seconds): "\(Int(seconds / 60)) min"
            case .endOfChapter: "End of chapter"
            }
        }
    }

    public private(set) var mode: Mode = .off
    /// Seconds left, for the countdown a listener glances at.
    public private(set) var remaining: TimeInterval?

    public static let presets: [Mode] = [
        .duration(5 * 60), .duration(15 * 60), .duration(30 * 60),
        .duration(45 * 60), .duration(60 * 60), .endOfChapter,
    ]

    private var task: Task<Void, Never>?
    private let onExpire: @MainActor () -> Void
    private let fade: @MainActor (Float) -> Void

    /// - Parameters:
    ///   - onExpire: called when the timer runs out; pauses playback.
    ///   - fade: called with a 0...1 volume multiplier during the fade-out.
    public init(
        onExpire: @escaping @MainActor () -> Void,
        fade: @escaping @MainActor (Float) -> Void = { _ in },
    ) {
        self.onExpire = onExpire
        self.fade = fade
    }

    /// The last stretch is faded rather than cut.
    static let fadeDuration: TimeInterval = 8

    public func start(_ mode: Mode) {
        cancel()
        self.mode = mode
        guard case let .duration(seconds) = mode else {
            // End-of-chapter is driven by the coordinator reaching a boundary,
            // not by a clock.
            remaining = nil
            return
        }

        remaining = seconds
        task = Task { [weak self] in
            let step: TimeInterval = 1
            var left = seconds
            while left > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(step))
                left -= step
                guard let self, !Task.isCancelled else { return }
                remaining = max(0, left)
                if left <= Self.fadeDuration {
                    fade(Float(max(0, left / Self.fadeDuration)))
                }
            }
            guard let self, !Task.isCancelled else { return }
            fade(1)
            onExpire()
            reset()
        }
    }

    /// Called when a chapter boundary is crossed, for the end-of-chapter mode.
    public func chapterDidEnd() {
        guard mode == .endOfChapter else { return }
        onExpire()
        reset()
    }

    public func cancel() {
        task?.cancel()
        task = nil
        fade(1)
        reset()
    }

    private func reset() {
        mode = .off
        remaining = nil
    }

    /// "12:30" for a glance in the dark.
    public var remainingText: String? {
        guard let remaining else { return nil }
        let total = Int(remaining.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
