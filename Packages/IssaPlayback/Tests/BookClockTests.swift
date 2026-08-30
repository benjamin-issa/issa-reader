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
}
