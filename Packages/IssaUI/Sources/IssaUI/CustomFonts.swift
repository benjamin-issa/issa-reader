import CoreText
import Foundation

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
    /// `Application Support`, excluded from backup — the file came from
    /// somewhere else and can come from there again, and a book's embedded
    /// font is already inside the book.
    public static func directory(named name: String) -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true,
        ) else { return nil }
        var url = support.appendingPathComponent(name, isDirectory: true)
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
}
