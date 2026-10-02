import Foundation
import ImageIO
import IssaEPUB

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Decodes and caches a chapter's artwork, keyed by archive path.
///
/// A chapter asks once per plate, and the cache lives as long as the chapter
/// does, so reflowing on a font change costs no re-decoding.
///
/// File scope rather than nested inside `ReaderModel`, which is `@MainActor`:
/// a type declared inside a globally-isolated one inherits that isolation, and
/// the search path now decodes plates off the main actor.
///
/// It lives in IssaRender rather than in the app because the Ask index parses
/// chapters with it too, and its offsets are only right because it does: every
/// plate contributes an object-replacement character and a line break to the
/// rendered string, so a parse without the images computes offsets that drift
/// ahead of the laid-out chapter's — far enough on an illustrated book to place
/// a retrieved passage in the wrong place, and to let the spoiler boundary cut
/// in the wrong place with it.
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
    private var decoded: [String: PlatformImage?] = [:]

    public init(archive: EPUBArchive, maxPixelSize: Int = ArchiveImageSource.defaultMaxPixelSize) {
        self.archive = archive
        self.maxPixelSize = maxPixelSize
    }

    public func image(for href: String) -> PlatformImage? {
        if let cached = decoded[href] { return cached }
        var result: PlatformImage?
        if let data = try? archive.read(href) {
            result = Self.decode(data, maxPixelSize: maxPixelSize)
        }
        decoded[href] = result
        return result
    }

    /// Decodes straight to a bounded bitmap, through an ImageIO thumbnail —
    /// the way `CoverImage` already decodes covers.
    ///
    /// `PlatformImage(data:)` kept the full-resolution bitmap for as long as
    /// the chapter was open, and drew from it. A thumbnail is never larger
    /// than the original, so an ordinary plate decodes at exactly its own
    /// size.
    ///
    /// The size it reports is the size `PlatformImage(data:)` would have, so
    /// the parser scales a plate exactly as it did: pixels on UIKit, and on
    /// AppKit pixels at the image's own resolution, which is what `NSImage`
    /// has always meant by size.
    static func decode(_ data: Data, maxPixelSize: Int) -> PlatformImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        else {
            // Something ImageIO will not make a bitmap of — on the Mac an SVG,
            // which `NSImage` draws as vectors. Not the hazard this bounds,
            // and the plate it was before.
            return PlatformImage(data: data)
        }
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        func pointsPerPixel(_ key: CFString) -> CGFloat {
            guard let dpi = (properties?[key] as? NSNumber)?.doubleValue, dpi.isFinite, dpi > 0
            else { return 1 }
            return 72 / CGFloat(dpi)
        }
        let size = CGSize(
            width: CGFloat(cgImage.width) * pointsPerPixel(kCGImagePropertyDPIWidth),
            height: CGFloat(cgImage.height) * pointsPerPixel(kCGImagePropertyDPIHeight))
        return NSImage(cgImage: cgImage, size: size)
        #endif
    }
}
