import Foundation
import IssaAsk
import IssaCore
import IssaEPUB
import IssaRender
import Testing

@testable import IssaReader_iOS

/// The line past which the model is never shown anything.
///
/// Two properties, and everything the feature promises rests on both. The
/// boundary has to be the end of what the page actually *paints* — not the end
/// of the range the page nominally holds, which on a long paragraph runs on past
/// the last visible word. And the string the index measures offsets into has to
/// be, character for character, the string the reader is looking at: the offset
/// means nothing otherwise, and the SQL that bounds retrieval would be bounding
/// the wrong place in the chapter.
@Suite("The reading boundary")
@MainActor
struct ReadingBoundaryTests {
    private final class BundleMarker {}

    static func aliceURL() throws -> URL {
        let bundle = Bundle(for: BundleMarker.self)
        return try #require(bundle.url(forResource: "alice", withExtension: "epub"),
                            "the fixture is not in the test bundle")
    }

    /// A reader with a chapter laid out, without a server or a download.
    ///
    /// `resize(to:)` before `go(toChapter:)` on purpose: it records the page
    /// size, and its own relayout is a no-op while there is no layout yet — so
    /// the chapter that follows is laid out at the size a phone would use.
    static func opened(spine: Int, size: CGSize = CGSize(width: 340, height: 560)) async throws
        -> ReaderModel {
        let book = SharedFixtures.book("Alice", uuid: "alice-uuid")
        let session = Session(
            serverURL: URL(string: "https://library.example")!,
            keychain: InMemoryTokens(),
            session: URLSession(configuration: .ephemeral),
        )
        let model = ReaderModel(book: book, session: session)
        model.package = try EPUBPackage.open(url: aliceURL())
        await model.resize(to: size)
        await model.go(toChapter: spine)
        return model
    }

    /// Chapter I of the fixture. Two wrappers in front — the SVG cover and
    /// Gutenberg's header page — are why this is 2 and not 0, which is exactly
    /// what makes a hand-built fixture useless for this.
    static let chapterI = 2

    @Test("the boundary is the end of what the page paints")
    func boundaryIsThePaintedEnd() async throws {
        let model = try await Self.opened(spine: Self.chapterI)
        let layout = try #require(model.layout)
        let page = try #require(model.currentPage)

        let boundary = try #require(model.readingBoundary())
        #expect(boundary.spineIndex == Self.chapterI)
        #expect(boundary.charOffset == NSMaxRange(layout.paintedCharacterRange(for: page)))
        #expect(boundary.pageNumber == 1)
        #expect(boundary.kind == .pageEnd)
    }

    /// The page number and the chapter name are the answer's footer, and a
    /// footer that names the wrong page is a promise the reader cannot check.
    @Test("turning the page moves the boundary with it")
    func boundaryFollowsThePage() async throws {
        let model = try await Self.opened(spine: Self.chapterI)
        try #require(model.pageCount > 2, "the chapter has to run to more than two pages")
        let first = try #require(model.readingBoundary())

        await model.nextPage()
        let second = try #require(model.readingBoundary())
        #expect(second.charOffset > first.charOffset)
        #expect(second.pageNumber == 2)

        let layout = try #require(model.layout)
        let page = try #require(model.currentPage)
        #expect(second.charOffset == NSMaxRange(layout.paintedCharacterRange(for: page)))
    }

    /// The index's whole contract with the reader.
    ///
    /// `AskIndexStore` parses each chapter with `ArchiveImageSource` and stores
    /// character offsets into the result. If that string differs from the one
    /// the reader's layout was built from — by one attachment character, by one
    /// entity — every offset in the index is wrong by that much, and the
    /// boundary lands somewhere the reader has not been.
    @Test("the index measures offsets into the very string on screen")
    func indexStringMatchesTheLaidOutChapter() async throws {
        let model = try await Self.opened(spine: Self.chapterI)
        let layout = try #require(model.layout)
        let package = try #require(model.package)

        let directory = URL.temporaryDirectory
            .appending(path: "issa-boundary-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AskIndexStore(directory: directory)
        let source = BookSource(
            bookUUID: "alice-uuid", fileURL: try Self.aliceURL(), package: package,
        )
        try await store.prepare(source: source)

        // Read back through the store's own retrieval, bounded at the very end
        // of the chapter, so what is compared is what the model would be shown.
        let onScreen = layout.attributedText.string
        let end = ReadingBoundary(
            spineIndex: Self.chapterI, charOffset: (onScreen as NSString).length,
        )
        let passages = try await store.recapPassages(
            in: "alice-uuid", before: end, limit: 200,
        )
            .map(\.passage)
            .filter { $0.spineIndex == Self.chapterI }
        #expect(!passages.isEmpty, "the chapter has to have been indexed for this to test anything")

        let chapter = onScreen as NSString
        for passage in passages {
            #expect(
                passage.end <= chapter.length,
                "passage \(passage.ordinal) runs past the end of the laid-out chapter")
            guard passage.end <= chapter.length else { continue }
            // Literal, not approximate. A stored passage's character *i* is
            // chapter offset `start + i` — that is the invariant the straddling
            // truncation cuts on, and containment would pass even if every
            // offset were out by the same amount.
            let slice = chapter.substring(
                with: NSRange(location: passage.start, length: passage.end - passage.start))
            #expect(
                slice.hasPrefix(passage.text)
                    || passage.text.hasPrefix(slice.trimmingCharacters(in: .newlines)),
                "passage \(passage.ordinal) is not where the index says it is")
        }
    }
}

/// A token store that never touches the keychain.
private final class InMemoryTokens: TokenPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]

    func read(account: String) -> String? { lock.withLock { stored[account] } }

    @discardableResult
    func write(_ token: String, account: String) -> Bool {
        lock.withLock { stored[account] = token }
        return true
    }

    @discardableResult
    func delete(account: String) -> Bool {
        lock.withLock { _ = stored.removeValue(forKey: account) }
        return true
    }
}
