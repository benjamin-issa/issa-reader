import Foundation
import IssaRender
import IssaUI
import Testing

@testable import IssaReader_iOS

/// Importing a font from one book's "Aa" sheet.
///
/// The global reading settings resolved an imported family through
/// `FontImport.typeface(for:)` and the book's sheet did not: it set
/// `.custom(family)` on whatever the import answered. A file of a family the
/// app ships is answered with the bundled family's name, so importing one from
/// the book's sheet set that book in a "custom" face that was really the app's
/// own — selected under no row of the picker, and keyed differently from the
/// bundled row the reader would pick by hand.
@Suite("Importing a font for one book")
@MainActor
struct BookFontImportTests {
    /// A bundled face's own file, wherever the build put it in the app.
    private func bundledFile(named name: String) throws -> URL {
        let root = Bundle.main.bundleURL
        let found = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == name }
        return try #require(found, "\(name) is not in the app bundle")
    }

    @Test("a copy of a family the app ships selects the app's own face")
    func bundledCopySelectsBundled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "book-font-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Renamed, as a file downloaded from elsewhere would be: the family
        // comes from inside the file, never from its name.
        let picked = directory.appending(path: "Picked-\(UUID().uuidString).ttf")
        try FileManager.default.copyItem(at: bundledFile(named: "Literata-Regular.ttf"), to: picked)
        // `adopt` keeps a copy in the fonts folder; this test's must not
        // outlive it.
        let imported = try #require(CustomFonts.importedDirectory)
            .appending(path: picked.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: imported) }

        #expect(BookTypographyView.importedTypeface(picked) == .bundled("Literata"))
    }

    @Test("a file that is not a font selects nothing")
    func refusedImportSelectsNothing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "book-font-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let picked = directory.appending(path: "Damaged-\(UUID().uuidString).ttf")
        try Data("this is not a font".utf8).write(to: picked)

        #expect(BookTypographyView.importedTypeface(picked) == nil)
        FontImport.notice.clear()
    }
}
