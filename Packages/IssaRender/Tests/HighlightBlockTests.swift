import CoreGraphics
import Foundation
import ImageIO
import IssaEPUB
import IssaUI
import Testing
import UniformTypeIdentifiers

@testable import IssaRender

/// The read-along highlight used to be filled once per line, each line's
/// rectangle grown by `insetBy(dx: -2, dy: -1)`. Consecutive lines are flush,
/// so the two pads overlapped by 2 pt at every seam and a translucent colour
/// was composited over itself there — a dark band across the middle of every
/// wrapped sentence. These tests hold the geometry that replaces it, and
/// `uniformAlphaAtTheSeam` counts the actual pixels, because that band is
/// invisible to any test that only compares rectangles.
@Suite("The highlight block")
struct HighlightBlockTests {
    /// The bundled reading faces, so the two tests that lay out a real chapter
    /// wrap it where the reader would. Nothing in IssaRender registers them,
    /// and without this the measure depends on whichever suite happened to run
    /// first — a fallback face wraps a paragraph somewhere else entirely.
    init() { IssaFonts.register() }

    // MARK: - Fixtures

    /// A three-line sentence that starts part-way along one line and ends
    /// part-way along another: a step on the left at the top, a step on the
    /// right at the bottom.
    static let first = CGRect(x: 120, y: 0, width: 200, height: 26)
    static let middle = CGRect(x: 0, y: 26, width: 320, height: 26)
    static let last = CGRect(x: 0, y: 52, width: 90, height: 26)
    /// One rectangle per line, which is what every fixture in this file is:
    /// `path(lines:)` takes the grouping, so a fixture that means three lines
    /// says so rather than leaving it to be guessed.
    static let staircase = [[first], [middle], [last]]

    /// A line carrying a tall inline run — a larger word, a footnote marker —
    /// with the next genuine line close under it. A(y 0–10) and B(y 0–20) are
    /// one line; C(y 12–22) is the next.
    static let inlineRun = [
        [
            CGRect(x: 0, y: 0, width: 100, height: 10),
            CGRect(x: 100, y: 0, width: 60, height: 20),
        ],
        [CGRect(x: 0, y: 12, width: 200, height: 10)],
    ]

    /// A 60 pt initial beside the first of three 20 pt lines. Told apart, it is
    /// three lines; guessed at, it is indistinguishable from one 60 pt line —
    /// the case that makes the grouping a parameter rather than a heuristic.
    static let dropCapital = [
        [
            CGRect(x: 0, y: 0, width: 40, height: 60),
            CGRect(x: 44, y: 0, width: 200, height: 20),
        ],
        [CGRect(x: 0, y: 20, width: 240, height: 20)],
        [CGRect(x: 0, y: 40, width: 120, height: 20)],
    ]

    /// 18 pt reading size: 3 pt of padding at each end, 1 pt above and below,
    /// a 4 pt corner.
    static let style = HighlightBlock.Style(fontSize: 18)

    // MARK: - Helpers

