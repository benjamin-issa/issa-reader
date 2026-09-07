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
        // Held across the whole test — acquired first so its release defer runs
        // last, after the unregister below — so no other suite resolves a
        // bundled family while this test has a duplicate copy registered.
        CustomFonts.testRegistryLock.lock()
        defer { CustomFonts.testRegistryLock.unlock() }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { unregisterFonts(under: directory) }
        let url = try copyFont("Literata-Regular.ttf", into: directory)

        let family = try #require(CustomFonts.register(url, imported: true))
        #expect(CustomFonts.families().contains(family))
    }

    @Test("a book-embedded face registers but is never listed")
    func embeddedFaceIsNotListed() throws {
        // Held across the whole test — acquired first so its release defer runs
        // last, after the unregister below — so no other suite resolves a
        // bundled family while this test has a duplicate copy registered.
        CustomFonts.testRegistryLock.lock()
        defer { CustomFonts.testRegistryLock.unlock() }
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
        // Held across the whole test — acquired first so its release defer runs
        // last, after the unregister below — so no other suite resolves a
        // bundled family while this test has a duplicate copy registered.
        CustomFonts.testRegistryLock.lock()
        defer { CustomFonts.testRegistryLock.unlock() }
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
        // Held across the whole test — acquired first so its release defer runs
        // last, after the unregister below — so no other suite resolves a
        // bundled family while this test has a duplicate copy registered.
        CustomFonts.testRegistryLock.lock()
        defer { CustomFonts.testRegistryLock.unlock() }
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
        // Held across the whole test — acquired first so its release defer runs
        // last, after the unregister below — so no other suite resolves a
        // bundled family while this test has a duplicate copy registered.
        CustomFonts.testRegistryLock.lock()
        defer { CustomFonts.testRegistryLock.unlock() }
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

    // MARK: - What goes when a download goes

    /// The leak: `resolvePublisherFont` writes a book's embedded face to
    /// `Fonts/<book-uuid>/` on every open, and nothing ever removed it —
    /// uncounted by the storage screen and unreachable from the interface, one
    /// directory per book for the life of the install.
    @Test("removing a download takes the face extracted from it")
    func extractedFaceGoesWithItsDownload() throws {
        CustomFonts.testRegistryLock.lock()
        defer { CustomFonts.testRegistryLock.unlock() }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { unregisterFonts(under: root) }

        let extracted = CustomFonts.extractedDirectory(bookUUID: "book-uuid", in: root)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let face = try copyFont("Literata-Regular.ttf", into: extracted, as: "body.ttf")
        #expect(CustomFonts.register(face) != nil)

        CustomFonts.removeExtracted(bookUUID: "book-uuid", in: root)

        #expect(!FileManager.default.fileExists(atPath: extracted.path))
    }

    /// The half that must **not** happen. A face the reader imported sits at
    /// the root of `Fonts/`, this is its only copy, and it belongs to them the
    /// way an annotation does — a sweep of the whole folder would delete files
    /// the app never downloaded and cannot fetch again.
    @Test("the reader's own imported faces survive, and so does the folder")
    func importedFacesSurviveASweep() throws {
        CustomFonts.testRegistryLock.lock()
        defer { CustomFonts.testRegistryLock.unlock() }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { unregisterFonts(under: root) }

        let mine = try copyFont("SourceSerif4-Regular.ttf", into: root, as: "Mine.ttf")
        let extracted = CustomFonts.extractedDirectory(bookUUID: "book-uuid", in: root)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        _ = try copyFont("Literata-Regular.ttf", into: extracted, as: "body.ttf")

        CustomFonts.removeAllExtracted(in: root)

        #expect(!FileManager.default.fileExists(atPath: extracted.path))
        #expect(FileManager.default.fileExists(atPath: mine.path), "that file is the reader's")
        #expect(FileManager.default.fileExists(atPath: root.path), "and so is the folder")
    }

    /// Called from a removal *and* from the reconciliation sweep, and on the
    /// ordinary path from both.
    @Test("removing a face that is not there is not an error")
    func removingNothingIsHarmless() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        CustomFonts.removeExtracted(bookUUID: "never-downloaded", in: root)
        CustomFonts.removeAllExtracted(in: root)

        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    /// Asking for the directory in order to delete it is how an empty
    /// `Fonts/<uuid>/` gets left behind for every book that never shipped a
    /// face.
    @Test("naming a book's font directory does not create one")
    func namingTheDirectoryDoesNotCreateIt() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let named = CustomFonts.extractedDirectory(bookUUID: "book-uuid", in: root)
        #expect(!FileManager.default.fileExists(atPath: named.path))
    }
}
