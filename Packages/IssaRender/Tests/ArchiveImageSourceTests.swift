import CoreGraphics
import Foundation
import ImageIO
import IssaEPUB
import Testing
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@testable import IssaRender

/// In-book plates are decoded through an ImageIO thumbnail with a pixel bound,
/// as covers already were. A flat-colour 15000-pixel PNG is a few hundred
/// kilobytes in the book and most of a gigabyte decoded, and
/// `PlatformImage(data:)` kept that bitmap for as long as the chapter was open.
@Suite("Chapter artwork is decoded at a bounded size")
struct ArchiveImageSourceTests {
    /// A PNG of an exact pixel size, built rather than shipped, tagged with a
    /// resolution when one is given.
    static func png(width: Int, height: Int, dpi: Double? = nil) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil))
        let properties = dpi.map {
            [kCGImagePropertyDPIWidth: $0, kCGImagePropertyDPIHeight: $0] as CFDictionary
        }
        CGImageDestinationAddImage(destination, image, properties)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    /// The smallest ZIP `EPUBArchive` reads: stored entries and a central
    /// directory. The archive's own tests cover the hostile shapes.
    static func archive(_ entries: [(String, Data)]) throws -> EPUBArchive {
        func le16(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]) }
        func le32(_ value: Int) -> Data { Data((0 ..< 4).map { UInt8((value >> ($0 * 8)) & 0xFF) }) }
        var out = Data()
        var central = Data()
        for (path, payload) in entries {
            let name = Data(path.utf8)
            let offset = out.count
            out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            out.append(le16(20) + le16(0) + le16(0) + le16(0) + le16(0))
            out.append(le32(0) + le32(payload.count) + le32(payload.count))
            out.append(le16(name.count) + le16(0))
            out.append(name)
            out.append(payload)

            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            central.append(le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0))
            central.append(le32(0) + le32(payload.count) + le32(payload.count))
            central.append(le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0))
            central.append(le32(0) + le32(offset))
            central.append(name)
        }
        let directoryOffset = out.count
        out.append(central)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        out.append(le16(0) + le16(0) + le16(entries.count) + le16(entries.count))
        out.append(le32(central.count) + le32(directoryOffset) + le16(0))
        return try EPUBArchive(data: out)
    }

    /// The bitmap a plate decoded to when drawn — what memory is spent on.
    static func pixels(of plate: ArchivePlate) throws -> CGSize {
        #expect(plate.artworkForDrawing() != nil)
        return try #require(plate.decodedPixels)
    }

    @Test("a 15000-pixel plate decodes to at most 4096 pixels")
    func hugePlateIsBounded() throws {
        // A strip rather than a square: the bound is on the longer side, and
        // building a 15000-pixel square would itself cost the memory this
        // exists to save.
        let source = ArchiveImageSource(
            archive: try Self.archive([("OEBPS/images/plate.png", Self.png(width: 15000, height: 30))]))
        let plate = try #require(source.image(for: "OEBPS/images/plate.png"))
        let pixels = try Self.pixels(of: plate)
        #expect(max(pixels.width, pixels.height) <= 4096, "decoded at \(pixels)")
        #expect(pixels.width > 4000, "bounded, not shrunk further")
    }

    @Test("an ordinary plate keeps the size it always had")
    func ordinaryPlateUnchanged() throws {
        let data = try Self.png(width: 800, height: 3000)
        let source = ArchiveImageSource(
            archive: try Self.archive([("OEBPS/images/plate.png", data)]))
        let plate = try #require(source.image(for: "OEBPS/images/plate.png"))
        let before = try #require(PlatformImage(data: data))
        // `layoutSize` is what the parser scales a plate by, so this is what
        // keeps every illustrated page laid out as it was.
        #expect(plate.layoutSize == before.size)
        #expect(try Self.pixels(of: plate) == CGSize(width: 800, height: 3000))
    }

    @Test("a missing or undecodable entry is no image")
    func missingIsNil() throws {
        let source = ArchiveImageSource(
            archive: try Self.archive([("OEBPS/images/broken.png", Data("not a png".utf8))]))
        #expect(source.image(for: "OEBPS/images/broken.png") == nil)
        #expect(source.image(for: "OEBPS/images/absent.png") == nil)
    }
}

