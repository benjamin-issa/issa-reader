import Foundation
import IssaRender
import Testing

@testable import IssaReader_iOS

/// The Page turn choice: Slide unless the reader picked otherwise, kept across
/// launches, and costing the open book nothing when it changes.
@Suite("The page turn setting", .serialized)
@MainActor
struct PageTurnSettingTests {
    private func withSuite(_ body: (String) -> Void) {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        body(suite)
    }

    @Test("a reader who never chose gets Slide")
    func slideByDefault() {
        withSuite { suite in
            #expect(PlaybackSettings(suiteName: suite).pageTurn == .slide)
        }
    }

    /// A value this build does not know — written by a later one, say — is no
    /// reason to turn the animation off.
    @Test("a stored value this build cannot read is Slide too")
    func unknownIsSlide() {
        withSuite { suite in
            UserDefaults(suiteName: suite)?.set("curl", forKey: "issa.pageTurn")
            #expect(PlaybackSettings(suiteName: suite).pageTurn == .slide)
        }
    }

    @Test("the choice is the choice a relaunch restores", arguments: PageTurnStyle.allCases)
    func persists(style: PageTurnStyle) {
        withSuite { suite in
            let settings = PlaybackSettings(suiteName: suite)
            settings.pageTurn = style
            #expect(PlaybackSettings(suiteName: suite).pageTurn == style)
        }
    }

    /// Kept out of the reading style on purpose: a change there re-paginates
    /// the open book.
    @Test("changing it leaves the reading style alone")
    func notAStyle() {
        withSuite { suite in
            let settings = PlaybackSettings(suiteName: suite)
            let style = settings.readerStyle
            settings.pageTurn = .cover
            #expect(settings.readerStyle == style)
            #expect(PlaybackSettings(suiteName: suite).readerStyle == style)
        }
    }
}

/// Where a turn past the end of a chapter lands — the rule the page turn and
/// the neighbouring-chapter prefetch both walk.
@Suite("Walking to the next chapter")
@MainActor
struct ChapterWalkTests {
    typealias Attempt = ChapterWalk.Attempt

    /// Walks a spine whose chapters are as given, from `start`.
    private func walk(_ chapters: [Attempt], from start: Int, step: Int = 1) async -> (ChapterWalk.Landing, [Int]) {
        var tried: [Int] = []
        let landing = await ChapterWalk.walk(from: start, step: step, spineCount: chapters.count) { index in
            tried.append(index)
            return chapters[index]
        }
        return (landing, tried)
    }

    @Test("it stops on the first chapter with something on it")
    func firstContent() async {
        let (landing, tried) = await walk([.content, .empty, .empty, .content, .content], from: 1)
        #expect(landing == ChapterWalk.Landing(chapter: 3, skipped: []))
        #expect(tried == [1, 2, 3])
    }

    @Test("it steps over a chapter that will not open, and names it")
    func stepsOverUnreadable() async {
        let (landing, _) = await walk([.content, .unreadable, .content], from: 1)
        #expect(landing == ChapterWalk.Landing(chapter: 2, skipped: [1]))
    }

    @Test("backwards, the same")
    func backwards() async {
        let (landing, tried) = await walk([.content, .unreadable, .empty, .content], from: 2, step: -1)
        #expect(landing == ChapterWalk.Landing(chapter: 0, skipped: [1]))
        #expect(tried == [2, 1, 0])
    }

    /// Nine empty chapters in a row: the walk tries eight, and lands on the
    /// last of them rather than nowhere.
    @Test("it gives up after eight, on the last one that opened")
    func limit() async {
        let chapters: [Attempt] = [.content] + Array(repeating: .empty, count: 9) + [.content]
        let (landing, tried) = await walk(chapters, from: 1)
        #expect(tried == Array(1 ... 8))
        #expect(landing == ChapterWalk.Landing(chapter: 8, skipped: []))
    }

    @Test("eight chapters that will not open land nowhere")
    func nowhere() async {
        let chapters: [Attempt] = [.content] + Array(repeating: .unreadable, count: 8) + [.content]
        let (landing, _) = await walk(chapters, from: 1)
        #expect(landing.chapter == nil)
        #expect(landing.skipped == Array(1 ... 8))
    }

    @Test("it stops at the end of the book")
    func spineEnd() async {
        let (landing, tried) = await walk([.content, .empty, .empty], from: 1)
        #expect(tried == [1, 2])
        #expect(landing == ChapterWalk.Landing(chapter: 2, skipped: []))
    }

    @Test("a walk that is no longer wanted stops at once and lands nowhere")
    func abandoned() async {
        let (landing, tried) = await walk([.content, .unreadable, .abandoned, .content], from: 1)
        #expect(tried == [1, 2])
        #expect(landing.abandoned)
        #expect(landing.chapter == nil)
    }

    @Test("a plate is content; whitespace is not")
    func emptiness() {
        #expect(ChapterWalk.isEmpty("  \n "))
        #expect(ChapterWalk.isEmpty("abc"))
        #expect(!ChapterWalk.isEmpty("\u{FFFC}"))
        #expect(!ChapterWalk.isEmpty("Once"))
    }
}
