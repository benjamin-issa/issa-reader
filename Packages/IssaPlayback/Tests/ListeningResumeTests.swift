import Foundation
import IssaCore
import IssaEPUB
import Testing

@testable import IssaPlayback

/// Resuming an audiobook, and refusing to guess when it cannot be done.
///
/// The replay in the middle of this file is the 2026-09-09 report: a book whose
/// stored anchor named the EPUB's narration chunks against a manifest with one
/// track called after the upload. Every rung failed, and the old code said "no
/// audio anchor for this book yet" — which was not true, and sent whoever read
/// the log looking in the wrong place entirely.
@Suite("Where an audiobook resumes")
struct ListeningResumeTests {
    /// Decoded, the way a real manifest arrives — the model has no public
    /// initialiser, and inventing one for tests would be a second definition of
    /// what a manifest is. `BookClockTests` builds one the same way.
    func manifest(_ tracks: [(href: String, duration: Double)]) -> AudiobookManifest {
        let json: [String: Any] = [
            "metadata": ["title": ["und": "A Book"]],
            "readingOrder": tracks.map { track in
                [
                    "href": track.href,
                    "type": "audio/mpeg",
                    "duration": track.duration,
                ]
            },
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(AudiobookManifest.self, from: data)
    }

    /// The server's own upload: one ten-hour file named after the book.
    let original = [(href: "The Outsider.mp3", duration: 36_000.0)]
    /// The same audio as the EPUB carries it: numbered narration chunks.
    let chunks = [
        (href: "OEBPS/Audio/00000-00085.mp3", duration: 600.0),
        (href: "OEBPS/Audio/00086-00170.mp3", duration: 600.0),
    ]

    /// A position the audiobook engine wrote: the href is a track, the fraction
    /// is a fraction of the audio.
    func audioLocator(_ href: String, _ progress: Double) -> ReadiumLocator {
        ReadiumLocator(
            href: href, type: "audio/mpeg",
            locations: .init(totalProgression: progress))
    }

    /// A position the reader wrote: the href is a chapter, the fraction is a
    /// fraction of the text, and the fragment names a narrated sentence.
    func textLocator(_ href: String, _ progress: Double, fragment: String?) -> ReadiumLocator {
        ReadiumLocator(
            href: href, type: "application/xhtml+xml",
            locations: .init(fragments: fragment.map { [$0] }, totalProgression: progress))
    }

    /// A stored position as the server keeps it: a locator, and epoch
    /// **milliseconds**. Spelled out rather than defaulted away, because the
    /// unit is the whole trap — an anchor's `writtenAt` is epoch *seconds*, the
    /// two fields are both `Double`, and both are named for the same idea. See
    /// `StoredPosition.writtenAt`.
    func stored(_ locator: ReadiumLocator, writtenAtEpochSeconds: Double = 0) -> StoredPosition {
        StoredPosition(locator: locator, timestamp: writtenAtEpochSeconds * 1000)
    }

    // MARK: - The anchor, which is the rung that should answer

    @Test("an anchor naming a track wins")
    func anAnchorNamingATrackWins() {
        let resolution = ListeningResume.resolve(
            anchor: AudioAnchor(audioHref: chunks[1].href, offset: 30, writtenAt: 1),
            stored: nil, timeline: nil, manifest: manifest(chunks))
        #expect(resolution.bookTime == 630, "the second chunk starts ten minutes in")
        #expect(resolution.reason == .anchor)
        #expect(resolution.isTrusted)
    }

    @Test("an anchor outranks a stored audio position")
    func anAnchorOutranksAStoredAudioPosition() {
        let resolution = ListeningResume.resolve(
            anchor: AudioAnchor(audioHref: chunks[1].href, offset: 30, writtenAt: 1),
            stored: stored(audioLocator(chunks[0].href, 0.05)),
            timeline: nil, manifest: manifest(chunks))
        #expect(resolution.bookTime == 630)
        #expect(resolution.reason == .anchor)
    }

    // MARK: - How old the anchor is

    /// The ordinary case, and the one that has to keep working: the audiobook
    /// writes its position and then its anchor, a beat apart and in that order.
    /// So an anchor a second younger than the position beside it is the *same*
    /// moment of listening, not a stale one, and rung 1 still answers.
    @Test("an anchor written beside its own position still answers")
    func anAnchorWrittenBesideItsOwnPositionStillAnswers() {
        let resolution = ListeningResume.resolve(
            anchor: AudioAnchor(audioHref: chunks[1].href, offset: 30, writtenAt: 1_757_000_001),
            stored: stored(
                audioLocator(chunks[0].href, 0.05), writtenAtEpochSeconds: 1_757_000_000),
            timeline: nil, manifest: manifest(chunks))
        #expect(resolution.bookTime == 630)
        #expect(resolution.reason == .anchor)
        #expect(resolution.isTrusted)
    }

    /// The regression rung 1's age test exists for, on the audio clock. The
    /// listener narrates to the second chunk, stops, and then listens on in the
    /// car — which moves the stored position and leaves the anchor where the
    /// narration ended. Trusting the anchor would resume where they were an
    /// hour ago and write that over where they are now.
    @Test("a stored audio position written since the anchor wins on the same manifest")
    func aStoredAudioPositionWrittenSinceTheAnchorWins() {
        let resolution = ListeningResume.resolve(
            anchor: AudioAnchor(audioHref: chunks[0].href, offset: 30, writtenAt: 1_757_000_000),
            stored: stored(
                audioLocator(chunks[1].href, 0.9), writtenAtEpochSeconds: 1_757_003_600),
            timeline: nil, manifest: manifest(chunks))
        #expect(resolution.bookTime == 1200 * 0.9)
        #expect(resolution.reason == .audioPosition)
        #expect(resolution.isTrusted)
    }

    /// The report this rung was added for, on the text clock. Narration plays
    /// to 0.20 and stops; the reader relaunches and reads on in silence to
    /// 0.70, which moves the position and never touches the anchor; they press
    /// Listen. Rung 1 used to trust the anchor whatever its age, so the car
    /// resumed at 0.20 and the fifteen-second writer put 0.20 over the 0.70.
    @Test("reading on in silence outranks the anchor the narration left")
    func readingOnInSilenceOutranksTheAnchorTheNarrationLeft() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/readalong", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        let timeline = SMILParser.timeline(for: package)
        let firstFileDuration = try #require(
            timeline.entries.last { $0.audioHref == "OEBPS/Audio/track1.mp3" }?.end)
        let tracks = [
            (href: "OEBPS/Audio/track1.mp3", duration: firstFileDuration),
            (href: "OEBPS/Audio/track2.mp3", duration: 9.75),
        ]
        let chapterTwo = try #require(
            timeline.entry(forFragment: "ch02-s0", inDocument: "OEBPS/ch02.xhtml"))

        // Where the narration stopped: the first file, near its start.
        let resolution = ListeningResume.resolve(
            anchor: AudioAnchor(
                audioHref: "OEBPS/Audio/track1.mp3", offset: 2, writtenAt: 1_757_000_000),
            // Where silent reading got to afterwards.
            stored: stored(
                textLocator("OEBPS/ch02.xhtml", 0.7, fragment: "ch02-s0"),
                writtenAtEpochSeconds: 1_757_003_600),
            timeline: timeline, manifest: manifest(tracks))
        #expect(resolution.bookTime == firstFileDuration + chapterTwo.start)
        #expect(resolution.reason == .readingPositionViaOverlay)
        #expect(resolution.isTrusted, "the overlay makes a reading position exact")
    }

    /// And the rung that catches the anchor when it loses. The same book on a
    /// cold CarPlay launch: no reader is open, so there is no overlay to
    /// convert the reading position through, and rung 3 cannot answer at all.
    ///
    /// Without this rung the losing anchor falls all the way to nothing, the
    /// caller plays from `atProgress: 0`, and a real place in the book — merely
    /// an old one — becomes chapter one. Which is worse than the stale place it
    /// was rejected for, and is the thing this whole file exists to prevent. So
    /// it plays from the anchor, untrusted: the hold keeps that old place from
    /// being written over the newer one it lost to.
    @Test("an anchor the reading left behind is a place to start, not to write from")
    func anAnchorTheReadingLeftBehindIsAPlaceToStartNotToWriteFrom() {
        let resolution = ListeningResume.resolve(
            anchor: AudioAnchor(audioHref: chunks[1].href, offset: 30, writtenAt: 1_757_000_000),
            stored: stored(
                textLocator("OEBPS/ch41.xhtml", 0.7, fragment: "ch41-s12"),
                writtenAtEpochSeconds: 1_757_003_600),
            timeline: nil, manifest: manifest(chunks))
        #expect(resolution.bookTime == 630, "the anchor's own place, which is still a real one")
        #expect(resolution.reason == .anchorOlderThanPosition)
        #expect(!resolution.isTrusted, "and not where the reader got to, so nothing may be saved")
    }

    // MARK: - The report, reproduced

    /// The phone log of 2026-09-09. The anchor named `OEBPS/Audio/00000-00085.mp3`
    /// — the EPUB's first narration chunk — and the server's manifest has one
    /// track, `The Outsider.mp3`. The stored position was the reader's, on the
    /// text clock, and the overlay was not in memory: a cold CarPlay launch has
    /// no open reader. Every rung has to fail, and the reason has to name the
    /// anchor rather than deny there is one.
    @Test("the report: an anchor naming a chunk falls through on the original manifest")
    func theOutsiderReplay_anAnchorNamingAChunkFallsThroughOnTheOriginalManifest() {
        let resolution = ListeningResume.resolve(
            anchor: AudioAnchor(audioHref: "OEBPS/Audio/00000-00085.mp3", offset: 12, writtenAt: 1),
            stored: stored(textLocator("OEBPS/text/ch41.xhtml", 0.5363, fragment: "ch41-s12")),
            timeline: nil,
            manifest: manifest(original))
        #expect(resolution.bookTime == nil, "a text fraction must never be scaled by the audio")
        #expect(resolution.reason == .anchorNamesUnknownFile)
        #expect(!resolution.isTrusted)
    }

    // MARK: - Two clocks wearing the same field

    /// The whole of the same narration, as the EPUB carries it: sixty chunks of
    /// ten minutes, which is the ten hours the server serves as one file. The
    /// two-chunk `chunks` above is a fragment of a book and cannot say anything
    /// about scaling between the lists; this can.
    let wholeChunks = (0 ..< 60).map {
        (href: String(format: "OEBPS/Audio/%05d.mp3", $0), duration: 600.0)
    }

    /// The one rung here that answers approximately, and a deliberate reversal:
    /// this used to assert that a foreign audio position was refused outright.
    ///
    /// The argument for refusing was that two track lists are two clocks and a
    /// fraction of one is not a fraction of the other. That is true, and it is
    /// still true — 18,651s is not where the listener was. What it missed is
    /// that the two lists are the *same narration* cut up differently, so the
    /// fraction lands within a chapter or two of the right place, and the thing
    /// it was being refused in favour of was chapter one. In a car, silence
    /// from the front of a book is the worse of those two by a wide margin.
    ///
    /// The refusal was never what protected the stored position anyway. That is
    /// the hold: `isTrusted` is false here, so `prepareListeningGuard` keeps the
    /// audio clock held and the fifteen-second writer cannot persist the guess
    /// until the listener names somewhere themselves.
    @Test("a stored audio position from another cut of the same narration is a place to start")
    func aStoredAudioPositionFromAnotherCutIsAPlaceToStart() throws {
        let resolution = ListeningResume.resolve(
            anchor: nil,
            stored: stored(audioLocator("The Outsider.mp3", 0.5181)),
            timeline: nil, manifest: manifest(wholeChunks))
        let time = try #require(resolution.bookTime)
        #expect(abs(time - 0.5181 * 36_000) < 0.001)
        #expect(resolution.reason == .audioPositionFromAnotherManifest)
        #expect(!resolution.isTrusted, "roughly right is a place to start, not a place to save")
    }

    /// And the exact rung still outranks it: a position whose href names a track
    /// in *this* manifest is a fraction of this manifest's own clock, with no
    /// scaling between lists at all.
    @Test("a stored audio position on this manifest is trusted")
    func aStoredAudioPositionOnThisManifestIsTrusted() {
        let resolution = ListeningResume.resolve(
            anchor: nil,
            stored: stored(audioLocator("The Outsider.mp3", 0.5)),
            timeline: nil, manifest: manifest(original))
        #expect(resolution.bookTime == 18_000)
        #expect(resolution.reason == .audioPosition)
        #expect(resolution.isTrusted)
    }

    // MARK: - The overlay bridge

    /// The rung that makes a reading position resumable as audio, and the one
    /// that needs a timeline handed to it — the caller's own reader may be
    /// closed. Expected values come off the fixture's overlay rather than a
    /// guess: chapter two's narration is the second file, so its first sentence
    /// begins exactly where the first file ends.
    @Test("a reading position converts through the timeline handed in")
    func aReadingPositionConvertsThroughTheTimelineHandedIn() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/readalong", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        let timeline = SMILParser.timeline(for: package)

        let first = try #require(timeline.entries.first { $0.audioHref == "OEBPS/Audio/track1.mp3" })
        let firstFileDuration = try #require(
            timeline.entries.last { $0.audioHref == "OEBPS/Audio/track1.mp3" }?.end)
        #expect(first.textHref == "OEBPS/ch01.xhtml")

        let tracks = [
            (href: "OEBPS/Audio/track1.mp3", duration: firstFileDuration),
            (href: "OEBPS/Audio/track2.mp3", duration: 9.75),
        ]
        let chapterTwo = try #require(
            timeline.entry(forFragment: "ch02-s0", inDocument: "OEBPS/ch02.xhtml"))
        let resolution = ListeningResume.resolve(
            anchor: nil,
            stored: stored(textLocator("OEBPS/ch02.xhtml", 0.6, fragment: "ch02-s0")),
            timeline: timeline, manifest: manifest(tracks))
        #expect(resolution.bookTime == firstFileDuration + chapterTwo.start)
        #expect(resolution.reason == .readingPositionViaOverlay)

        // And a sentence part-way into that file, so the assertion above cannot
        // pass on a zero offset alone.
        let later = try #require(
            timeline.entry(forFragment: "ch02-s1", inDocument: "OEBPS/ch02.xhtml"))
        let onward = ListeningResume.resolve(
            anchor: nil,
            stored: stored(textLocator("OEBPS/ch02.xhtml", 0.8, fragment: "ch02-s1")),
            timeline: timeline, manifest: manifest(tracks))
        #expect(onward.bookTime == firstFileDuration + later.start)
        #expect(later.start > 0)
    }

    /// The cold CarPlay launch: nothing is open, so there is no overlay to
    /// convert through. The text fraction is still not an answer.
    @Test("a reading position without a timeline resolves to nothing")
    func aReadingPositionWithoutATimelineResolvesToNothing() {
        let resolution = ListeningResume.resolve(
            anchor: nil,
            stored: stored(textLocator("OEBPS/text/ch41.xhtml", 0.5363, fragment: "ch41-s12")),
            timeline: nil, manifest: manifest(original))
        #expect(resolution.bookTime == nil)
        #expect(resolution.reason == .noAnchorStored)
    }

    // MARK: - Nothing at all

    /// A book opened for the first time. Distinct from every failure above:
    /// there is nothing to lose here, and the caller acts on that difference.
    @Test("nothing stored is said plainly")
    func nothingStoredIsSaidPlainly() {
        let resolution = ListeningResume.resolve(
            anchor: nil, stored: nil, timeline: nil, manifest: manifest(original))
        #expect(resolution.bookTime == nil)
        #expect(resolution.reason == .noStoredPosition)
    }
}
