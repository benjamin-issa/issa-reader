import Foundation
import IssaEPUB
import Testing

@testable import IssaPlayback

/// What a button does when nobody has said otherwise.
///
/// The rule these encode is blunt on purpose: **no default on any surface moves
/// a whole chapter.** A chapter is tens of minutes, and a control that jumps one
/// unasked — on a lock screen, on AirPods, on a steering wheel — loses a
/// listener's place outright. Chapter stays one pick away in Settings.
struct CommandMapTests {
    @Test("no default on any surface moves a whole chapter")
    func noChapterDefaults() {
        // Asserted as a property rather than as a list of expected values,
        // because a list is exactly what the next edit to the table outgrows
        // without anybody noticing.
        #expect(CommandMap.defaultsIncludeAChapterJump == false)
    }

    @Test("forward and back are time skips, and the intervals are 15 back / 30 forward")
    func skipDefaults() {
        let map = CommandMap()
        #expect(map.action(for: .tapForward, on: .phone) == .skipForward)
        #expect(map.action(for: .tapBackward, on: .phone) == .skipBackward)
        #expect(map.action(for: .tapForward, on: .carPlay) == .skipForward)
        #expect(map.action(for: .tapBackward, on: .carPlay) == .skipBackward)
        #expect(map.action(for: .doubleTapForward, on: .headphones) == .skipForward)
        #expect(map.action(for: .doubleTapBackward, on: .headphones) == .skipBackward)
        #expect(map.skipForwardInterval == 30)
        #expect(map.skipBackwardInterval == 15)
    }

    @Test("hold moves by paragraph, which is a unit and not a chapter")
    func holdDefaults() {
        let map = CommandMap()
        #expect(map.action(for: .holdForward, on: .phone) == .nextParagraph)
        #expect(map.action(for: .holdBackward, on: .phone) == .previousParagraph)
    }

    @Test("the phone leaves the track buttons alone so the Lock Screen draws the skips")
    func phoneDoesNotClaimTrackCommands() {
        let map = CommandMap()
        // The whole point: with nothing bound to the wheel, iOS has no track
        // command to draw and falls back to the interval skips.
        #expect(map.usesTrackCommands(on: .phone) == false)
        #expect(map.usesTrackCommands(on: .headphones) == false)
    }

    @Test("the car binds the wheel, because an unbound wheel is a dead button at speed")
    func carPlayClaimsTrackCommands() {
        let map = CommandMap()
        #expect(map.usesTrackCommands(on: .carPlay))
        #expect(map.action(for: .wheelNext, on: .carPlay) == .skipForward)
        #expect(map.action(for: .wheelPrevious, on: .carPlay) == .skipBackward)
    }

    @Test("binding the wheel brings the track commands back")
    func bindingTheWheelReenablesTrackCommands() {
        var map = CommandMap()
        #expect(map.usesTrackCommands(on: .phone) == false)
        map.bind(.nextChapter, to: .wheelNext, on: .phone)
        #expect(map.usesTrackCommands(on: .phone))
        // And unbinding takes them away again.
        map.bind(.none, to: .wheelNext, on: .phone)
        #expect(map.usesTrackCommands(on: .phone) == false)
    }

    @Test("rebinding one surface leaves the others alone")
    func rebinding() {
        var map = CommandMap()
        map.bind(.nextChapter, to: .wheelNext, on: .carPlay)
        #expect(map.action(for: .wheelNext, on: .carPlay) == .nextChapter)
        #expect(map.action(for: .wheelNext, on: .phone) == .none)
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

    // MARK: - Migration
    //
    // Anyone who has already opened the app has the old table sitting in the
    // App Group's defaults, so changing `defaultBindings` alone reaches nobody.

    /// A map as an older build wrote it: the old table, and no version field at
    /// all — which is the shape that actually exists on the reader's phone.
    static func storedByOldBuild(_ bindings: CommandMap.Bindings) throws -> Data {
        let data = try JSONEncoder().encode(
            CommandMap(bindings: bindings, bindingsVersion: 0))
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "bindingsVersion")
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test("an install carrying the old chapter bindings is moved onto the new ones")
    func migratesLegacyBindings() throws {
        let data = try Self.storedByOldBuild(CommandMap.legacyBindings)
        let map = try JSONDecoder().decode(CommandMap.self, from: data)

        // The reported complaint, gone: nothing reachable jumps a chapter.
        #expect(map.action(for: .wheelNext, on: .phone) == .none)
        #expect(map.action(for: .wheelPrevious, on: .phone) == .none)
        #expect(map.action(for: .wheelNext, on: .headphones) == .none)
        #expect(map.action(for: .holdForward, on: .phone) == .nextParagraph)
        #expect(map.usesTrackCommands(on: .phone) == false)
        #expect(map.bindingsVersion == CommandMap.currentBindingsVersion)
    }

    @Test("a binding the reader chose themselves survives the migration")
    func migrationKeepsDeliberateChoices() throws {
        var legacy = CommandMap.legacyBindings
        // Two deliberate departures from the old table. The second is itself a
        // chapter jump, and must survive precisely because they asked for it —
        // the rule is "never by default", not "never".
        legacy[.phone]?[.wheelNext] = .sleepTimer
        legacy[.headphones]?[.wheelNext] = .previousChapter
        let map = try JSONDecoder().decode(
            CommandMap.self, from: Self.storedByOldBuild(legacy))

        #expect(map.action(for: .wheelNext, on: .phone) == .sleepTimer)
        #expect(map.action(for: .wheelNext, on: .headphones) == .previousChapter)
        // …while the ones they never touched still move to the new defaults.
        #expect(map.action(for: .holdForward, on: .phone) == .nextParagraph)
        #expect(map.action(for: .wheelPrevious, on: .phone) == .none)
        #expect(map.action(for: .wheelPrevious, on: .headphones) == .none)
        // And having kept a wheel binding, they keep the track buttons too.
        #expect(map.usesTrackCommands(on: .phone))
        #expect(map.usesTrackCommands(on: .headphones))
    }

    @Test("a map already on the current version is not migrated again")
    func doesNotRemigrate() throws {
        var map = CommandMap()
        map.bind(.nextChapter, to: .tapForward, on: .phone)
        let decoded = try JSONDecoder().decode(
            CommandMap.self, from: JSONEncoder().encode(map))
        #expect(decoded.action(for: .tapForward, on: .phone) == .nextChapter)
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
