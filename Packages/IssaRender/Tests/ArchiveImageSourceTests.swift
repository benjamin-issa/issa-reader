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
    /// A PNG of an exact pixel size, built rather than shipped.
    static func png(width: Int, height: Int) throws -> Data {
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
        CGImageDestinationAddImage(destination, image, nil)
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

    /// The bitmap's own dimensions, which is what memory is spent on.
    static func pixels(of image: PlatformImage) throws -> CGSize {
        #if canImport(UIKit)
        let cgImage = try #require(image.cgImage)
        #else
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        #endif
        return CGSize(width: cgImage.width, height: cgImage.height)
    }

    @Test("a 15000-pixel plate decodes to at most 4096 pixels")
    func hugePlateIsBounded() throws {
        // A strip rather than a square: the bound is on the longer side, and
        // building a 15000-pixel square would itself cost the memory this
        // exists to save.
        let source = ArchiveImageSource(
            archive: try Self.archive([("OEBPS/images/plate.png", Self.png(width: 15000, height: 30))]))
        let image = try #require(source.image(for: "OEBPS/images/plate.png"))
        let pixels = try Self.pixels(of: image)
        #expect(max(pixels.width, pixels.height) <= 4096, "decoded at \(pixels)")
        #expect(pixels.width > 4000, "bounded, not shrunk further")
    }

    @Test("an ordinary plate keeps the size it always had")
    func ordinaryPlateUnchanged() throws {
        let data = try Self.png(width: 800, height: 3000)
        let source = ArchiveImageSource(
            archive: try Self.archive([("OEBPS/images/plate.png", data)]))
        let image = try #require(source.image(for: "OEBPS/images/plate.png"))
        let before = try #require(PlatformImage(data: data))
        // `size` is what the parser scales a plate by, so this is what keeps
        // every illustrated page laid out as it was.
        #expect(image.size == before.size)
        #expect(try Self.pixels(of: image) == CGSize(width: 800, height: 3000))
    }

    @Test("a missing or undecodable entry is no image")
    func missingIsNil() throws {
        let source = ArchiveImageSource(
            archive: try Self.archive([("OEBPS/images/broken.png", Data("not a png".utf8))]))
        #expect(source.image(for: "OEBPS/images/broken.png") == nil)
        #expect(source.image(for: "OEBPS/images/absent.png") == nil)
    }
}
