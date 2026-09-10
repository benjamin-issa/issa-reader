import Foundation
@testable import IssaEPUB
import Testing

@testable import IssaReader_iOS

/// The chapter marks on the television's strip, and the line that says the same
/// thing in words.
///
/// The property that matters is that the marks and the reader's own position
/// are measured on the **same clock**. A book that is 40% read by audio time is
/// rarely 40% read by byte weight, so two clocks on one strip put chapter marks
/// on the wrong side of the marker — which is worse than having no strip.
@Suite("The television's chapter marks")
struct TVBookTimelineTests {
    private final class BundleMarker {}

    /// A real archive, because `EPUBPackage` holds one. Everything else about
    /// the package below is synthesised, so the spine, the navigation and the
    /// weights are exactly what each test needs them to be.
    private static func archive() throws -> EPUBArchive {
        let bundle = Bundle(for: BundleMarker.self)
        let url = try #require(bundle.url(forResource: "alice", withExtension: "epub"),
                               "the fixture is not in the test bundle")
        return try EPUBArchive(url: url)
    }

    private static func package(
        hrefs: [String], weights: [Double], navigation: [EPUBPackage.NavPoint],
    ) throws -> EPUBPackage {
        EPUBPackage(
            archive: try archive(),
            rootDirectory: "",
            metadata: EPUBPackage.Metadata(
                title: "A Book", language: "en", authors: [],
                identifier: nil, mediaDuration: nil, mediaActiveClass: nil,
            ),
            manifest: [:],
            spine: hrefs.map {
                EPUBPackage.SpineItem(idref: $0, linear: true, href: $0, mediaOverlayID: nil)
            },
            navigation: navigation,
            frontMatter: [],
            spineWeights: weights,
        )
    }

    private static func nav(_ title: String, _ href: String, fragment: String? = nil, depth: Int = 0)
        -> EPUBPackage.NavPoint
    {
        EPUBPackage.NavPoint(title: title, href: href, fragment: fragment, depth: depth)
    }

    private static func entry(
        _ fragment: String, _ href: String, start: TimeInterval, end: TimeInterval,
        cumulativeEnd: TimeInterval,
    ) -> SMILEntry {
        SMILEntry(fragmentID: fragment, textHref: href, audioHref: "\(href).mp3",
                  start: start, end: end, cumulativeEnd: cumulativeEnd)
    }

    /// Three chapters of 10, 30 and 60 seconds. By weight they would be a
    /// third each; by the clock the reader actually hears they are not.
    private static func threeDocuments() -> SMILTimeline {
        SMILTimeline(entries: [
            entry("a1", "a.xhtml", start: 0, end: 10, cumulativeEnd: 10),
            entry("b1", "b.xhtml", start: 0, end: 15, cumulativeEnd: 25),
            entry("b2", "b.xhtml", start: 15, end: 30, cumulativeEnd: 40),
            entry("c1", "c.xhtml", start: 0, end: 60, cumulativeEnd: 100),
        ])
    }

    // MARK: - The audio clock

    @Test("a narrated book puts its chapter marks on the audio clock")
    func audioClockFractions() throws {
        let package = try Self.package(
            hrefs: ["a.xhtml", "b.xhtml", "c.xhtml"],
            weights: [1, 1, 1],
            navigation: [
                Self.nav("One", "a.xhtml"), Self.nav("Two", "b.xhtml"), Self.nav("Three", "c.xhtml"),
            ],
        )
        let ticks = TVBookTimeline.ticks(for: package, timeline: Self.threeDocuments())
        #expect(ticks.map(\.title) == ["One", "Two", "Three"])
        #expect(ticks.map(\.fraction) == [0, 0.1, 0.4])
        // Not the byte-weighted answer, which is what the spine clock gives.
        #expect(ticks[1].fraction != 1.0 / 3.0)
    }

    /// Gutenberg packs a whole book into a handful of files and distinguishes
    /// its chapters only by fragment id. Ignoring the fragment collapses a
    /// seventeen-chapter book to four marks.
    @Test("nav points inside one file get a mark each from their fragments")
    func fragmentLevelNavPoints() throws {
        let package = try Self.package(
            hrefs: ["b.xhtml"],
            weights: [1],
            navigation: [
                Self.nav("Two", "b.xhtml", fragment: "b1"),
                Self.nav("Two and a half", "b.xhtml", fragment: "b2"),
            ],
        )
        let ticks = TVBookTimeline.ticks(for: package, timeline: Self.threeDocuments())
        #expect(ticks.map(\.title) == ["Two", "Two and a half"])
        #expect(ticks.map(\.fraction) == [0.1, 0.25])
    }

    /// A document with no narration has no position on the tape at all. Guessing
    /// one would put a mark where nothing is ever spoken.
    @Test("an un-narrated document gets no mark on the audio clock")
    func unNarratedDocumentsAreSkipped() throws {
        let package = try Self.package(
            hrefs: ["a.xhtml", "notes.xhtml", "c.xhtml"],
            weights: [1, 1, 1],
            navigation: [
                Self.nav("One", "a.xhtml"), Self.nav("Notes", "notes.xhtml"), Self.nav("Three", "c.xhtml"),
            ],
        )
        let ticks = TVBookTimeline.ticks(for: package, timeline: Self.threeDocuments())
        #expect(ticks.map(\.title) == ["One", "Three"])
    }

    // MARK: - The spine clock

    @Test("a plain ebook falls back to spine weight")
    func spineWeightFallback() throws {
        let package = try Self.package(
            hrefs: ["a.xhtml", "b.xhtml", "c.xhtml"],
            weights: [1, 3, 1],
            navigation: [
                Self.nav("One", "a.xhtml"), Self.nav("Two", "b.xhtml"), Self.nav("Three", "c.xhtml"),
            ],
        )
        let ticks = TVBookTimeline.ticks(for: package, timeline: nil)
        #expect(ticks.map(\.fraction) == [0, 0.2, 0.8])
        // An empty timeline is not a narrated book either.
        #expect(TVBookTimeline.ticks(for: package, timeline: SMILTimeline(entries: [])) == ticks)
    }

    /// Several navigation entries naming the same file and no anchor inside it
    /// all land on that file's start, which is a true answer given three times
    /// — and three marks in one place is a blot rather than a division.
    @Test("marks landing in the same place collapse to one")
    func dedupesEqualFractions() throws {
        let package = try Self.package(
            hrefs: ["a.xhtml", "b.xhtml"],
            weights: [1, 1],
            navigation: [
                Self.nav("One", "a.xhtml"),
                Self.nav("Also one", "a.xhtml"),
                Self.nav("One again", "a.xhtml"),
                Self.nav("Four", "b.xhtml"),
            ],
        )
        let ticks = TVBookTimeline.ticks(for: package, timeline: nil)
        #expect(ticks.map(\.title) == ["One", "Four"])
    }

    @Test("only top-level navigation makes a mark")
    func nestedEntriesAreIgnored() throws {
        let package = try Self.package(
            hrefs: ["a.xhtml", "b.xhtml"],
            weights: [1, 1],
            navigation: [
                Self.nav("One", "a.xhtml"),
                Self.nav("A sub-heading", "a.xhtml", fragment: "sub", depth: 1),
                Self.nav("Two", "b.xhtml"),
            ],
        )
        #expect(TVBookTimeline.ticks(for: package, timeline: nil).map(\.title) == ["One", "Two"])
    }

    /// "Section 3" rather than an invented chapter name: the file is the only
    /// boundary such a book actually has.
    @Test("a book with no navigation is divided into numbered sections")
    func sectionFallback() throws {
        let package = try Self.package(
            hrefs: ["a.xhtml", "b.xhtml", "c.xhtml"], weights: [1, 1, 1], navigation: [],
        )
        let ticks = TVBookTimeline.ticks(for: package, timeline: nil)
        #expect(ticks.map(\.title) == ["Section 1", "Section 2", "Section 3"])
    }

    @Test("a nav point pointing outside the spine is dropped")
    func unknownHrefIsDropped() throws {
        let package = try Self.package(
            hrefs: ["a.xhtml"], weights: [1],
            navigation: [Self.nav("One", "a.xhtml"), Self.nav("Ghost", "nowhere.xhtml")],
        )
        #expect(TVBookTimeline.ticks(for: package, timeline: nil).map(\.title) == ["One"])
    }

    // MARK: - Placing a chapter inside its own file

    /// The scan that replaces a second XML parse.
    @Test("every element id is found, in markup order")
    func anchorsInOrder() {
        let markup = Data("""
        <html><body id="body">
          <h2 id="chap1">One</h2>
          <p><span id="chap1-s0">First.</span><span id="chap1-s1">Second.</span></p>
          <div data-id="not-an-id" aria-labelledby="chap1"><img id="plate"/></div>
        </body></html>
        """.utf8)
        let anchors = TVBookTimeline.anchors(in: markup)
        #expect(anchors.map(\.id) == ["body", "chap1", "chap1-s0", "chap1-s1", "plate"])
        // Offsets must climb, or "the first narrated id after this one" means
        // nothing.
        #expect(anchors.map(\.offset) == anchors.map(\.offset).sorted())
        #expect(TVBookTimeline.anchors(in: Data()).isEmpty)
        // An unterminated attribute is markup nobody can read; it must stop the
        // scan rather than run off the end of the buffer.
        #expect(TVBookTimeline.anchors(in: Data("<p id=\"open".utf8)).isEmpty)
        #expect(TVBookTimeline.anchors(in: Data("<p id='open".utf8)).isEmpty)
    }

    /// The bug: one byte was both the pattern's fourth character and the value
    /// terminator, so `id='chapter-3'` — which is what Sigil and Calibre write —
    /// matched nothing at all. Every chapter in such a file then failed to
    /// place, fell back to the file's own start and was collapsed onto one tick
    /// by `dedupe`: the "seventeen marks in three places" defect this whole path
    /// exists to prevent.
    @Test("an id in single quotes is an id")
    func singleQuotedIdsAreFound() {
        let markup = Data("""
        <html><body id='body'>
          <h2 id='chapter-3'>Three</h2>
          <p><span id='chapter-3-s0'>First.</span></p>
        </body></html>
        """.utf8)
        let anchors = TVBookTimeline.anchors(in: markup)
        #expect(anchors.map(\.id) == ["body", "chapter-3", "chapter-3-s0"])
        #expect(anchors.map(\.offset) == anchors.map(\.offset).sorted())
    }

    /// A hand-edited chapter dropped into a Sigil book is exactly how one file
    /// comes to carry both, and a scan that handled only one would place half
    /// the chapters and stack the rest.
    @Test("one file may quote its ids both ways")
    func mixedQuotingInOneFile() {
        let markup = Data("""
        <html><body>
          <h2 id='chap1'>One</h2>
          <h2 id="chap2">Two</h2>
          <h2 id='chap3'>Three</h2>
        </body></html>
        """.utf8)
        #expect(TVBookTimeline.anchors(in: markup).map(\.id) == ["chap1", "chap2", "chap3"])
    }

    /// The reason the terminator is whichever quote opened, rather than either
    /// of them: an apostrophe is an ordinary character inside a double-quoted
    /// attribute, and stopping on it would cut the id in half and place the
    /// chapter by an id no document contains.
    @Test("an apostrophe inside a double-quoted id is part of the id")
    func apostropheInsideADoubleQuotedID() {
        let markup = Data("<h2 id=\"it's-chapter-3\">Three</h2><p id='say \"no\"'>x</p>".utf8)
        #expect(TVBookTimeline.anchors(in: markup).map(\.id) == ["it's-chapter-3", "say \"no\""])
    }

    /// Over a real book's own markup: an anchor the file has is placed inside
    /// it, and an anchor it has not got is dropped.
    ///
    /// `?? 0` gave the missing one the top of the file, which reads as a real
    /// position — and since every unplaceable chapter in a file said the same
    /// thing, `dedupe` then stacked them into one mark.
    @Test("a chapter is placed inside its file, and one that cannot be is dropped")
    func chaptersArePlacedOrDropped() throws {
        let chapter = "OEBPS/6260297267691793459_11-h-1.htm.xhtml"
        let package = try Self.package(
            hrefs: [chapter, "OEBPS/toc.xhtml"],
            weights: [1, 1],
            navigation: [
                Self.nav("Down the Rabbit-Hole", chapter, fragment: "pgepubid00003"),
                Self.nav("Chapter One", chapter, fragment: "chap01"),
                Self.nav("Nowhere", chapter, fragment: "no-such-anchor"),
            ],
        )
        let ticks = TVBookTimeline.ticks(for: package, timeline: nil)
        try #require(ticks.count == 2)
        #expect(ticks.map(\.title) == ["Down the Rabbit-Hole", "Chapter One"])
        // Placed by where they sit in the markup, so they are two marks and not
        // one, and neither is parked on the file's own start.
        #expect(ticks[0].fraction > 0)
        #expect(ticks[0].fraction < ticks[1].fraction)
    }

    /// The bug behind three marks on a seventeen-chapter novel: a navigation
    /// entry names the heading, and a media overlay names the sentences under
    /// it, so the anchor itself is never on the tape.
    @Test("a chapter anchor is placed by the first narrated id after it")
    func chapterAnchorFindsItsSentence() {
        let anchors = [
            TVBookTimeline.Anchor(id: "chap1", offset: 10),
            TVBookTimeline.Anchor(id: "heading", offset: 40),
            TVBookTimeline.Anchor(id: "chap1-s0", offset: 90),
            TVBookTimeline.Anchor(id: "chap2", offset: 500),
            TVBookTimeline.Anchor(id: "chap2-s0", offset: 540),
        ]
        let narrated: Set<String> = ["chap1-s0", "chap2-s0"]
        #expect(TVBookTimeline.firstNarrated(
            atOrAfter: "chap1", in: anchors, isNarrated: { narrated.contains($0) }) == "chap1-s0")
        #expect(TVBookTimeline.firstNarrated(
            atOrAfter: "chap2", in: anchors, isNarrated: { narrated.contains($0) }) == "chap2-s0")
        // An anchor already narrated answers with itself.
        #expect(TVBookTimeline.firstNarrated(
            atOrAfter: "chap1-s0", in: anchors, isNarrated: { narrated.contains($0) }) == "chap1-s0")
        // Nothing to stand in for it, and nothing invented.
        #expect(TVBookTimeline.firstNarrated(
            atOrAfter: "chap2-s0", in: anchors, isNarrated: { $0 == "chap1-s0" }) == nil)
        #expect(TVBookTimeline.firstNarrated(
            atOrAfter: "nowhere", in: anchors, isNarrated: { _ in true }) == nil)
    }

    // MARK: - Reading the marks

    @Test("the current chapter is the last mark at or before the reader")
    func currentIndex() {
        let ticks = [
            TVBookTimeline.Tick(title: "One", fraction: 0),
            TVBookTimeline.Tick(title: "Two", fraction: 0.1),
            TVBookTimeline.Tick(title: "Three", fraction: 0.4),
        ]
        #expect(TVBookTimeline.currentIndex(in: ticks, fraction: 0) == 0)
        #expect(TVBookTimeline.currentIndex(in: ticks, fraction: 0.09) == 0)
        #expect(TVBookTimeline.currentIndex(in: ticks, fraction: 0.1) == 1)
        #expect(TVBookTimeline.currentIndex(in: ticks, fraction: 0.99) == 2)
        // Front matter belongs to the first chapter: "Chapter 0 of 17" is not
        // a thing to show anyone.
        #expect(TVBookTimeline.currentIndex(in: [TVBookTimeline.Tick(title: "One", fraction: 0.2)],
                                            fraction: 0.1) == 0)
        #expect(TVBookTimeline.currentIndex(in: [], fraction: 0.5) == nil)
        // A NaN is not a place in the book, and must not trap on the way in.
        #expect(TVBookTimeline.currentIndex(in: ticks, fraction: .nan) == 0)
    }

    // MARK: - Saying it in words

    @Test("the footer says the chapter, the percentage and what is left")
    func progressLineHasEveryPart() {
        let line = TVBookTimeline.progressLine(
            chapter: 12, count: 17, progress: 0.34, remaining: 3 * 3600 + 11 * 60,
        )
        #expect(line == "Chapter 12 of 17 · 34% · 3h 11m left")
    }

    /// Every part is dropped when the book cannot supply it, rather than shown
    /// empty or as a zero.
    @Test("parts the book has not got are left out")
    func progressLineDropsWhatIsMissing() {
        #expect(TVBookTimeline.progressLine(chapter: nil, count: 0, progress: 0.34, remaining: nil)
            == "34%")
        #expect(TVBookTimeline.progressLine(chapter: 1, count: 3, progress: 0.5, remaining: nil)
            == "Chapter 1 of 3 · 50%")
        #expect(TVBookTimeline.progressLine(chapter: nil, count: 3, progress: 0, remaining: 90)
            == "0% · 2m left")
        // A chapter number outside the count is a bug upstream, not a label.
        #expect(TVBookTimeline.progressLine(chapter: 9, count: 3, progress: 0.5, remaining: nil)
            == "50%")
    }

    @Test("a duration reads the way a person says it")
    func remainingText() {
        #expect(TVBookTimeline.remainingText(0) == "0m")
        // Rounded, not floored: fifty-nine seconds of a book left is a minute
        // of it, and this is the one number on the screen that says how much
        // book there is.
        #expect(TVBookTimeline.remainingText(59) == "1m")
        #expect(TVBookTimeline.remainingText(90) == "2m")
        #expect(TVBookTimeline.remainingText(11 * 60) == "11m")
        #expect(TVBookTimeline.remainingText(3600) == "1h 0m")
        #expect(TVBookTimeline.remainingText(4271) == "1h 11m")
        // Not a crash and not "nan m".
        #expect(TVBookTimeline.remainingText(.nan) == "0m")
        #expect(TVBookTimeline.remainingText(-5) == "0m")
        #expect(TVBookTimeline.remainingText(.infinity) == "0m")
        // The one the copy of this helper got wrong, and the reason it is gone:
        // `totalDuration` comes off the wire, `1e300` is finite, and
        // `Int((1e300 / 60).rounded())` traps rather than returning a number.
        #expect(TVBookTimeline.remainingText(1e300) == "0m")
    }

    // MARK: - Drawing the marks

    /// The ticks were clamped by their extent and the marker was not: `place`
    /// was held to 0…1 and then used as a *centre*, so at progress 0 — where
    /// every newly opened book starts — half of a twenty point disc was drawn
    /// off the left of the strip, inside the television's overscan band.
    @Test("a mark is drawn wholly inside the strip, wherever it belongs")
    func marksAreClampedIntoTheStrip() {
        let strip: CGFloat = 1_000
        let disc: CGFloat = 20
        // The newly opened book. Not -10.
        #expect(TVBookTimeline.markOrigin(centredOn: 0, width: disc, in: strip) == 0)
        // The finished one. The unclamped arithmetic put the disc at 990…1010,
        // with its right half off the end of the strip.
        #expect(TVBookTimeline.markOrigin(centredOn: strip, width: disc, in: strip) == 980)
        // Anywhere the clamp is not needed, it does nothing.
        #expect(TVBookTimeline.markOrigin(centredOn: 500, width: disc, in: strip) == 490)
        #expect(TVBookTimeline.markOrigin(centredOn: 10, width: disc, in: strip) == 0)
        // A hairline tick is clamped by the same arithmetic, which is where it
        // came from.
        #expect(TVBookTimeline.markOrigin(centredOn: 0, width: 1.5, in: strip) == 0)
        #expect(TVBookTimeline.markOrigin(centredOn: strip, width: 1.5, in: strip) == 998.5)
        // A strip narrower than the mark cannot happen on a television, but
        // `strip - width` alone answers it with a negative origin — further
        // outside than no clamp at all.
        #expect(TVBookTimeline.markOrigin(centredOn: 5, width: disc, in: 10) == 0)
    }
}
