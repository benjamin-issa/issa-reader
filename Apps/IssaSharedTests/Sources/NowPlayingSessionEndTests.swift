import Foundation
import IssaCore
import Testing

@testable import IssaPlayback
@testable import IssaReader_iOS

/// The sleep timer running out is the end of listening for the night, so the
/// audio route goes back to whatever the book interrupted. It paused and kept
/// the non-mixable session active with nothing playing, so the music or
/// podcast that had been playing was never told it could resume.
@Suite("The sleep timer gives the audio route back")
@MainActor
struct NowPlayingSessionEndTests {
    static func engine() -> AudiobookCoordinator {
        AudiobookCoordinator(
            manifest: AudiobookManifest(
                metadata: .init(title: ["und": "Dracula"]),
                readingOrder: [.init(href: "track1.mp3", type: "audio/mpeg", duration: 3_600)]),
            source: .files([:]))
    }

    @Test("a sleep timer that expires ends the session; a pause does not")
    func anExpiredTimerEndsTheSession() throws {
        let controller = NowPlayingController()
        let engine = Self.engine()
        controller.attach(coordinator: engine, book: SharedFixtures.book("Dracula", uuid: "sleep-uuid"))
        defer { controller.attach(coordinator: nil, book: nil) }
        engine.player.play()
        engine.player.pause()
        engine.player.play()
        #expect(engine.player.sessionsEnded == 0, "a pause keeps the route")

        try #require(controller.sleepTimer).start(.endOfChapter)
        engine.onChapterChangeObserved?()

        #expect(engine.player.isPlaying == false)
        #expect(engine.player.sessionsEnded == 1, "the timer stopped the book and kept the route")
    }
}
