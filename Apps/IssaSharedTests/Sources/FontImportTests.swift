import Foundation
import IssaRender
import IssaUI
import Testing

@testable import IssaReader_iOS

/// Importing a font, when the file is not one, and listing what was imported.
///
/// A file CoreText rejects used to be a silent no-op: the picker closed, "Your
/// fonts" was unchanged, and nothing — no footnote, no log line — told it from
/// an import that had worked and not refreshed.
@Suite("Importing a font")
@MainActor
struct FontImportTests {
    /// A file with a font's name and none of a font's bytes, outside the
    /// fonts folder, as the document picker would hand one over.
    private func notAFont(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "font-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data("this is not a font".utf8).write(to: url)
        return url
    }

    @Test("a damaged file is refused, said, and leaves nothing behind")
    func damagedFileIsTold() throws {
        let picked = try notAFont(named: "Damaged-\(UUID().uuidString).ttf")
        defer { try? FileManager.default.removeItem(at: picked.deletingLastPathComponent()) }

        #expect(FontImport.adopt(picked) == nil)
        #expect(FontImport.notice.message == "That file isn't a font this device can read.")
        let directory = try #require(CustomFonts.importedDirectory)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: picked.lastPathComponent).path),
                "a rejected copy would be retried, and fail, at every launch")
    }

    @Test("a WOFF file is told which format to look for")
    func woffIsTold() throws {
        let picked = try notAFont(named: "Web-\(UUID().uuidString).woff2")
        defer { try? FileManager.default.removeItem(at: picked.deletingLastPathComponent()) }

        #expect(FontImport.adopt(picked) == nil)
        #expect(FontImport.notice.message?.contains("OTF or TTF") == true)
    }

    @Test("the next attempt clears what the last one said")
    func noticeClears() throws {
        let picked = try notAFont(named: "Damaged-\(UUID().uuidString).otf")
        defer { try? FileManager.default.removeItem(at: picked.deletingLastPathComponent()) }
        _ = FontImport.adopt(picked)
        #expect(FontImport.notice.message != nil)
        FontImport.notice.clear()
        #expect(FontImport.notice.message == nil)
    }

    @Test("a family the app ships is not listed under Your fonts, in any case")
    func bundledFamiliesAreNotListed() {
        let listed = TypographyControls.listedCustomFamilies(["Literata", "lexend", "My Own Face"])
        #expect(listed == ["My Own Face"])
    }

    @Test("an import answered with a bundled family selects the bundled row")
    func bundledImportSelectsBundled() {
        #expect(FontImport.typeface(for: "LITERATA") == .bundled("Literata"))
        #expect(FontImport.typeface(for: "My Own Face") == .custom("My Own Face"))
    }

    // MARK: - F9

    /// One of the app's own font files, as a reader's Files would hand it
    /// over: a copy outside the app's font folder.
    private func bundledFontCopy() throws -> URL {
        let resources = try #require(Bundle.main.resourceURL)
        let enumerator = FileManager.default.enumerator(at: resources, includingPropertiesForKeys: nil)
        var found: URL?
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "Literata-Regular.ttf" { found = url; break }
        }
        let source = try #require(found, "the app bundle carries no Literata-Regular.ttf")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "font-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let picked = directory.appending(path: "Literata-Copy-\(UUID().uuidString).ttf")
        try FileManager.default.copyItem(at: source, to: picked)
        return picked
    }

    /// Importing a family the app ships selects the app's own row and never
    /// lists the file under "Your fonts" — so a copy kept in the fonts folder
    /// could not be seen, let alone removed, and was read again by the
    /// launch-time registration for nothing.
    @Test("a font the app already ships is not kept in the fonts folder")
    func bundledImportKeepsNoCopy() throws {
        let picked = try bundledFontCopy()
        defer { try? FileManager.default.removeItem(at: picked.deletingLastPathComponent()) }
        let directory = try #require(CustomFonts.importedDirectory)
        let landed = directory.appending(path: picked.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: landed) }

        let family = FontImport.adopt(picked)

        #expect(family == "Literata")
        #expect(FontImport.notice.message == nil)
        #expect(!FileManager.default.fileExists(atPath: landed.path),
                "the copy of a bundled family stayed in Fonts/, with no way to remove it")
    }
}
