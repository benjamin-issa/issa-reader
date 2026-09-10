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

    // MARK: - The anchor, which is the rung that should answer

    @Test("an anchor naming a track wins")
    func anAnchorNamingATrackWins() {
        let resolution = ListeningResume.resolve(
            anchor: AudioAnchor(audioHref: chunks[1].href, offset: 30, writtenAt: 1),
            stored: nil, timeline: nil, manifest: manifest(chunks))
        #expect(resolution.bookTime == 630, "the second chunk starts ten minutes in")
        #expect(resolution.reason == .anchor)
        #expect(resolution.isResolved)
    }

    @Test("an anchor outranks a stored audio position")
    func anAnchorOutranksAStoredAudioPosition() {
        let resolution = ListeningResume.resolve(
            anchor: AudioAnchor(audioHref: chunks[1].href, offset: 30, writtenAt: 1),
            stored: audioLocator(chunks[0].href, 0.05),
            timeline: nil, manifest: manifest(chunks))
        #expect(resolution.bookTime == 630)
        #expect(resolution.reason == .anchor)
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
            stored: textLocator("OEBPS/text/ch41.xhtml", 0.5363, fragment: "ch41-s12"),
            timeline: nil,
            manifest: manifest(original))
        #expect(resolution.bookTime == nil, "a text fraction must never be scaled by the audio")
        #expect(resolution.reason == .anchorNamesUnknownFile)
        #expect(!resolution.isResolved)
    }

    // MARK: - Two clocks wearing the same field

    /// 0.5181 of the server's single upload is five hours in; 0.5181 of the
    /// EPUB's chunk list is ten minutes in. Same number, same field, different
    /// book. The href is the only thing that says which.
    @Test("a stored audio position from another manifest is not scaled")
    func aStoredAudioPositionFromAnotherManifestIsNotScaled() {
        let resolution = ListeningResume.resolve(
            anchor: nil,
            stored: audioLocator("The Outsider.mp3", 0.5181),
            timeline: nil, manifest: manifest(chunks))
        #expect(resolution.bookTime == nil)
        #expect(resolution.reason == .noAnchorStored)
        #expect(resolution.skippedForeignAudioPosition,
                "the log has to be able to say why: it was stored, and it was foreign")
    }

    @Test("a stored audio position on this manifest is trusted")
    func aStoredAudioPositionOnThisManifestIsTrusted() {
        let resolution = ListeningResume.resolve(
            anchor: nil,
            stored: audioLocator("The Outsider.mp3", 0.5),
            timeline: nil, manifest: manifest(original))
        #expect(resolution.bookTime == 18_000)
        #expect(resolution.reason == .audioPosition)
        #expect(!resolution.skippedForeignAudioPosition)
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
            stored: textLocator("OEBPS/ch02.xhtml", 0.6, fragment: "ch02-s0"),
            timeline: timeline, manifest: manifest(tracks))
        #expect(resolution.bookTime == firstFileDuration + chapterTwo.start)
        #expect(resolution.reason == .readingPositionViaOverlay)

        // And a sentence part-way into that file, so the assertion above cannot
        // pass on a zero offset alone.
        let later = try #require(
            timeline.entry(forFragment: "ch02-s1", inDocument: "OEBPS/ch02.xhtml"))
        let onward = ListeningResume.resolve(
            anchor: nil,
            stored: textLocator("OEBPS/ch02.xhtml", 0.8, fragment: "ch02-s1"),
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
            stored: textLocator("OEBPS/text/ch41.xhtml", 0.5363, fragment: "ch41-s12"),
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
        #expect(!resolution.skippedForeignAudioPosition)
    }
}
