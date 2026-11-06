import Foundation
import IssaCore
import IssaEPUB
import IssaRender
import Testing

@testable import IssaPlayback
@testable import IssaReader_iOS

/// Two pages side by side: iPhone Duo's inner display held wide (1.6.0).
///
/// The left page is the position, as the one page is everywhere else, so a
/// spread moves the reader exactly as far as the pages it shows and saves
/// what one page would. With one page shown every path here is 1.5.2's.
@Suite("Two pages side by side", .serialized)
@MainActor
struct SpreadPagingTests {
    static let pageSize = CGSize(width: 320, height: 300)

    /// Forty narrated sentences, one to a paragraph, then a plain chapter of
    /// the same length: several pages each at this size.
    static func opened(
        pagesShown: Int, sentenceLength: Int = 1,
    ) async throws -> (model: ReaderModel, directory: URL) {
        func paragraphs(_ prefix: String, narrated: Bool) -> String {
            (0 ..< 40).map { index in
                let sentence = "Sentence \(index) of the \(prefix) chapter, long enough to take a line or two of the page."
                let text = String(repeating: sentence + " ", count: sentenceLength)
                return narrated ? "<p><span id=\"\(prefix)\(index)\">\(text)</span></p>" : "<p>\(text)</p>"
            }.joined()
        }
        let model = ReaderModel(
            book: SharedFixtures.book("Spread", uuid: "spread-paging-uuid"),
            session: Session(
                serverURL: URL(string: "https://library.example")!,
                keychain: SpreadTokens(),
                session: URLSession(configuration: .ephemeral)))
        model.enqueuePosition = { _, _, _ in true }
        model.package = try TestEPUB.package(
            chapters: [
                TestEPUB.Chapter(
                    id: "one", title: "One", body: paragraphs("a", narrated: true),
                    narrated: (0 ..< 40).map { "a\($0)" }),
                TestEPUB.Chapter(id: "two", title: "Two", body: paragraphs("b", narrated: false)),
            ],
            audio: SilentAudio.wav(seconds: 40))
        let package = try #require(model.package)
        let timeline = SMILParser.timeline(for: package)
        model.pagesShown = pagesShown
        await model.resize(to: pageSize)
        await model.go(toChapter: 0)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-spread-\(UUID().uuidString)")
        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "spread-paging", into: directory)
        model.attachNarration(timeline: timeline, audioFiles: files)
        let readalong = try #require(model.readalong)
        readalong.player.onTimeUpdate = nil
        readalong.player.onFinishedFile = nil
        return (model, directory)
    }

    /// What closing iPhone Duo does to the page, as the app logged it: a run
    /// of layouts in under a second, none of them the reader's, while the
    /// window, the insets and the pages shown arrive one at a time. Ending
    /// where it began, so that the place can be asked for exactly.
    static let settling: [(size: CGSize, shown: Int)] = [
        (CGSize(width: 640, height: 300), 1),
        (CGSize(width: 250, height: 310), 1),
        (CGSize(width: 300, height: 290), 1),
        (CGSize(width: 660, height: 280), 1),
        (CGSize(width: 660, height: 240), 1),
        (CGSize(width: 280, height: 260), 2),
        (pageSize, 2),
    ]

    static func settle(_ model: ReaderModel) async {
        for step in settling {
            model.pagesShown = step.shown
            await model.resize(to: step.size)
        }
    }

    /// Each layout snapped to the start of the page holding the place, and
    /// that start became the next layout's place, so a close and an open
    /// walked the reader back to the top of the chapter.
    @Test("a page size settling through several layouts keeps the place")
    func settlingKeepsThePlace() async throws {
        let (model, directory) = try await Self.opened(pagesShown: 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        try #require(model.pageCount >= 5, "the chapter has to run to several spreads")
        await model.nextPage()
        await model.nextPage()
        let page = try #require(model.currentPage)

        await Self.settle(model)

        #expect(model.pageIndex == page.index)
        #expect(model.currentPage?.characterRange.location == page.characterRange.location)
    }

    /// The place held through a settling is the reader's until they move it.
    @Test("a turn after a layout settled is the place the next one keeps")
    func aTurnMovesThePlace() async throws {
        let (model, directory) = try await Self.opened(pagesShown: 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        try #require(model.pageCount >= 5, "the chapter has to run to several spreads")
        await model.nextPage()
        await Self.settle(model)
        await model.nextPage()
        let page = try #require(model.currentPage)

        await Self.settle(model)

        #expect(model.pageIndex == page.index)
    }

    /// A chapter of its own has offsets of its own.
    @Test("another chapter does not inherit the place held in the last one")
    func anotherChapter() async throws {
        let (model, directory) = try await Self.opened(pagesShown: 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.nextPage()
        await Self.settle(model)
        await model.go(toChapter: 1)
        #expect(model.pageIndex == 0)

        await Self.settle(model)

        #expect(model.pageIndex == 0)
        #expect(model.chapterIndex == 1)
    }

    /// An anchor past every page's range is at the end of the chapter, not
    /// the top of it. `computePages` can end a chapter on a page of no
    /// characters, whose location is in no range, and a reflow used to send
    /// that reader to the first page. The parser trims trailing newlines, so
    /// no chapter it makes ends that way today, which is why this asks the
    /// rule itself rather than building one.
    @Test("an anchor at the end of a chapter is on its last page, and the rest on their own")
    func anchorAtTheEnd() async throws {
        let (model, directory) = try await Self.opened(pagesShown: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let layout = try #require(model.layout)
        let last = try #require(layout.pages.last)
        try #require(layout.pages.count >= 3)
        let middle = layout.pages[layout.pages.count / 2]

        #expect(ReaderModel.pageIndex(holding: 0, in: layout) == 0)
        #expect(ReaderModel.pageIndex(holding: middle.characterRange.location, in: layout) == middle.index)
        #expect(ReaderModel.pageIndex(holding: NSMaxRange(last.characterRange), in: layout) == last.index)
    }

    /// A style change lays the chapter out again and lands on a page number
    /// of its own. If that number is the one a reflow left, the place held
    /// from before the change would be taken for the reader's.
    @Test("a reload does not inherit the place held before it")
    func aReloadClearsTheHeldPlace() async throws {
        let (model, directory) = try await Self.opened(pagesShown: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        try #require(model.pageCount >= 4, "the chapter has to run to several pages")
        await model.nextPage()
        await model.nextPage()
        await model.resize(to: CGSize(width: Self.pageSize.width, height: Self.pageSize.height + 30))
        let heldPage = model.pageIndex
        let heldWords = try #require(model.currentPage).characterRange.location

        // Bigger type, so the words held are on a later page than they were.
        let revision = model.layoutRevision
        var style = model.style
        style.fontSize *= 2
        model.style = style
        try #require(await waitUntil { model.layoutRevision != revision })
        // And the reader on the page number the reflow left, which is all the
        // held place is keyed to.
        model.pageIndex = heldPage
        let page = try #require(model.currentPage)
        try #require(!NSLocationInRange(heldWords, page.characterRange),
                     "the held words have to have moved off this page for this to test anything")

        await model.resize(to: CGSize(width: Self.pageSize.width, height: Self.pageSize.height + 31))

        let after = try #require(model.currentPage)
        #expect(NSLocationInRange(page.characterRange.location, after.characterRange))
    }

    /// The page drawn after a layout that kept the page number was the one
    /// from before it: blank on the Duo's outer display, and short of its last
    /// lines on the spread, with the words below them never shown. No
    /// accessibility query can see a canvas, so this asks what SwiftUI asks.
    @Test("a layout that keeps the page number still redraws the pages", arguments: [1, 2])
    func sameNumberNewLayout(pagesShown: Int) async throws {
        let (model, directory) = try await Self.opened(pagesShown: pagesShown)
        defer { try? FileManager.default.removeItem(at: directory) }
        try #require(model.pageIndex == 0)
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        let before = model.currentSnapshot()
        withObservationTracking {
            _ = model.currentSnapshot()
            _ = model.facingSnapshot()
        } onChange: {
            flag.fired = true
        }

        await model.resize(to: CGSize(width: Self.pageSize.width, height: Self.pageSize.height - 20))

        #expect(model.pageIndex == 0, "the page number has to be what stayed the same")
        #expect(flag.fired, "nothing told the page to draw again")
        #expect(model.currentSnapshot()?.revision != before?.revision)
    }

    /// With no voice to bound it, Ask stops at the end of what is on screen.
    /// It stopped at the left page, so the right page's text was out of every
    /// answer on a spread, however long the reader had been looking at it.
    @Test("Ask reads as far as the right page of a spread")
    func askReadsTheRightPage() async throws {
        let (model, directory) = try await Self.opened(pagesShown: 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        let layout = try #require(model.layout)
        let left = try #require(model.currentPage)
        let right = try #require(model.facingPage)

        let boundary = try #require(model.readingBoundary())

        #expect(boundary.charOffset == NSMaxRange(layout.paintedCharacterRange(for: right)))
        #expect(boundary.charOffset > NSMaxRange(layout.paintedCharacterRange(for: left)))
        #expect(boundary.pageNumber == 2)
    }

    /// The footer names the page the boundary is on, and with the voice on
    /// the right page of a spread that is not the left one.
    @Test("Ask numbers the voice's page on a spread")
    func askNumbersTheVoicesPage() async throws {
        let (model, directory) = try await Self.opened(pagesShown: 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readalong = try #require(model.readalong)
        let layout = try #require(model.layout)
        let right = try #require(model.facingPage)
        let onRight = try #require(
            (0 ..< 40).map { "a\($0)" }.first { layout.page(containingFragment: $0)?.index == right.index })
        let href = TestEPUB.href(of: TestEPUB.Chapter(id: "one", title: "", body: ""))
        await readalong.seek(toFragment: onRight, inDocument: href)
        readalong.player.play()
        defer { readalong.player.pause() }

        let boundary = try #require(model.readingBoundary())

        #expect(boundary.kind == .narratedSentence)
        #expect(boundary.pageNumber == right.index + 1)
    }

    /// The offset is the sentence's end, so a number taken from its start named
    /// the page before the one the offset is on.
    @Test("Ask numbers the page a sentence crossing a break ends on")
    func askNumbersTheSentencesLastPage() async throws {
        let (model, directory) = try await Self.opened(pagesShown: 1, sentenceLength: 8)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readalong = try #require(model.readalong)
        let layout = try #require(model.layout)
        func lastPage(_ range: NSRange) -> Int? { layout.page(containingOffset: NSMaxRange(range) - 1)?.index }
        let crossing = try #require((0 ..< 40).map { "a\($0)" }.first { fragment in
            guard let range = layout.fragmentRange(for: fragment) else { return false }
            return layout.page(containingOffset: range.location)?.index != lastPage(range)
        })
        let range = try #require(layout.fragmentRange(for: crossing))
        let last = try #require(lastPage(range))
        let href = TestEPUB.href(of: TestEPUB.Chapter(id: "one", title: "", body: ""))
        await readalong.seek(toFragment: crossing, inDocument: href)
        readalong.player.play()
        defer { readalong.player.pause() }

        #expect(model.readingBoundary()?.pageNumber == last + 1)
    }

    @Test("Ask stops at the end of a single page when one is shown")
    func askReadsOnePage() async throws {
        let (model, directory) = try await Self.opened(pagesShown: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let layout = try #require(model.layout)
        let page = try #require(model.currentPage)

        let boundary = try #require(model.readingBoundary())

        #expect(boundary.charOffset == NSMaxRange(layout.paintedCharacterRange(for: page)))
        #expect(boundary.pageNumber == 1)
    }

    @Test("a spread turns two pages, and back two")
    func turnsByTwo() async throws {
        let (model, directory) = try await Self.opened(pagesShown: 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        try #require(model.pageCount >= 5, "the chapter has to run to several spreads")
        #expect(model.facingPage?.index == 1)

        await model.nextPage()
        #expect(model.pageIndex == 2)
        #expect(model.facingPage?.index == 3)
        await model.previousPage()
        #expect(model.pageIndex == 0)
        #expect(model.chapterIndex == 0)
    }

    @Test("one page shown turns one page, as it always has")
    func onePageTurnsByOne() async throws {
        let (model, directory) = try await Self.opened(pagesShown: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(model.facingPage == nil)
        await model.nextPage()
        #expect(model.pageIndex == 1)
        await model.previousPage()
        #expect(model.pageIndex == 0)
        #expect(model.progressText.contains("–") == false)
    }

    @Test("the last spread of a chapter turns into the next, and back onto that spread")
    func crossesChaptersBySpread() async throws {
        let (model, directory) = try await Self.opened(pagesShown: 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        let count = model.pageCount
        while model.chapterIndex == 0 { await model.nextPage() }
        #expect(model.chapterIndex == 1)
        #expect(model.pageIndex == 0)

        await model.previousPage()
        #expect(model.chapterIndex == 0)
        #expect(model.pageIndex == max(count - 2, 0), "back onto the chapter's last two pages")
        #expect(model.facingPage?.index == count - 1)
    }

    @Test("the footer counts both pages, and the left alone where it stands alone")
    func countsBothPages() async throws {
        let (model, directory) = try await Self.opened(pagesShown: 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        var style = model.style
        style.progressDisplay = .chapterPage
        model.style = style
        let count = model.pageCount
        #expect(model.progressText == "1–2 / \(count)")
        #expect(model.spokenPagePosition.hasPrefix("Pages 1 and 2 of \(count)"))
        model.pageIndex = count - 1
        #expect(model.facingPage == nil)
        #expect(model.progressText == "\(count) / \(count)")
    }

    @Test("a spread saves the left page, as one page would")
    func savesTheLeftPage() async throws {
        var saved: [Int: ReadiumLocator] = [:]
        for shown in [1, 2] {
            let (model, directory) = try await Self.opened(pagesShown: shown)
            defer { try? FileManager.default.removeItem(at: directory) }
            model.enqueuePosition = { locator, _, _ in
                saved[shown] = locator
                return true
            }
            model.pageIndex = 2
            model.cancelPendingSave()
            await model.saveProgress()
        }
        let one = try #require(saved[1])
        let two = try #require(saved[2])
        #expect(one.href == two.href)
        #expect(one.locations?.charOffset == two.locations?.charOffset)
        #expect(one.locations?.fragments == two.locations?.fragments)
    }

    @Test("narration on the right page leaves the spread; past it, the voice's page becomes the left")
    func narrationFollowsBySpread() async throws {
        let (model, directory) = try await Self.opened(pagesShown: 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readalong = try #require(model.readalong)
        let layout = try #require(model.layout)
        let href = TestEPUB.href(of: TestEPUB.Chapter(id: "one", title: "", body: ""))
        func sentence(on page: Int) -> String? {
            (0 ..< 40).map { "a\($0)" }.first { layout.page(containingFragment: $0)?.index == page }
        }

        let onRight = try #require(sentence(on: 1))
        await readalong.seek(toFragment: onRight, inDocument: href)
        #expect(model.pageIndex == 0, "the spread turned for a sentence already on screen")

        let beyond = try #require(sentence(on: 3))
        await readalong.seek(toFragment: beyond, inDocument: href)
        #expect(model.pageIndex == 3, "the voice's page did not come to the left")
    }

    @Test("a selection made on the right page is that page's text")
    func selectsOnTheRightPage() async throws {
        let (model, directory) = try await Self.opened(pagesShown: 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        let facing = try #require(model.facingPage)
        model.beginSelection(at: CGPoint(x: 40, y: 12), facing: true)
        let selection = try #require(model.selection)
        #expect(NSIntersectionRange(selection, facing.characterRange).length > 0)
        #expect(model.currentPage.map { NSIntersectionRange(selection, $0.characterRange).length } == 0)
        // And it is still the reader's on screen, so a turn's tidy-up keeps it.
        model.clearSelectionIfStale()
        #expect(model.selection != nil)
    }
}

/// Per file, as every other suite in here keeps it.
private final class SpreadTokens: TokenPersisting, @unchecked Sendable {
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
