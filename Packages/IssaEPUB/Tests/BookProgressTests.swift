import Foundation
import Testing

@testable import IssaEPUB

/// Book progress used to count spine items equally, so a two-page front-matter
/// wrapper weighed as much as a forty-page chapter. That was tolerable while the
/// number only fed a hidden Handoff payload; it is now shown to the reader.
@Suite("How far through the book")
struct BookProgressTests {
    /// Sizes chosen to be lopsided the way a real EPUB is: three tiny wrappers
    /// around one long chapter.
    func package(sizes: [Int]) throws -> EPUBPackage {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/alice", withExtension: "epub"))
        let real = try EPUBPackage.open(url: url)
        // Reuse the real package's shape, substituting known weights.
        return EPUBPackage(
            archive: real.archive,
            rootDirectory: real.rootDirectory,
            metadata: real.metadata,
            manifest: real.manifest,
            spine: Array(real.spine.prefix(sizes.count)),
            navigation: real.navigation,
            spineWeights: sizes.map(Double.init),
        )
    }

    @Test("a long chapter is worth more of the book than a short wrapper")
    func weightsBySize() throws {
        // cover 500 · title 500 · chapter 99_000
        let book = try package(sizes: [500, 500, 99_000])

        // Halfway through the long final chapter is ~50% of the book, not the
        // 83% that counting three equal items would have produced.
        let weighted = book.bookProgress(spineIndex: 2, within: 0.5)
        #expect(weighted > 0.5 && weighted < 0.52, "got \(weighted)")

        let byIndex = (2.0 + 0.5) / 3.0
        #expect(abs(byIndex - 0.833) < 0.01)
        #expect(weighted < byIndex - 0.3, "the two must differ substantially")
    }

    @Test("the start is zero and the end is one")
    func endpoints() throws {
        let book = try package(sizes: [1_000, 2_000, 3_000])
        #expect(book.bookProgress(spineIndex: 0, within: 0) == 0)
        #expect(abs(book.bookProgress(spineIndex: 2, within: 1) - 1) < 0.0001)
    }

    @Test("progress only ever increases across the spine")
    func monotonic() throws {
        let book = try package(sizes: [800, 40_000, 1_200, 25_000])
        var previous = -1.0
        for index in 0 ..< 4 {
            for within in [0.0, 0.5, 0.99] {
                let value = book.bookProgress(spineIndex: index, within: within)
                #expect(value >= previous, "went backwards at \(index)/\(within)")
                previous = value
            }
        }
    }

    /// A book whose central directory reports nothing must still produce a
    /// sensible number rather than a division by zero.
    @Test("no sizes falls back to counting items equally")
    func fallsBackWithoutSizes() throws {
        let book = try package(sizes: [0, 0, 0])
        #expect(abs(book.bookProgress(spineIndex: 1, within: 0.5) - 0.5) < 0.0001)
    }

    @Test("an out-of-range index and a wild fraction are clamped")
    func clamped() throws {
        let book = try package(sizes: [1_000, 1_000])
        #expect(book.bookProgress(spineIndex: 99, within: 0.5) == 0)
        #expect(book.bookProgress(spineIndex: 0, within: 5) <= 1)
        #expect(book.bookProgress(spineIndex: 0, within: -5) >= 0)
    }
}
