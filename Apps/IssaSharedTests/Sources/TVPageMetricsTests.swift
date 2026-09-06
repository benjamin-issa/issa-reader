import CoreGraphics
import Foundation
import Testing

@testable import IssaReader_iOS

/// Where the television puts the page.
///
/// The numbers matter more here than anywhere else in the app: a television
/// crops the edges of its own picture, so a band a few points out is not a
/// slightly untidy layout but a running header the viewer cannot see. And the
/// page's height is the input to pagination — get it wrong and the chapter is
/// laid out for a page that is not on the screen.
@Suite("The television's page")
struct TVPageMetricsTests {
    /// A 4K Apple TV renders at 1920 × 1080 points, whatever the panel does.
    private static let screen = CGSize(width: 1920, height: 1080)
    private static let margin: CGFloat = 60
    private static let fontSize: CGFloat = 40

    private static func frames(
        in size: CGSize = screen, margin: CGFloat = margin, fontSize: CGFloat = fontSize,
    ) -> TVPageMetrics.Frames {
        TVPageMetrics.frames(in: size, margin: margin, fontSize: fontSize)
    }

    @Test("the page is a 1280 by 736 column, centred, below the header")
    func pageOnATelevision() {
        let page = Self.frames().page
        #expect(page.origin.x == 320)
        #expect(page.origin.y == 128)
        #expect(page.width == 1280)
        #expect(page.height == 736)
    }

    /// Each band sits where the one above it ended, plus its gap — and the last
    /// one ends exactly on the title-safe margin. Asserted as a chain rather
    /// than four literals, so a change to any gap has to be a deliberate one.
    @Test("the bands stack without overlapping and end on the safe margin")
    func bandsTile() {
        let frames = Self.frames()
        #expect(frames.header.origin.y == Self.margin)
        #expect(frames.header.height == 40)
        #expect(frames.page.minY == frames.header.maxY + 28)
        #expect(frames.timeline.minY == frames.page.maxY + 32)
        #expect(frames.timeline.height == 24)
        #expect(frames.footer.minY == frames.timeline.maxY + 16)
        #expect(frames.footer.height == 84)
        #expect(frames.footer.maxY == Self.screen.height - Self.margin)
    }

    @Test("every band shares the page's column")
    func bandsShareTheColumn() {
        let frames = Self.frames()
        for band in [frames.header, frames.timeline, frames.footer] {
            #expect(band.origin.x == frames.page.origin.x)
            #expect(band.width == frames.page.width)
        }
        // Centred inside the safe width: the same gutter on both sides.
        let right = Self.screen.width - Self.margin - frames.page.maxX
        #expect(right == frames.page.minX - Self.margin)
    }

    /// A half-point width makes TextKit fit a different number of characters
    /// per line each time the window is measured, and the whole chapter
    /// re-paginates for nothing.
    @Test("every value is a whole number of points")
    func integralValues() {
        for size in [Self.screen, CGSize(width: 1921, height: 1081), CGSize(width: 1280, height: 720)] {
            let frames = Self.frames(in: size)
            for band in [frames.header, frames.page, frames.timeline, frames.footer] {
                #expect(band.origin.x == band.origin.x.rounded())
                #expect(band.origin.y == band.origin.y.rounded())
                #expect(band.width == band.width.rounded())
                #expect(band.height == band.height.rounded())
            }
        }
    }

    /// The measure is capped by the screen, not the other way round: 32 em at
    /// 40 pt is 1280, and a window narrower than that gets its whole safe width.
    @Test("a narrow window still yields a readable page")
    func narrowWindow() {
        let frames = Self.frames(in: CGSize(width: 1280, height: 720))
        // 1280 wide less two 60 pt margins: the whole safe width, because 32 em
        // of 40 pt type would not fit in it.
        #expect(frames.page.width == 1160)
        #expect(frames.page.height >= 200)
        #expect(frames.footer.maxY == 720 - Self.margin)
    }

    /// Nothing here may hand `open(pageSize:)` a NaN or a negative: a text
    /// container sized that way lays out no glyphs at all, and a blank book
    /// reports no error anywhere.
    @Test("a degenerate window produces a usable page rather than nonsense")
    func degenerateWindow() {
        let nowhere = CGSize(width: CGFloat.nan, height: CGFloat.nan)
        for size in [CGSize(width: 0, height: 0), nowhere, CGSize(width: -100, height: -100)] {
            let frames = Self.frames(in: size)
            #expect(frames.page.width >= 0)
            #expect(frames.page.width.isFinite)
            #expect(frames.page.height >= TVPageMetrics.minimumPageHeight)
        }
    }

    /// The measure follows the type. This is the one number to tune if a full
    /// line reads too short or too long across a room.
    @Test("the column is the measure in ems, capped by the safe width")
    func columnFollowsTheFont() {
        #expect(Self.frames(fontSize: 30).page.width == 30 * TVPageMetrics.measureInEms)
        // 32 em of 60 pt is 1920, wider than the 1800 pt safe width, so the
        // safe width wins rather than the text running off both edges.
        #expect(Self.frames(fontSize: 60).page.width == 1800)
    }
}
