import Foundation
import IssaEPUB

/// Decodes and caches a chapter's artwork, keyed by archive path.
///
/// A chapter asks once per plate, and the cache lives as long as the chapter
/// does, so reflowing on a font change costs no re-decoding.
///
/// File scope rather than nested inside `ReaderModel`, which is `@MainActor`:
/// a type declared inside a globally-isolated one inherits that isolation, and
/// the search path now decodes plates off the main actor.
///
/// It lives in IssaRender rather than in the app because the Ask index parses
/// chapters with it too, and its offsets are only right because it does: every
/// plate contributes an object-replacement character and a line break to the
/// rendered string, so a parse without the images computes offsets that drift
/// ahead of the laid-out chapter's — far enough on an illustrated book to place
/// a retrieved passage in the wrong place, and to let the spoiler boundary cut
/// in the wrong place with it.
public final class ArchiveImageSource {
    private let archive: EPUBArchive
    private var decoded: [String: PlatformImage?] = [:]

    public init(archive: EPUBArchive) { self.archive = archive }

    public func image(for href: String) -> PlatformImage? {
        if let cached = decoded[href] { return cached }
        var result: PlatformImage?
        if let data = try? archive.read(href) {
            result = PlatformImage(data: data)
        }
        decoded[href] = result
        return result
    }
}
