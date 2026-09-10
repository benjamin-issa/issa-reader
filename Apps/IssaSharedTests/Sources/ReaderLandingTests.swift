import Foundation
import IssaCore
import IssaEPUB
import Testing

@testable import IssaReader_iOS

/// Which chapter opening a book lands on.
///
/// The reverse of the listening ladder, and the half a listener actually sees:
/// they finish a drive, pick the phone up, and the book has to open where the
/// car left off. The audio position the car wrote names a track, which is not a
/// chapter of anything — only the media overlay can turn one into the other.
@Suite("Where opening a book lands")
@MainActor
struct ReaderLandingTests {
    private final class BundleMarker {}

    static func package() throws -> EPUBPackage {
        let bundle = Bundle(for: BundleMarker.self)
        let url = try #require(bundle.url(forResource: "readalong", withExtension: "epub"),
                               "the fixture is not in the test bundle")
        return try EPUBPackage.open(url: url)
    }

    static func timeline(_ package: EPUBPackage) -> SMILTimeline {
        SMILParser.timeline(for: package)
    }

    static func audioLocator(_ href: String, _ progress: Double) -> ReadiumLocator {
        ReadiumLocator(
            href: href, type: "audio/mpeg",
            locations: .init(totalProgression: progress))
    }

    /// The drive-then-read case. The stored href is a track, so no spine item
    /// matches it; the anchor names the same track and an offset, and the
    /// overlay says which sentence that is.
    @Test("an audio position written by the car lands on the sentence its anchor names")
    func anAudioPositionWrittenByTheCarLandsOnTheSentenceItsAnchorNames() throws {
        let package = try Self.package()
        let landing = ReaderModel.resolveLanding(
            stored: Self.audioLocator("OEBPS/Audio/track2.mp3", 0.9),
            anchor: AudioAnchor(audioHref: "OEBPS/Audio/track2.mp3", offset: 1.0, writtenAt: 1),
            package: package, timeline: Self.timeline(package))

        #expect(landing.how == .audioAnchor)
        #expect(landing.index == 1, "track two narrates the second chapter")
        #expect(landing.restoring?.locations?.fragments == ["ch02-s0"])
    }

    /// The 2026-09-09 shape, on this side of the bridge. The anchor names the
    /// server's single upload, which the EPUB's overlay has never heard of, so
    /// there is no sentence to land on and the whole-book fraction is all that
    /// is left. Approximate — but it is the reader's own number, not the other
    /// clock's, so it is bounded.
    @Test("an anchor naming the original upload falls back to progression")
    func anAnchorNamingTheOriginalUploadFallsBackToProgression() throws {
        let package = try Self.package()
        let stored = Self.audioLocator("The Outsider.mp3", 0.5181)
        let landing = ReaderModel.resolveLanding(
            stored: stored,
            anchor: AudioAnchor(audioHref: "The Outsider.mp3", offset: 16, writtenAt: 1),
            package: package, timeline: Self.timeline(package))

        #expect(landing.how == .progression)
        let expected = try #require(
            ReaderModel.spinePosition(atTotalProgression: 0.5181, in: package))
        #expect(landing.index == expected.index)
    }

    /// A reading position names its own chapter, and an anchor left over from
    /// some earlier listening must not get a vote. This is the case the audio
    /// branch has to stay out of: it re-anchors on a sentence, and doing that
    /// to a text position would throw away the character offset the reader
    /// actually stopped at.
    @Test("a text position is untouched by the anchor")
    func aTextPositionIsUntouchedByTheAnchor() throws {
        let package = try Self.package()
        let stored = ReadiumLocator(
            href: "OEBPS/ch02.xhtml", type: "application/xhtml+xml",
            locations: .init(fragments: ["ch02-s1"], totalProgression: 0.8))
        let landing = ReaderModel.resolveLanding(
            stored: stored,
            anchor: AudioAnchor(audioHref: "OEBPS/Audio/track1.mp3", offset: 0, writtenAt: 1),
            package: package, timeline: Self.timeline(package))

        #expect(landing.how == .storedHref)
        #expect(landing.index == 1)
        #expect(landing.restoring == stored, "the reader's own locator, not a synthesised one")
    }
}