/// R-14 and R-59: what the bounded decode cost, and what it changed.
///
/// The parser needs a plate's size to lay a chapter out; only drawing needs
/// its pixels. Decoding every plate as the chapter was parsed made the in-book
/// search and the Ask index decode every illustration in the book, and each
/// chapter open, turn and typeface step decode all of its plates on the main
/// actor and keep them resident — where 1.3.0's `PlatformImage(data:)` read
/// only the header.
@MainActor
@Suite("Chapter artwork is decoded only when it is drawn")
struct PlateDecodingTests {
    static let chapter = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <p>Before.</p><img src="images/plate.png" alt="A plate"/><p>After.</p>
        </body></html>
        """.utf8)

    static func parse(
        _ source: ArchiveImageSource, maxImageWidth: CGFloat = 320,
    ) throws -> HTMLContentParser.Result {
        try HTMLContentParser(
            style: ReaderStyle(), maxImageWidth: maxImageWidth,
            loadImage: { source.image(for: $0) },
        ).parse(xhtml: chapter, baseHref: "OEBPS/chapter.xhtml")
    }

    /// The size the parser gave the plate's place in the flow.
    static func displaySize(in result: HTMLContentParser.Result) throws -> CGSize {
        var sizes: [CGSize] = []
        result.text.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: result.text.length),
        ) { value, _, _ in
            if let attachment = value as? ImageAttachment { sizes.append(attachment.displaySize) }
        }
        #expect(sizes.count == 1)
        return try #require(sizes.first)
    }

    @Test("parsing a chapter learns its plates' sizes without decoding one")
    func parsingDecodesNothing() throws {
        let source = ArchiveImageSource(archive: try ArchiveImageSourceTests.archive([
            ("OEBPS/images/plate.png", ArchiveImageSourceTests.png(width: 200, height: 300)),
        ]))
        let result = try Self.parse(source)

        #expect(try Self.displaySize(in: result) == CGSize(width: 200, height: 300))
        // What search and the Ask index do with every chapter of the book.
        #expect(source.decodeCount == 0, "a parse decoded \(source.decodeCount) plates")
    }

    @Test("a plate is decoded once its page is drawn, and once only")
    func drawingDecodesOnce() throws {
        let source = ArchiveImageSource(archive: try ArchiveImageSourceTests.archive([
            ("OEBPS/images/plate.png", ArchiveImageSourceTests.png(width: 200, height: 300)),
        ]))
        let result = try Self.parse(source)
        let layout = ChapterLayout(text: result.text, fragmentRanges: result.fragmentRanges)
        layout.layout(pageSize: CGSize(width: 340, height: 560))
        let page = try #require(layout.pages.first)
        // Laying a chapter out is not drawing it: the reader lays out every
        // page of a chapter at each open and each typeface step.
        #expect(source.decodeCount == 0, "laying the chapter out decoded its plate")

        // The plate is a 200x300 block of one dark colour on a white page.
        let coverage = DrawingTests.inkCoverage(layout, page: page)
        #expect(coverage > 0.2, "the plate did not paint (coverage \(coverage))")
        #expect(source.decodeCount == 1)

        // Every narrated sentence and page turn redraws.
        _ = DrawingTests.inkCoverage(layout, page: page)
        #expect(source.decodeCount == 1, "a redraw decoded the plate again")
    }

    /// R-59. On the Mac a plate's size is in points at its own resolution, as
    /// `NSImage(data:)` has always reported it. Taken from the bounded
    /// thumbnail instead, a 6000-pixel plate tagged 300 DPI shrank from
    /// 1440 points to 983, and since the parser never scales up it was drawn
    /// that much smaller than in 1.3.0. On UIKit the size is pixels either way.
    @Test("a high-resolution plate past the bound keeps the size it had in 1.3.0", arguments: [
        (6000, 40, 300.0), (5000, 30, 144.0), (800, 600, 300.0), (800, 600, 72.0),
    ])
    func highResolutionPlateKeepsItsSize(width: Int, height: Int, dpi: Double) throws {
        let data = try ArchiveImageSourceTests.png(width: width, height: height, dpi: dpi)
        let source = ArchiveImageSource(archive: try ArchiveImageSourceTests.archive([
            ("OEBPS/images/plate.png", data),
        ]))
        let before = try #require(PlatformImage(data: data)).size
        // A column wide enough that nothing is scaled to fit it: the size laid
        // out is the size the source reported.
        let laidOut = try Self.displaySize(in: try Self.parse(source, maxImageWidth: 100_000))
        #expect(abs(laidOut.width - before.width) < 0.5 && abs(laidOut.height - before.height) < 0.5,
                "laid out at \(laidOut), 1.3.0 had \(before)")
    }
}
