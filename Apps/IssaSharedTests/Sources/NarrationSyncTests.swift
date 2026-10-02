import Foundation
import IssaCore
import IssaEPUB
import IssaPlayback
import Testing

@testable import IssaReader_iOS

/// Coming back to a book whose voice was paused.
///
/// The reader screen re-syncs to the narration every time it appears, for the
/// listener who left the book playing and came back an hour later. It keyed on
/// the sentence the voice was on — and a pause keeps that sentence, and the
/// app keeps a paused book's model while the reader is away. So a reader who
/// paused, read on silently, went to the library and came back was turned back
/// to the paused sentence with nothing said, and the next page turn saved that
/// older place over the one they had reached.
@Suite("Coming back to a book whose voice was paused")
@MainActor
struct NarrationSyncTests {
    private final class BundleMarker {}

    static let chapterOne = "OEBPS/ch01.xhtml"

    /// The read-along fixture, open at chapter one with its narration hooked
    /// up, the voice paused on chapter one's first sentence, and the reader
    /// read on silently into chapter two.
    static func pausedAndReadOn() async throws -> (model: ReaderModel, directory: URL) {
        let model = ReaderModel(
            book: SharedFixtures.book("Fixture", uuid: "narration-sync-uuid"),
            session: Session(
                serverURL: URL(string: "https://library.example")!,
                keychain: SyncTokens(),
                session: URLSession(configuration: .ephemeral)))
        model.enqueuePosition = { _, _, _ in true }
        let bundle = Bundle(for: BundleMarker.self)
        let url = try #require(bundle.url(forResource: "readalong", withExtension: "epub"))
        model.package = try EPUBPackage.open(url: url)
        let package = try #require(model.package)
        let timeline = SMILParser.timeline(for: package)
        // `resize` before `go`: it records the page size, and its own relayout
        // is a no-op while there is no layout yet.
        await model.resize(to: CGSize(width: 340, height: 560))
        await model.go(toChapter: 0)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-narration-sync-\(UUID().uuidString)")
        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "narration-sync", into: directory)
        model.attachNarration(timeline: timeline, audioFiles: files)

        let first = try #require(timeline.firstEntry(inDocument: chapterOne))
        #expect(await model.resumeNarration(at: first, playing: false))
        #expect(model.readalong?.player.isPlaying == false)
        #expect(model.chapterIndex == 0)
        // Chapter one is a single page at this size, so the next page is the
        // next chapter.
        await model.nextPage()
        #expect(model.chapterIndex == 1, "the reader has read on, past the paused sentence")
        return (model, directory)
    }

    /// F02#5. The voice did not move while the reader was away, so neither may
    /// the page.
    @Test("a paused voice does not turn the reader back when they return")
    func aPausedVoiceLeavesThePageAlone() async throws {
        let (model, directory) = try await Self.pausedAndReadOn()
        defer { try? FileManager.default.removeItem(at: directory) }

        model.setReaderVisible(false)
        model.setReaderVisible(true)
        await model.syncToNarration()

        #expect(model.chapterIndex == 1, "the reader keeps the chapter they read on to")
    }

    /// The case the re-sync exists for, so the fix cannot be "never move a
    /// paused book": the voice was moved while the reader was elsewhere — the
    /// lock screen, the player sheet, a sentence played and then paused — and
    /// the page has to be where the voice now is.
    @Test("a voice moved while the reader was away is caught up with, though paused")
    func aVoiceMovedWhileAwayIsFollowed() async throws {
        let (model, directory) = try await Self.pausedAndReadOn()
        defer { try? FileManager.default.removeItem(at: directory) }
        let readalong = try #require(model.readalong)
        let timeline = try #require(model.timeline)
        let first = try #require(readalong.activeEntry)
        let later = try #require(
            timeline.entries.first { $0.textHref == Self.chapterOne && $0 != first })

        model.setReaderVisible(false)
        #expect(await readalong.prepare(at: later))
        model.setReaderVisible(true)
        await model.syncToNarration()

        #expect(model.chapterIndex == 0, "the page catches up with where the voice got to")
    }

    /// And the listener who left it playing.
    @Test("a voice still playing is caught up with")
    func aPlayingVoiceIsFollowed() async throws {
        let (model, directory) = try await Self.pausedAndReadOn()
        defer { try? FileManager.default.removeItem(at: directory) }
        let readalong = try #require(model.readalong)

        model.setReaderVisible(false)
        // Nothing between this and the re-sync suspends, so the fixture's tenth
        // of a second of audio cannot run out first.
        readalong.player.play()
        model.setReaderVisible(true)
        await model.syncToNarration()

        #expect(model.chapterIndex == 0)
    }
}

/// Per file, as every other suite in here keeps it.
private final class SyncTokens: TokenPersisting, @unchecked Sendable {
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
