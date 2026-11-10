import IssaUI
import SwiftUI
import WidgetKit
#if canImport(UIKit)
import ImageIO
import UIKit
#endif

/// Decoding covers for the widget.
///
/// An extension is held to roughly 30 MB, and a `UIImage(data:)` of a 320 px
/// JPEG is decoded at full size — 600 KB for one portrait cover, and the large
/// family draws five. Everything here goes through ImageIO's thumbnail path
/// instead, which decodes straight to the size asked for and never holds the
/// full bitmap.
enum WidgetImages {
    #if canImport(UIKit)
    /// The cover decoded no larger than `longEdge` pixels on its longer side,
    /// or at its own size if that is smaller (a thumbnail never upscales here:
    /// a 320 px cover stretched to 510 px would be a blur that costs more).
    static func image(from data: Data, longEdge: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return nil }
        let own = ownLongEdge(of: source) ?? longEdge
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(longEdge, own).rounded(.up)),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    private static func ownLongEdge(of source: CGImageSource) -> CGFloat? {
        size(of: source).map { max($0.width, $0.height) }
    }

    private static func size(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The cover decoded for a frame of `pixels`: just enough that the scale
    /// that covers (`fill`) or contains (`fit`) the frame is met, never more
    /// than the file has. Reads the header for the size, not the bitmap.
    static func image(from data: Data, framePixels pixels: CGSize, fill: Bool) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary), let own = size(of: source), own.width > 0, own.height > 0
        else { return image(from: data, longEdge: max(pixels.width, pixels.height)) }
        let widthScale = pixels.width / own.width, heightScale = pixels.height / own.height
        let scale = min(1, fill ? max(widthScale, heightScale) : min(widthScale, heightScale))
        return image(from: data, longEdge: max(own.width, own.height) * scale)
    }

    /// What decoding `image` costs in memory, for the budget the widget is
    /// held to: four bytes a pixel.
    static func decodedBytes(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        return cg.bytesPerRow * cg.height
    }
    #endif
}

/// How the small family draws a cover that is not square.
///
/// A 2:3 jacket aspect-filled into a square loses a third of its height, and
/// its printed title is often in that third.
enum SmallCoverStyle {
    /// Aspect-fill, the full square: a portrait cover loses its top and bottom.
    case fill
    /// The whole cover, aspect-fit and centred, over a heavily blurred and
    /// darkened copy of itself that fills the square. Nothing is cropped.
    case fitOverBlur

    /// The one switch. Changed here, and nowhere else, when the choice is made.
    static let current: SmallCoverStyle = .fill
}

/// A cover at a given size, in one of two fits.
struct CoverArt: View {
    enum Fit {
        /// Aspect-fill, cropping what overflows.
        case fill
        /// Aspect-fit over a blurred, darkened copy that fills the frame.
        case fitOverBlur
    }

    let data: Data?
    let size: CGSize
    var fit: Fit = .fill
    /// Shown in place of an absent cover, which is the normal state on a first
    /// render and after a sign-out. Nil draws the glyph alone — only the small
    /// family passes one, because it prints no title of its own.
    var placeholderTitle: String?
    var glyphSize: CGFloat = 16
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    @ViewBuilder
    private var content: some View {
        #if canImport(UIKit)
        if let data, let image = decoded(data) {
            switch fit {
            case .fill:
                Image(uiImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
            case .fitOverBlur:
                ZStack {
                    // A 48 px decode: it is about to be blurred past
                    // recognition, so more would only be memory.
                    if let small = WidgetImages.image(from: data, longEdge: 48) {
                        Image(uiImage: small)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: size.width, height: size.height)
                            .blur(radius: min(size.width, size.height) * 0.12, opaque: true)
                            .overlay(Color.black.opacity(0.4))
                    }
                    Image(uiImage: image)
                        .resizable()
                        .widgetAccentedRenderingMode(.fullColor)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size.width, height: size.height)
                }
            }
        } else {
            placeholder
        }
        #else
        placeholder
        #endif
    }

    #if canImport(UIKit)
    private func decoded(_ data: Data) -> UIImage? {
        WidgetImages.image(
            from: data,
            framePixels: CGSize(width: size.width * displayScale, height: size.height * displayScale),
            fill: fit == .fill)
    }
    #endif

    private var placeholder: some View {
        ZStack {
            // border, not surfaceRaised: the latter is ~1.1:1 against the
            // widget's own surface, so the placeholder was effectively
            // invisible.
            Palette.border
            VStack(spacing: 6) {
                Image(systemName: "book.closed")
                    .font(.system(size: glyphSize))
                if let placeholderTitle {
                    // A placeholder has no title of its own, so it carries the
                    // book's: this is the one place the small family prints it.
                    Text(placeholderTitle)
                        .font(Typography.serif(14, weight: .medium))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 12)
                }
            }
            .foregroundStyle(Palette.inkSecondary)
        }
    }
}
