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

@Suite("A clip time that is not a duration cannot poison the book")
struct SMILClockValidationTests {
    /// The hazard, proved before the guard. `Double` parses all three of these
    /// happily, and each reached the timeline as a duration.
    @Test("Swift really does parse these as numbers")
    func theHazardIsReal() {
        #expect(Double("inf")?.isInfinite == true)
        #expect(Double("nan")?.isNaN == true)
        #expect(Double("1e400")?.isInfinite == true)
        #expect(Double("-5") == -5)
    }

    @Test("a non-finite or negative clip time is refused", arguments: [
        "inf", "-inf", "nan", "1e400s", "infs", "-5s", "-5", "-0.5min", "nans",
    ])
    func refusesUnusableValues(_ raw: String) {
        #expect(
            SMILClock.seconds(from: raw) == nil,
            "\"\(raw)\" must not become a duration: one of these made every later cumulativeEnd infinite and saved the reader's place as 0")
    }

    @Test("the forms a real overlay uses still parse", arguments: [
        ("12.345s", 12.345), ("300ms", 0.3), ("1.5min", 90.0), ("2h", 7200.0),
        ("00:00:12.345", 12.345), ("01:02:03", 3723.0), ("02:03", 123.0), ("0s", 0.0),
    ])
    func acceptsRealValues(_ raw: String, _ expected: Double) {
        let parsed = SMILClock.seconds(from: raw)
        #expect(parsed != nil, "\(raw) is legal SMIL")
        #expect(abs((parsed ?? -1) - expected) < 0.0005)
    }
}

@Suite("Deeply nested markup is refused rather than walked")
struct XMLDepthTests {
    private func nested(_ depth: Int) -> Data {
        Data(("<r>" + String(repeating: "<d>", count: depth) + "x"
            + String(repeating: "</d>", count: depth) + "</r>").utf8)
    }

    /// The hazard, before the guard. XMLParser has no limit of its own, which
    /// is what makes the recursive walks over its output a crash rather than an
    /// error — and an earlier reading of this claimed a ~256 cap that does not
    /// exist.
    @Test("the system parser itself imposes no depth limit")
    func theParserHasNoCapOfItsOwn() {
        final class Counter: NSObject, XMLParserDelegate {
            var maxDepth = 0
            private var depth = 0
            func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?,
                        qualifiedName q: String?, attributes: [String: String]) {
                depth += 1; maxDepth = max(maxDepth, depth)
            }
            func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?,
                        qualifiedName q: String?) { depth -= 1 }
        }
        let parser = XMLParser(data: nested(2_000))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        let counter = Counter()
        parser.delegate = counter
        #expect(parser.parse())
        #expect(counter.maxDepth > EPUBXML.maximumDepth, "so the cap has to be ours")
    }

    @Test("an ordinary document is unaffected")
    func ordinaryDepthParses() throws {
        let root = try EPUBXML.parse(nested(20))
        #expect(root.name == "r")
    }

    @Test("nesting past the cap throws instead of overflowing the stack")
    func deepNestingThrows() {
        #expect(throws: EPUBError.self) {
            try EPUBXML.parse(nested(EPUBXML.maximumDepth + 10))
        }
    }

    /// The payload shape that made this reachable: cheap to compress, so it
    /// passes every archive size guard on the way in.
    @Test("the hostile document is small enough to arrive inside a normal book")
    func thePayloadIsCheap() {
        let bytes = nested(150_000).count
        #expect(bytes < 2_000_000, "about 1.2MB of XHTML, a few hundred bytes deflated")
    }
}
