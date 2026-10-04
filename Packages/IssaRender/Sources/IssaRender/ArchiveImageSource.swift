import Foundation
import ImageIO
import IssaEPUB

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A chapter's artwork, keyed by archive path: each plate's size at once, its
/// pixels only when it is drawn.
///
/// A chapter asks once per plate, and the cache lives as long as the chapter
/// does, so reflowing on a font change costs no re-reading.
///
/// File scope rather than nested inside `ReaderModel`, which is `@MainActor`:
/// a type declared inside a globally-isolated one inherits that isolation, and
/// the search path parses chapters off the main actor.
///
/// It lives in IssaRender rather than in the app because the Ask index parses
/// chapters with it too, and its offsets are only right because it does: every
/// plate contributes an object-replacement character and a line break to the
/// rendered string, so a parse without the images computes offsets that drift
/// ahead of the laid-out chapter's — far enough on an illustrated book to place
/// a retrieved passage in the wrong place, and to let the spoiler boundary cut
/// in the wrong place with it.
///
/// Neither the search nor the Ask index ever draws, so neither ever decodes:
/// a parse reads each plate's header and nothing more, as 1.3.0's
/// `PlatformImage(data:)` did. See `ArchivePlate`.
public final class ArchiveImageSource {
    /// The longest side, in pixels, a plate is decoded at.
    ///
    /// Far more than any column draws — a full-width plate on the widest Mac
    /// window at 2x is under 4000 — and far less than the flat-colour
    /// 15000-pixel PNG that compresses to a few hundred kilobytes and decodes
    /// to most of a gigabyte, which on an iPhone or an Apple TV is the end of
    /// the app.
    public static let defaultMaxPixelSize = 4096

    private let archive: EPUBArchive
    private let maxPixelSize: Int
    private var plates: [String: ArchivePlate?] = [:]
    private let decodes = ArchivePlate.DecodeCounter()

    public init(archive: EPUBArchive, maxPixelSize: Int = ArchiveImageSource.defaultMaxPixelSize) {
        self.archive = archive
        self.maxPixelSize = maxPixelSize
    }

    /// The plate at an archive path, sized but not decoded; nil when the entry
    /// is missing or is no image at all.
    public func image(for href: String) -> ArchivePlate? {
        if let cached = plates[href] { return cached }
        var result: ArchivePlate?
        if let data = try? archive.read(href) {
            result = ArchivePlate(data: data, maxPixelSize: maxPixelSize, decodes: decodes)
        }
        plates[href] = result
        return result
    }

    /// How many bitmaps this source's plates have decoded. Internal, for the
    /// tests that hold the parse to reading headers only.
    var decodeCount: Int { decodes.count }
}

/// One illustration: its size from the image's header, its bitmap decoded the
/// first time the page it is on is drawn.
///
/// Decoded straight to a bounded bitmap through an ImageIO thumbnail — the
/// way `CoverImage` decodes covers — never larger than the original, so an
/// ordinary plate decodes at exactly its own size, and a 15000-pixel one at
/// `ArchiveImageSource.defaultMaxPixelSize`. Kept once decoded, because every
/// narrated sentence and page turn redraws the page.
///
/// Holds the image's own bytes, as `PlatformImage(data:)` did, rather than
/// the archive: a plate is drawn on the main actor while a search may be
/// reading the same book's archive elsewhere.
///
/// Not `Sendable`: it caches what it decodes, and it is drawn on one actor.
public final class ArchivePlate: ChapterArtwork {
    /// Counts decodes for one `ArchiveImageSource`. Only ever touched on the
    /// actor that draws the chapter.
    final class DecodeCounter {
        var count = 0
    }

    /// The size `PlatformImage(data:)` would report, so the parser lays a
    /// plate out exactly as it always has: pixels on UIKit, and on AppKit
    /// pixels at the image's own resolution, which is what `NSImage` has
    /// always meant by size. From the original's header, not the bounded
    /// bitmap: a 6000-pixel plate tagged 300 DPI is 1440 points on the Mac,
    /// not the 983 its 4096-pixel thumbnail would make it.
    public let layoutSize: CGSize

    private let data: Data
    private let maxPixelSize: Int
    private let decodes: DecodeCounter
    /// Something ImageIO will not read — on the Mac an SVG, which `NSImage`
    /// draws as vectors. Not the hazard the bound is for, and the plate it
    /// was before.
    private let undecodable: PlatformImage?
    private var decoded: PlatformImage??

    init?(data: Data, maxPixelSize: Int, decodes: DecodeCounter) {
        self.data = data
        self.maxPixelSize = max(maxPixelSize, 1)
        self.decodes = decodes
        if let size = Self.headerSize(of: data) {
            layoutSize = size
            undecodable = nil
        } else {
            guard let image = PlatformImage(data: data), image.size.width > 0, image.size.height > 0
            else { return nil }
            layoutSize = image.size
            undecodable = image
        }
    }

    /// The decoded bitmap's own dimensions, which is what memory is spent on;
    /// nil until it is drawn. Internal, for tests.
    private(set) var decodedPixels: CGSize?

    public func artworkForDrawing() -> PlatformImage? {
        if let undecodable { return undecodable }
        if let decoded { return decoded }
        let image = decode()
        decoded = .some(image)
        return image
    }

    /// The size from the header alone: `CGImageSourceCopyPropertiesAtIndex`
    /// reads metadata and decodes nothing.
    private static func headerSize(of data: Data) -> CGSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }
        #if canImport(UIKit)
        var size = CGSize(width: width, height: height)
        #else
        func pointsPerPixel(_ key: CFString) -> Double {
            guard let dpi = (properties[key] as? NSNumber)?.doubleValue, dpi.isFinite, dpi > 0
            else { return 1 }
            return 72 / dpi
        }
        var size = CGSize(
            width: width * pointsPerPixel(kCGImagePropertyDPIWidth),
            height: height * pointsPerPixel(kCGImagePropertyDPIHeight))
        #endif
        // Turned upright, as the decode below turns the pixels
        // (`kCGImageSourceCreateThumbnailWithTransform`) and as
        // `UIImage(data:)` reports it: orientations 5 to 8 are quarter turns.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5 ... 8).contains(orientation) {
            size = CGSize(width: size.height, height: size.width)
        }
        return size
    }

    private func decode() -> PlatformImage? {
        decodes.count += 1
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        else { return nil }
        decodedPixels = CGSize(width: cgImage.width, height: cgImage.height)
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        // The bounded bitmap, at the size the plate was laid out by.
        return NSImage(cgImage: cgImage, size: layoutSize)
        #endif
    }
}
