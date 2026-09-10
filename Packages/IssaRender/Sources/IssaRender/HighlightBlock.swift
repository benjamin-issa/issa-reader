import CoreGraphics
import Foundation

/// One connected shape for a marked passage, in place of one lozenge per line.
///
/// The reader used to fill a rounded rectangle for every line fragment TextKit
/// reported, each grown by `insetBy(dx: -2, dy: -1)` and painted in a
/// translucent colour. Consecutive lines' rectangles are flush, so the two pads
/// met and every seam was covered twice: 0.22 alpha composited over 0.22 alpha
/// reads as 0.39, which is the dark band that ran across the middle of every
/// wrapped sentence. The separate lozenges also read as a stack of strips
/// rather than one marked passage.
///
/// The cure is to paint once. This turns the line rectangles into a single
/// rectilinear outline whose seams are *shared* edges rather than overlapping
/// pads, rounds its corners, and hands back one `CGPath` for the caller to fill
/// in one go — so the alpha is uniform by construction rather than by luck.
///
/// Deliberately pure CoreGraphics: no state, nothing `@MainActor`, no view. The
/// phone, the Mac and the television all mark a sentence with the same shape,
/// and every step below is testable on its own.
public enum HighlightBlock {

    // MARK: - Style

    /// How much air the block puts around the glyphs, and how round it is.
    public struct Style: Sendable, Hashable {
        /// Added to each end of every row, so a mark starts a little before the
        /// first glyph and ends a little after the last.
        public var horizontal: CGFloat

        /// Added above the first row and below the last — and only there.
        /// Padding a seam is precisely what produced the double-composited
        /// band, so the seams between rows stay exactly shared.
        public var vertical: CGFloat

        public var cornerRadius: CGFloat

        public init(horizontal: CGFloat, vertical: CGFloat, cornerRadius: CGFloat) {
            self.horizontal = Self.sane(horizontal)
            self.vertical = Self.sane(vertical)
            self.cornerRadius = Self.sane(cornerRadius)
        }

        /// The proportions the reader uses, derived from the reading size.
        ///
        /// Derived rather than fixed because the same block is drawn on a phone
        /// at 18 pt and on a television at 40 pt, and a 3 pt pad that looks
        /// generous around small type all but disappears around large type.
        /// 18 pt gives 3 / 1 / 4; 40 pt gives 6 / 2 / 9.
        public init(fontSize: CGFloat) {
            let size = fontSize.isFinite ? max(1, fontSize) : 18
            self.init(
                horizontal: max(1, (size * 0.15).rounded()),
                vertical: max(1, (size * 0.05).rounded()),
                cornerRadius: max(1, (size * 0.22).rounded()),
            )
        }

        /// A non-finite or negative measurement would put NaN into the path and
        /// silently blank the whole page, so it is refused here instead.
        private static func sane(_ value: CGFloat) -> CGFloat {
            value.isFinite ? max(0, value) : 0
        }
    }

    // MARK: - Building the path

    /// The outline of a marked passage, given its rectangles grouped by line.
    ///
    /// Grouped by the caller because only the caller can know. TextKit splits a
    /// line wherever the attributes change, so one line arrives as several
    /// rectangles — and two *genuine* lines at `LineSpacing.tight`, or a line
    /// carrying a drop capital, produce exactly the same overlapping geometry.
    /// Inferring it here merged a narrated sentence with the line under it and
    /// painted the mark across words the sentence does not cover.
    ///
    /// The nested array *is* the identity, rather than a `LineRect(rect:line:)`
    /// pair: a struct with a defaulted line number can be filled in wrongly and
    /// still type-check, and the wrong answer it then gives is the very bug
    /// this signature exists to make unrepresentable.
    ///
    /// Rows that cannot be joined without overlapping — a short centred line,
    /// an RTL opening line, a mark that jumps a paragraph — become separate
    /// closed subpaths. Disjoint subpaths never cover the same pixel, so one
    /// fill still gives one alpha.
    public static func path(lines: [[CGRect]], style: Style) -> CGPath {
        let path = CGMutablePath()
        let rows = rows(fromLines: lines, horizontalPadding: style.horizontal)
        guard !rows.isEmpty else { return path }

        let runs = runs(rows, minimumOverlap: style.cornerRadius * 2)
        for (index, run) in runs.enumerated() {
            guard let top = run.first, let bottom = run.last else { continue }
            // Vertical padding belongs to the outside of the shape, never to a
            // seam. A run that sits flush against its neighbour is a seam even
            // though the two are drawn separately, so it goes unpadded there
            // too — otherwise the very overlap this file exists to remove
            // reappears in the corner where the two runs meet.
            let padsTop = index == 0 || (runs[index - 1].last.map { $0.maxY < top.minY - epsilon } ?? true)
            let padsBottom = index == runs.count - 1
                || (runs[index + 1].first.map { $0.minY > bottom.maxY + epsilon } ?? true)

            var shaped = straightened(run, tolerance: style.cornerRadius)
            if padsTop {
                shaped[0].origin.y -= style.vertical
                shaped[0].size.height += style.vertical
            }
            if padsBottom {
                shaped[shaped.count - 1].size.height += style.vertical
            }
            addRounded(outline(of: shaped), radius: style.cornerRadius, to: path)
        }
        return path
    }

