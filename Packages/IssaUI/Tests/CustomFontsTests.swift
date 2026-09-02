import CoreText
import Foundation
import Testing

@testable import IssaUI

/// The registry behind the picker's "Your fonts" section.
///
/// One registry serves two kinds of face — ones the reader imported, and ones
/// extracted from inside a book — and only the first kind may be listed. A
/// book's face is written under `Fonts/<book-uuid>/`, which the launch-time
/// `registerAll` never descends into, so a selection made from one used to
/// resolve to nothing on the next run and every book fell silently back to the
/// default face.
@Suite("Custom font registry", .serialized)
struct CustomFontsTests {
    /// The bundled font files, straight from the source tree — this test
    /// target ships no resources of its own.
    private static let fonts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // IssaUI/
        .appendingPathComponent("Sources/IssaUI/Resources/Fonts", isDirectory: true)

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CustomFontsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// CoreText registration is process-global, and every package's tests run
    /// in this one process — BundledFaceTests resolves the very families this
    /// suite copies into temp directories, and a leftover duplicate
    /// registration flips which member `PlatformFont(name:)` finds for the
    /// bare family name. Each test unregisters everything it registered.
    private func unregisterFonts(under directory: URL) {
        guard let files = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in files
        where CustomFonts.readableExtensions.contains(url.pathExtension.lowercased()) {
            CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Copies one bundled font into `directory`, optionally under a new name —
    /// a book's face lands on disk as `body.ttf`, not under its family.
    private func copyFont(
        _ file: String, into directory: URL, as name: String? = nil,
    ) throws -> URL {
        let destination = directory.appendingPathComponent(name ?? file)
        try FileManager.default.copyItem(
            at: Self.fonts.appendingPathComponent(file), to: destination)
        return destination
    }

    @Test("an imported face registers and is listed")
    func importedFaceIsListed() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { unregisterFonts(under: directory) }
        let url = try copyFont("Literata-Regular.ttf", into: directory)

        let family = try #require(CustomFonts.register(url, imported: true))
        #expect(CustomFonts.families().contains(family))
    }

    @Test("a book-embedded face registers but is never listed")
    func embeddedFaceIsNotListed() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { unregisterFonts(under: directory) }
        // The shape ReaderModel writes: <fonts>/<book-uuid>/<member name>.
        let bookDirectory = directory.appendingPathComponent("book-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDirectory, withIntermediateDirectories: true)
        let url = try copyFont("Lexend-Regular.ttf", into: bookDirectory, as: "body.ttf")

        // Usable in the book that shipped it…
        let family = try #require(CustomFonts.register(url))
        // …but never offered as one of "Your fonts".
        #expect(!CustomFonts.families().contains(family))
    }

    @Test("registerAll lists what it finds, and re-registration keeps it listed")
    func registerAllListsRootFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { unregisterFonts(under: directory) }
        let url = try copyFont("OpenDyslexic-Regular.otf", into: directory)
        // A book's sub-directory must not leak into the listing through the
        // launch pass; `registerAll` is shallow on purpose.
        let bookDirectory = directory.appendingPathComponent("book-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDirectory, withIntermediateDirectories: true)
        let embedded = try copyFont("Newsreader.ttf", into: bookDirectory, as: "body.ttf")

        let families = CustomFonts.registerAll(in: directory)
        let family = try #require(families.first)
        #expect(families.count == 1)
        #expect(CustomFonts.families().contains(family))
        // The idempotent early return must not drop the imported marking.
        #expect(CustomFonts.register(url) == family)
        #expect(CustomFonts.families().contains(family))
        // The embedded file was skipped entirely, not registered quietly.
        if let embeddedFamily = CustomFonts.familyName(in: embedded) {
            #expect(!CustomFonts.families().contains(embeddedFamily))
        }
    }

    @Test("a plain registration is upgraded when the same URL is imported")
    func importUpgradesExistingRegistration() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { unregisterFonts(under: directory) }
        let url = try copyFont("SourceSerif4-Regular.ttf", into: directory)

        let family = try #require(CustomFonts.register(url))
        #expect(!CustomFonts.families().contains(family))
        #expect(CustomFonts.register(url, imported: true) == family)
        #expect(CustomFonts.families().contains(family))
    }

    @Test("a file CoreText cannot read is refused, imported or not")
    func unreadableFilesAreRefused() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The right extension with junk behind it, and a format CoreText
        // cannot read at all.
        let junk = directory.appendingPathComponent("junk.ttf")
        try Data("not a font".utf8).write(to: junk)
        let woff = directory.appendingPathComponent("face.woff")
        try Data("not a font either".utf8).write(to: woff)

        #expect(CustomFonts.register(junk, imported: true) == nil)
        #expect(CustomFonts.register(woff, imported: true) == nil)
    }
}
