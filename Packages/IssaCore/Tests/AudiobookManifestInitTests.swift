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

/// `startTime(ofTrackAt:)` and `locate(bookTime:)` are one function read in two
/// directions, and they have to agree exactly.
///
/// Not approximately: every chapter of a book playing the server's own manifest
/// starts at a number `startTime` produced, and `previousChapter()` hands that
/// number straight back to `locate` to restart it. A boundary that resolves a
/// ULP low is not "a few milliseconds out" — it is the *previous* track, loaded
/// a fraction of a second from its end. It runs out immediately, the coordinator
/// reads that as a chapter ending, and an end-of-chapter sleep timer stops the
/// book. `AudioAnchor.bookTime(for:)` adds the same durations up the same way, so
/// a resume from a stored anchor lands a whole chunk early for the same reason.
@Suite("A track boundary means the same thing from both sides")
struct AudiobookManifestLocateTests {
    /// Durations only, since nothing else here is read. Built rather than
    /// decoded for the reason the suite above exists: it is the same type.
    static func manifest(_ durations: [Double]) -> AudiobookManifest {
        AudiobookManifest(
            metadata: .init(title: ["und": "A Book Of Awkward Thirds"]),
            readingOrder: durations.enumerated().map { index, duration in
                .init(href: "t\(index).mp3", type: "audio/mpeg", duration: duration)
            },
        )
    }

    /// The measured case, and the one that shipped. Four tracks of a hundred
    /// point one: a left fold of the first three is `300.29999999999995`, and the
    /// old subtract-as-you-go walk had already taken a hair *more* than that off
    /// its remainder by the time it reached the boundary, so the residual sat
    /// just under track two's duration and the answer was the end of track two.
    @Test("locate lands on the track startTime names, for durations that are not whole seconds")
    func locateInvertsStartTimeForFractionalDurations() {
        let subject = Self.manifest([100.1, 100.1, 100.1, 100.1])

        // The hazard first, so a later change to the arithmetic that made this
        // exact rather than merely equal would be visible here rather than
        // silently making the rest of the test vacuous.
        #expect(subject.startTime(ofTrackAt: 3) == 300.29999999999995,
                "the sum is not 300.3, and that is the whole problem")

        for index in 0 ..< 4 {
            let start = subject.startTime(ofTrackAt: index)
            let located = subject.locate(bookTime: start)
            #expect(located?.index == index,
                    "startTime(ofTrackAt: \(index)) == \(start) located track \(located?.index ?? -1)")
            #expect(located?.offset == 0,
                    "and at its start, not \(located?.offset ?? -1) into the one before it")
        }
    }

    /// The twin that was always green, spelled out so nobody re-derives the
    /// wrong conclusion from it. Every fixture in the suites that exercise this
    /// — `BookClockTests` at 1,000 and 1,600 seconds a track, `ChapterClockTests`
    /// at 100 — uses whole seconds, which are exact in binary and sum the same
    /// way whichever direction they are added, so the defect could not appear in
    /// any of them. Real durations come off an audio file and are never round.
    @Test("whole seconds round-trip either way, which is why this went unnoticed")
    func wholeSecondsRoundTripRegardless() {
        let subject = Self.manifest([100, 100, 100, 100])

        #expect(subject.startTime(ofTrackAt: 3) == 300, "exact in binary, so exact in both folds")

        for index in 0 ..< 4 {
            let located = subject.locate(bookTime: subject.startTime(ofTrackAt: index))
            #expect(located?.index == index)
            #expect(located?.offset == 0)
        }
    }

    /// And a shape where only one track is fractional, because a book is not one
    /// duration repeated: it is whatever the encoder made of forty chapters. One
    /// inexact track is enough to move every boundary after it off a
    /// representable number.
    @Test("one fractional track is enough to move the boundaries after it")
    func oneFractionalTrackMovesTheBoundariesAfterIt() {
        let subject = Self.manifest([100.0, 100.2, 100.0])

        #expect(subject.startTime(ofTrackAt: 2) == 200.2)

        for index in 0 ..< 3 {
            let located = subject.locate(bookTime: subject.startTime(ofTrackAt: index))
            #expect(located?.index == index)
            #expect(located?.offset == 0)
        }
    }

    /// Everything the old walk already got right, so the rewrite cannot have
    /// bought the boundaries at the cost of the ordinary case: a time inside a
    /// track, a time before the book, a time past its end — which clamps into
    /// the last track rather than refusing, because the clock can run a beat
    /// past a stated duration — and a book with nothing playable in it.
    @Test("the places that are not boundaries still resolve as they always did")
    func ordinaryPositionsAreUnchanged() {
        let subject = Self.manifest([100.1, 100.1, 100.1, 100.1])

        let inside = subject.locate(bookTime: 150)
        #expect(inside?.index == 1)
        #expect(abs((inside?.offset ?? 0) - 49.9) < 0.001)

        let before = subject.locate(bookTime: -30)
        #expect(before?.index == 0)
        #expect(before?.offset == 0, "a negative clock is the start of the book, not a refusal")

        let past = subject.locate(bookTime: 100_000)
        #expect(past?.index == 3, "clamped into the last track")
        #expect(past?.offset == 100.1, "at its very end")

        #expect(Self.manifest([]).locate(bookTime: 0) == nil, "no track to name")
    }

    /// The m4b alternate link the server advertises for a single-file audiobook
    /// has no duration and always 404s, so `playableTracks` drops it — and both
    /// halves of this round trip index into *that* list, not into the reading
    /// order. Pinned here because the two are easy to confuse and a mismatch
    /// between them would move every boundary by a whole track.
    @Test("both halves index the playable tracks, not the reading order")
    func bothHalvesIndexThePlayableTracks() {
        let subject = AudiobookManifest(
            metadata: .init(title: ["und": "A Book With A Dead Link"]),
            readingOrder: [
                .init(href: "whole.m4b", type: "audio/mp4"),
                .init(href: "t0.mp3", type: "audio/mpeg", duration: 100.1),
                .init(href: "t1.mp3", type: "audio/mpeg", duration: 100.1),
            ],
        )

        #expect(subject.playableTracks.count == 2)
        let located = subject.locate(bookTime: subject.startTime(ofTrackAt: 1))
        #expect(located?.index == 1)
        #expect(located?.offset == 0)
        #expect(subject.playableTracks[located?.index ?? 0].href == "t1.mp3")
    }
}
