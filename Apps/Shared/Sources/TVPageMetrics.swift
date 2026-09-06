import CoreGraphics
import Foundation

/// Where each band of the television's book screen sits.
///
/// Pure arithmetic over a window size, so the one decision that governs whether
/// the TV reads like a book — how wide the column is, and how much height is
/// left for the page after the running header, the timeline and the footer —
/// can be asserted rather than eyeballed on a screen ten feet away.
///
/// In `Apps/Shared` rather than beside `TVReadalongView` because the tvOS
/// target has no test bundle; this compiles into iOS as well, and
/// `IssaSharedTests` runs there.
///
/// Deliberately **not** written in `Metrics` tokens. Those double themselves on
/// tvOS (`Metrics.scale == 2`) and stay at 1× everywhere else, so a layout
/// stated in them would measure differently in the test bundle from the screen
/// it describes. These numbers are the television's own, in its own 1920 × 1080
/// coordinates, and they are the same wherever this file is compiled.
enum TVPageMetrics {
    // MARK: - The bands

    /// Running header: the book title on the left, the chapter on the right.
    static let headerHeight: CGFloat = 40
    /// Header to page. Wider than the gaps below it, so the page reads as the
    /// subject of the screen and the header as a label above it.
    static let headerGap: CGFloat = 28
    /// Page to timeline.
    static let timelineGap: CGFloat = 32
    /// The chapter-marker strip.
    static let timelineHeight: CGFloat = 24
    /// Timeline to footer. Tight on purpose: the strip and the words beneath it
    /// say the same thing, and a gap here would read as two separate readouts.
    static let footerGap: CGFloat = 16
    /// Cover, progress line, hint line and the transport row.
    static let footerHeight: CGFloat = 84

    /// How many characters wide a comfortable measure is, in ems.
    ///
    /// The one number to tune if a full line comes out too short or too long:
    /// 32 em of a serif runs to roughly 58–70 characters, which is the measure
    /// a printed book uses and the reason the page reads as a page rather than
    /// as a screenful of subtitles. At 40 pt that is a 1280 pt column on a
    /// 1800 pt safe width — the rest is margin, which is the point.
    static let measureInEms: CGFloat = 32

    /// Never let the page collapse to nothing on a container too short to hold
    /// the full furniture: a page of no height draws no glyphs at all, which
    /// reads as a broken screen rather than as a cramped one.
    static let minimumPageHeight: CGFloat = 200

    /// The four rectangles, in the window's own coordinates.
    struct Frames: Equatable {
        var header: CGRect
        var page: CGRect
        var timeline: CGRect
        var footer: CGRect

        /// What `ReaderModel.open(pageSize:)` is given, and the id the layout
        /// task is keyed on.
        var pageSize: CGSize { page.size }
    }

    /// The bands for a window, inside a title-safe margin.
    ///
    /// Every value is rounded: a page whose width lands on a half point makes
    /// TextKit fit a different number of characters per line each time the
    /// window is measured, and the whole chapter re-paginates for nothing.
    ///
    /// - Parameters:
    ///   - size: the whole window, not the safe-area content box — the TV's
    ///     overscan allowance is the margin below, so measuring the safe box
    ///     would subtract it twice.
    ///   - margin: the title-safe gutter, 60 pt on a television.
    ///   - fontSize: the reading size the page is set at, which is what fixes
    ///     the width of the measure.
    static func frames(in size: CGSize, margin: CGFloat, fontSize: CGFloat) -> Frames {
        let margin = sane(margin)
        let width = max(sane(size.width) - margin * 2, 0)
        let height = max(sane(size.height) - margin * 2, 0)

        // The furniture takes what it needs; the page takes the rest.
        let furniture = headerHeight + headerGap + timelineGap
            + timelineHeight + footerGap + footerHeight
        let pageHeight = max((height - furniture).rounded(), minimumPageHeight)

        // Centred within the safe width, and never wider than it: a 32 em
        // measure at a large size on a small window would otherwise run off
        // both edges.
        let column = min((max(sane(fontSize), 1) * measureInEms).rounded(), width)
        let columnX = (margin + (width - column) / 2).rounded()

        let headerY = margin.rounded()
        let pageY = (headerY + headerHeight + headerGap).rounded()
        let timelineY = (pageY + pageHeight + timelineGap).rounded()
        let footerY = (timelineY + timelineHeight + footerGap).rounded()

        return Frames(
            header: CGRect(x: columnX, y: headerY, width: column, height: headerHeight),
            page: CGRect(x: columnX, y: pageY, width: column, height: pageHeight),
            timeline: CGRect(x: columnX, y: timelineY, width: column, height: timelineHeight),
            footer: CGRect(x: columnX, y: footerY, width: column, height: footerHeight),
        )
    }

    /// A NaN width would put NaN into the page size, and a text container sized
    /// NaN lays out nothing at all — a blank book with no error anywhere.
    private static func sane(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }
}