    /// The outline of a marked passage from a flat list of rectangles, with the
    /// grouping guessed by `inferredLines(from:)`.
    ///
    /// Kept, rather than erased, because the guess is what a caller holding no
    /// line identity is left with, and a named wrong-but-documented path is
    /// easier to reason about than an inlined one. It is deprecated because the
    /// guess is provably unable to answer: a drop capital and three lines are
    /// the same geometry.
    @available(*, deprecated, message: """
    Group the rectangles by line and call path(lines:style:). The flat guess \
    merges a tall inline run with the line below it, and cannot tell a drop \
    capital from the three lines it spans.
    """)
    public static func path(lineRects: [CGRect], style: Style) -> CGPath {
        path(lines: inferredLines(from: lineRects), style: style)
    }

    // MARK: - Rows

    /// Tolerance for "the same coordinate". Page geometry arrives from TextKit
    /// in points with fractional parts, so exact equality is not on offer.
    static let epsilon: CGFloat = 1e-6

    /// One rectangle per row of text, padded at the ends, with every seam
    /// between consecutive rows made exactly shared.
    ///
    /// Two things happen that the grouped segments do not do for us. The lines
    /// arrive in layout order, which is not always page order once a mark runs
    /// over a bidirectional line, so the rows are sorted here — the walk that
    /// closes the seams below reads them top to bottom. And consecutive rows
    /// are usually flush but occasionally leave a hairline gap or a hairline
    /// overlap — Alice's justified page reports neighbours 1e-14 apart —
    /// either of which would show through a translucent fill; closing it by
    /// moving one row's bottom onto the next row's top makes the seam an edge
    /// the outline can simply walk along.
    ///
    /// A line that overlaps the one below it by more than a hairline is
    /// trimmed rather than merged: the caller has said these are two lines, and
    /// the answer to overlapping bounds at `LineSpacing.tight` is a shared
    /// seam, not one row swallowing the other.
    static func rows(fromLines lines: [[CGRect]], horizontalPadding: CGFloat) -> [CGRect] {
        // One row per line, so the pieces' own order inside a line cannot
        // matter; a line with nothing usable on it is dropped rather than left
        // as an empty row for the seam walk to trip over.
        var merged: [CGRect] = []
        for line in lines {
            let usable = line.map { $0.standardized }.filter { isUsable($0) }
            guard let first = usable.first else { continue }
            merged.append(usable.dropFirst().reduce(first) { $0.union($1) })
        }
        merged.sort { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }

        var padded = merged.map {
            CGRect(
                x: $0.minX - horizontalPadding,
                y: $0.minY,
                width: $0.width + horizontalPadding * 2,
                height: $0.height,
            )
        }

        for index in padded.indices.dropLast() {
            let gap = padded[index + 1].minY - padded[index].maxY
            let shorter = min(padded[index].height, padded[index + 1].height)
            // A gap wider than this is a real break in the mark — a paragraph
            // skipped, a heading between two lines — and stays a break.
            guard gap < 0 || gap <= shorter * 0.4 else { continue }
            guard padded[index + 1].minY > padded[index].minY else { continue }
            padded[index].size.height = padded[index + 1].minY - padded[index].minY
        }
        return padded
    }

