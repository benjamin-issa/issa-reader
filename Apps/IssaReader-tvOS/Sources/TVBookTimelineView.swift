import IssaUI
import SwiftUI

/// The whole book as one strip, with a mark where each chapter starts.
///
/// A television has no scrubber and no contents list a remote can comfortably
/// scroll while the voice is talking, so this is the only "where am I" on the
/// screen. It says three things at a glance: how far in, how long the current
/// chapter is against its neighbours, and how many are left.
///
/// **Values only.** Nothing here reads a model. `Canvas` draws on SwiftUI's
/// renderer, which is not the main actor, and `ReaderModel` is `@MainActor` —
/// touching it from a draw closure traps in `dispatch_assert_queue`, which is
/// how `ViewThatFits` crashed this screen twice before. Colours and numbers
/// cross threads; the model does not.
struct TVBookTimelineView: View {
    let ticks: [TVBookTimeline.Tick]
    /// How far through the book, on the same clock the ticks were built on.
    let progress: Double
    /// Which tick the reader is inside, drawn in the accent so the current
    /// chapter can be picked out of seventeen of them.
    let currentTick: Int?
    let track: Color
    let accent: Color
    /// The ground behind the strip, used as a ring around the marker so the
    /// disc stays visible when it lands on top of a tick.
    let paper: Color

    private static let trackHeight: CGFloat = 4
    private static let tickWidth: CGFloat = 1.5
    private static let tickHeight: CGFloat = 12
    private static let markerDiameter: CGFloat = 14
    private static let markerRing: CGFloat = 3

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let midY = size.height / 2
            let place = progress.clampedToUnitInterval()

            // The track, then the part already read on top of it.
            let bar = CGRect(
                x: 0, y: midY - Self.trackHeight / 2,
                width: size.width, height: Self.trackHeight,
            )
            context.fill(
                Path(roundedRect: bar, cornerRadius: Self.trackHeight / 2),
                with: .color(track),
            )
            if place > 0 {
                let elapsed = CGRect(
                    x: 0, y: bar.minY,
                    width: (size.width * place).rounded(), height: Self.trackHeight,
                )
                context.fill(
                    Path(roundedRect: elapsed, cornerRadius: Self.trackHeight / 2),
                    with: .color(accent),
                )
            }

            // The chapter marks. Taller than the track, so they read as
            // divisions of the book rather than as texture on it.
            for (index, tick) in ticks.enumerated() {
                let x = (size.width * (tick.fraction.clampedToUnitInterval())).rounded()
                let rect = CGRect(
                    x: min(max(x - Self.tickWidth / 2, 0), size.width - Self.tickWidth),
                    y: midY - Self.tickHeight / 2,
                    width: Self.tickWidth, height: Self.tickHeight,
                )
                context.fill(
                    Path(rect),
                    with: .color(index == currentTick ? accent : track),
                )
            }

            // Where the reader is. Ringed in the paper colour: without it the
            // disc vanishes into a chapter mark every time it crosses one.
            let centre = CGPoint(x: (size.width * place).rounded(), y: midY)
            let outer = Self.markerDiameter + Self.markerRing * 2
            context.fill(
                Path(ellipseIn: CGRect(
                    x: centre.x - outer / 2, y: centre.y - outer / 2,
                    width: outer, height: outer,
                )),
                with: .color(paper),
            )
            context.fill(
                Path(ellipseIn: CGRect(
                    x: centre.x - Self.markerDiameter / 2,
                    y: centre.y - Self.markerDiameter / 2,
                    width: Self.markerDiameter, height: Self.markerDiameter,
                )),
                with: .color(accent),
            )
        }
        // A picture of what the footer line already says in words, which is the
        // version VoiceOver can use. Two readings of the same thing is noise.
        .accessibilityHidden(true)
    }
}
