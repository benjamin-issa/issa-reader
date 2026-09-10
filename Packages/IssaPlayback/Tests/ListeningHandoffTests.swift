import Foundation
import IssaCore
import IssaEPUB
import Testing

@testable import IssaPlayback

/// When the car gives the book back to the phone.
///
/// The two engines are exclusive, so this decision is the only thing standing
/// between "the reader catches up with the voice" and "the book comes off the
/// dashboard at 70mph". Every rung is stated here because staging the real
/// thing needs a car, a CarPlay session and a downloaded novel — which is
/// exactly why the ladder was lifted out of `AppModel` in the first place.
@Suite("Handing listening back to the reader")
@MainActor
struct ListeningHandoffTests {
    static func fixture() throws -> (package: EPUBPackage, timeline: SMILTimeline) {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/readalong", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        return (package, SMILParser.timeline(for: package))
    }

    static let bookUUID = "readalong-uuid"

    static func anchor(
        _ href: String = "OEBPS/Audio/track2.mp3", _ offset: TimeInterval = 1.0,
    ) -> AudioAnchor {
        AudioAnchor(audioHref: href, offset: offset, writtenAt: 1)
    }

    /// Every input already set to the shape that hands the book over, so each
    /// test below moves exactly one of them and the reason it gets back is the
    /// rung it moved — not some later one it happened to trip on the way.
    static func decide(
        listeningBookUUID: String? = bookUUID,
        visibleBookUUID: String? = bookUUID,
        surface: ControlSurface = .phone,
        isForeground: Bool = true,
        anchor: AudioAnchor? = anchor(),
        isPlaying: Bool = true,
        package: EPUBPackage?,
        timeline: SMILTimeline?,
        hasReadalong: Bool = true,
    ) -> ListeningHandoff.Decision {
        ListeningHandoff.decide(
            listeningBookUUID: listeningBookUUID,
            visibleBookUUID: visibleBookUUID,
            surface: surface,
            isForeground: isForeground,
            anchor: anchor,
            isPlaying: isPlaying,
            package: package,
            timeline: timeline,
            hasReadalong: hasReadalong)
    }

    // MARK: - Placing an anchor

    /// The bridge, in the direction that matters here: the car knows a file and
    /// an offset, and only the overlay can say which sentence of which chapter
    /// that is.
    @Test("an anchor into the second track places on the second chapter's first sentence")
    func anAnchorPlacesOnItsSentence() throws {
        let (package, timeline) = try Self.fixture()

        let placed = try #require(
            ListeningHandoff.place(Self.anchor(), in: package, timeline: timeline))

