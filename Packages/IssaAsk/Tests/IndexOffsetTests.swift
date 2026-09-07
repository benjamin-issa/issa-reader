import Foundation
import IssaRender
import Testing

@testable import IssaAsk

/// The assertion the whole spoiler defence rests on.
///
/// The boundary is a comparison of two integers: the reader's position, measured
/// against a chapter laid out by `ReaderModel`, and a passage's offsets,
/// measured against a chapter parsed by the index. If those two strings differ
/// by so much as one character, every comparison downstream is off by that much
/// — and off in the direction that shows the reader text they have not read.
struct IndexOffsetTests {
    @Test("stored passages are literal substrings of a fresh parse")
    func offsetsMatchAFreshParse() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let indexURL = store.indexURL(for: AskFixture.bookUUID)
        for spine in [AskFixture.Spine.chapterI, AskFixture.Spine.chapterVI] {
            let fresh = try AskFixture.text(spine: spine) as NSString
            let stored = try AskFixture.storedPassages(spine: spine, indexURL: indexURL)
            try #require(!stored.isEmpty)
            for passage in stored {
                #expect(passage.end <= fresh.length)
                // Not "contains" — at exactly this offset. A passage that
                // happens to appear elsewhere in the chapter would pass a
                // `contains` check while its offsets pointed at the wrong page.
                #expect(fresh.substring(with: passage.range).hasPrefix(passage.text))
            }
        }
    }

    @Test("the rendered string is identical under two very different styles")
    func styleDoesNotMoveOffsets() throws {
        // The index is built once, with a plain `ReaderStyle()`, and then
        // compared against a reader who may be at 40 pt in the publisher's face,
        // justified, with roomy spacing. Typeface, size and spacing are
        // attributes; if any of them ever changed a character, the index would
        // have to be rebuilt on every font change — and until someone noticed,
        // it would silently point at the wrong place.
        let plain = ReaderStyle()
        let extreme = ReaderStyle(
            typeface: .publisher,
            fontSize: 40,
            lineSpacing: .roomy,
            justified: true,
            pageMargin: 4,
        )
        for spine in [AskFixture.Spine.chapterI, AskFixture.Spine.chapterVI] {
            let a = try AskFixture.text(spine: spine, style: plain)
            let b = try AskFixture.text(spine: spine, style: extreme)
            #expect(a == b)
        }
    }

    @Test("chunking a fresh parse reproduces the stored passages exactly")
    func chunkingIsReproducible() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let indexURL = store.indexURL(for: AskFixture.bookUUID)
        let titles = try AskFixture.package().navigation.map(\.title)
        // Every chapter, and through `indexable` rather than `chunk`: dropping
        // the contents table is what the store now does, and comparing against
        // the unfiltered chunking would only prove the two disagree.
        for spine in [AskFixture.Spine.chapterI, 1, AskFixture.Spine.chapterVI] {
            let fresh = PassageChunker.indexable(
                text: try AskFixture.text(spine: spine), spineIndex: spine,
                navigationTitles: titles,
            )
            let stored = try AskFixture.storedPassages(spine: spine, indexURL: indexURL)
            // Rebuilding from the same book must give the same offsets, or an
            // index built on one launch and used on the next answers about a
            // different part of the chapter.
            #expect(fresh == stored, "spine \(spine)")
        }
    }

    /// The passage that was cited as evidence for "Who is Alice?".
    ///
    /// Asserted against the rows the store actually wrote rather than against
    /// the chunker, because the filter is only worth anything if the *index*
    /// applies it — a tested function nothing calls is not a fix.
    @Test("nothing outside the book itself is stored, and the story all is")
    func theContentsTableIsNotStored() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let indexURL = store.indexURL(for: AskFixture.bookUUID)
        // Gutenberg's header page: a legal notice, a credits block and a
        // contents table, and not one sentence of *Alice*.
        #expect(try AskFixture.storedPassages(spine: 1, indexURL: indexURL).isEmpty)
        // …and its footer, which is three pages of licence.
        #expect(try AskFixture
            .storedPassages(spine: source.package.spine.count - 1, indexURL: indexURL).isEmpty)
        // Every chapter of the story is untouched.
        for spine in 2 ... 13 {
            #expect(try !AskFixture.storedPassages(spine: spine, indexURL: indexURL).isEmpty,
                    "spine \(spine)")
        }
        // And the transcribers are no longer people the reader has met.
        let names = try await store.topNames(
            in: AskFixture.bookUUID,
            before: AskFixture.endOf(spine: AskFixture.Spine.chapterVI), limit: 20,
        )
        #expect(!names.contains { $0.contains("Widger") || $0.contains("Carroll") })
        #expect(names.first == "Alice")
    }
}
