import CoreGraphics
import ImageIO
import Foundation
import IssaEPUB
import Testing

@testable import IssaRender

/// Rendering tests that actually rasterise. A pagination test can pass while
/// nothing is drawn on screen; only counting pixels distinguishes "this page is
/// genuinely empty" from "the draw path is broken".
@MainActor
struct DrawingTests {
    static func layout(for fixture: String, spineIndex: Int = 0) throws -> (ChapterLayout, String) {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(fixture)", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        let item = package.spine[spineIndex]
        let parsed = try HTMLContentParser(style: ReaderStyle())
            .parse(xhtml: try package.archive.read(item.href), baseHref: item.href)
        let layout = ChapterLayout(text: parsed.text, fragmentRanges: parsed.fragmentRanges)
        layout.layout(pageSize: CGSize(width: 340, height: 560))
        return (layout, parsed.text.string)
    }

    /// Draws a page and returns the fraction of pixels that are not the
    /// background colour.
    static func inkCoverage(_ layout: ChapterLayout, page: RenderedPage) -> Double {
        let width = 340
        let height = 560
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return 0 }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // TextKit draws in a top-left origin, y-down space; CGContext is y-up.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        layout.draw(page: page, in: context)

        var inked = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index] < 200 {
            inked += 1
        }
        return Double(inked) / Double(width * height)
    }

    @Test("a chapter with prose actually rasterises glyphs")
    func drawsGlyphs() throws {
        let (layout, text) = try Self.layout(for: "readalong")
        #expect(text.count > 100, "fixture chapter should have prose")
        let page = try #require(layout.pages.first)
        let coverage = Self.inkCoverage(layout, page: page)
        #expect(coverage > 0.005, "page rendered no visible glyphs (coverage \(coverage))")
    }

    @Test("a real book's prose chapter rasterises too")
    func drawsRealBook() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/alice", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)

        var found: (ChapterLayout, Int)?
        for (index, item) in package.spine.enumerated() {
            let parsed = try HTMLContentParser(style: ReaderStyle())
                .parse(xhtml: try package.archive.read(item.href), baseHref: item.href)
            guard parsed.text.length > 2000 else { continue }
            let layout = ChapterLayout(text: parsed.text, fragmentRanges: parsed.fragmentRanges)
            layout.layout(pageSize: CGSize(width: 340, height: 560))
            found = (layout, index)
            break
        }
        let (layout, _) = try #require(found, "no prose chapter found")
        let page = try #require(layout.pages.first)
        #expect(Self.inkCoverage(layout, page: page) > 0.01)
    }

    @Test("the first spine item of a Gutenberg book is often a coverless title page")
    func reportsFirstSpineContent() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/alice", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        let first = package.spine[0]
        let parsed = try HTMLContentParser(style: ReaderStyle())
            .parse(xhtml: try package.archive.read(first.href), baseHref: first.href)
        // Documented, not asserted as good or bad: this is why the reader must
        // open on the first chapter with content rather than spine item zero.
        print("first spine item \(first.href) has \(parsed.text.length) characters, \(parsed.complexity.imageCount) images")
        #expect(parsed.text.length >= 0)
    }
}

/// Illustrations must occupy real space and actually paint.
///
/// Every Gutenberg book opens on a cover wrapper that is nothing but an image,
/// so "renders no image" and "renders an empty chapter" look identical from the
/// outside — which is exactly how the blank first page shipped once already.
@MainActor
struct ImageRenderingTests {
    static func aliceCoverChapter() throws -> (HTMLContentParser.Result, EPUBArchive) {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/alice", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        let archive = package.archive
        let item = package.spine[0]

        let parsed = try HTMLContentParser(
            style: ReaderStyle(),
            maxImageWidth: 300,
            loadImage: { href in
                guard let data = try? archive.read(href) else { return nil }
                return PlatformImage(data: data)
            },
        ).parse(xhtml: try archive.read(item.href), baseHref: item.href)
        return (parsed, archive)
    }

    @Test("a cover-only chapter is no longer empty")
    func coverChapterHasContent() throws {
        let (parsed, _) = try Self.aliceCoverChapter()
        #expect(parsed.complexity.imageCount > 0)
        // The object-replacement character stands in for the illustration.
        #expect(parsed.text.string.contains("\u{FFFC}"))
        var hrefs: [String] = []
        parsed.text.enumerateAttribute(
            .issaImageHref, in: NSRange(location: 0, length: parsed.text.length),
        ) { value, _, _ in
            if let href = value as? String { hrefs.append(href) }
        }
        #expect(!hrefs.isEmpty, "no image href recorded")
    }

    @Test("the illustration actually rasterises")
    func coverChapterRasterises() throws {
        let (parsed, _) = try Self.aliceCoverChapter()
        let layout = ChapterLayout(text: parsed.text, fragmentRanges: parsed.fragmentRanges)
        layout.layout(pageSize: CGSize(width: 340, height: 560))
        let page = try #require(layout.pages.first)

        let coverage = DrawingTests.inkCoverage(layout, page: page)
        #expect(coverage > 0.02, "cover illustration did not paint (coverage \(coverage))")
    }

