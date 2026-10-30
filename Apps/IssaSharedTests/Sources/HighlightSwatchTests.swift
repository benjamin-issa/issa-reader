import IssaCore
import IssaUI
import SwiftUI
import Testing
import UIKit

@testable import IssaReader_iOS

/// The icons in the Highlight menu are the tints' own colours.
///
/// A menu paints a template image in the app's accent, so the five swatches
/// were all tangerine. What this holds is the helper's half of the fix: an
/// image that is not a template and whose middle is the tint. That the menu
/// uses it is `LayoutSweepTests.testHighlightMenuColours`, which looks at the
/// open menu's pixels.
@Suite("Highlight colour swatches")
@MainActor
struct HighlightSwatchTests {
    private typealias RGB = (r: Double, g: Double, b: Double)

    /// The pixel in the middle of the image, read back in sRGB.
    private func centre(of image: UIImage) throws -> RGB {
        let cg = try #require(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let column = cg.width / 2, row = cg.height / 2
        // Drawn so that the middle pixel lands on the context's only one.
        context.draw(cg, in: CGRect(
            x: -column, y: -(cg.height - 1 - row), width: cg.width, height: cg.height))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    private func rgb(_ color: Color, style: UIUserInterfaceStyle = .light) -> RGB {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func distance(_ a: RGB, _ b: RGB) -> Double {
        max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
    }

    @Test("a swatch is drawn as it is, never as a template", arguments: Annotation.Tint.allCases)
    func isNotATemplate(tint: Annotation.Tint) {
        #expect(ReaderPalette.swatch(for: tint).renderingMode == .alwaysOriginal)
    }

    /// The highlight menu asks on every rebuild; the same image comes back.
    @Test("a swatch is drawn once and then reused", arguments: Annotation.Tint.allCases)
    func isDrawnOnce(tint: Annotation.Tint) {
        #expect(ReaderPalette.swatch(for: tint) === ReaderPalette.swatch(for: tint))
    }

    @Test("a swatch's middle is the tint's colour", arguments: Annotation.Tint.allCases)
    func centreIsTheTint(tint: Annotation.Tint) throws {
        let drawn = try centre(of: ReaderPalette.swatch(for: tint))
        let wanted = rgb(ReaderPalette.color(for: tint))
        #expect(distance(drawn, wanted) < 0.02, "\(tint): drew \(drawn), wanted \(wanted)")
    }

    @Test("the five swatches are five different colours, and none but Tangerine is the accent")
    func swatchesDiffer() throws {
        let drawn = try Annotation.Tint.allCases.map { ($0, try centre(of: ReaderPalette.swatch(for: $0))) }
        for (index, first) in drawn.enumerated() {
            for second in drawn[(index + 1)...] {
                #expect(distance(first.1, second.1) > 0.1, "\(first.0) and \(second.0) look alike")
            }
        }
        // Tangerine is the accent and a tint both, so only the other four can
        // be tested for not being it.
        for style in [UIUserInterfaceStyle.light, .dark] {
            let accent = rgb(Palette.tangerine, style: style)
            for (tint, colour) in drawn where tint != .tangerine {
                #expect(distance(colour, accent) > 0.1, "\(tint) is drawn in the accent")
            }
        }
    }
}
