import Foundation
import Testing

@testable import IssaCore

/// Mapping a place in the downloaded file to a place the server understands.
@Suite("The offline stand-in's place in the server's terms")
struct OfflineStandInTests {
    private static func kept(_ durations: [Double]) -> AudiobookManifest {
        AudiobookManifest(
            metadata: .init(title: ["und": "T"]),
            readingOrder: durations.enumerated().map {
                .init(href: "/api/track-\($0.offset + 1).mp3", type: "audio/mpeg", title: "T\($0.offset + 1)", duration: $0.element)
            })
    }

    @Test("a point inside a middle track names that track and the offset into it")
    func middleTrack() throws {
        let place = try #require(OfflineStandIn.place(
            atFileTime: 130, kept: Self.kept([100, 100, 100]), fileLength: 300))
        #expect(place.trackIndex == 1)
        #expect(place.track.href == "/api/track-2.mp3")
        #expect(place.offset == 30)
        #expect(abs(place.progression - 0.3) < 1e-9)
        #expect(abs(place.totalProgression - 130.0 / 300) < 1e-9)
    }

    @Test("a track boundary is the start of the next track")
    func boundary() throws {
        let place = try #require(OfflineStandIn.place(
            atFileTime: 200, kept: Self.kept([100, 100, 100]), fileLength: 300))
        #expect(place.trackIndex == 2)
        #expect(place.offset == 0)
    }

    @Test("the last track, and the end of the file")
    func lastTrack() throws {
        let kept = Self.kept([100, 100, 100])
        let inside = try #require(OfflineStandIn.place(atFileTime: 250, kept: kept, fileLength: 300))
        #expect(inside.trackIndex == 2)
        #expect(inside.offset == 50)
        let end = try #require(OfflineStandIn.place(atFileTime: 300, kept: kept, fileLength: 300))
        #expect(end.trackIndex == 2)
        #expect(end.offset == 100)
        #expect(end.totalProgression == 1)
    }

    @Test("a kept manifest of another length gives no place")
    func mismatch() {
        #expect(OfflineStandIn.place(atFileTime: 10, kept: Self.kept([100, 100]), fileLength: 300) == nil)
        // Within the tolerance of two seconds on a short book, and outside it.
        #expect(OfflineStandIn.place(atFileTime: 10, kept: Self.kept([100, 100]), fileLength: 201.5) != nil)
        #expect(OfflineStandIn.place(atFileTime: 10, kept: Self.kept([100, 100]), fileLength: 203) == nil)
        // Half a percent of a long book.
        #expect(OfflineStandIn.place(atFileTime: 10, kept: Self.kept([20_000]), fileLength: 20_090) != nil)
        #expect(OfflineStandIn.place(atFileTime: 10, kept: Self.kept([20_000]), fileLength: 20_110) == nil)
    }

    @Test("no kept manifest gives no place")
    func none() {
        #expect(OfflineStandIn.place(atFileTime: 10, kept: nil, fileLength: 300) == nil)
    }

    @Test("a one-track manifest maps to itself")
    func identity() throws {
        let place = try #require(OfflineStandIn.place(
            atFileTime: 42, kept: Self.kept([300]), fileLength: 300))
        #expect(place.trackIndex == 0)
        #expect(place.offset == 42)
        #expect(abs(place.progression - 42.0 / 300) < 1e-9)
        #expect(abs(place.totalProgression - place.progression) < 1e-9)
    }

    @Test("the device-only place is kept beside the download and goes with it")
    func devicePlace() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "issa-place-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let uuid = "0198ab12-cd34-4e56-8f90-123456789abc"
        try Data("x".utf8).write(to: BookContentService.localURL(in: directory, bookUUID: uuid, format: .audiobook))
        #expect(BookContentService.standInPlace(bookUUID: uuid, in: directory) == nil)

        BookContentService.saveStandInPlace(
            StandInPlace(fileSeconds: 61.5, writtenAt: 1_700_000_000_000), bookUUID: uuid, in: directory)
        #expect(BookContentService.standInPlace(bookUUID: uuid, in: directory)
            == StandInPlace(fileSeconds: 61.5, writtenAt: 1_700_000_000_000))
        #expect(!BookContentService.downloadedFormats(bookUUID: uuid, in: directory).isEmpty)

        BookContentService.removeDownload(bookUUID: uuid, format: .audiobook, in: directory)
        #expect(BookContentService.standInPlace(bookUUID: uuid, in: directory) == nil)
    }
}