        #expect(placed.spineIndex == 1, "track two narrates the second chapter")
        #expect(placed.entry.fragmentID == "ch02-s0")
        #expect(placed.entry.textHref == "OEBPS/ch02.xhtml")
    }

    /// A chunk whose first clip starts a beat in, and an anchor from before it.
    /// No sentence is being spoken there, so the exact lookup answers nothing —
    /// but the file still names the chapter, and landing nowhere would leave a
    /// listener who parked in the pause between sentences with a page that
    /// never turned.
    @Test("an offset before the file's first clip still lands on the file's chapter")
    func anOffsetBeforeTheFirstClipFallsBackToTheFile() throws {
        let (package, _) = try Self.fixture()
        // Hand-built rather than parsed: the fixture's overlays both start at
        // zero, and the whole case is a first clip that does not.
        let timeline = SMILTimeline(entries: [
            SMILEntry(
                fragmentID: "ch01-s0", textHref: "OEBPS/ch01.xhtml",
                audioHref: "OEBPS/Audio/track1.mp3",
                start: 0, end: 4, cumulativeEnd: 4),
            SMILEntry(
                fragmentID: "ch02-s0", textHref: "OEBPS/ch02.xhtml",
                audioHref: "OEBPS/Audio/track2.mp3",
                start: 0.5, end: 5, cumulativeEnd: 8.5),
        ])

        let placed = try #require(
            ListeningHandoff.place(
                Self.anchor("OEBPS/Audio/track2.mp3", 0.1),
                in: package, timeline: timeline))

        #expect(placed.entry.fragmentID == "ch02-s0")
        #expect(placed.spineIndex == 1)
    }

    /// The server's single upload against the EPUB's own chunks — the mismatch
    /// `ListeningResume` guards from the other side. Refusing is the point: a
    /// guess here is a page turn to somewhere the listener has never been.
    @Test("an anchor naming a file the overlay has never heard of places nowhere")
    func anUnknownFilePlacesNowhere() throws {
        let (package, timeline) = try Self.fixture()

        #expect(
            ListeningHandoff.place(
                Self.anchor("The Outsider.mp3", 900), in: package, timeline: timeline) == nil)
    }

    // MARK: - The ladder, rung by rung

    @Test("nothing playing is nothing to hand over")
    func notListening() throws {
        let (package, timeline) = try Self.fixture()
        let decision = Self.decide(
            listeningBookUUID: nil, package: package, timeline: timeline)
        #expect(decision == .skip(.notListening))
    }

    @Test("no reader on screen is nobody to hand it to")
    func noVisibleReader() throws {
        let (package, timeline) = try Self.fixture()
        let decision = Self.decide(
            visibleBookUUID: nil, package: package, timeline: timeline)
        #expect(decision == .skip(.noVisibleReader))
    }

    /// Browsing another book while the audiobook runs. Handing over here would
    /// stop the audio for a book nobody asked about.
    @Test("a reader open on another book is not a hand-off")
    func differentBook() throws {
        let (package, timeline) = try Self.fixture()
        let decision = Self.decide(
            visibleBookUUID: "some-other-book", package: package, timeline: timeline)
        #expect(decision == .skip(.differentBook))
    }

    /// The rung that exists for a person rather than for the code. A phone in a
    /// pocket reports a visible reader and a foreground app for the whole
    /// drive.
    @Test("the car keeps the book while it is still connected")
    func carConnected() throws {
        let (package, timeline) = try Self.fixture()
        let decision = Self.decide(
            surface: .carPlay, package: package, timeline: timeline)
        #expect(decision == .skip(.carConnected))
    }

    /// Being backgrounded does not dismiss the reader on iOS, so a visible
    /// reader alone would fire this from a pocket.
    @Test("a backgrounded app hands nothing over")
    func background() throws {
        let (package, timeline) = try Self.fixture()
        let decision = Self.decide(
            isForeground: false, package: package, timeline: timeline)
        #expect(decision == .skip(.background))
    }

    /// The same rung on a platform that has no car in it.
    ///
    /// macOS keeps the `.phone` default for the life of the process — there is
    /// no CarPlay scene to push anything else in — so `carConnected` can never
    /// fire there, and `background` is the only thing between a `readerReady`
    /// trigger and a book taken off the audiobook engine while the app sits
    /// behind another one. Worth a row of its own because that is exactly the
    /// rung the Mac had no writer for: nothing called `setForeground`, so
    /// `isForeground` was `true` for ever and this decision was unreachable.
    @Test("a phone surface is no excuse for a backgrounded app")
    func backgroundHoldsWithNoCarInSight() throws {
        let (package, timeline) = try Self.fixture()
        let decision = Self.decide(
            surface: .phone, isForeground: false, package: package, timeline: timeline)
        #expect(decision == .skip(.background))
    }

    /// Three ways to be half-open, and all of them mean the same thing: there
    /// is nothing yet to aim at. `readerReady` brings the decision back.
    @Test("a reader still opening its book is not ready to take one")
    func readerNotReady() throws {
        let (package, timeline) = try Self.fixture()
        #expect(
            Self.decide(package: nil, timeline: timeline) == .skip(.readerNotReady))
        #expect(
            Self.decide(package: package, timeline: nil) == .skip(.readerNotReady))
        #expect(
            Self.decide(package: package, timeline: timeline, hasReadalong: false)
                == .skip(.readerNotReady))
    }

    /// An engine that has played nothing has no place to hand over — the same
    /// refusal `ReadalongCoordinator.currentAnchor` makes for the same reason.
    @Test("an engine with no anchor yet hands nothing over")
    func noAnchor() throws {
        let (package, timeline) = try Self.fixture()
        let decision = Self.decide(anchor: nil, package: package, timeline: timeline)
        #expect(decision == .skip(.noAnchor))
    }

    @Test("an anchor the overlay cannot place hands nothing over")
    func anchorNamesNoFile() throws {
        let (package, timeline) = try Self.fixture()
        let decision = Self.decide(
            anchor: Self.anchor("The Outsider.mp3", 900),
            package: package, timeline: timeline)
        #expect(decision == .skip(.anchorNamesNoFile))
    }

    // MARK: - Handing over

    @Test("a car still playing hands over a sentence to carry on from")
    func handsOverWhilePlaying() throws {
        let (package, timeline) = try Self.fixture()

        let decision = Self.decide(isPlaying: true, package: package, timeline: timeline)

        let target = try #require(decision.target)
        #expect(target.wasPlaying, "the phone has to carry the voice on")
        #expect(target.spineIndex == 1)
        #expect(target.entry.fragmentID == "ch02-s0")
        #expect(target.anchor == Self.anchor())
    }

    /// The driver pressed pause at the door. The page still has to move; the
    /// room stays quiet.
    @Test("a paused car hands over a page and no sound")
    func handsOverWhilePaused() throws {
        let (package, timeline) = try Self.fixture()

        let decision = Self.decide(isPlaying: false, package: package, timeline: timeline)

        let target = try #require(decision.target)
        #expect(target.wasPlaying == false)
        #expect(target.spineIndex == 1)
    }

    /// The anchor a real audiobook engine actually produces, rather than one
    /// written by hand: a coordinator over the fixture's own chunks, seeked
    /// past the end of the first track. If the two ever disagree about how a
    /// track is named, this is what says so.
    @Test("the anchor a chunked audiobook publishes places on the chapter it is in")
    func aLiveCoordinatorsAnchorPlaces() async throws {
        let (package, timeline) = try Self.fixture()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-handoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "handoff", into: directory)
        let built = ChunkManifest.make(
            timeline: timeline, package: package, audioFiles: files,
            durations: [:], title: "Fixture")
        let subject = AudiobookCoordinator(manifest: built.manifest, source: .files(built.files))
        // The coordinator's own clock hook, unhooked from the player: a real
        // periodic observer fires with a time of zero and would overwrite the
        // seek between the call and the assertion. `ChapterClockTests` documents
        // the same hazard.
        subject.player.onTimeUpdate = nil

        let first = try #require(built.manifest.playableTracks.first?.duration)
        await subject.seek(toBookTime: first + 1)

        let anchor = try #require(subject.currentAnchor)
        let placed = try #require(
            ListeningHandoff.place(anchor, in: package, timeline: timeline))
        #expect(placed.spineIndex == 1, "one second into track two is the second chapter")
    }
}

private extension ListeningHandoff.Decision {
    /// The target, or nil for a skip — so a test can `#require` it and say what
    /// it expected rather than pattern-matching in every assertion.
    var target: ListeningHandoff.Target? {
        if case let .handOff(target) = self { return target }
        return nil
    }
}
