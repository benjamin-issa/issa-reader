import Foundation
import IssaCore
import IssaEPUB
import IssaRender
import Testing

@testable import IssaReader_iOS

/// Where a stored highlight is drawn, when the chapter is no longer exactly the
/// chapter it was marked in.
///
/// A highlight is saved with the offset of its own first character. That offset
/// is only as stable as the rendered text, and the renderer does change: on
/// 2026-09-17 it stopped keeping the space that pretty-printed markup leaves
/// between two blocks, which moved every character in every chapter by one per
/// paragraph above it. Reading positions have re-anchored by their quoted text
/// for as long as they have existed; highlights were painted from the stored
/// integer alone, so every one of them would have been drawn a word or so off.
@Suite("Re-anchoring a highlight")
@MainActor
struct HighlightAnchoringTests {
    func annotation(excerpt: String, offset: Int?, before: String? = nil) -> Annotation {
        Annotation(
            bookUUID: "b", kind: .highlight,
            locator: ReadiumLocator(
                href: "ch01.xhtml", type: "application/xhtml+xml",
                locations: .init(progression: 0.1, totalProgression: 0.1, charOffset: offset),
                text: before.map { ReadiumLocator.Text(before: $0, highlight: excerpt) },
            ),
            excerpt: excerpt)
    }

    /// Where the mark is found, by the function `anchorAnnotations` calls.
    func anchored(_ annotation: Annotation, in text: NSString) -> Int? {
        ReaderModel.anchoredRange(of: annotation, in: text as String)?.location
    }

    /// The ordinary case, and the one that must stay cheap: nothing has moved,
    /// so the stored offset is taken as it stands.
    @Test("an offset that still names its own words is used as it is")
    func exactHit() {
        let text = "The Wart was the youngest, and the least considered." as NSString
        let found = anchored(annotation(excerpt: "youngest", offset: 17), in: text)
        #expect(found == 17)
        #expect(text.substring(with: NSRange(location: found!, length: 8)) == "youngest")
    }

    @Test("an offset the text has moved under finds its words again")
    func shiftedText() throws {
        // Two characters inserted ahead of the mark, which is what removing a
        // stray space from each paragraph above it does in reverse.
        let text = "  The Wart was the youngest, and the least considered." as NSString
        let found = try #require(anchored(annotation(excerpt: "youngest", offset: 17), in: text))
        #expect(found == 19)
        #expect(text.substring(with: NSRange(location: found, length: 8)) == "youngest")
    }

    /// A reader highlights a phrase that occurs twice; the mark belongs to the
    /// copy they marked, not to the first one in the chapter.
    @Test("a phrase that occurs twice resolves to the nearer occurrence")
    func nearestOccurrence() {
        let text = "he said nothing. She waited. he said nothing again." as NSString
        // The two copies sit at 0 and 29; a mark recorded near either resolves
        // to that one rather than to whichever comes first in the chapter.
        #expect(anchored(annotation(excerpt: "he said nothing", offset: 27), in: text) == 29)
        #expect(anchored(annotation(excerpt: "he said nothing", offset: 2), in: text) == 0)
    }

    /// The chapter genuinely no longer contains the marked words — a different
    /// edition, or a publisher's re-export. Better to fall back to the stored
    /// offset than to paint the highlight somewhere arbitrary.
    @Test("words the chapter no longer holds fall back to the stored offset")
    func excerptGone() {
        let text = "Nothing here resembles the mark." as NSString
        #expect(anchored(annotation(excerpt: "a phrase from another book", offset: 7), in: text) == 7)
    }

    @Test("a mark with no offset and no match is nothing to draw")
    func nothingToGoOn() {
        let text = "Nothing here resembles the mark." as NSString
        #expect(anchored(annotation(excerpt: "absent", offset: nil), in: text) == nil)
        #expect(anchored(annotation(excerpt: "", offset: nil), in: text) == nil)
    }

    // MARK: - Words across a paragraph break, and words too short to trust

    /// C-08. `annotate` stores the chapter's newlines as spaces, and the search
    /// was a literal one — so a selection across a paragraph break, which
    /// VoiceOver's whole-page highlight makes on nearly every page, never found
    /// its words and was painted at its stored offset however stale.
    @Test("a highlight across a paragraph break is found where it is now")
    func acrossAParagraphBreak() throws {
        let text = "The first paragraph ends here.\nThe second one begins now." as NSString
        let truth = text.range(of: "ends here").location
        // As `annotate` stores it, made three characters further up the page.
        let mark = annotation(excerpt: "ends here. The second", offset: truth + 3)

        let found = try #require(ReaderModel.anchoredRange(of: mark, in: text as String))
        #expect(found.location == truth)
        #expect(text.substring(with: found) == "ends here.\nThe second")
    }

