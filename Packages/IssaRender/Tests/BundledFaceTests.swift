import IssaUI
import Testing
@testable import IssaRender

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Every advertised face must actually be there, under the name we advertise.
///
/// `BundledFace.family` is the name CoreText reads out of the file, and it is
/// also the string persisted in `ReaderStyle.Typeface.bundled` — so a typo is
/// not a cosmetic problem. It resolves to nothing, `bodyFont` falls silently
/// through to the default face, and the picker offers a choice that does
/// nothing at all. The files are `PublicSans.ttf` and
/// `SourceSerif4-Regular.ttf` while the families are "Public Sans" and
/// "Source Serif 4", so this is a live trap and not a hypothetical one.
@Suite("Bundled reading faces")
struct BundledFaceTests {
    init() { IssaFonts.register() }

    @Test("every advertised face resolves under the name it is advertised by",
          arguments: IssaFonts.allFaces)
    func resolves(_ face: BundledFace) throws {
        let font = try #require(PlatformFont(name: face.family, size: 18),
                                "nothing registered under the family \"\(face.family)\"")
        #expect(font.familyName == face.family)
    }

    /// Not merely "a bold descriptor came back". CoreText hands back the
    /// upright face when the family has no bold member, so a book set in it
    /// would render `<strong>` as body text with nothing to show for it.
    @Test("every face carries a real bold", arguments: IssaFonts.allFaces)
    func hasBold(_ face: BundledFace) throws {
        let regular = try #require(PlatformFont(name: face.family, size: 18))
        let bold = regular.withBoldTrait()
        #expect(bold.fontName != regular.fontName,
                "\(face.family) has no bold member — \(bold.fontName) is the upright")
    }

    @Test("every face that claims an italic has one", arguments: IssaFonts.allFaces)
    func hasItalic(_ face: BundledFace) throws {
        let regular = try #require(PlatformFont(name: face.family, size: 18))
        let italic = regular.withItalicTrait()
        if face.hasItalic {
            #expect(italic.fontName != regular.fontName,
                    "\(face.family) claims an italic but resolves to \(italic.fontName)")
        } else {
            // Lexend ships none at any weight, and `withItalicTrait` will not
            // fake one. The upright face is the honest answer, and the picker
            // says so rather than leaving it to be found mid-chapter.
            #expect(italic.fontName == regular.fontName)
        }
    }

    /// Bold layered on italic must keep the italic. AppKit's
    /// `withSymbolicTraits(_:)` *replaces* the descriptor's traits, so a bare
    /// `.bold` there stripped the italic — `<strong><em>` text rendered bold
    /// upright on the Mac and bold italic everywhere else. The order matters:
    /// `bodyFont(italic:)` italicises first and the parser bolds second, so
    /// this walks the same path a nested emphasis does.
    @Test("bold layered on an italic face keeps the italic",
          arguments: IssaFonts.allFaces.filter(\.hasItalic))
    func boldKeepsItalic(_ face: BundledFace) throws {
        let regular = try #require(PlatformFont(name: face.family, size: 18))
        let boldItalic = regular.withItalicTrait().withBoldTrait()
        #if canImport(UIKit)
        #expect(boldItalic.fontDescriptor.symbolicTraits.contains(.traitItalic),
                "\(face.family): applying bold stripped the italic — resolved \(boldItalic.fontName)")
        #else
        #expect(boldItalic.fontDescriptor.symbolicTraits.contains(.italic),
                "\(face.family): applying bold stripped the italic — resolved \(boldItalic.fontName)")
        #endif
    }

    @Test("the default face is one of the faces actually shipped")
    func defaultIsBundled() {
        #expect(IssaFonts.allFaces.contains { $0.family == ReaderStyle.defaultFamily })
        // Still shipped, because the app's own UI serif is set in it and
        // because anyone moved off it must be able to pick it back.
        #expect(IssaFonts.allFaces.contains { $0.family == ReaderStyle.legacyDefaultFamily })
    }

    @Test("no family is offered twice — a picker cannot carry one tag in two sections")
    func familiesAreUnique() {
        let families = IssaFonts.allFaces.map(\.family)
        #expect(Set(families).count == families.count)
    }

    @Test("every face ships the licence it is bound by", arguments: IssaFonts.allFaces)
    func hasLicence(_ face: BundledFace) throws {
        let text = try #require(IssaFonts.licence(for: face.family),
                                "no OFL file bundled for \(face.family)")
        #expect(text.contains("SIL OPEN FONT LICENSE"))
    }
}