    @Test("an image with no resolver is skipped rather than reserving empty space")
    func unresolvableImageSkipped() throws {
        let html = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <p>Before.</p><img src="missing.png"/><p>After.</p>
        </body></html>
        """.utf8)
        let result = try HTMLContentParser(style: ReaderStyle()).parse(xhtml: html, baseHref: "c.xhtml")
        #expect(result.complexity.imageCount == 1)
        // Counted, but nothing reserved: a box with no picture in it is worse
        // than no box.
        #expect(!result.text.string.contains("\u{FFFC}"))
        #expect(result.text.string.contains("Before."))
        #expect(result.text.string.contains("After."))
    }
}


/// The clip that keeps a straddling paragraph's lines on the right page.
///
/// `computePages` can now split a paragraph mid-line, so a page's last
/// fragment may continue onto the next page too — `draw(page:)` used to
/// select fragments by whether they *start* on this page, then draw each one
/// whole. Once a fragment can straddle the boundary, drawing it whole draws
/// lines that belong to the *next* page as well: visible past the bottom edge
/// of a fixed-size, clipped canvas, and then drawn *again* when that next
/// page's own turn comes. A pagination-only test cannot see this — it never
/// rasterises — which is exactly why `PageBoundaryTests`' pixel-blind checks
/// passed even with the clip removed.
@MainActor
struct StraddlingParagraphDrawTests {
    static let pageHeight: CGFloat = 400
    static let pageWidth = 320

    /// Rasterises a page at its own true size, rather than the fixed 340×560
    /// `inkCoverage` uses elsewhere — the straddling case only shows up when
    /// the bitmap matches the page the fixture was actually paginated at.
    static func render(_ layout: ChapterLayout, page: RenderedPage) -> [UInt8] {
        let width = pageWidth
        let height = Int(pageHeight)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return pixels }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        layout.draw(page: page, in: context)
        return pixels
    }

    /// Whether row `y` (top-down, matching TextKit's own coordinate sense) has
    /// any non-background pixel.
    static func rowHasInk(_ pixels: [UInt8], y: Int) -> Bool {
        let rowStart = y * pageWidth * 4
        for x in stride(from: rowStart, to: rowStart + pageWidth * 4, by: 4) where pixels[x] < 200 {
            return true
        }
        return false
    }

    @Test("nothing is drawn below where a page's own content actually ends")
    func nothingDrawnPastContentBottom() throws {
        let layout = try PageBoundaryTests.oneGiantParagraphLayout(pageHeight: Self.pageHeight)
        // A page in the middle of the giant paragraph: its predecessor and its
        // successor both belong to the very same fragment, so this is squarely
        // the straddling case, not an edge page that might legitimately be
        // fully used or fully empty. Deliberately not page 0: its `yOffset` is
        // 0, which made a clip anchored at local `y: 0` instead of `y:
        // page.yOffset` look correct by coincidence — that bug shipped a
        // reader a blank page on anything but a chapter's opening page, and
        // this suite still passed, because every assertion below only ever
        // checked for the ABSENCE of ink. A page with no ink anywhere trivially
        // has none below content-bottom either.
        let page = try #require(layout.pages.dropFirst().dropLast().first)
        let localContentBottom = Int((page.contentBottom - page.yOffset).rounded(.up))
        #expect(localContentBottom < Int(Self.pageHeight), "the fixture should leave a real margin to check")

        let pixels = Self.render(layout, page: page)
        #expect((0 ..< localContentBottom).contains { Self.rowHasInk(pixels, y: $0) },
                "no row above content-bottom \(localContentBottom) has any ink — the page drew nothing at all")
        for y in localContentBottom ..< Int(Self.pageHeight) {
            #expect(!Self.rowHasInk(pixels, y: y),
                    "row \(y) has ink below content-bottom \(localContentBottom) — the next page's lines leaked through")
        }
    }

    @Test("consecutive pages of a straddling paragraph do not repeat the same line")
    func consecutivePagesDoNotRepeatALine() throws {
        let layout = try PageBoundaryTests.oneGiantParagraphLayout(pageHeight: Self.pageHeight)
        let page = try #require(layout.pages.dropFirst().dropLast().first)
        let pageIndex: Int = page.index
        #expect(layout.pages.indices.contains(pageIndex + 1), "the fixture should have a following page")

        // The first row of the next page, translated into this page's own
        // coordinate space, is this page's own content-bottom — if that same
        // row shows ink here, this page drew a line the next page will draw
        // too.
        let seam = Int((page.contentBottom - page.yOffset).rounded())
        guard seam < Int(Self.pageHeight) else { return }
        let pixels = Self.render(layout, page: page)
        #expect(!Self.rowHasInk(pixels, y: seam),
                "page \(pageIndex) painted its own seam row, which the next page will paint too")
    }
}
