import Foundation
import IssaEPUB
import MediaPlayer
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

    @Test("the Controls picker offers only actions something actually performs")
    func assignableActions() {
        // `.sleepTimer` was bindable while neither coordinator performed it: a
        // dead steering-wheel button, configured in good faith.
        #expect(!PlaybackAction.assignable.contains(.sleepTimer))
        // The discrete pair exists for the system's own play/pause commands; a
        // button already has the toggle.
        #expect(!PlaybackAction.assignable.contains(.play))
        #expect(!PlaybackAction.assignable.contains(.pause))
        // Unbinding must stay possible, and the everyday actions must remain.
        #expect(PlaybackAction.assignable.contains(.none))
        #expect(PlaybackAction.assignable.contains(.playPause))
        #expect(PlaybackAction.assignable.contains(.nextChapter))
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

/// What counts as a chapter name.
///
/// A read-along coordinator has no table of contents — only the text document
/// the current sentence lives in — so asking it for "the chapter" hands back an
/// archive path. The player sheet knew to hide that; the mini bar did not, and
/// printed `OEBPS/8960978148133687104_chapter_11.xhtml` under the book's title
/// where the chapter name belongs.
struct ChapterNamingTests {
    @Test("a document href is not a chapter name", arguments: [
        "OEBPS/8960978148133687104_chapter_11.xhtml",
        "OEBPS/ch01.xhtml",
        "chapter_11.xhtml",
        "text/part1.html",
        "content.xml",
        "",
        "   ",
    ])
    func rejectsHrefs(_ candidate: String) {
        #expect(ChapterNaming.isDisplayable(candidate) == false)
    }

    @Test("a name somebody wrote is a chapter name", arguments: [
        "The Flight",
        "Chapter 11",
        "17. The When Wendy Grew Up",
        "Peter Breaks Through",
        "Épilogue",
    ])
    func acceptsNames(_ candidate: String) {
        #expect(ChapterNaming.isDisplayable(candidate))
    }
}

/// Which transport the system draws.
///
/// This is the part the unit above cannot see on its own: iOS shows `⏮ ⏭` and
/// hides the interval skips whenever the next/previous **track** commands are
/// enabled, and shows `⏪15` / `⏩30` when they are not. Registering the track
/// pair unconditionally is what made every remote control on the phone jump a
/// whole chapter and made the Lock Screen advertise that as all it could do.
///
/// Serialised because `MPRemoteCommandCenter.shared()` is process-wide.
@Suite(.serialized)
@MainActor
struct RemoteCommandRegistrationTests {
    static var center: MPRemoteCommandCenter { MPRemoteCommandCenter.shared() }

    /// Leaves no enabled commands behind for a later test — or a later run — to
    /// trip over.
    static func reset() {
        let remote = RemoteCommandCenter()
        remote.tearDown()
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    @Test("by default the system draws the skip buttons, not the track buttons")
    func defaultsDrawSkipButtons() {
        Self.reset()
        let remote = RemoteCommandCenter()
        remote.activate()
        defer { Self.reset() }

        #expect(Self.center.nextTrackCommand.isEnabled == false)
        #expect(Self.center.previousTrackCommand.isEnabled == false)
        // …while the skips are enabled and carry the intervals they claim.
        #expect(Self.center.skipForwardCommand.isEnabled)
        #expect(Self.center.skipBackwardCommand.isEnabled)
        #expect(Self.center.skipForwardCommand.preferredIntervals == [30])
        #expect(Self.center.skipBackwardCommand.preferredIntervals == [15])
    }

    @Test("binding the wheel brings the track buttons back")
    func bindingTheWheelEnablesTrackCommands() {
        Self.reset()
        var map = CommandMap()
        map.bind(.nextChapter, to: .wheelNext, on: .phone)
        let remote = RemoteCommandCenter(commandMap: map)
        remote.activate()
        defer { Self.reset() }

        #expect(Self.center.nextTrackCommand.isEnabled)
        #expect(Self.center.previousTrackCommand.isEnabled)
    }

    @Test("connecting to a car re-registers against the car's own bindings")
    func surfaceChangeReregisters() {
        Self.reset()
        let remote = RemoteCommandCenter()
        remote.activate()
        defer { Self.reset() }
        // Nothing is bound to the wheel on the phone…
        #expect(Self.center.nextTrackCommand.isEnabled == false)

        // …but the car binds it, so its buttons come into being on connect.
        remote.activeSurface = .carPlay
        #expect(Self.center.nextTrackCommand.isEnabled)

        // And go away again on disconnect, which is why assigning the surface
        // re-registers rather than merely being read at fire time.
        remote.activeSurface = .phone
        #expect(Self.center.nextTrackCommand.isEnabled == false)
    }

    @Test("a changed interval reaches the buttons the system draws")
    func intervalChangeReachesTheSystem() {
        Self.reset()
        var map = CommandMap()
        map.skipBackwardInterval = 10
        map.skipForwardInterval = 45
        let remote = RemoteCommandCenter(commandMap: map)
        remote.activate()
        defer { Self.reset() }

        #expect(Self.center.skipBackwardCommand.preferredIntervals == [10])
        #expect(Self.center.skipForwardCommand.preferredIntervals == [45])
    }
}

/// Where a control's binding is looked up — what made the Headphones tab real.
///
/// Nothing ever *assigns* `.headphones`: the CarPlay bridge only ever hands
/// over `.carPlay` and `.phone`, so before this every binding stored under the
/// headphones surface was silently discarded. The surface is inferred per
/// control from the audio route instead, and only for the wheel, because the
/// wheel — `nextTrack`/`previousTrack` — is where AirPods' double- and
/// triple-press arrive.
@MainActor
struct SurfaceResolutionTests {
    @Test("the wheel belongs to headphones while a headphone-class device is routed")
    func wheelFollowsHeadphones() {
        #expect(RemoteCommandCenter.surface(
            for: .wheelNext, active: .phone, headphonesRouted: true) == .headphones)
        #expect(RemoteCommandCenter.surface(
            for: .wheelPrevious, active: .phone, headphonesRouted: true) == .headphones)
        // Unrouted, the wheel is the phone's — a Bluetooth head unit's buttons.
        #expect(RemoteCommandCenter.surface(
            for: .wheelNext, active: .phone, headphonesRouted: false) == .phone)
    }

    @Test("the tap controls stay with the phone: skip commands only ever come from a screen")
    func tapsStayOnThePhone() {
        #expect(RemoteCommandCenter.surface(
            for: .tapForward, active: .phone, headphonesRouted: true) == .phone)
        #expect(RemoteCommandCenter.surface(
            for: .tapBackward, active: .phone, headphonesRouted: true) == .phone)
    }

    @Test("the car wins outright: CarPlay declares itself, the route does not decide")
    func carPlayWins() {
        for control in PlaybackControl.allCases {
            #expect(RemoteCommandCenter.surface(
                for: control, active: .carPlay, headphonesRouted: true) == .carPlay)
        }
    }
}

