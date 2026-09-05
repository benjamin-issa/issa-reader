import Foundation
import Testing

@testable import IssaCore

private func temporaryDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "issa-anchor-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// The bridge between the two clocks one book is played on.
///
/// The app has two playback engines for a read-along: the read-along
/// coordinator, driven by the EPUB's media overlay, and the audiobook
/// coordinator, driven by the server's track list. They keep different
/// timelines, and `totalProgression` carried whichever one wrote last — so each
/// side read the other's number on its own scale.
///
/// From the car: tapping *The Hero of Ages* in CarPlay resumed from
/// `atProgress=0.7383`, which was a fraction of the **text**, multiplied by the
/// duration of the **audio**. The book is 109 spine items and 85 narrated ones,
/// so the two are not the same fraction, and 27h25m of audiobook started tens
/// of minutes early.
@Suite("Anchoring playback to a place both engines know")
struct AudioAnchorTests {
    /// Four tracks, an hour each, in the shape a Storyteller manifest arrives in.
    static func manifest() -> AudiobookManifest {
        AudiobookManifest(
            metadata: .init(title: ["und": "The Hero of Ages"]),
            readingOrder: [
                .init(href: "chapter01.mp3", duration: 3600),
                .init(href: "chapter02.mp3", duration: 3600),
                .init(href: "chapter03.mp3", duration: 3600),
                .init(href: "chapter04.mp3", duration: 3600),
            ],
        )
    }

    @Test("an anchor is the track's start plus the offset into it")
    func bookTimeSumsPrecedingTracks() throws {
        let anchor = AudioAnchor(audioHref: "chapter03.mp3", offset: 120, writtenAt: 1)
        let time = try #require(Self.manifest().bookTime(for: anchor))
        #expect(time == 7320)
    }

    /// The media overlay names an archive path inside the EPUB; the manifest
    /// names what the server serves. Same file, two names — and matching on the
    /// last *two* components, which is right for text resources, fails here.
    @Test("the EPUB's archive path and the server's href are the same file")
    func matchesAcrossDifferentPaths() throws {
        let anchor = AudioAnchor(
            audioHref: "OEBPS/audio/Chapter03.MP3", offset: 30, writtenAt: 1)
        let time = try #require(Self.manifest().bookTime(for: anchor))
        #expect(time == 7230)
    }

    /// `nil`, not a guess. A wrong number here is the whole bug.
    @Test("a file no track answers to resolves to nothing")
    func unmatchedFileIsRefused() {
        let anchor = AudioAnchor(audioHref: "interview-with-the-author.mp3", offset: 5, writtenAt: 1)
        #expect(Self.manifest().bookTime(for: anchor) == nil)
    }

    /// An anchor written against a differently transcoded copy can overshoot,
    /// and overshooting rolls silently into the next chapter.
    @Test("an offset past the end of its track is clamped to that track")
    func offsetClampedToTrack() throws {
        let anchor = AudioAnchor(audioHref: "chapter02.mp3", offset: 9_999, writtenAt: 1)
        let time = try #require(Self.manifest().bookTime(for: anchor))
        #expect(time == 7200)
    }

    @Test("a nonsense offset never becomes a place in the book")
    func nonFiniteOffsetRefused() {
        #expect(AudioAnchor(audioHref: "a.mp3", offset: .nan, writtenAt: 1).offset == 0)
        #expect(AudioAnchor(audioHref: "a.mp3", offset: -30, writtenAt: 1).offset == 0)
    }

    /// The regression, stated as arithmetic.
    ///
    /// A book whose front matter carries text but no audio: the reader is
    /// three-quarters through the *text*, which is further than three-quarters
    /// through the *audio*, because the unnarrated pages spent text and no
    /// seconds. Scaling the text fraction by the audio duration therefore lands
    /// early — here by nearly half an hour on a four-hour book, and by tens of
    /// minutes on the real 27-hour one.
    @Test("the anchor lands where scaling a text fraction does not")
    func anchorBeatsScalingATextFraction() throws {
        let manifest = Self.manifest()
        // Where the listener actually is: 10 minutes into the last track.
        let anchor = AudioAnchor(audioHref: "chapter04.mp3", offset: 600, writtenAt: 1)
        let truth = try #require(manifest.bookTime(for: anchor))
        #expect(truth == 3 * 3600 + 600)

        // What the old code did with a *text* progression of 0.7383.
        let scaled = manifest.totalDuration * 0.7383

        // Early, and by a margin a listener notices. This synthetic book runs
        // four hours and the gap is already ~12 minutes; *The Hero of Ages*
        // runs 27h25m, where the same fraction error is worth well over an
        // hour. The point is not the size — it is that the two numbers are
        // answers to different questions and only coincidence makes them agree.
        #expect(scaled < truth, "scaling a text fraction lands early, every time")
        #expect(truth - scaled > 10 * 60, "by \(Int((truth - scaled) / 60)) minutes here")
    }

    @Test("a newer anchor wins, an older one does not")
    func newerAnchorWins() {
        let old = AudioAnchor(audioHref: "chapter01.mp3", offset: 10, writtenAt: 100)
        let new = AudioAnchor(audioHref: "chapter04.mp3", offset: 10, writtenAt: 200)
        #expect(new.isNewerThan(old))
        #expect(!old.isNewerThan(new))
        #expect(new.isNewerThan(nil), "anything beats having none")
    }

    // MARK: - Which clock a stored position is on

    /// Both writers have always recorded the type correctly. Nothing read it,
    /// which is why each side interpreted the other's number on its own scale.
    @Test("a locator says which clock its progression belongs to")
    func locatorCarriesItsScale() {
        let fromTheReader = ReadiumLocator(href: "chapter62.xhtml", type: "application/xhtml+xml")
        let fromTheAudiobook = ReadiumLocator(href: "chapter62.mp3", type: "audio/mpeg")
        #expect(!fromTheReader.isAudioScaled)
        #expect(fromTheAudiobook.isAudioScaled)
        // Servers are not reliably lower-case about media types.
        #expect(ReadiumLocator(href: "x.m4a", type: "AUDIO/MP4").isAudioScaled)
    }

    // MARK: - Persistence

    @Test("an anchor survives a restart, and the newer of two wins")
    func anchorRoundTrips() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)

        #expect(try await store.audioAnchor(forBook: "b1") == nil)

        let first = AudioAnchor(audioHref: "chapter01.mp3", offset: 30, writtenAt: 100)
        try await store.setAudioAnchor(first, forBook: "b1")
        #expect(try await store.audioAnchor(forBook: "b1") == first)

        // The reader and the audiobook both write these, and the phone may have
        // been running while the car was not: last *in time*, not last to
        // arrive.
        let stale = AudioAnchor(audioHref: "chapter01.mp3", offset: 5, writtenAt: 50)
        try await store.setAudioAnchor(stale, forBook: "b1")
        #expect(try await store.audioAnchor(forBook: "b1") == first, "a stale anchor is refused")

        let fresh = AudioAnchor(audioHref: "chapter04.mp3", offset: 600, writtenAt: 200)
        try await store.setAudioAnchor(fresh, forBook: "b1")
        #expect(try await store.audioAnchor(forBook: "b1") == fresh)

        // And it is per book.
        #expect(try await store.audioAnchor(forBook: "b2") == nil)

        let reopened = try LibraryStore(serverKey: "http://example.test", directory: directory)
        #expect(try await reopened.audioAnchor(forBook: "b1") == fresh)
    }
}
