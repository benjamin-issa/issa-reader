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
        player.startCheckPatience = .seconds(3600)
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
        // Well into the file, so "kept" cannot be mistaken for "back to zero".
        let place: TimeInterval = 300
        try #require(await player.seek(to: place))
        let engine = player.engineIdentity
        var clockWhileReopening: TimeInterval?
        player.whileLoadingAsset = { clockWhileReopening = player.currentTime }

        player.mediaServicesWereReset()
        await player.rebuildTask?.value

        #expect(player.engineIdentity != engine, "the dead engine was kept")
        #expect(model.isPlaying)
        #expect(clockWhileReopening == place, "the clock read \(String(describing: clockWhileReopening)) while it reopened")
        // Real audio plays on after the reopen, so only a floor is exact; the
        // ceiling is wider than any stall on a loaded machine.
        #expect(player.currentTime >= place - 0.01 && player.currentTime < place + 10,
                "reopened at \(player.currentTime), not \(place)")
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
        Self.twoLooks(player)
        await player.rebuildTask?.value
        #expect(player.rebuilds == 1)
        Self.twoLooks(player)

        #expect(!model.isPlaying, "the button still said playing over silence")
        let notice = try #require(model.chapterNotice, "nothing told the reader why it went quiet")
        #expect(notice.persists, "the notice would have gone in five seconds")
        #expect(notice.message == ReaderModel.narrationAudioStopped)
        #expect(ChapterNoticeBanner.lifetime(of: notice, in: .reader) == nil)
        #expect(ChapterNoticeBanner.lifetime(of: notice, in: .television) == nil)

        player.engineTimeControl = nil
        await model.togglePlayback()
        #expect(model.isPlaying)
        #expect(model.chapterNotice == notice, "a press took the reason down before anything was heard")

        Self.heardToPlay(player)

        #expect(model.chapterNotice == nil, "the notice outlived the narration playing again")
    }

    /// The two looks the start check's timers would take.
    static func twoLooks(_ player: AudioPlayer) {
        player.checkStart(now: .now + .seconds(1))
        player.checkStart(now: .now + .seconds(3))
    }

    /// The engine's clock moving under a fresh look: playing confirmed.
    static func heardToPlay(_ player: AudioPlayer) {
        player.engineTimeControl = { .playing }
        let moving = player.engineTime + 1
        player.engineClock = { moving }
        twoLooks(player)
        player.engineClock = nil
        player.engineTimeControl = nil
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

        // A second refused press does not put the same words up again: each
        // new notice was announced to VoiceOver once more.
        await model.togglePlayback()
        #expect(model.chapterNotice == notice, "the same reason was posted again")

        player.activateSession = { true }
        await model.togglePlayback()
        #expect(model.isPlaying)
        #expect(model.chapterNotice == notice, "the press took the reason down before anything was heard")

        Self.heardToPlay(player)

        #expect(model.chapterNotice == nil)
        #expect(player.startFailure == nil)
    }

    @Test("an ordinary notice does not cover the reason narration is silent")
    func ordinaryNoticeDoesNotCoverAFailure() async throws {
        let (model, directory, player) = try await Self.opened()
        defer { try? FileManager.default.removeItem(at: directory) }
        player.activateSession = { false }
        await model.togglePlayback()
        let failure = try #require(model.chapterNotice)

        model.postNotice(ReaderModel.ChapterNotice(message: "A chapter of this book couldn't be opened, so it was skipped."))

        #expect(model.chapterNotice == failure, "a chapter notice covered why narration is silent")
        model.postNotice(ReaderModel.ChapterNotice(message: ReaderModel.narrationAudioStopped, persists: true))
        #expect(model.chapterNotice?.message == ReaderModel.narrationAudioStopped, "a newer reason was refused")
    }

    /// The audiobook engine's player is not the reader's own: its failures,
    /// including a give-up seconds after the press, reach the page through
    /// `watchAudiobookFailures`, and the player sheet shows `startFailure`.
    @Test("a failure of the audiobook engine reaches the reader's page and the player sheet")
    func audiobookFailureReachesThePage() async throws {
        let (model, directory, _) = try await Self.opened()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audiobook = AudioPlayer()
        audiobook.startCheckDelay = .seconds(3600)
        audiobook.startCheckPatience = .seconds(3600)
        #expect(await audiobook.load(url: Self.silence, href: "track.wav", startAt: 30) == .loaded)
        model.watchAudiobookFailures(of: audiobook)
        audiobook.play()
        audiobook.engineTimeControl = { .paused }

        Self.twoLooks(audiobook)
        await audiobook.rebuildTask?.value
        Self.twoLooks(audiobook)

        #expect(!audiobook.isPlaying)
        let notice = try #require(model.chapterNotice, "the audiobook's give-up never reached the page")
        #expect(notice.persists)
        #expect(notice.message == ReaderModel.narrationAudioStopped)
        #expect(audiobook.startFailure == .audioStopped, "the player sheet has nothing to show")
        #expect(ReaderModel.narrationFailureText(try #require(audiobook.startFailure)) == ReaderModel.narrationAudioStopped)
    }

    /// The reader screen's press on the audiobook engine says only what that
    /// press found; a failure an earlier press left recorded is not this one.
    @Test("a declined press on the audiobook engine says nothing, whatever an earlier press left")
    func declinedAudiobookPressSaysNothing() async throws {
        let (model, directory, _) = try await Self.opened()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audiobook = AudioPlayer()
        audiobook.activateSession = { false }
        audiobook.play()
        try #require(audiobook.startFailure == .audioBusy)

        model.audiobookResumeFinished(.landed)
        model.audiobookResumeFinished(nil)
        #expect(model.chapterNotice == nil, "a stale failure was said for a press that did not fail")

        model.audiobookResumeFinished(.unplayable)
        #expect(model.chapterNotice?.message == ReaderModel.narrationUnplayable)
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