    /// The grouping a caller holding no line identity is reduced to guessing.
    ///
    /// Pieces of one line share a baseline, so they overlap vertically by more
    /// than half the shorter one's height; two lines set flush do not overlap
    /// at all. Each incoming rectangle is measured against **the rectangle that
    /// opened its line**, never against the growing union: comparing against
    /// the union let a tall inline run raise the accumulator's `maxY`, and the
    /// next genuine line then cleared the threshold and was swallowed. Three
    /// rectangles A(y 0–10), B(y 0–20), C(y 12–22) came back as one row
    /// spanning y 0–22 — the mark painted over a line the sentence never
    /// reached. Measured against A, C overlaps by −2 and opens a line of its
    /// own.
    ///
    /// It is still a guess, and it is still wrong for a drop capital: a 60 pt
    /// initial beside a 20 pt line, over three 20 pt lines, is the same
    /// geometry as one tall line, and no rule over rectangles alone can tell
    /// them apart. That is what `path(lines:style:)` takes the grouping for.
    static func inferredLines(from rects: [CGRect]) -> [[CGRect]] {
        var usable: [CGRect] = rects.map { $0.standardized }.filter { isUsable($0) }
        usable.sort { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
        guard !usable.isEmpty else { return [] }

        var lines: [[CGRect]] = []
        var opener: CGRect?
        for rect in usable {
            if let opener {
                let overlap = min(opener.maxY, rect.maxY) - max(opener.minY, rect.minY)
                if overlap > min(opener.height, rect.height) / 2 {
                    lines[lines.count - 1].append(rect)
                    continue
                }
            }
            lines.append([rect])
            opener = rect
        }
        return lines
    }

    /// A rectangle with four finite corners and some area to it. A NaN would
    /// propagate through the whole outline; an empty rectangle would leave a
    /// zero-width spur on it.
    private static func isUsable(_ rect: CGRect) -> Bool {
        guard !rect.isNull, !rect.isInfinite else { return false }
        return rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    // MARK: - Runs

    /// Groups rows into the connected shapes they can honestly make.
    ///
    /// Two rows join only if they are flush *and* share enough width for the
    /// corners to be rounded without the two roundings meeting in mid-air. A
    /// mark that jumps from the right edge to the left — the first line of an
    /// RTL paragraph, a short centred line — would otherwise be joined by a
    /// sliver of shape crossing empty paper.
    ///
    /// - Parameter minimumOverlap: how much width consecutive rows must share;
    ///   the caller passes twice the corner radius.
    static func runs(_ rows: [CGRect], minimumOverlap: CGFloat) -> [[CGRect]] {
        guard let first = rows.first else { return [] }
        var runs: [[CGRect]] = [[first]]
        for row in rows.dropFirst() {
            guard let previous = runs[runs.count - 1].last else { continue }
            let flush = abs(previous.maxY - row.minY) <= epsilon
            let overlap = min(previous.maxX, row.maxX) - max(previous.minX, row.minX)
            if flush, overlap > 0, overlap >= minimumOverlap {
                runs[runs.count - 1].append(row)
            } else {
                runs.append([row])
            }
        }
        return runs
    }

    // MARK: - Straightening

    /// Flattens steps between rows that are too small to round.
    ///
    /// A justified paragraph's right margin, or hanging punctuation, leaves
    /// steps of a point or two. Rounding one of those produces a visible nick
    /// rather than a corner. Rows are always *extended* to meet, never
    /// shrunk — a shrink would leave a glyph sticking out of its own highlight.
    static func straightened(_ rows: [CGRect], tolerance: CGFloat) -> [CGRect] {
        guard rows.count > 1, tolerance > 0 else { return rows }
        var result = rows
        // Extending is monotonic — left edges only move left, right edges only
        // move right — so this settles; the counter is a belt-and-braces bound.
        var passes = 0
        var changed = true
        while changed, passes <= result.count {
            changed = false
            passes += 1
            for index in result.indices.dropLast() {
                let left = min(result[index].minX, result[index + 1].minX)
                if abs(result[index].minX - result[index + 1].minX) > epsilon,
                   abs(result[index].minX - result[index + 1].minX) < tolerance {
                    result[index] = extended(result[index], minX: left)
                    result[index + 1] = extended(result[index + 1], minX: left)
                    changed = true
                }
                let right = max(result[index].maxX, result[index + 1].maxX)
                if abs(result[index].maxX - result[index + 1].maxX) > epsilon,
                   abs(result[index].maxX - result[index + 1].maxX) < tolerance {
                    result[index] = extended(result[index], maxX: right)
                    result[index + 1] = extended(result[index + 1], maxX: right)
                    changed = true
                }
            }
        }
        return result
    }

    private static func extended(_ rect: CGRect, minX: CGFloat) -> CGRect {
        CGRect(x: minX, y: rect.minY, width: rect.maxX - minX, height: rect.height)
    }

    private static func extended(_ rect: CGRect, maxX: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: rect.minY, width: maxX - rect.minX, height: rect.height)
    }

    // MARK: - Outline

    /// A clockwise rectilinear polygon around one run of flush rows.
    ///
    /// Clockwise in the page's own coordinates, which run downwards: along the
    /// top of the first row, down the right-hand edges stepping in or out at
    /// each seam, along the bottom of the last row, then back up the left-hand
    /// edges. Nothing here knows about writing direction — an RTL block is the
    /// same walk with the steps the other way about, so it mirrors itself.
    ///
    /// Collinear vertices are dropped, so a run of equal-width rows comes back
    /// as a plain rectangle rather than a rectangle with invisible corners on
    /// its sides, each of which would otherwise be rounded into a dent.
    static func outline(of rows: [CGRect]) -> [CGPoint] {
        guard let first = rows.first, let last = rows.last else { return [] }
        var points: [CGPoint] = [
            CGPoint(x: first.minX, y: first.minY),
            CGPoint(x: first.maxX, y: first.minY),
        ]
        for index in rows.indices.dropFirst() {
            let seam = rows[index].minY
            points.append(CGPoint(x: rows[index - 1].maxX, y: seam))
            points.append(CGPoint(x: rows[index].maxX, y: seam))
        }
        points.append(CGPoint(x: last.maxX, y: last.maxY))
        points.append(CGPoint(x: last.minX, y: last.maxY))
        for index in rows.indices.dropFirst().reversed() {
            let seam = rows[index].minY
            points.append(CGPoint(x: rows[index].minX, y: seam))
            points.append(CGPoint(x: rows[index - 1].minX, y: seam))
        }
        return withoutCollinearPoints(points)
    }

    /// Drops vertices that lie on the line between their neighbours, and any
    /// vertex that repeats the next one.
    static func withoutCollinearPoints(_ points: [CGPoint]) -> [CGPoint] {
        var result = points
        var index = 0
        while result.count > 3, index < result.count {
            let previous = result[(index - 1 + result.count) % result.count]
            let current = result[index]
            let next = result[(index + 1) % result.count]
            let cross = (current.x - previous.x) * (next.y - current.y)
                - (current.y - previous.y) * (next.x - current.x)
            let repeats = abs(current.x - next.x) <= epsilon && abs(current.y - next.y) <= epsilon
            if repeats || abs(cross) <= epsilon {
                result.remove(at: index)
                // Removing a vertex can make the one before it collinear.
                index = max(0, index - 1)
            } else {
                index += 1
            }
        }
        return result
    }

    // MARK: - Rounding

    /// Adds one closed, corner-rounded subpath through the given polygon.
    ///
    /// Built from `addArc(tangent1End:tangent2End:radius:)`, which rounds
    /// convex corners and fillets concave ones — the notch where a long line
    /// meets a short one wants a fillet, not a spike. The radius at each corner
    /// is clamped to half the shorter of its two edges, so no two roundings can
    /// reach past one another however narrow the step; below half a point there
    /// is nothing to see, and a straight line is drawn instead.
    static func addRounded(_ points: [CGPoint], radius: CGFloat, to path: CGMutablePath) {
        guard points.count >= 3 else { return }
        let count = points.count
        // Starting mid-edge guarantees the first arc has half an edge of run-up,
        // exactly as every later arc does.
        path.move(to: midpoint(points[count - 1], points[0]))
        for index in 0 ..< count {
            let corner = points[index]
            let previous = points[(index - 1 + count) % count]
            let next = points[(index + 1) % count]
            let limit = min(distance(previous, corner), distance(corner, next)) / 2
            let clamped = min(radius, limit)
            if clamped < 0.5 {
                path.addLine(to: corner)
            } else {
                path.addArc(tangent1End: corner, tangent2End: next, radius: clamped)
            }
        }
        path.closeSubpath()
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a - b).length
    }
}

private extension CGPoint {
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    var length: CGFloat { (x * x + y * y).squareRoot() }
}
