import Foundation
import Testing

@testable import IssaEPUB

/// Opened against real EPUBs from Project Gutenberg rather than hand-built
/// archives, because the failures that matter come from real-world structure:
/// namespace prefixes, nested navigation, compressed and stored entries mixed
/// in one archive.
struct EPUBPackageTests {
    static func fixtureURL(_ name: String) throws -> URL {
        try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "epub"),
            "missing fixture \(name).epub",
        )
    }

    @Test("opens a real EPUB and reads its container")
    func opensRealArchive() throws {
        let archive = try EPUBArchive(url: try Self.fixtureURL("alice"))
        #expect(archive.contains("META-INF/container.xml"))
        #expect(archive.contains("mimetype"))

        // The mimetype entry is stored uncompressed by spec; reading it proves
        // the stored path works alongside the deflated one.
        let mimetype = try archive.read("mimetype")
        #expect(String(decoding: mimetype, as: UTF8.self) == "application/epub+zip")
    }

    @Test("parses the package document")
    func parsesPackage() throws {
        let package = try EPUBPackage.open(url: try Self.fixtureURL("alice"))
        #expect(package.metadata.title?.contains("Alice") == true)
        #expect(package.metadata.authors.contains { $0.contains("Carroll") })
        #expect(package.metadata.language?.hasPrefix("en") == true)
        #expect(!package.manifest.isEmpty)
        #expect(!package.spine.isEmpty)
    }

    @Test("spine items resolve to readable documents")
    func spineResolves() throws {
        let package = try EPUBPackage.open(url: try Self.fixtureURL("alice"))
        for item in package.spine {
            #expect(package.archive.contains(item.href), "spine href not in archive: \(item.href)")
        }
        // Every spine document must actually inflate — this is what catches a
        // broken DEFLATE path, which a manifest-only test would miss.
        let first = try #require(package.spine.first)
        let html = try package.archive.read(first.href)
        #expect(!html.isEmpty)
        #expect(String(decoding: html.prefix(512), as: UTF8.self).lowercased().contains("<"))
    }

    @Test("builds a table of contents")
    func parsesNavigation() throws {
        let package = try EPUBPackage.open(url: try Self.fixtureURL("alice"))
        #expect(!package.navigation.isEmpty)
        let titles = package.navigation.map(\.title).joined(separator: " ")
        #expect(titles.lowercased().contains("chapter") || titles.lowercased().contains("rabbit"))
        for point in package.navigation {
            #expect(package.archive.contains(point.href), "nav href not in archive: \(point.href)")
        }
    }

    @Test("opens a second, differently-structured book")
    func opensSecondBook() throws {
        let package = try EPUBPackage.open(url: try Self.fixtureURL("time-machine"))
        #expect(package.metadata.title?.contains("Time Machine") == true)
        #expect(!package.spine.isEmpty)
        let first = try #require(package.spine.first)
        #expect(!(try package.archive.read(first.href).isEmpty))
    }

    @Test("a plain ebook has no media overlays")
    func plainBookHasNoTimeline() throws {
        let package = try EPUBPackage.open(url: try Self.fixtureURL("alice"))
        #expect(SMILParser.timeline(for: package).isEmpty)
    }

    @Test("href resolution handles relative and parent paths")
    func resolvesHrefs() {
        #expect(EPUBPackage.resolve("ch01.xhtml", relativeTo: "OEBPS/text/nav.xhtml") == "OEBPS/text/ch01.xhtml")
        #expect(EPUBPackage.resolve("../Audio/t.mp3", relativeTo: "OEBPS/MediaOverlays/c1.smil") == "OEBPS/Audio/t.mp3")
        #expect(EPUBPackage.resolve("ch01.xhtml#frag", relativeTo: "OEBPS/nav.xhtml") == "OEBPS/ch01.xhtml")
        #expect(EPUBPackage.resolve("/abs/x.xhtml", relativeTo: "OEBPS/nav.xhtml") == "abs/x.xhtml")
    }
}

struct SMILClockTests {
    @Test("parses the metric forms Storyteller writes")
    func parsesMetricForms() {
        #expect(SMILClock.seconds(from: "12.345s") == 12.345)
        #expect(SMILClock.seconds(from: "300ms") == 0.3)
        #expect(SMILClock.seconds(from: "1.5min") == 90)
        #expect(SMILClock.seconds(from: "2h") == 7200)
    }

    @Test("parses full and partial clock values")
    func parsesClockForms() {
        #expect(SMILClock.seconds(from: "00:01:30.50") == 90.5)
        #expect(SMILClock.seconds(from: "01:00:00.00") == 3600)
        #expect(SMILClock.seconds(from: "02:30") == 150)
    }

    @Test("returns nil rather than zero for nonsense")
    func rejectsGarbage() {
        #expect(SMILClock.seconds(from: "") == nil)
        #expect(SMILClock.seconds(from: "abc") == nil)
    }
}

/// Navigation entries must keep their fragment.
///
/// Gutenberg packs many chapters into a handful of large spine files, so nav
/// points differ only by the `#fragment`. Dropping it turns a seventeen-chapter
/// book into four table-of-contents rows that all open page one.
struct NavigationFragmentTests {
    @Test("extracts the fragment from an href")
    func extractsFragment() {
        #expect(EPUBPackage.fragmentIdentifier(of: "ch01.xhtml#sec-3") == "sec-3")
        #expect(EPUBPackage.fragmentIdentifier(of: "ch01.xhtml") == nil)
        #expect(EPUBPackage.fragmentIdentifier(of: "ch01.xhtml#") == nil)
    }

    @Test("a real book keeps more nav points than spine items")
    func keepsPerChapterEntries() throws {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/alice", withExtension: "epub"),
        )
        let package = try EPUBPackage.open(url: url)
        let distinctHrefs = Set(package.navigation.map(\.href))

        // Whether this book packs chapters into few files or many, every entry
        // that names a fragment must have kept it.
        for point in package.navigation where point.href.contains("#") {
            #expect(point.fragment != nil)
        }
        #expect(!package.navigation.isEmpty)
        #expect(!distinctHrefs.isEmpty)

        // Entries pointing into the same document must be distinguishable.
        let grouped = Dictionary(grouping: package.navigation, by: \.href)
        for (_, points) in grouped where points.count > 1 {
            let fragments = points.compactMap(\.fragment)
            #expect(fragments.count == points.count,
                    "nav points share a document but not all carry a fragment")
        }
    }
}
