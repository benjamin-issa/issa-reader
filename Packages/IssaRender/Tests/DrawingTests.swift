import CoreGraphics
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
