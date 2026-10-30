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
    static func opened(pagesShown: Int) async throws -> (model: ReaderModel, directory: URL) {
        func paragraphs(_ prefix: String, narrated: Bool) -> String {
            (0 ..< 40).map { index in
                let text = "Sentence \(index) of the \(prefix) chapter, long enough to take a line or two of the page."
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
