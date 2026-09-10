import Foundation
import Testing

import IssaCore

/// A manifest built in code has to be the same manifest the server's JSON
/// decodes into.
///
/// The read-along path synthesises one over the EPUB's narration chunks, so for
/// the first time this type is constructed as well as decoded. Two shapes of
/// the same model is how a field acquires a second meaning — a `type` the
/// decoder fills and the builder forgets, say — and every consumer downstream
/// reads it through one code path that cannot tell which built it. Round
/// tripping through `Codable` states that they are one type: whatever the
/// builder puts in survives the encoder, the decoder and `==`.
///
/// Deliberately without `@testable`: the point of the initialisers is that a
/// caller outside this module can reach them.
@Suite("Building a manifest in code")
struct AudiobookManifestInitTests {
    @Test("a manifest built in code equals its decoded twin")
    func aManifestBuiltInCodeEqualsItsDecodedTwin() throws {
        let built = AudiobookManifest(
            metadata: .init(
                title: ["und": "The Patient Record of the Days"],
                subtitle: ["und": "A Fixture"],
                language: ["en"],
                duration: 32.75,
            ),
            readingOrder: [
                .init(href: "OEBPS/Audio/track1.mp3", type: "audio/mpeg", duration: 23),
                .init(
                    href: "OEBPS/Audio/track2.mp3", type: "audio/mpeg", title: "Chapter Two",
                    duration: 9.75, size: 2_052, bitrate: 128_000, rel: ["contents"],
                ),
            ],
            links: [.init(href: "manifest.json", type: "application/json", rel: ["self"])],
            toc: [.init(href: "OEBPS/Audio/track1.mp3", title: "Chapter One")],
        )

        let data = try JSONEncoder().encode(built)
        let decoded = try JSONDecoder().decode(AudiobookManifest.self, from: data)

        #expect(decoded == built)
        // And the fields the rest of the app actually reads off it, since
        // equality would also hold if both sides were empty.
        #expect(decoded.totalDuration == 32.75)
        #expect(decoded.playableTracks.count == 2)
        #expect(decoded.playableTracks[1].type == "audio/mpeg")
        #expect(decoded.title(of: decoded.playableTracks[0], at: 0) == "Track 1")
    }
}
