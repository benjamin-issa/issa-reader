import Foundation
import IssaCore
import Testing

@testable import IssaPlayback

/// The book clock is what the lock screen publishes and what every skip is
/// measured from. A single non-finite sample used to latch into it, make iOS
/// count up from zero, send both rewind and fast-forward to the start of the
/// book, and then persist that zero to the server — losing hours of position.
@Suite("The book clock")
@MainActor
struct BookClockTests {
    /// Decoded, the way a real manifest arrives — the model has no public
    /// initialiser, and inventing one for tests would be a second definition of
    /// what a manifest is.
    func manifest(trackCount: Int = 60, each: Double = 1_600) -> AudiobookManifest {
        let json: [String: Any] = [
            "metadata": ["title": ["und": "Long Book"]],
            "readingOrder": (0 ..< trackCount).map { index in
                [
                    "href": "t\(index).mp4",
                    "type": "audio/mp4",
                    "title": "Track \(index + 1)",
                    "duration": each,
                ]
            },
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(AudiobookManifest.self, from: data)
    }

    func coordinator(_ manifest: AudiobookManifest) -> AudiobookCoordinator {
        AudiobookCoordinator(
            manifest: manifest,
            source: .local(URL(fileURLWithPath: "/dev/null")),
        )
    }

    /// Swift's `min`/`max` return the other operand when a comparison against
    /// NaN is false, so the old `min(max(NaN, 0), 1)` produced NaN, not 0.
    @Test("a non-finite clock never becomes a valid-looking progress")
    func nanDoesNotBecomeProgress() {
        let subject = coordinator(manifest())
        // Prove the hazard is real before proving the guard holds.
        #expect(min(max(Double.nan, 0), 1).isNaN, "Swift's clamp does not filter NaN")
        subject.player.onTimeUpdate?(.nan)
        #expect(subject.bookTime.isFinite, "a NaN sample must not reach the book clock")
        #expect(subject.progress.isFinite)
        #expect(subject.progress == 0)
    }

    @Test("an infinite sample is refused too")
    func infinityIsRefused() {
        let subject = coordinator(manifest())
        subject.player.onTimeUpdate?(.infinity)
        #expect(subject.bookTime.isFinite)
    }

    /// The fingerprint of the reported bug: a fast-forward that jumps backwards
    /// to 0:00, because `max(0, min(NaN + delta, total))` collapses to zero.
    @Test("a skip from a poisoned clock does not seek to the start of the book")
    func skipFromBrokenClockDoesNothing() async {
        let subject = coordinator(manifest())
        await subject.seek(toBookTime: 4 * 3_600)
        let before = subject.bookTime
        #expect(before > 0)

        subject.player.onTimeUpdate?(.nan)
        await subject.skip(by: 30)
        #expect(subject.bookTime.isFinite)
        #expect(subject.bookTime > 0, "must not have been thrown back to the start")

        // And the arithmetic that used to do it, stated plainly.
        #expect(max(0, min(Double.nan + 30, 96_000)) == 0, "this is what the old clamp did")
    }

    /// Elapsed is published as book-wide seconds; the lock-screen scrubber
    /// hands the same number back. The round trip must be the identity.
    @Test("the published position round-trips through a seek")
    func positionRoundTrips() async {
        let book = manifest()
        let subject = coordinator(book)
        let total = subject.totalDuration
        #expect(total == 60 * 1_600)

        for target in [0.0, 1_600.0, 4 * 3_600.0, total - 1] {
            await subject.seek(toBookTime: target)
            let published = total * subject.bookProgress
            #expect(abs(published - target) < 1, "published \(published) for \(target)")

            // What changePlaybackPositionCommand delivers, converted the way
            // NowPlayingController converts it.
            await subject.seek(toBookProgress: published / total)
            #expect(abs(subject.bookTime - target) < 1)
        }
    }

    /// Book-wide, not per-file: a skip near a track boundary has to cross it.
    @Test("a skip crosses a track boundary rather than stopping at its edge")
    func skipCrossesTracks() async {
        let book = manifest(trackCount: 10, each: 100)
        let subject = coordinator(book)
        await subject.seek(toBookTime: 305)          // 5s into track 4
        #expect(subject.trackIndex == 3)

        await subject.skip(by: -30)                   // back across the boundary
        #expect(abs(subject.bookTime - 275) < 1, "landed at \(subject.bookTime)")
        #expect(subject.trackIndex == 2, "should be in the previous track")
    }

    @Test("progress is clamped to 0...1 even for an out-of-range clock")
    func progressStaysInRange() async {
        let subject = coordinator(manifest())
        await subject.seek(toBookTime: -500)
        #expect(subject.progress >= 0)
        await subject.seek(toBookTime: 10_000_000)
        #expect(subject.progress <= 1)
    }

    /// `previousChapter()`'s restart-the-current-track branch used to seek the
    /// player directly, without the `bookTime` update every other seek path —
    /// `seek(toBookTime:)`, `load(track:startAt:)` — performs. A skip fired
    /// right after a restart computed its target from wherever playback had
    /// been a moment before, not from the restart, overshooting by however far
    /// into the track the listener had gotten.
    @Test("restarting the current chapter keeps the book clock in step")
    func restartingCurrentChapterUpdatesBookTime() async {
        let subject = coordinator(manifest(trackCount: 3, each: 1_000))
        await subject.seek(toBookTime: 1_010) // 10s into track 1
        #expect(subject.trackIndex == 1)

        // Disconnected deliberately. `AudiobookCoordinator` wires the player's
        // own periodic time observer to keep `bookTime` current during real
        // playback — and against a real (if unplayable) `AVPlayer`, that
        // observer can fire essentially synchronously with a seek, which
        // quietly repaired this exact bug by accident inside this test harness
        // and would have made the mutation below pass either way. On a device
        // the observer fires on a 0.2-1.0s cadence, so a skip tapped right
        // after "previous chapter" is not guaranteed to race behind it — the
        // whole reason the fix sets `bookTime` itself rather than trusting that
        // race. Disconnecting it here is what makes this test about
        // `previousChapter()`'s own code, not about incidental test-harness
        // timing.
        subject.player.onTimeUpdate = nil

        // Simulate real playback progress past the 3s threshold that decides
        // "restart this track" versus "go back a track".
        await subject.player.seek(to: 10)
        #expect(subject.player.currentTime > 3)

        await subject.previousChapter()
        #expect(subject.trackIndex == 1, "a restart stays on the same track")
        #expect(subject.bookTime == 1_000, "bookTime must reflect the restart, not the old position")

        // The regression, made concrete: a skip fired immediately after must be
        // measured from the true, just-restarted position.
        await subject.skip(by: 30)
        #expect(abs(subject.bookTime - 1_030) < 0.001,
                "skip after a restart landed at \(subject.bookTime), not 1030")
    }

