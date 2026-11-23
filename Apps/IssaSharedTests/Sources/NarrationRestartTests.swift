import AVFoundation
import Foundation
import IssaCore
import Testing

@testable import IssaPlayback
@testable import IssaReader_iOS

/// The reader's side of narration that goes silent: after a phone call on 21
/// Nov 2026 a press of play drew Pause over silence and said nothing.
///
/// On the simulator, so the session code the Mac compiles out runs: the
/// rebuild sets up and takes the real `AVAudioSession`. A real reset of the
/// media services cannot be staged, and posting the system's notice would
/// rebuild every other suite's players too, so the notice's handler is called
/// as its observer calls it.
@Suite("Narration that stopped, and saying so", .serialized)
@MainActor
struct NarrationRestartTests {
    /// The fixture book over long silent files. Its own audio is an eighth
    /// of a second a file, so every place in it is the end of a file, where a
    /// stopped engine is the item pausing itself and rightly not a dead start.
    private static func opened() async throws -> (model: ReaderModel, directory: URL, player: AudioPlayer) {
        let (model, directory) = try await NarrationStopTests.opened()
        let timeline = try #require(model.timeline)
        let silent = Dictionary(uniqueKeysWithValues: Set(timeline.entries.map(\.audioHref)).map { ($0, Self.silence) })
        model.attachNarration(timeline: timeline, audioFiles: silent)
        let player = try #require(model.readalong?.player)
        player.onTimeUpdate = nil
        player.onFinishedFile = nil
        // Driven by hand below.
        player.startCheckDelay = .seconds(3600)
        player.watchdogInterval = .seconds(3600)
        return (model, directory, player)
    }

    /// Ten minutes of eight-bit, 2 kHz mono silence, written once per run.
    static let silence: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-narration-restart-silence-v1.wav")
        let samples = 600 * 2_000
        var data = Data()
        func le32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        le32(UInt32(36 + samples))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        le32(16)
        le16(1)
        le16(1)
        le32(2_000)
        le32(2_000)
        le16(1)
        le16(8)
        data.append(contentsOf: Array("data".utf8))
        le32(UInt32(samples))
        data.append(Data(repeating: 0x80, count: samples))
        try? data.write(to: url, options: .atomic)
        return url
    }()

    @Test("a reset under playing narration rebuilds the engine on the real session, and it plays on unannounced")
    func resetWhilePlaying() async throws {
        let (model, directory, player) = try await Self.opened()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.togglePlayback()
        try #require(model.isPlaying)
        let engine = player.engineIdentity
        let place = player.currentTime

        player.mediaServicesWereReset()
        await player.rebuildTask?.value

        #expect(player.engineIdentity != engine, "the dead engine was kept")
        #expect(model.isPlaying)
        #expect(abs(player.currentTime - place) < 0.25, "reopened at \(player.currentTime), not \(place)")
        #expect(model.chapterNotice == nil, "a rebuild that worked is not news")
    }

    @Test("a reset under paused narration leaves it paused")
    func resetWhilePaused() async throws {
        let (model, directory, player) = try await Self.opened()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.togglePlayback()
        await model.togglePlayback()
        try #require(!model.isPlaying)

        player.mediaServicesWereReset()
        await player.rebuildTask?.value

        #expect(player.rebuilds == 1)
        #expect(!model.isPlaying, "a paused book started by itself")
    }

    @Test("a start that stays silent is rebuilt once, then stopped, and the reader is told until it plays")
    func deadStartIsSaidUntilItPlays() async throws {
        let (model, directory, player) = try await Self.opened()
        defer { try? FileManager.default.removeItem(at: directory) }
        player.engineTimeControl = { .paused }

        await model.togglePlayback()
        try #require(model.isPlaying, "the press itself goes through")
        player.checkStart(now: .now + .seconds(1))
        await player.rebuildTask?.value
        #expect(player.rebuilds == 1)
        player.checkStart(now: .now + .seconds(1))

        #expect(!model.isPlaying, "the button still said playing over silence")
        let notice = try #require(model.chapterNotice, "nothing told the reader why it went quiet")
        #expect(notice.persists, "the notice would have gone in five seconds")
        #expect(notice.message == ReaderModel.narrationAudioStopped)
        #expect(ChapterNoticeBanner.lifetime(of: notice, in: .reader) == nil)
        #expect(ChapterNoticeBanner.lifetime(of: notice, in: .television) == nil)

        player.engineTimeControl = nil
        await model.togglePlayback()

        #expect(model.isPlaying)
        #expect(model.chapterNotice == nil, "the notice outlived the narration playing again")
    }

    @Test("a press refused while a call holds the audio says so, and stays until a play goes through")
    func busyPressIsSaid() async throws {
        let (model, directory, player) = try await Self.opened()
        defer { try? FileManager.default.removeItem(at: directory) }
        player.activateSession = { false }

        await model.togglePlayback()

        #expect(!model.isPlaying)
        let notice = try #require(model.chapterNotice)
        #expect(notice.persists)
        #expect(notice.message == ReaderModel.narrationAudioBusy)
        #expect(player.startFailure == .audioBusy, "the player sheet has nothing to show")

        player.activateSession = { true }
        await model.togglePlayback()

        #expect(model.isPlaying)
        #expect(model.chapterNotice == nil)
        #expect(player.startFailure == nil)
    }

    @Test("a file that dies while playing says so, where nobody was waiting on a press")
    func itemDyingMidPlayIsSaid() async throws {
        let (model, directory, player) = try await Self.opened()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.togglePlayback()
        try #require(model.isPlaying)

        player.itemDidStop(generation: player.itemGenerationForTests, reason: "test", servicesReset: false)

        #expect(!model.isPlaying)
        let notice = try #require(model.chapterNotice, "a stop the reader did not ask for went unsaid")
        #expect(notice.persists)
        #expect(notice.message == ReaderModel.narrationUnplayable)
    }

    @Test("a tap takes a persistent notice down")
    func tapDismisses() async throws {
        let (model, directory, player) = try await Self.opened()
        defer { try? FileManager.default.removeItem(at: directory) }
        player.activateSession = { false }
        await model.togglePlayback()
        let notice = try #require(model.chapterNotice)

        model.dismissChapterNotice(notice)

        #expect(model.chapterNotice == nil)
    }

    @Test("an ordinary chapter notice still goes by itself, and narration playing does not take it")
    func ordinaryNoticeStillExpires() async throws {
        let (model, opening) = try await ChapterFailureTests().opened()
        defer { opening.tearDown() }
        try #require(model.phase == .ready)
        await model.go(toChapter: 1)
        await model.go(toChapter: 2)
        let notice = try #require(model.chapterNotice)

        #expect(!notice.persists)
        #expect(ChapterNoticeBanner.lifetime(of: notice, in: .reader) == .seconds(5))
        #expect(ChapterNoticeBanner.lifetime(of: notice, in: .television) == .seconds(6))
        model.narrationPlayed()
        #expect(model.chapterNotice == notice, "playing narration took down a notice about a chapter")
    }
}
