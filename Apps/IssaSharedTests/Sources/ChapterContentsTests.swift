import Foundation
@testable import IssaEPUB
import Testing

@testable import IssaReader_iOS

/// The table of contents, built once instead of per rendered row.
///
/// `entries` was a computed property, and `isCurrent(_:)` called it again —
/// twice per row. Opening the contents of a book with 400 nav points meant 800
/// rebuilds of a 400-entry array, each one scanning the whole spine per entry,
/// and 800 calls to `visibleFragments()`, which walks the current page's
/// attributes. On the main actor, while the list was trying to appear. It is
/// hoisted into state now, and the href lookup is a dictionary — so what needs
/// pinning is that the rows themselves are unchanged.
@Suite("The contents list")
@MainActor
struct ChapterContentsTests {
    private final class BundleMarker {}

    static func alice() throws -> EPUBPackage {
        let bundle = Bundle(for: BundleMarker.self)
        let url = try #require(bundle.url(forResource: "alice", withExtension: "epub"),
                               "the fixture is not in the test bundle")
        return try EPUBPackage.open(url: url)
    }

    /// One row per nav point, not per spine item. Books that pack many chapters
    /// into a few large files distinguish them only by fragment, so deduping by
    /// spine index collapses a seventeen-chapter book to four rows that all
    /// open on page one.
    @Test("every navigation point that resolves gets its own row")
    func oneRowPerNavPoint() throws {
        let package = try Self.alice()
        let hrefs = Set(package.spine.map(\.href))
        let expected = package.navigation.filter { hrefs.contains($0.href) }
        #expect(!expected.isEmpty, "the fixture has to have navigation for this to test anything")

        let entries = ChapterListView.build(from: package)
        #expect(entries.count == expected.count)
        #expect(entries.map(\.title) == expected.map { $0.title.isEmpty ? nil : $0.title }
            .enumerated().map { $1 ?? "Chapter \($0 + 1)" })
        #expect(entries.map(\.fragment) == expected.map(\.fragment))
    }

    /// The href lookup, which is what changed: a dictionary built once, where
    /// there used to be a `firstIndex(where:)` per nav point. First match wins
    /// in both, and a row pointing at the wrong spine item opens the wrong
    /// chapter.
    @Test("each row points at the spine item its navigation entry names")
    func rowsPointAtTheRightChapter() throws {
        let package = try Self.alice()
        for entry in ChapterListView.build(from: package) {
            let expected = try #require(package.spine.firstIndex { $0.href == package.navigation
                .first { $0.fragment == entry.fragment && $0.title == entry.title }?.href })
            #expect(entry.spineIndex == expected,
                    "\"\(entry.title)\" opens spine item \(entry.spineIndex), not \(expected)")
        }
    }

    /// Ids are what the current-chapter marker is matched on, so two rows
    /// sharing one would mark both — and `List` would drop one of them.
    @Test("row ids are unique")
    func idsAreUnique() throws {
        let entries = ChapterListView.build(from: try Self.alice())
        #expect(Set(entries.map(\.id)).count == entries.count)
    }

    /// A book with no usable navigation still needs a way to move around.
    @Test("no navigation at all still yields a row per spine item")
    func fallsBackToTheSpine() throws {
        let package = try Self.alice()
        let stripped = EPUBPackage(
            archive: package.archive, rootDirectory: package.rootDirectory,
            metadata: package.metadata, manifest: package.manifest,
            spine: package.spine, navigation: [], spineWeights: package.spineWeights,
        )
        let entries = ChapterListView.build(from: stripped)
        #expect(entries.count == package.spine.count)
        #expect(entries.map(\.spineIndex) == Array(package.spine.indices))
        #expect(entries.allSatisfy { $0.fragment == nil })
    }

    @Test("no book at all yields no rows")
    func noPackageNoRows() {
        #expect(ChapterListView.build(from: nil).isEmpty)
    }
}