    /// The other branch, unchanged: three or fewer seconds in moves back a
    /// whole track, and `load(track:startAt:)` already keeps `bookTime` correct
    /// there — this just confirms the boundary between the two branches.
    @Test("previous chapter near the start of a track moves back a track instead")
    func previousChapterNearStartMovesBackATrack() async {
        let subject = coordinator(manifest(trackCount: 3, each: 1_000))
        await subject.seek(toBookTime: 1_002) // 2s into track 1
        await subject.player.seek(to: 2)
        #expect(subject.player.currentTime <= 3)

        await subject.previousChapter()
        #expect(subject.trackIndex == 0)
        #expect(subject.bookTime == 0)
    }

    /// `min(trackIndex + 1, tracks.count - 1)` on the final track resolved to
    /// the *current* track: a restart at zero, marked as steered — which the
    /// position writer then sent to the server as `.chosen`, the one origin
    /// PositionGuard never refuses.
    @Test("next chapter on the last track refuses rather than restarting it")
    func nextChapterOnLastTrackDoesNothing() async {
        let subject = coordinator(manifest(trackCount: 3, each: 1_000))
        await subject.seek(toBookTime: 2_500) // 500s into the final track
        #expect(subject.trackIndex == 2)
        _ = subject.consumeSteering()

        await subject.nextChapter()

        #expect(subject.trackIndex == 2)
        #expect(abs(subject.bookTime - 2_500) < 1, "must not restart the track at zero")
        #expect(subject.consumeSteering() == false,
                "a refused move must not be written back as a chosen position")
    }

    /// `advance()` runs `play()` after `load()` — and `load()` is what fires
    /// `onChapterChange`, which is where an "end of chapter" sleep timer
    /// pauses. The unconditional play() undid that pause in the same turn,
    /// after the timer had already reset itself, so the rest of the book
    /// played on into the night.
    @Test("the end-of-chapter pause survives the automatic advance")
    func endOfChapterPauseSurvivesAdvance() async {
        let subject = coordinator(manifest(trackCount: 3, each: 1_000))
        await subject.seek(toBookTime: 999)
        subject.player.play()
        // The Now Playing wiring, in miniature: the timer's expiry pauses from
        // inside the chapter-change callback, mid-`advance()`.
        var boundaryCrossed = false
        subject.onChapterChange = { [weak subject] _ in
            subject?.player.pause()
            boundaryCrossed = true
        }

        subject.player.onFinishedFile?()
        // `onFinishedFile` hops through a Task; from the callback to the end
        // of `advance()` there is no further suspension, so once the boundary
        // has been observed the coordinator's decision is already made.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !boundaryCrossed, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(boundaryCrossed, "the next track never loaded")
        #expect(subject.trackIndex == 1)
        #expect(subject.player.isPlaying == false,
                "advance() must not undo the pause the boundary just asked for")
    }

    @Test("the discrete play and pause commands hold their meaning when repeated")
    func discretePlayPause() async {
        let subject = coordinator(manifest())
        let map = CommandMap()

        await subject.perform(.play, using: map)
        #expect(subject.player.isPlaying)
        // A stalled book draws ▶ (the published rate is 0) while `isPlaying`
        // is true; the tap that arrives is `.play` and must not flip to pause.
        await subject.perform(.play, using: map)
        #expect(subject.player.isPlaying, "play is not a toggle")

        await subject.perform(.pause, using: map)
        #expect(subject.player.isPlaying == false)
        await subject.perform(.pause, using: map)
        #expect(subject.player.isPlaying == false, "pause is not a toggle")
    }
}

/// What the rate observers are told, which is what the widget and the lock
/// screen believe.
@MainActor
struct RateObserverTests {
    @Test("changing speed while paused does not announce playback")
    func pausedRateChangeReportsZero() {
        let subject = AudioPlayer()
        var reported: [Float] = []
        let owner = NSObject()
        subject.setRateObserver(for: owner) { reported.append($0) }

        // Paused: picking 1.5× from the menu must not tell anyone the book
        // started. AppModel publishes the widget's `isPlaying` from exactly
        // this number, and a paused book never republishes to correct it.
        subject.rate = 1.5
        #expect(reported == [0], "the effective rate of a paused player is zero")

        subject.play()
        #expect(reported.last == 1.5)
        subject.rate = 2.0
        #expect(reported.last == 2.0)
        subject.pause()
        #expect(reported.last == 0)
    }
}
