import CoreText
import Foundation
import IssaCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Faces the app did not ship: ones the reader imported, and ones found inside
/// a book.
///
/// Separate from `IssaFonts`, which registers four bundled files behind a
/// single global flag and cannot generalise. Registration is process-wide, so
/// this keeps a registry keyed by file URL — two books shipping different files
/// both called "Minion Pro" would otherwise collide, and the second would
/// silently render in the first's face.
public enum CustomFonts {
    /// Formats CoreText can actually read.
    ///
    /// EPUB 3 permits WOFF and WOFF2, and CoreText reads neither. A book that
    /// ships only those has no usable font, and the reader should be told that
    /// rather than left wondering why the setting did nothing.
    public static let readableExtensions: Set<String> = ["otf", "ttf", "ttc", "otc"]

    public static func isReadable(_ url: URL) -> Bool {
        readableExtensions.contains(url.pathExtension.lowercased())
    }

    private static let lock = NSLock()

    /// Serialises CoreText registration across test suites. Registration is
    /// process-global, and several suites in one test process touch the shared
    /// registry — one suite registering a bundled family from a temporary copy
    /// while another resolves that same family flips which member CoreText hands
    /// back for the bare family name. Suites that register or resolve fonts run
    /// their bodies inside this lock so they never overlap. Not used by the app.
    package static let testRegistryLock = NSLock()

    /// File URL → the family name it registered under.
    nonisolated(unsafe) private static var registered: [URL: String] = [:]
    /// The subset of `registered` the reader imported themselves.
    ///
    /// `registered` also carries faces extracted from books, and those must
    /// not reach the picker: a book's face lives under `Fonts/<book-uuid>/`,
    /// which the launch-time `registerAll` never descends into, so choosing
    /// one persisted a family name that resolved to nothing on the next
    /// launch — every book silently set in the fallback face.
    nonisolated(unsafe) private static var importedURLs: Set<URL> = []

    /// Registers a font file and returns the family name to ask for.
    ///
    /// Idempotent per URL. Returns `nil` for a format CoreText cannot read, or
    /// a file it rejects — callers fall back to the chosen face rather than
    /// rendering nothing. Pass `imported: true` only for a face the reader
    /// imported into the fonts directory root: those are what `families()`
    /// offers, because they are the only ones registered again at launch.
    @discardableResult
    public static func register(_ url: URL, imported: Bool = false) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let known = registered[url] {
            if imported { importedURLs.insert(url) }
            return known
        }
        guard isReadable(url) else { return nil }