    /// The same, made under the old renderer: two spaces in the excerpt where
    /// the chapter now has one newline. Painted from its start for the
    /// excerpt's length, it would run a character into the next word.
    @Test("a highlight made under the old renderer is painted over its own words, not past them")
    func oldDoubleSpace() throws {
        let text = "The first paragraph ends here.\nThe second one begins now." as NSString
        let truth = text.range(of: "ends here").location
        let excerpt = "ends here.  The second"
        let mark = annotation(excerpt: excerpt, offset: truth + 1)

        let found = try #require(ReaderModel.anchoredRange(of: mark, in: text as String))
        #expect(found.location == truth)
        #expect(found.length == (excerpt as NSString).length - 1)
    }

    /// A one-word mark, twelve paragraphs down, made under the old renderer:
    /// its offset is twelve characters late, and the next "the" along is nearer
    /// to that than the one marked. The words stored before it say which it was.
    @Test("a one-word highlight lands on the word that was marked, not the nearest copy")
    func oneWordMark() throws {
        let paragraphs = (1 ... 12).map { "Line \($0)." } + ["In the hall the dog slept, then woke."]
        let text = paragraphs.joined(separator: "\n") as NSString
        let old = paragraphs.joined(separator: "\n ") as NSString
        let marked = old.range(of: "the hall").location
        let before = old.substring(with: NSRange(location: marked - 32, length: 32))
            .replacingOccurrences(of: "\n", with: " ")

        let found = try #require(ReaderModel.anchoredRange(
            of: annotation(excerpt: "the", offset: marked, before: before), in: text as String))
        #expect(found == NSRange(location: text.range(of: "the hall").location, length: 3))
    }

    // MARK: - Opening a mark, and finding a bookmark, on the page it is on

    /// Sixty short paragraphs, each a sentence with an id of its own as a
    /// read-along has them — enough paragraph breaks that the old renderer's
    /// offset for a place near the foot of a page is on the next one. Every
    /// few words carry the paragraph's number, so any stretch of the chapter
    /// long enough to quote occurs in it once.
    static let longChapter = TestEPUB.Chapter(
        id: "long", title: "A Long Chapter",
        body: (0 ..< 60).map { n in
            "<p><span id=\"s\(n)\">Paragraph \(n) holds mark \(n), word \(n), line \(n) and end \(n).</span></p>"
        }.joined())
    static let pageSize = CGSize(width: 300, height: 400)

    static func model() async throws -> ReaderModel {
        let model = ReaderModel(
            book: SharedFixtures.book("Marks", uuid: "highlight-anchoring-uuid"),
            session: Session(
                serverURL: URL(string: "https://library.example")!,
                keychain: AnchoringTokens(),
                session: URLSession(configuration: .ephemeral)))
        // A jump saves, and a save with nowhere to go would go to the network.
        model.enqueuePosition = { _, _, _ in true }
        model.package = try TestEPUB.package(chapters: [longChapter])
        // `resize` before `go`: it records the page size, and its own relayout
        // is a no-op while there is no layout yet.
        await model.resize(to: pageSize)
        await model.go(toChapter: 0)
        return model
    }

    /// The chapter as the old renderer laid it out: a space after every
    /// newline. An offset into this is what a mark made then recorded.
    static func oldRendering(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\n ")
    }

    /// A word whose old offset — one character late for every paragraph break
    /// above it — is on the page after the one it is on.
    static func placeWhoseOldOffsetIsOnTheNextPage(
        in layout: ChapterLayout,
    ) -> (truth: Int, old: Int, page: Int)? {
        let text = layout.attributedText.string as NSString
        var breaks = 0
        for index in 0 ..< text.length {
            let unit = text.character(at: index)
            if unit == 10 { breaks += 1; continue }
            guard index > 0, text.character(at: index - 1) == 32,
                  let scalar = Unicode.Scalar(unit), scalar.properties.isAlphabetic
            else { continue }
            let old = index + breaks
            guard old < text.length,
                  let here = layout.pages.first(where: { NSLocationInRange(index, $0.characterRange) }),
                  let there = layout.pages.first(where: { NSLocationInRange(old, $0.characterRange) }),
                  there.index == here.index + 1
            else { continue }
            return (index, old, here.index)
        }
        return nil
    }

    /// C-07. The mark is painted on its own page — the paint has re-anchored
    /// since 1.3.0 — but the marks list opened the page its stale offset
    /// named, the one after, with nothing marked on it, and saved that as the
    /// reader's own choice.
    @Test("a mark made under the old renderer opens on the page it is painted on")
    func aStaleMarkOpensOnItsOwnPage() async throws {
        let model = try await Self.model()
        let layout = try #require(model.layout)
        let (truth, old, page) = try #require(Self.placeWhoseOldOffsetIsOnTheNextPage(in: layout))
        let text = layout.attributedText.string as NSString
        let excerpt = text.substring(with: NSRange(location: truth, length: 24))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mark = Annotation(
            bookUUID: "highlight-anchoring-uuid", kind: .highlight,
            locator: ReadiumLocator(
                href: TestEPUB.href(of: Self.longChapter), type: "application/xhtml+xml",
                locations: .init(charOffset: old),
                text: LocatorAnchoring.quote(
                    from: Self.oldRendering(text as String), at: old, length: 24)),
            excerpt: excerpt)
        model.loadAnnotations([mark])
        #expect(!model.highlightBlocks(on: layout.pages[page]).isEmpty,
                "the mark is drawn on the page its words are on")
        model.pageIndex = layout.pages.count - 1

        await model.go(to: mark)

        #expect(model.pageIndex == page, "and the marks list opens that page, not the one after")
    }

    /// C-07's other half. A bookmark was matched to a page by its stored offset
    /// alone, so one made under the old renderer showed on the page after its
    /// own — and tapping the button on its own page added a second.
    @Test("a bookmark made under the old renderer is on its own page, and the toggle there removes it")
    func aStaleBookmarkIsOnItsOwnPage() async throws {
        let model = try await Self.model()
        let layout = try #require(model.layout)
        let (truth, old, page) = try #require(Self.placeWhoseOldOffsetIsOnTheNextPage(in: layout))
        let oldText = Self.oldRendering(layout.attributedText.string)
        // What `locator(forRange:)` wrote for it: the sentence under its first
        // character, its offset, and the first eighty characters from there.
        let sentence = layout.attributedText
            .attribute(.issaFragmentID, at: truth, effectiveRange: nil) as? String
        let quote = try #require(LocatorAnchoring.quote(from: oldText, at: old, length: 80))
        let bookmark = Annotation(
            bookUUID: "highlight-anchoring-uuid", kind: .bookmark,
            locator: ReadiumLocator(
                href: TestEPUB.href(of: Self.longChapter), type: "application/xhtml+xml",
                locations: .init(
                    fragments: sentence.map { [$0] },
                    progression: Double(old) / Double((oldText as NSString).length),
                    charOffset: old),
                text: quote),
            excerpt: quote.highlight ?? "")
        model.loadAnnotations([bookmark])

        model.pageIndex = page
        #expect(model.isPageBookmarked, "the page the bookmark's words are on carries it")
        model.pageIndex = page + 1
        #expect(!model.isPageBookmarked, "and the page after does not")

        model.pageIndex = page
        model.toggleBookmark()
        #expect(model.annotations.isEmpty, "the toggle on its own page removes it, not adds a second")
    }

    /// The toggle on a page bookmarked this session, so the anchoring cannot
    /// have made a fresh bookmark harder to find than a stale one.
    @Test("a bookmark made now is on the page it was made on")
    func aFreshBookmarkIsOnItsPage() async throws {
        let model = try await Self.model()
        let layout = try #require(model.layout)
        try #require(layout.pages.count > 3, "the chapter has to run to several pages")
        for page in [1, 2, layout.pages.count - 1] {
            model.pageIndex = page
            #expect(!model.isPageBookmarked)
            model.toggleBookmark()
            #expect(model.isPageBookmarked, "page \(page) carries the bookmark just made")
            model.pageIndex = page - 1
            #expect(!model.isPageBookmarked, "and page \(page - 1) does not")
            model.pageIndex = page
            model.toggleBookmark()
            #expect(model.annotations.isEmpty)
        }
    }
}

/// Per file, as every other suite in here keeps it.
private final class AnchoringTokens: TokenPersisting, @unchecked Sendable {
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