/// The read-along coordinator's seeking contract.
@MainActor
struct ReadalongCoordinatorTests {
    /// The fixture book with its narration genuinely extracted, so
    /// `play(from:)` has real files to load.
    static func make() throws -> (ReadalongCoordinator, SMILTimeline, URL) {
        let (timeline, package) = try ReadalongLookupTests.timeline()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-readalong-coordinator-\(UUID().uuidString)")
        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "coordinator-test", into: directory,
        )
        return (ReadalongCoordinator(timeline: timeline, audioFiles: files), timeline, directory)
    }

    /// The coordinator is built eagerly on open and the reader footer draws
    /// the skip buttons regardless, so before narration has played a skip had
    /// no anchor — `bookProgress` still read 0 — and resolved to sentence one
    /// of the whole book, a shelf of chapters away from the reader.
    @Test("a skip before narration has ever played refuses rather than jumping to sentence one")
    func skipBeforeNarrationDoesNothing() async throws {
        let (subject, _, directory) = try Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }

        await subject.skipBook(by: -15)
        await subject.skipBook(by: 30)

        #expect(subject.activeEntry == nil, "no anchor: the skip must refuse, not resolve")
        #expect(subject.player.currentAudioHref == nil, "nothing should have been loaded")
        #expect(subject.player.isPlaying == false)
    }

    /// `seek(toBookProgress:)` is a protocol requirement with a neutral
    /// contract — the audiobook implementation moves the playhead and nothing
    /// else — but the read-along one funnelled into `play(from:)`, so dragging
    /// the Lock Screen scrubber on a paused book started it reading aloud.
    @Test("a scrub while paused moves the playhead without starting playback")
    func pausedSeekStaysPaused() async throws {
        let (subject, timeline, directory) = try Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try #require(timeline.entries.first)
        await subject.play(from: first)
        #expect(subject.player.isPlaying)
        subject.player.pause()

        await subject.seek(toBookProgress: 0.9)

        #expect(subject.player.isPlaying == false, "a seek is not a play button")
        let landed = try #require(subject.activeEntry)
        #expect(landed.fragmentID != first.fragmentID, "the playhead must still have moved")
        #expect(subject.bookProgress > 0, "a paused scrub must still reach the scrubber")
    }

    @Test("a scrub while playing keeps playing")
    func playingSeekKeepsPlaying() async throws {
        let (subject, timeline, directory) = try Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try #require(timeline.entries.first)
        await subject.play(from: first)

        await subject.seek(toBookProgress: 0.5)
        #expect(subject.player.isPlaying)
    }

    @Test("the discrete play and pause commands hold their meaning when repeated")
    func discretePlayPause() async throws {
        let (subject, timeline, directory) = try Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try #require(timeline.entries.first)
        await subject.play(from: first)
        let map = CommandMap()

        await subject.perform(.pause, using: map)
        #expect(subject.player.isPlaying == false)
        await subject.perform(.pause, using: map)
        #expect(subject.player.isPlaying == false, "pause is not a toggle")

        await subject.perform(.play, using: map)
        #expect(subject.player.isPlaying)
        await subject.perform(.play, using: map)
        #expect(subject.player.isPlaying, "play is not a toggle")
    }
}