        var error: Unmanaged<CFError>?
        let added = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !added, let cfError = error?.takeRetainedValue(),
           CFErrorGetCode(cfError) != CTFontManagerError.alreadyRegistered.rawValue {
            return nil
        }
        guard let family = familyName(in: url) else { return nil }
        registered[url] = family
        if imported { importedURLs.insert(url) }
        return family
    }

    /// Reads the family name out of the file, rather than trusting its name.
    ///
    /// A file called `body.otf` registers under whatever family it declares,
    /// and that is the only name CoreText will answer to.
    static func familyName(in url: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
            as? [CTFontDescriptor], let first = descriptors.first
        else { return nil }
        let family = CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
        return family ?? CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String
    }

    /// Every imported face currently registered, for the picker to list.
    ///
    /// Imported only — never a face extracted from a book. Those were listed
    /// here once, under "Your fonts", and picking one made a promise the next
    /// launch could not keep.
    public static func families() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Set(importedURLs.compactMap { registered[$0] }).sorted()
    }

    /// Registers everything in the app's own font directory.
    ///
    /// Called at launch: a face imported in a previous session has to be
    /// registered again before the first page is set, or the book renders in
    /// the fallback and the setting looks like it was forgotten.
    @discardableResult
    public static func registerAll(in directory: URL) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        // Everything at this directory's root was put there by
        // `FontImport.adopt`, so it counts as imported and belongs in the
        // picker.
        return files.compactMap { register($0, imported: true) }
    }

    /// Where imported and extracted faces live.
    ///
    /// Under `StorageRoot`, excluded from backup — the file came from
    /// somewhere else and can come from there again, and a book's embedded
    /// font is already inside the book.
    public static func directory(named name: String) -> URL? {
        prepared(StorageRoot.directory(name))
    }

    /// Creates a font directory and marks it as not worth backing up.
    private static func prepared(_ url: URL) -> URL? {
        var url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return url
    }

    /// Imported faces live here; the reader chose them.
    public static var importedDirectory: URL? { directory(named: "Fonts") }

    /// Where a book's own extracted face is written. One directory per book,
    /// which is what makes the two kinds of face separable at all.
    ///
    /// Path only, so the sweep below can name a directory without creating one:
    /// asking for it in order to delete it is how an empty `Fonts/<uuid>/` gets
    /// left behind for every book that never shipped a face.
    ///
    /// The id is put through `safePathComponent` before it names anything, and
    /// this is the call that most needed it: `removeExtracted` deletes whatever
    /// this returns, whole. The id was interpolated raw, so `..` produced
    /// `Fonts/../` — the storage root — and removing that one book's face
    /// deleted every download, the catalogue, the logs and the reader's own
    /// imported fonts. The orphan sweep reaches here with ids it decoded from
    /// filenames found on disk, so `..-ebook.epub` sitting in `Books/` was the
    /// whole exploit; `BookContentService.decodeFilename` now refuses that name
    /// as well, but the guard belongs here too, where the deletion is.
    public static func extractedDirectory(bookUUID: String, in root: URL? = nil) -> URL {
        (root ?? StorageRoot.directory("Fonts"))
            .appending(path: bookUUID.safePathComponent, directoryHint: .isDirectory)
    }

    /// The same directory, created and excluded from backup, for the writer.
    public static func prepareExtractedDirectory(bookUUID: String) -> URL? {
        prepared(extractedDirectory(bookUUID: bookUUID))
    }

    /// Drops the faces extracted from one book, when its download goes.
    ///
    /// `ReaderModel.resolvePublisherFont` writes a publisher's embedded face to
    /// `Fonts/<book-uuid>/` on every open of a book that ships one, and nothing
    /// ever removed it: deleting the download left the font behind, the storage
    /// screen never counted it, and the only way to reclaim it was deleting the
    /// app.
    ///
    /// **Only the subdirectory.** Faces sitting at the root of `Fonts/` were
    /// imported by the reader and are theirs, like their annotations — a sweep
    /// of the whole folder would delete files the app never downloaded and
    /// cannot fetch again.
    ///
    /// Unregistered before it is deleted. Registration is process-wide and keyed
    /// by file URL, so leaving it in place keeps CoreText holding a mapping for
    /// a file that no longer exists — and the cached `registered` entry would
    /// then hand a stale family name straight back if the book were downloaded
    /// again into the same path.
    public static func removeExtracted(bookUUID: String, in root: URL? = nil) {
        removeExtracted(at: extractedDirectory(bookUUID: bookUUID, in: root))
    }

    /// The removal itself, given the directory rather than the book.
    ///
    /// Split out for `removeAllExtracted`, which already holds a real directory
    /// URL and must not re-derive one: a book whose id was malformed lives in
    /// `Fonts/unsafe-<hash>/`, and putting *that* name back through
    /// `extractedDirectory` hashes it a second time and names a directory that
    /// has never existed — so "sign out and delete my downloads" would have
    /// walked straight past the very faces the guard above was protecting.
    private static func removeExtracted(at directory: URL) {
        lock.lock()
        for url in registered.keys where url.path.hasPrefix(directory.path + "/") {
            CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
            registered[url] = nil
            // Belt and braces: an extracted face is never registered as
            // imported, but forgetting it here means the picker cannot offer
            // one even if that rule is broken later.
            importedURLs.remove(url)
        }
        lock.unlock()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Every face extracted from a book, for "sign out and delete my downloads".
    ///
    /// Subdirectories only, for the reason `removeExtracted` gives: the faces
    /// at the root of `Fonts/` are the reader's own imports, this is their only
    /// copy, and they are no more the account's than an annotation is.
    public static func removeAllExtracted(in root: URL? = nil) {
        let root = root ?? StorageRoot.directory("Fonts")
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries
            where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            removeExtracted(at: entry)
        }
    }
}
