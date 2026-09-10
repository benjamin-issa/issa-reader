#if os(macOS)
import AppKit
import IssaUI
import SwiftUI

/// The Mac's Ask popover: the sheet's contents, in a box that scrolls and that
/// the reader can drag bigger.
///
/// A popover is sized by what is inside it, so "resizable" here means resizing
/// the content — there is no window frame to take hold of, and `NSPopover` will
/// not be dragged. The bare sheet was pinned at 420 points wide with a minimum
/// height and no maximum it could reach, no scroller anywhere in `Ask/`, and an
/// answer that insists on its full height: anything longer than a short
/// paragraph was cut off mid-sentence with nothing to say so and no way to
/// reach the rest of it.
///
/// The size is remembered rather than reset per question. A reader who has just
/// dragged the panel open to finish one answer is usually about to ask another.
struct AskPanel: View {
    let model: ReaderModel

    @AppStorage("issa.ask.panel.width") private var width = AskPanel.defaultWidth
    @AppStorage("issa.ask.panel.height") private var height = AskPanel.defaultHeight

    /// The size the drag began from.
    ///
    /// `DragGesture.translation` is measured from where the press landed, so
    /// adding it to the live size on every change compounds and the corner runs
    /// away from the pointer.
    @State private var sizeAtDragStart: CGSize?

    /// Room for a paragraph and its sources without a scroll, while leaving
    /// most of the page the question is about on screen.
    private static let defaultWidth: Double = 460
    private static let defaultHeight: Double = 560
    /// Narrower than this and the header's title, its Beta pill and its Done
    /// button stop fitting on one line.
    private static let minWidth: Double = 360
    private static let minHeight: Double = 280
    /// Wider or taller than this and the popover is bigger than the reading
    /// window it is pointing at on the smallest Mac laptop.
    private static let maxWidth: Double = 720
    private static let maxHeight: Double = 820

    var body: some View {
        ScrollView {
            AskSheet(model: model, layout: .panel)
        }
        // Nothing to bounce against when the composer is half the panel's
        // height, which is most of the time.
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: width, height: height)
        // The sheet paints its own paper, but in `.panel` it is only as tall as
        // it needs to be — so below a short question the popover's own material
        // would otherwise show through.
        .background(Palette.paper)
        .overlay(alignment: .bottomTrailing) { grabber }
    }

    /// Three strokes across the corner, which is what a box that can be dragged
    /// bigger has looked like since long before this one.
    private var grabber: some View {
        ResizeGrip()
            .stroke(Palette.inkTertiary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 11, height: 11)
            // A hit area wider than the strokes, and a shape to make the gaps
            // between them count: a grip you have to hit exactly is a grip
            // nobody finds.
            .padding(5)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.frameResize(position: .bottomRight, directions: .all).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = sizeAtDragStart ?? CGSize(width: width, height: height)
                        sizeAtDragStart = start
                        width = Self.clamped(
                            Double(start.width + value.translation.width),
                            from: Self.minWidth, to: Self.maxWidth)
                        height = Self.clamped(
                            Double(start.height + value.translation.height),
                            from: Self.minHeight, to: Self.maxHeight)
                    }
                    .onEnded { _ in sizeAtDragStart = nil },
            )
            .accessibilityLabel("Resize the Ask panel")
    }

    private static func clamped(_ value: Double, from lower: Double, to upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}

/// The corner grip's three diagonals, longest nearest the corner.
private struct ResizeGrip: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [0.35, 0.65, 0.95] {
            let inset = rect.width * fraction
            path.move(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - inset))
        }
        return path
    }
}
#endif
