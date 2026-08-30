import Foundation
import Testing

@testable import IssaPlayback

@MainActor
struct SleepTimerTests {
    @Test("presets cover the useful range and read sensibly")
    func presets() {
        let titles = SleepTimer.presets.map(\.title)
        #expect(titles.contains("15 min"))
        #expect(titles.contains("End of chapter"))
        #expect(SleepTimer.Mode.off.title == "Off")
    }

    @Test("starts off, and cancelling restores full volume")
    func cancelRestoresVolume() {
        var faded: [Float] = []
        let timer = SleepTimer(onExpire: {}, fade: { faded.append($0) })
        #expect(timer.mode == .off)
        #expect(timer.remaining == nil)

        timer.start(.duration(600))
        #expect(timer.mode == .duration(600))
        #expect(timer.remaining == 600)

        timer.cancel()
        #expect(timer.mode == .off)
        // Cancelling must undo any partial fade, or the next play is silent.
        #expect(faded.last == 1)
    }

    @Test("end-of-chapter fires only on a chapter boundary")
    func endOfChapter() {
        var expired = 0
        let timer = SleepTimer(onExpire: { expired += 1 })

        // No timer set: a boundary must not stop playback.
        timer.chapterDidEnd()
        #expect(expired == 0)

        timer.start(.endOfChapter)
        // A clock-based countdown does not apply to this mode.
        #expect(timer.remaining == nil)
        timer.chapterDidEnd()
        #expect(expired == 1)
        #expect(timer.mode == .off)

        // And it does not fire twice.
        timer.chapterDidEnd()
        #expect(expired == 1)
    }

    @Test("a duration timer ignores chapter boundaries")
    func durationIgnoresChapters() {
        var expired = 0
        let timer = SleepTimer(onExpire: { expired += 1 })
        timer.start(.duration(300))
        timer.chapterDidEnd()
        #expect(expired == 0)
        timer.cancel()
    }

    @Test("formats the countdown for a glance in the dark")
    func countdownText() {
        let timer = SleepTimer(onExpire: {})
        #expect(timer.remainingText == nil)
        timer.start(.duration(750))
        #expect(timer.remainingText == "12:30")
        timer.cancel()
    }
}
