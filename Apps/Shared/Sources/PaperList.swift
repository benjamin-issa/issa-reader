import IssaCore
import IssaUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public extension View {
    /// Puts a List on the app's paper ground.
    ///
    /// `scrollContentBackground` does not exist on tvOS, where a List draws no
    /// opaque background of its own anyway, so the modifier is simply skipped
    /// there rather than each caller carrying its own #if.
    func paperListBackground() -> some View {
        #if os(tvOS)
        background(Palette.paper)
        #else
        scrollContentBackground(.hidden).background(Palette.paper)
        #endif
    }
}

/// Colours for the marks a reader makes.
///
/// Named tints rather than raw hex on the annotation itself, so a future theme
/// can restate them without migrating anything already saved.
///
/// Fixed, not `Palette` tokens: a mark is drawn on the page, whose theme is the
/// reader's own choice, and the colour of a highlighter is a property of the
/// mark rather than of the room's lighting. Taking these from the adaptive
/// palette made a saved slate highlight turn pale blue when the system switched
/// to Dark Mode, on a page that had not changed at all.
public enum ReaderPalette {
    public static func color(for tint: Annotation.Tint) -> Color {
        switch tint {
        case .tangerine: Color(hex: 0xE2853A)
        case .moss: Color(hex: 0x7C8A5A)
        case .slate: Color(hex: 0x2F3A3F)
        case .rose: Color(hex: 0xC46A6A)
        case .plum: Color(hex: 0x8A6AA8)
        }
    }
}

#if !os(tvOS)
extension ReaderPalette {
    /// How big a swatch is drawn, in points: a menu's icon slot, with a point
    /// of margin all round for the ring.
    static let swatchSide: CGFloat = 20

    /// The tint's own colour as an icon a menu will not recolour.
    ///
    /// A menu paints a template image — which is what an SF Symbol is, and so
    /// what `Label(_, systemImage: "circle.fill")` gave it — in the app's
    /// accent, so all five highlighter colours came out tangerine. A bitmap
    /// marked "always original" is drawn as it is.
    ///
    /// A hairline ring in a translucent grey goes round the disc. Slate is the
    /// near-black of the five, and on a dark menu a bare slate disc is a hole
    /// in the row; the grey is half-way between the two grounds, which is the
    /// only ring that shows on both. The disc's centre is the pure colour, and
    /// is what the tests read.
    #if canImport(UIKit)
    static func swatch(for tint: Annotation.Tint) -> UIImage {
        let bounds = CGRect(x: 0, y: 0, width: swatchSide, height: swatchSide)
        let image = UIGraphicsImageRenderer(size: bounds.size).image { context in
            let disc = bounds.insetBy(dx: 1, dy: 1)
            UIColor(color(for: tint)).setFill()
            context.cgContext.fillEllipse(in: disc)
            UIColor(white: 0.5, alpha: 0.6).setStroke()
            context.cgContext.setLineWidth(0.5)
            context.cgContext.strokeEllipse(in: disc)
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// The swatch for a `Label`'s icon slot.
    static func swatchIcon(for tint: Annotation.Tint) -> Image {
        Image(uiImage: swatch(for: tint)).renderingMode(.original)
    }
    #elseif canImport(AppKit)
    static func swatch(for tint: Annotation.Tint) -> NSImage {
        let image = NSImage(
            size: NSSize(width: swatchSide, height: swatchSide), flipped: false,
        ) { bounds in
            let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            NSColor(color(for: tint)).setFill()
            disc.fill()
            NSColor(white: 0.5, alpha: 0.6).setStroke()
            disc.lineWidth = 0.5
            disc.stroke()
            return true
        }
        // Set explicitly: a template image is drawn in the menu's text colour,
        // which is the Mac's version of the accent-tinted circles.
        image.isTemplate = false
        return image
    }

    /// The swatch for a `Label`'s icon slot.
    static func swatchIcon(for tint: Annotation.Tint) -> Image {
        Image(nsImage: swatch(for: tint)).renderingMode(.original)
    }
    #endif
}
#endif
