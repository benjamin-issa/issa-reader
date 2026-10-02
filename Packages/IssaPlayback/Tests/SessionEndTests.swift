import Foundation
import IssaCore
import IssaEPUB
import Testing

@testable import IssaPlayback

/// When listening is over, the audio route goes back to whoever had it.
///
/// The session is non-mixable: going active stops the listener's music, and
/// nothing ever went inactive, so the app that was interrupted was never told
/// it could resume. The end of the book and the sleep timer are the ends of
/// listening; an ordinary pause and the hand-off to the reader are not.
@Suite("Ending a listening session")
@MainActor
struct SessionEndTests {
    static func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("the read-along running out at the end of the book ends the session; a pause does not")
    func readalongEndOfBook() async throws {
        let (subject, timeline, directory) = try ReadalongCoordinatorTests.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        subject.player.onTimeUpdate = nil
        let last = try #require(timeline.entries.last)

        // A pause, and the silent landing the car-to-reader hand-off makes.
        #expect(await subject.prepare(at: last))
        subject.player.play()
        subject.player.pause()
        #expect(subject.player.sessionsEnded == 0, "a pause keeps the route")

        subject.player.onFinishedFile?()
        #expect(await Self.waitUntil { subject.player.sessionsEnded == 1 },
                "the end of the book kept the audio route")
        #expect(subject.player.isPlaying == false)
    }

    @Test("the audiobook running out of tracks ends the session; a track boundary does not")
    func audiobookEndOfBook() async throws {
        let manifest = ChapterClockTests.manifest(trackCount: 2, each: 100)
        let subject = ChapterClockTests.coordinator(manifest)
        _ = try ChapterClockTests.detachClock(subject)
        var loads = 0
        subject.onChapterChange = { _ in loads += 1 }

        await subject.seek(toBookTime: 50)
        subject.player.onFinishedFile?()
        #expect(await Self.waitUntil { subject.trackIndex == 1 && loads >= 2 })
        #expect(subject.player.sessionsEnded == 0, "the next track is not the end of the book")

        subject.player.onFinishedFile?()
        #expect(await Self.waitUntil { subject.player.sessionsEnded == 1 },
                "the end of the book kept the audio route")
    }
}

/// A speed chosen from a bound control is reported as chosen, so the app can
/// remember it; a speed merely restored is not.
@Suite("A chosen playback speed")
@MainActor
struct ChosenRateTests {
    @Test("speed up and down, from either engine, report the speed they chose")
    func boundSpeedActionsReportTheirChoice() async throws {
        let map = CommandMap()
        let audiobook = ChapterClockTests.coordinator(ChapterClockTests.manifest(trackCount: 1, each: 100))
        var chosen: [Float] = []
        audiobook.player.onRateChosen = { chosen.append($0) }
        await audiobook.perform(.speedUp, using: map)
        await audiobook.perform(.speedDown, using: map)
        await audiobook.perform(.speedDown, using: map)
        #expect(chosen == [1.25, 1.0, 0.75])

        let (readalong, _, directory) = try ReadalongCoordinatorTests.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        var readalongChosen: [Float] = []
        readalong.player.onRateChosen = { readalongChosen.append($0) }
        await readalong.perform(.speedUp, using: map)
        #expect(readalongChosen == [1.25])
    }

    /// The saved speed applied when a book opens is not a new choice to save.
    @Test("setting the rate directly reports nothing")
    func aRestoredRateIsNotAChoice() {
        let player = AudioPlayer()
        var chosen: [Float] = []
        player.onRateChosen = { chosen.append($0) }
        player.rate = 1.5
        #expect(chosen.isEmpty)
    }
}