    static func subpathCount(_ path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { count += 1 }
        }
        return count
    }

    static func union(_ rects: [CGRect]) -> CGRect {
        rects.reduce(CGRect.null) { $0.union($1) }
    }

    /// The bounding box the block is obliged to have: the rows as padded at
    /// their ends, with the block's vertical padding above the first and below
    /// the last, and nowhere in between.
    static func expectedBounds(_ lines: [[CGRect]], style: HighlightBlock.Style) -> CGRect {
        var box = union(HighlightBlock.rows(fromLines: lines, horizontalPadding: style.horizontal))
        box.origin.y -= style.vertical
        box.size.height += style.vertical * 2
        return box
    }

    static func expectClose(_ actual: CGRect, _ expected: CGRect, _ what: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(actual.minX - expected.minX) < 0.01, "\(what): minX", sourceLocation: sourceLocation)
        #expect(abs(actual.minY - expected.minY) < 0.01, "\(what): minY", sourceLocation: sourceLocation)
        #expect(abs(actual.maxX - expected.maxX) < 0.01, "\(what): maxX", sourceLocation: sourceLocation)
        #expect(abs(actual.maxY - expected.maxY) < 0.01, "\(what): maxY", sourceLocation: sourceLocation)
    }

    // MARK: - Style

    @Test("the reading size decides how much air the block leaves")
    func styleFromFontSize() {
        let phone = HighlightBlock.Style(fontSize: 18)
        #expect(phone.horizontal == 3)
        #expect(phone.vertical == 1)
        #expect(phone.cornerRadius == 4)

        // The television reads at 40 pt, where a phone's 3 pt pad vanishes.
        let television = HighlightBlock.Style(fontSize: 40)
        #expect(television.horizontal == 6)
        #expect(television.vertical == 2)
        #expect(television.cornerRadius == 9)

        // A nonsense size must not put NaN into a path: that blanks the page.
        let broken = HighlightBlock.Style(fontSize: .nan)
        #expect(broken.horizontal.isFinite && broken.vertical.isFinite && broken.cornerRadius.isFinite)
        let negative = HighlightBlock.Style(horizontal: -4, vertical: .infinity, cornerRadius: -1)
        #expect(negative.horizontal == 0 && negative.vertical == 0 && negative.cornerRadius == 0)
    }

    // MARK: - One line

    @Test("a single line is exactly the rounded rectangle it used to be")
    func singleRectIsARoundedRect() {
        let rect = CGRect(x: 40, y: 10, width: 200, height: 26)
        let block = HighlightBlock.path(lines: [[rect]], style: Self.style)
        let padded = rect.insetBy(dx: -Self.style.horizontal, dy: -Self.style.vertical)
        let rounded = CGPath(
            roundedRect: padded,
            cornerWidth: Self.style.cornerRadius,
            cornerHeight: Self.style.cornerRadius,
            transform: nil,
        )

        Self.expectClose(block.boundingBoxOfPath, padded, "single line bounds")
        #expect(Self.subpathCount(block) == 1)

        // Compared by what they cover rather than by their curve segments: the
        // rounding here is a true arc and CoreGraphics's is a Bézier fitted to
        // one, which differ by a fraction of a point at the corners. Only
        // points that are unambiguously in or out of the reference shape —
        // three quarters of a point clear of its edge in every direction — are
        // asked to agree.
        var checked = 0
        for x in stride(from: 30.0, through: 250.0, by: 0.5) {
            for y in stride(from: 0.0, through: 46.0, by: 0.5) {
                let point = CGPoint(x: x, y: y)
                let inside = rounded.contains(point)
                let unambiguous = [-0.75, 0.75].allSatisfy { dx in
                    [-0.75, 0.75].allSatisfy { dy in
                        rounded.contains(CGPoint(x: x + dx, y: y + dy)) == inside
                    }
                }
                guard unambiguous else { continue }
                #expect(block.contains(point) == inside, "disagreed at \(point)")
                checked += 1
            }
        }
        #expect(checked > 10_000, "the grid should have covered the shape")
    }

    // MARK: - The staircase

    @Test("a wrapped sentence is one subpath covering exactly the padded rows")
    func staircaseBounds() {
        let block = HighlightBlock.path(lines: Self.staircase, style: Self.style)
        #expect(Self.subpathCount(block) == 1, "a wrapped sentence is one shape, not three")
        // 3 pt at each end of every row, 1 pt above the first and below the
        // last, and nothing added at the two seams.
        Self.expectClose(block.boundingBoxOfPath, CGRect(x: -3, y: -1, width: 326, height: 80), "staircase")
        Self.expectClose(block.boundingBoxOfPath, Self.expectedBounds(Self.staircase, style: Self.style), "derived")
    }

    @Test("the seam and its neighbours are inside; the notches beside them are not")
    func seamsAndNotches() {
        let block = HighlightBlock.path(lines: Self.staircase, style: Self.style)

        // x = 200 lies inside every one of the first two rows, so the seam
        // between them and the half point either side of it are all covered.
        for y in [25.5, 26.0, 26.5] {
            #expect(block.contains(CGPoint(x: 200, y: y)), "seam at y \(y) should be covered")
        }
        // x = 50 lies inside the second and third rows, whose seam is at 52.
        for y in [51.5, 52.0, 52.5] {
            #expect(block.contains(CGPoint(x: 50, y: y)), "seam at y \(y) should be covered")
        }

        // The paper the sentence does not reach stays paper: to the left of the
        // first line, and to the right of the last.
        #expect(!block.contains(CGPoint(x: 50, y: 12)), "the first line starts at x 120")
        #expect(!block.contains(CGPoint(x: 116, y: 12)))
        #expect(!block.contains(CGPoint(x: 200, y: 65)), "the last line ends at x 90")
        #expect(!block.contains(CGPoint(x: 100, y: 70)))
    }

    // MARK: - The bug itself

    /// The regression test for the band. It rasterises, because the band is a
    /// composite of two fills and no amount of rectangle comparison can see it.
    @Test("the seam is exactly as dark as the middle of a line")
    func uniformAlphaAtTheSeam() throws {
        let block = HighlightBlock.path(lines: Self.staircase, style: Self.style)
        let alpha: CGFloat = 0.22 // ReaderTheme.highlight on light paper.

        let painted = try Self.raster { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
            context.addPath(block)
            context.fillPath()
        }
        // x = 200 sits well inside the first two rows, and y = 26 is their
        // seam; y = 12 and y = 39 are the middles of those rows.
        let seam = painted.alpha(x: 200, y: 26)
        let centre = painted.alpha(x: 200, y: 39)
        #expect(seam == centre, "the seam painted \(seam), the middle of a line \(centre)")
        #expect(abs(Int(centre) - 56) <= 1, "0.22 of 255 is 56, and it was \(centre)")
        #expect(painted.alpha(x: 200, y: 12) == centre)
        #expect(painted.alpha(x: 50, y: 52) == centre, "the lower seam too")

        // And the same picture drawn the old way, to show the test can fail:
        // one rounded rect per line, each grown by 1 pt vertically, so the two
        // pads share 2 pt at the seam and the colour is composited twice.
        let control = try Self.raster { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
            for rect in Self.staircase.flatMap({ $0 }) {
                context.addPath(CGPath(
                    roundedRect: rect.insetBy(dx: -2, dy: -1),
                    cornerWidth: 3, cornerHeight: 3, transform: nil,
                ))
                context.fillPath()
            }
        }
        let oldSeam = control.alpha(x: 200, y: 26)
        let oldCentre = control.alpha(x: 200, y: 39)
        #expect(oldSeam > oldCentre + 20, "the old drawing should darken the seam (\(oldSeam) vs \(oldCentre))")
        #expect(abs(Int(oldCentre) - 56) <= 1)
    }

    @Test("the whole block rasterises to one flat tone")
    func rasterisesEvenly() throws {
        let block = HighlightBlock.path(lines: Self.staircase, style: Self.style)
        let painted = try Self.raster { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
            context.addPath(block)
            context.fillPath()
        }

        // Every pixel a good way inside the shape, seams included, must carry
        // the same alpha; anything else is a second fill overlapping a first.
        var interior = 0
        for row in HighlightBlock.rows(fromLines: Self.staircase, horizontalPadding: Self.style.horizontal) {
            for x in stride(from: row.minX + 6, to: row.maxX - 6, by: 1) {
                for y in stride(from: row.minY + 2, to: row.maxY - 2, by: 1) {
                    guard x >= 0, y >= 0, x < 340, y < 80 else { continue }
                    #expect(painted.alpha(x: Int(x), y: Int(y)) == 56, "uneven at \(x), \(y)")
                    interior += 1
                }
            }
        }
        #expect(interior > 5_000)

        // The same shape, magnified, so the corners and the two steps can be
        // looked at rather than only asserted about.
        let picture = try Self.raster(width: 1000, height: 250, scale: 3, offset: CGPoint(x: 4, y: 3)) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
            context.addPath(block)
            context.fillPath()
        }
        try picture.writePNG(named: "highlight-block")
    }

    // MARK: - Rows and runs

    @Test("rows that do not meet become separate closed shapes")
    func separateSubpaths() {
        // Flush, but a short centred line under a short centred line: nothing
        // to join them with but a sliver crossing blank paper.
        let apart = [[CGRect(x: 0, y: 0, width: 40, height: 26)], [CGRect(x: 280, y: 26, width: 40, height: 26)]]
        #expect(Self.subpathCount(HighlightBlock.path(lines: apart, style: Self.style)) == 2)

        // A gap far too wide to be a line break — a mark that skips a heading.
        let distant = [[CGRect(x: 0, y: 0, width: 200, height: 26)], [CGRect(x: 0, y: 100, width: 200, height: 26)]]
        #expect(Self.subpathCount(HighlightBlock.path(lines: distant, style: Self.style)) == 2)

        // Both halves of a split run get their own vertical padding, since
        // neither edge is a seam any more.
        let block = HighlightBlock.path(lines: distant, style: Self.style)
        Self.expectClose(block.boundingBoxOfPath, CGRect(x: -3, y: -1, width: 206, height: 128), "split run")

        // Flush and overlapping, but by less than the two corner radii the join
        // would need: 1 pt of shared text, 7 pt once both rows are padded,
        // against the 8 pt a 4 pt corner asks for on each side.
        let barely = [[CGRect(x: 0, y: 0, width: 100, height: 26)], [CGRect(x: 99, y: 26, width: 100, height: 26)]]
        #expect(Self.subpathCount(HighlightBlock.path(lines: barely, style: Self.style)) == 2)
        #expect(HighlightBlock.runs(
            HighlightBlock.rows(fromLines: barely, horizontalPadding: 3), minimumOverlap: 8).count == 2)

        // Three points of shared text is nine once padded, and joins.
        let enough = [[CGRect(x: 0, y: 0, width: 100, height: 26)], [CGRect(x: 97, y: 26, width: 100, height: 26)]]
        #expect(Self.subpathCount(HighlightBlock.path(lines: enough, style: Self.style)) == 1)
    }

    @Test("a hairline gap between lines is closed, so the seam is exactly shared")
    func closesHairlineGaps() {
        let gapped = HighlightBlock.rows(
            fromLines: [
                [CGRect(x: 0, y: 0, width: 200, height: 26)],
                [CGRect(x: 0, y: 26.4, width: 200, height: 26)],
            ],
            horizontalPadding: 0,
        )
        #expect(gapped.count == 2)
        #expect(gapped[0].maxY == gapped[1].minY)
        // Closed downwards: the row above grows to meet the one below, so no
        // glyph loses its cover.
        #expect(gapped[0].maxY == 26.4)

        // And the other direction, which is the one a real page hands over:
        // Alice's justified column reports consecutive lines overlapping by a
        // hairline as often as it leaves a gap. The row above is trimmed onto
        // the row below rather than swallowing it, so two lines stay two.
        let lapped = HighlightBlock.rows(
            fromLines: [
                [CGRect(x: 0, y: 0, width: 200, height: 26)],
                [CGRect(x: 0, y: 25.6, width: 200, height: 26)],
            ],
            horizontalPadding: 0,
        )
        #expect(lapped.count == 2)
        #expect(lapped[0].maxY == lapped[1].minY)
        #expect(lapped[0].maxY == 25.6)
    }

    @Test("the pieces TextKit splits one line into come back as one row")
    func mergesSplitLines() {
        // A line broken at an attribute run: same band, two rectangles, and the
        // caller says so.
        let pieces = [
            [
                CGRect(x: 0, y: 26, width: 100, height: 26),
                CGRect(x: 100, y: 26, width: 120, height: 26),
            ],
            [CGRect(x: 0, y: 0, width: 200, height: 26)],
        ]
        let grouped = HighlightBlock.rows(fromLines: pieces, horizontalPadding: 0)
        #expect(grouped.count == 2, "two lines, however many segments they arrived in")
        #expect(grouped[0].minY == 0)
        #expect(grouped[1].width == 220)

        // The same rectangles with the grouping thrown away. The guess gets
        // this one right — the two pieces share a band and the line above
        // touches neither — which is why it survived as long as it did.
        let guessed = HighlightBlock.rows(
            fromLines: HighlightBlock.inferredLines(from: pieces.flatMap { $0 }),
            horizontalPadding: 0,
        )
        #expect(guessed.count == 2)
        #expect(guessed[1].width == 220)
    }

    // MARK: - The grouping, and the guess behind it

    /// A footnote marker or a word at a larger size makes one line arrive as a
    /// short rectangle beside a tall one. The old merge compared each incoming
    /// rectangle against the *grown union*, so the tall piece raised the
    /// accumulator's `maxY` and the next genuine line then cleared the
    /// `min(height) / 2` threshold and was unioned in: A, B and C came back as
    /// one row spanning y 0–22, and the mark was painted over a line the
    /// sentence never reached.
    @Test("a tall run on one line does not swallow the line beneath it")
    func tallRunDoesNotSwallowTheNextLine() {
        let rows = HighlightBlock.rows(fromLines: Self.inlineRun, horizontalPadding: 0)
        #expect(rows.count == 2, "a tall run and the line under it are two lines")
        #expect(rows[0].minY == 0)
        #expect(rows[0].maxY == 12, "trimmed onto the line below, not merged with it")
        #expect(rows[1].maxY == 22)
    }

    /// The same three rectangles with the grouping thrown away — the shape a
    /// caller that has no line identity is left with, and the exact input the
    /// review executed. Two, now, because `inferredLines` measures each
    /// rectangle against the one that *opened* its line rather than the union
    /// the line has grown into: C overlaps A by −2, not by 8.
    @Test("the guess measures against the rectangle that opened the line")
    func inferredLinesDoNotGrow() {
        let guessed = HighlightBlock.inferredLines(from: Self.inlineRun.flatMap { $0 })
        #expect(guessed.count == 2, "the tall run swallowed the line below it again")
        #expect(guessed[0].count == 2, "the short piece and the tall one are one line")
        #expect(guessed[1].count == 1)
        #expect(HighlightBlock.rows(fromLines: guessed, horizontalPadding: 0).count == 2)
    }

    /// The case no rule over rectangles alone can decide, which is why the
    /// grouping is a parameter. Told which line each rectangle is on, the block
    /// is three rows and the short last line stays short.
    @Test("a drop capital told apart from the lines it spans is three rows")
    func dropCapitalGrouped() {
        let rows = HighlightBlock.rows(fromLines: Self.dropCapital, horizontalPadding: 0)
        #expect(rows.count == 3)
        #expect(rows[0].maxY == 20, "the initial is trimmed onto line two, not left 60 pt tall")
        #expect(rows[2].maxX == 120, "the last line ends where the sentence ends")

        let block = HighlightBlock.path(lines: Self.dropCapital, style: Self.style)
        #expect(!block.contains(CGPoint(x: 220, y: 50)),
                "the mark reaches past the end of the last line")
    }

    /// Deliberately the wrong answer. `cap(y 0–60)` overlaps all three 20 pt
    /// lines by their whole height, so every one of them is "the same line" as
    /// the initial — and "a 60 pt run on line one" and "three lines" are the
    /// same geometry, so nothing here could tell them apart. This is what the
    /// grouping is passed in for; the assertion is pinned so the guess cannot
    /// quietly start claiming to be able to do it.
    @Test("guessed, a drop capital is one line — which is why the grouping is passed in")
    func dropCapitalGuessedWrong() {
        let guessed = HighlightBlock.inferredLines(from: Self.dropCapital.flatMap { $0 })
        #expect(guessed.count == 1,
                "the guess answered \(guessed.count); if it can do this, the grouping is not needed")

        let block = HighlightBlock.path(lines: guessed, style: Self.style)
        #expect(block.contains(CGPoint(x: 220, y: 50)),
                "the guess stopped over-reaching here, so the grouped case above pins nothing")
    }

    /// `LineSpacing.tight` is 1.05, and a line's typographic bounds carry the
    /// face's own leading on top of that, so two genuine lines can genuinely
    /// overlap. The caller has said these are two lines, so they stay two, with
    /// the seam where the second one starts.
    @Test("two lines whose bounds overlap at tight leading stay two lines")
    func tightLeadingOverlap() {
        let tight = [
            [CGRect(x: 0, y: 0, width: 200, height: 22)],
            [CGRect(x: 0, y: 18, width: 140, height: 22)],
        ]
        let rows = HighlightBlock.rows(fromLines: tight, horizontalPadding: 0)
        #expect(rows.count == 2)
        #expect(rows[0].maxY == 18, "the seam is where the second line starts")
        #expect(rows[1].minY == 18)
        #expect(rows[1].maxY == 40)
    }

    /// Segments arrive in layout order, which is not reading order once a mark
    /// runs over a bidirectional line — and a whole line can arrive after the
    /// line below it. Sorted here so the seam-closing walk sees page order.
    @Test("rectangles that arrive out of order are put back into page order")
    func outOfOrder() {
        let jumbled = [
            [
                CGRect(x: 120, y: 26, width: 100, height: 26),
                CGRect(x: 0, y: 26, width: 120, height: 26),
            ],
            [CGRect(x: 0, y: 0, width: 200, height: 26)],
        ]
        let rows = HighlightBlock.rows(fromLines: jumbled, horizontalPadding: 0)
        #expect(rows.count == 2)
        #expect(rows[0].minY == 0, "the line above comes first however it arrived")
        #expect(rows[1].minX == 0)
        #expect(rows[1].maxX == 220, "and the two pieces of one line are one row")
    }

    /// The deprecated flat entry point is kept rather than deleted, so a caller
    /// that genuinely holds no line identity still has a named, documented
    /// answer instead of an inlined guess. It is exactly the guess followed by
    /// the grouped call, and this is what holds it to that.
    @available(*, deprecated, message: "calls the deprecated flat entry point on purpose")
    @Test("the deprecated flat call is the guess followed by the grouped one")
    func deprecatedFlatShim() {
        let flat = Self.inlineRun.flatMap { $0 }
        let shim = HighlightBlock.path(lineRects: flat, style: Self.style)
        let explicit = HighlightBlock.path(
            lines: HighlightBlock.inferredLines(from: flat), style: Self.style)
        Self.expectClose(shim.boundingBoxOfPath, explicit.boundingBoxOfPath, "flat shim")
        #expect(Self.subpathCount(shim) == Self.subpathCount(explicit))
        #expect(!shim.isEmpty)
    }

    @Test("lines of different heights still make one block")
    func differentHeights() {
        // A line with a larger face on it — a drop capital, an inline heading.
        let mixed = [
            [CGRect(x: 0, y: 0, width: 200, height: 34)],
            [CGRect(x: 0, y: 34, width: 200, height: 20)],
        ]
        let block = HighlightBlock.path(lines: mixed, style: Self.style)
        #expect(Self.subpathCount(block) == 1)
        Self.expectClose(block.boundingBoxOfPath, CGRect(x: -3, y: -1, width: 206, height: 56), "mixed heights")
        #expect(block.contains(CGPoint(x: 100, y: 34)), "the seam between them is covered")
    }

    // MARK: - Straightening

    @Test("a step too small to round is flattened outwards, never inwards")
    func straightensTinySteps() {
        // A justified right margin leaves steps of a point or two.
        let ragged = [
            [CGRect(x: 0, y: 0, width: 200, height: 26)],
            [CGRect(x: 0, y: 26, width: 198, height: 26)],
        ]
        let rows = HighlightBlock.rows(fromLines: ragged, horizontalPadding: 0)
        let straight = HighlightBlock.straightened(rows, tolerance: 4)
        #expect(straight[0].maxX == 200)
        #expect(straight[1].maxX == 200, "the shorter row is extended, not the longer one shortened")

        let block = HighlightBlock.path(lines: ragged, style: Self.style)
        Self.expectClose(block.boundingBoxOfPath, CGRect(x: -3, y: -1, width: 206, height: 54), "straightened")
        #expect(block.contains(CGPoint(x: 202, y: 39)), "the second row now reaches as far as the first")

        // A step worth rounding survives.
        let stepped = [
            [CGRect(x: 0, y: 0, width: 200, height: 26)],
            [CGRect(x: 0, y: 26, width: 160, height: 26)],
        ]
        let kept = HighlightBlock.straightened(
            HighlightBlock.rows(fromLines: stepped, horizontalPadding: 0), tolerance: 4)
        #expect(kept[1].maxX == 160)
    }

    @Test("a chain of tiny steps settles rather than leaving one behind")
    func straighteningSettles() {
        let chain = (0 ..< 5).map {
            [CGRect(x: 0, y: CGFloat($0) * 26, width: 200 + CGFloat($0) * 2, height: 26)]
        }
        let straight = HighlightBlock.straightened(
            HighlightBlock.rows(fromLines: chain, horizontalPadding: 0), tolerance: 4)
        #expect(straight.allSatisfy { $0.maxX == 208 })
    }

    // MARK: - Nothing to draw

    @Test("nothing, or nonsense, draws nothing at all")
    func emptyAndDegenerate() {
        #expect(HighlightBlock.path(lines: [], style: Self.style).isEmpty)
        #expect(HighlightBlock.path(lines: [[]], style: Self.style).isEmpty)
        #expect(HighlightBlock.path(lines: [[.zero]], style: Self.style).isEmpty)
        #expect(HighlightBlock.path(lines: [[.null]], style: Self.style).isEmpty)
        #expect(HighlightBlock.path(lines: [[.infinite]], style: Self.style).isEmpty)
        #expect(HighlightBlock.path(
            lines: [[CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)]], style: Self.style).isEmpty)
        #expect(HighlightBlock.path(
            lines: [[CGRect(x: 0, y: 0, width: 100, height: 0)]], style: Self.style).isEmpty)
        #expect(HighlightBlock.rows(fromLines: [], horizontalPadding: 3).isEmpty)
        #expect(HighlightBlock.inferredLines(from: []).isEmpty)
        #expect(HighlightBlock.runs([], minimumOverlap: 8).isEmpty)
        #expect(HighlightBlock.outline(of: []).isEmpty)

        // One good row among the rubbish still draws — and a line made
        // entirely of rubbish is dropped rather than left as an empty row.
        let mixed = [
            [CGRect.null],
            [CGRect(x: 0, y: 0, width: 100, height: 26)],
            [CGRect(x: 5, y: 5, width: 0, height: 0)],
        ]
        #expect(!HighlightBlock.path(lines: mixed, style: Self.style).isEmpty)
        #expect(HighlightBlock.rows(fromLines: mixed, horizontalPadding: 3).count == 1)
    }

    @Test("a right-to-left block is the same walk, mirrored")
    func rightToLeft() {
        // The last line of an RTL paragraph ends at the *left*, so the step is
        // on the other side. Nothing in the outline knows about direction.
        let rtl = [
            [CGRect(x: 0, y: 0, width: 320, height: 26)],
            [CGRect(x: 230, y: 26, width: 90, height: 26)],
        ]
        let block = HighlightBlock.path(lines: rtl, style: Self.style)
        #expect(Self.subpathCount(block) == 1)
        Self.expectClose(block.boundingBoxOfPath, CGRect(x: -3, y: -1, width: 326, height: 54), "RTL")
        #expect(block.contains(CGPoint(x: 280, y: 26)), "the seam under the short line is covered")
        #expect(!block.contains(CGPoint(x: 100, y: 40)), "the paper it does not reach stays paper")
    }

    // MARK: - Against a real chapter

    @Test("every wrapped sentence of a real chapter makes one covering block")
    @MainActor
    func realChapter() throws {
        let (text, ranges) = try PaginatorTests.readalongChapter()
        try Self.check(text: text, ranges: ranges, style: HighlightBlock.Style(fontSize: 18))
    }

    @Test(
        "the same holds at every line spacing, and justified",
        arguments: [
            ReaderStyle(lineSpacing: .tight),
            ReaderStyle(lineSpacing: .normal),
            ReaderStyle(lineSpacing: .roomy),
            ReaderStyle(lineSpacing: .normal, justified: true),
        ],
    )
    @MainActor
    func realChapterAcrossStyles(style: ReaderStyle) throws {
        let (text, ranges) = try Self.chapter(style: style)
        try Self.check(text: text, ranges: ranges, style: HighlightBlock.Style(fontSize: style.fontSize))
    }

    /// A wider net than the four narrated sentences the readalong fixture
    /// holds: hundreds of real wrapped selections out of a real book, on a
    /// justified page, where hanging punctuation and a ragged right margin
    /// produce the steps and hairline gaps the geometry has to survive.
    @Test("a long selection in a real book is one covering block too")
    @MainActor
    func realSelections() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/alice", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        var found: HTMLContentParser.Result?
        for item in package.spine {
            let parsed = try HTMLContentParser(style: ReaderStyle(justified: true))
                .parse(xhtml: try package.archive.read(item.href), baseHref: item.href)
            if parsed.text.length > 4000 { found = parsed; break }
        }
        let content = try #require(found, "no long chapter found")
        let layout = ChapterLayout(text: content.text, fragmentRanges: content.fragmentRanges)
        layout.layout(pageSize: CGSize(width: 300, height: 480))
        let style = HighlightBlock.Style(fontSize: 18)

        var wrapped = 0
        for page in layout.pages.prefix(6) {
            let end = page.characterRange.location + page.characterRange.length
            // A stride that does not divide the line length, so the selections
            // start and stop all over the measure rather than in a pattern.
            for location in stride(from: page.characterRange.location, to: end, by: 97) {
                let range = NSRange(location: location, length: min(140, end - location))
                let lines = layout.lines(forRange: range, on: page)
                let rows = HighlightBlock.rows(fromLines: lines, horizontalPadding: style.horizontal)
                guard rows.count >= 2 else { continue }
                wrapped += 1

                let block = HighlightBlock.path(lines: lines, style: style)
                Self.expectClose(block.boundingBoxOfPath, Self.expectedBounds(lines, style: style),
                                 "selection at \(location)")
                for row in rows {
                    #expect(block.contains(CGPoint(x: row.midX, y: row.midY)),
                            "the middle of a row of the selection at \(location) is outside its own block")
                }
            }
        }
        #expect(wrapped >= 25, "the sweep should have found plenty of wrapped selections (was \(wrapped))")
    }

    /// The readalong fixture parsed under a given reading style, since line
    /// spacing and justification are attributes of the parsed string.
    /// Generalises `PaginatorTests.readalongChapter()`, which uses the default.
    @MainActor
    static func chapter(style: ReaderStyle) throws -> (NSAttributedString, [String: NSRange]) {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/readalong", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        let first = try #require(package.spine.first)
        let parsed = try HTMLContentParser(style: style)
            .parse(xhtml: try package.archive.read(first.href), baseHref: first.href)
        return (parsed.text, parsed.fragmentRanges)
    }

    @MainActor
    static func check(text: NSAttributedString, ranges: [String: NSRange],
                      style: HighlightBlock.Style) throws {
        // Narrow, so most of the fixture's sentences wrap: an unwrapped
        // sentence is one rectangle and tests nothing this file does.
        let layout = ChapterLayout(text: text, fragmentRanges: ranges)
        layout.layout(pageSize: CGSize(width: 240, height: 560))

        var wrapped = 0
        for id in ranges.keys.sorted() {
            guard let page = layout.page(containingFragment: id) else { continue }
            let lines = layout.highlightLines(forFragment: id, on: page)
            let rows = HighlightBlock.rows(fromLines: lines, horizontalPadding: style.horizontal)
            guard rows.count >= 2 else { continue }
            wrapped += 1

            let block = HighlightBlock.path(lines: lines, style: style)
            expectClose(block.boundingBoxOfPath, expectedBounds(lines, style: style), "fragment \(id)")
            for row in rows {
                #expect(block.contains(CGPoint(x: row.midX, y: row.midY)),
                        "the middle of a row of \(id) is outside its own highlight")
            }
        }
        // Four narrated sentences is all the fixture holds; at this width
        // every one of them wraps.
        #expect(wrapped >= 4, "the fixture should offer several wrapped sentences (was \(wrapped))")
    }

    // MARK: - Rasterising

    /// By default a 340 × 80 canvas the size of a phone's page, in the page's
    /// own coordinates: y grows downwards, as it does everywhere TextKit hands
    /// rectangles out, so a fixture row's numbers are also its pixel rows.
    /// `scale` and `offset` exist only for the picture written out at the end,
    /// where the corners want magnifying to be looked at.
    static func raster(
        width: Int = 340,
        height: Int = 80,
        scale: CGFloat = 1,
        offset: CGPoint = .zero,
        _ draw: (CGContext) -> Void,
    ) throws -> Raster {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: offset.x, y: offset.y)
        draw(context)
        return Raster(width: width, height: height, pixels: pixels)
    }

    struct Raster {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        /// The alpha byte, which is what a double composite shows up in: the
        /// canvas starts empty and the fill is white, so a pixel covered once
        /// at 0.22 reads 56 and a pixel covered twice reads 100.
        func alpha(x: Int, y: Int) -> UInt8 {
            pixels[(y * width + x) * 4 + 3]
        }

        /// Writes the block out so its shape can be looked at rather than only
        /// asserted about. `ISSA_ARTEFACT_DIR` says where; otherwise it lands
        /// in the temporary directory and the path is printed.
        func writePNG(named name: String) throws {
            let directory = ProcessInfo.processInfo.environment["ISSA_ARTEFACT_DIR"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(name).png")

            // Composited onto white, because a translucent mark on a
            // transparent ground is unreadable in most viewers.
            var flattened = [UInt8](repeating: 255, count: width * height * 4)
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Double(pixels[index + 3]) / 255
                for channel in 0 ..< 3 {
                    // The mark, in the reader's tangerine, over white paper.
                    let ink = [0.886, 0.522, 0.227][channel]
                    flattened[index + channel] = UInt8((ink * alpha + (1 - alpha)) * 255)
                }
            }
            let provider = try #require(CGDataProvider(data: Data(flattened) as CFData))
            let image = try #require(CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
            ))
            let destination = try #require(CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            print("highlight block written to \(url.path)")
        }
    }
}
