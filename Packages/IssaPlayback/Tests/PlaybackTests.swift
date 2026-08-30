import Foundation
import IssaEPUB
import Testing

@testable import IssaPlayback

struct CommandMapTests {
    @Test("defaults match what an audiobook listener expects")
    func defaults() {
        let map = CommandMap()
        #expect(map.action(for: .tapForward, on: .phone) == .skipForward)
        #expect(map.action(for: .holdForward, on: .phone) == .nextChapter)
        #expect(map.skipForwardInterval == 30)
        #expect(map.skipBackwardInterval == 15)
    }

    @Test("the wheel means something different in the car")
    func perSurfaceBindings() {
        let map = CommandMap()
        // A chapter is too coarse a jump while driving and a sentence too fine,
        // so the car defaults to paragraph while the phone defaults to chapter.
        #expect(map.action(for: .wheelNext, on: .carPlay) == .nextParagraph)
        #expect(map.action(for: .wheelNext, on: .phone) == .nextChapter)
        #expect(map.action(for: .tapForward, on: .headphones) == .playPause)
    }

    @Test("rebinding one surface leaves the others alone")
    func rebinding() {
        var map = CommandMap()
        map.bind(.nextChapter, to: .wheelNext, on: .carPlay)
        #expect(map.action(for: .wheelNext, on: .carPlay) == .nextChapter)
        #expect(map.action(for: .wheelNext, on: .phone) == .nextChapter)
        #expect(map.action(for: .tapForward, on: .carPlay) == .skipForward)
    }

    @Test("an unbound control does nothing rather than falling back")
    func unbound() {
        var map = CommandMap(bindings: [:])
        #expect(map.action(for: .tapForward, on: .phone) == .none)
        map.bind(.playPause, to: .tapForward, on: .phone)
        #expect(map.action(for: .tapForward, on: .phone) == .playPause)
    }

    @Test("survives a round trip through Codable, so settings persist")
    func codable() throws {
        var map = CommandMap()
        map.bind(.sleepTimer, to: .holdBackward, on: .headphones)
        map.skipForwardInterval = 45
        let decoded = try JSONDecoder().decode(CommandMap.self, from: JSONEncoder().encode(map))
        #expect(decoded == map)
        #expect(decoded.action(for: .holdBackward, on: .headphones) == .sleepTimer)
        #expect(decoded.skipForwardInterval == 45)
    }
}

struct ReadalongLookupTests {
    static func timeline() throws -> (SMILTimeline, EPUBPackage) {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/readalong", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        return (SMILParser.timeline(for: package), package)
    }

    @Test("maps a position inside a track to the right sentence")
    func perFileLookup() throws {
        let (timeline, _) = try Self.timeline()
        let track1 = "OEBPS/Audio/track1.mp3"

        // Clip times restart at zero in every track, so this lookup must be
        // scoped to the file. A book-time search here lands on the wrong
        // sentence entirely.
        let opening = try #require(timeline.entry(inFile: track1, at: 1.0))
        #expect(opening.fragmentID == "ch01-s0")

        let second = try #require(timeline.entry(inFile: track1, at: 6.0))
        #expect(second.fragmentID == "ch01-s1")
    }

    @Test("the same offset in a different track resolves to a different chapter")
    func trackScoping() throws {
        let (timeline, _) = try Self.timeline()
        let first = try #require(timeline.entry(inFile: "OEBPS/Audio/track1.mp3", at: 1.0))
        let second = try #require(timeline.entry(inFile: "OEBPS/Audio/track2.mp3", at: 1.0))
        #expect(first.fragmentID == "ch01-s0")
        #expect(second.fragmentID == "ch02-s0")
        #expect(first.textHref != second.textHref)
    }

    @Test("a boundary belongs to the entry that starts there")
    func boundaries() throws {
        let (timeline, _) = try Self.timeline()
        let track1 = "OEBPS/Audio/track1.mp3"
        let atBoundary = try #require(timeline.entry(inFile: track1, at: 4.250))
        #expect(atBoundary.fragmentID == "ch01-s1")
        let justBefore = try #require(timeline.entry(inFile: track1, at: 4.249))
        #expect(justBefore.fragmentID == "ch01-s0")
    }

    @Test("a time past the last clip stays on the final sentence")
    func pastEnd() throws {
        let (timeline, _) = try Self.timeline()
        let entry = try #require(timeline.entry(inFile: "OEBPS/Audio/track1.mp3", at: 9_999))
        #expect(entry.fragmentID == "ch01-s5")
    }

    @Test("steps forward and back through sentences, across chapters")
    func sentenceStepping() throws {
        let (timeline, _) = try Self.timeline()
        let last = try #require(timeline.entries(inDocument: "OEBPS/ch01.xhtml").last)
        // Stepping past the end of a chapter continues into the next one.
        let next = try #require(timeline.entry(after: last))
        #expect(next.textHref == "OEBPS/ch02.xhtml")
        let back = try #require(timeline.entry(before: next))
        #expect(back.fragmentID == last.fragmentID)
    }

    @Test("extracts the embedded audio the aligner packs into the EPUB")
    func extractsAudio() throws {
        let (timeline, package) = try Self.timeline()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-audio-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "test", into: directory,
        )
        // Narration lives inside the EPUB, so one download yields text and audio.
        #expect(files.count == 2)
        for (href, url) in files {
            #expect(FileManager.default.fileExists(atPath: url.path), "missing extraction for \(href)")
            #expect((try Data(contentsOf: url)).count > 0)
        }
    }
}
