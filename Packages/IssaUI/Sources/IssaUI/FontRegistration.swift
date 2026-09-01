import CoreText
import Foundation

/// One reading face the app ships.
///
/// `family` is the name CoreText reads out of the file, not the file's own
/// name, and the two differ more often than not — the files are
/// `PublicSans.ttf` and `SourceSerif4-Regular.ttf`, the families are
/// "Public Sans" and "Source Serif 4". It is also the string persisted in
/// `ReaderStyle.Typeface.bundled`, so it must be exactly right; `BundledFaceTests`
/// asserts every one of these resolves.
public struct BundledFace: Hashable, Sendable {
    /// The CoreText family name, and the persisted identifier.
    public let family: String
    /// What the picker shows.
    public let title: String
    /// Whether the family ships an italic. Lexend does not, at any weight, and
    /// `withItalicTrait` deliberately never fakes one — so emphasis in a Lexend
    /// book is set upright rather than in a synthesised oblique.
    public let hasItalic: Bool

    public init(family: String, title: String, hasItalic: Bool = true) {
        self.family = family
        self.title = title
        self.hasItalic = hasItalic
    }
}

/// Registers the bundled reading faces.
///
/// Fonts shipped in a Swift package resource bundle are not picked up the way
/// an app's `UIAppFonts` entry would be, so they must be handed to CoreText
/// explicitly. Doing it here keeps the app targets from each needing their own
/// copy of the files and their own plist entry.
///
/// Every bundled face is under the SIL Open Font License 1.1; each family's
/// own licence sits beside the files as `Resources/Fonts/OFL-<Family>.txt`, and
/// `FontLicencesView` shows them in the app, which is what the licence asks for.
public enum IssaFonts {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered = false

    /// Faces for setting a book in. Literata leads because it is the default.
    public static let readingFaces: [BundledFace] = [
        BundledFace(family: "Literata", title: "Literata"),
        BundledFace(family: "Source Serif 4", title: "Source Serif 4"),
        BundledFace(family: "Newsreader", title: "Newsreader"),
        BundledFace(family: "Public Sans", title: "Public Sans"),
    ]

    /// Faces chosen for legibility rather than for how the page looks.
    ///
    /// Lexend is here rather than beside the others because that is what it is
    /// for — it is a reading-proficiency face, not a second sans. A `Picker`
    /// cannot carry the same tag in two sections, so it appears once.
    public static let accessibilityFaces: [BundledFace] = [
        BundledFace(family: "Lexend", title: "Lexend", hasItalic: false),
        BundledFace(family: "OpenDyslexic", title: "OpenDyslexic"),
    ]

    public static var allFaces: [BundledFace] { readingFaces + accessibilityFaces }

    /// Idempotent, and safe to call from anywhere. Call once at launch, before
    /// the first view renders, or type falls back to the system face.
    public static func register() {
        lock.lock()
        defer { lock.unlock() }
        guard !registered else { return }
        registered = true

        // Everything in the bundle, rather than a hardcoded list of names with
        // a hardcoded `.ttf`. That list had to be edited in lockstep with the
        // directory, and the extension meant an `.otf` face — OpenDyslexic
        // ships as one — would have been skipped in silence. The files are now
        // the whole source of truth.
        for ext in CustomFonts.readableExtensions.sorted() {
            let urls = Bundle.module.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
            for url in urls {
                var error: Unmanaged<CFError>?
                // .process scope: the faces are visible to this process only,
                // which is what a bundled app font should be.
                if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                    // Already registered is not a failure worth surfacing;
                    // anything else means type will silently fall back, so it
                    // is logged.
                    if let cfError = error?.takeRetainedValue(),
                       CFErrorGetCode(cfError) != CTFontManagerError.alreadyRegistered.rawValue {
                        print("[IssaUI] font registration failed for \(url.lastPathComponent): \(cfError)")
                    }
                }
            }
        }
    }

    /// The text of one family's licence, for the screen that shows them.
    public static func licence(for family: String) -> String? {
        let stem = "OFL-" + family.replacingOccurrences(of: " ", with: "")
        guard let url = Bundle.module.url(forResource: stem, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text
    }
}
