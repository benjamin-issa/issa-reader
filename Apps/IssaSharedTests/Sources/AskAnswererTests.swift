import Foundation
import IssaAsk
import Testing

@testable import IssaReader_iOS

/// Where a question is answered: on the device unless the reader chose Apple's
/// servers, for that question or by default.
///
/// Two scripted models, one per place, so every test can say which one was
/// reached — a test that only looked at the answer would pass the bug where
/// the switch is drawn and every question still goes to the device, or worse,
/// where a question the reader kept on the device goes to Apple.
@Suite("Where a question is answered")
@MainActor
struct AskAnswererTests {
    @MainActor
    struct Rig {
        let coordinator: AskCoordinator
        let device: ScriptedAnswerModel
        let cloud: ScriptedAnswerModel
        let directory: URL
        let suite: String

        func cleanUp() { AskCoordinatorTests.cleanUp(directory, suite) }
    }

    static let deviceAnswer = "On the device: Alice followed a white rabbit.\nSources: 1"
    static let cloudAnswer = "On the server: Alice followed a white rabbit.\nSources: 1"

    static func rig(
        device deviceTurns: [ScriptedAnswerModel.Turn] = [.answer(deviceAnswer)],
        cloud cloudTurns: [ScriptedAnswerModel.Turn] = [.answer(cloudAnswer)],
        availability: CloudAvailability = .available(
            CloudQuota(isLimitReached: false, isApproachingLimit: false, resetDate: nil)),
    ) throws -> Rig {
        let directory = URL.temporaryDirectory
            .appending(path: "issa-ask-answerer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (defaults, suite) = SharedFixtures.scratchDefaults()
        let device = ScriptedAnswerModel(turns: deviceTurns)
        let cloud = ScriptedAnswerModel(turns: cloudTurns, contextSize: 32_768)
        let coordinator = AskCoordinator(
            store: AskIndexStore(directory: directory),
            model: device,
            cloudModel: cloud,
            cloudAvailability: { availability },
            notifier: nil,
            defaults: defaults,
        )
        return Rig(coordinator: coordinator, device: device, cloud: cloud, directory: directory, suite: suite)
    }

    static func ask(
        _ rig: Rig, _ answerer: AskAnswerer? = nil, question: String = "What did Alice follow?",
    ) async throws -> AskJob {
        let source = try AskCoordinatorTests.source()
        let job: AskJob?
        if let answerer {
            job = rig.coordinator.ask(
                question, source: source, boundary: AskCoordinatorTests.boundary(), answerer: answerer)
        } else {
            job = rig.coordinator.ask(question, source: source, boundary: AskCoordinatorTests.boundary())
        }
        let asked = try #require(job)
        await asked.task?.value
        return asked
    }

    static func answerText(_ job: AskJob) -> String? {
        if case let .answered(answer) = job.state { return answer.text }
        return nil
    }

    // MARK: - Routing

    @Test("with nothing chosen, a question stays on the device")
    func deviceByDefault() async throws {
        let rig = try Self.rig()
        defer { rig.cleanUp() }
        let job = try await Self.ask(rig)
        #expect(job.answerer == .device)
        #expect(job.answeredBy == .device)
        #expect(await rig.device.received.count == 1)
        #expect(await rig.cloud.received.isEmpty, "nothing may reach Apple's servers unasked")
        #expect(Self.answerText(job)?.hasPrefix("On the device") == true)
    }

    @Test("a question sent to Apple's servers reaches the server model, not the device")
    func cloudWhenChosen() async throws {
        let rig = try Self.rig()
        defer { rig.cleanUp() }
        let job = try await Self.ask(rig, .cloud)
        #expect(job.answerer == .cloud)
        #expect(job.answeredBy == .cloud)
        #expect(await rig.cloud.received.count == 1)
        #expect(await rig.device.received.isEmpty)
        #expect(Self.answerText(job)?.hasPrefix("On the server") == true)
    }

    /// The server is asked with its own profile, not the device's — the unit the
    /// accuracy study tunes per place.
    @Test("the server model is asked with the cloud profile")
    func cloudProfile() async throws {
        let rig = try Self.rig()
        defer { rig.cleanUp() }
        _ = try await Self.ask(rig, .cloud)
        let received = try #require(await rig.cloud.received.first)
        #expect(received.instructions == AskProfile.cloud.instructions)
        #expect(received.options.maximumResponseTokens == AskProfile.cloud.responseTokens)
        #expect(received.options.reasoning == AskProfile.cloud.reasoning)
    }

    /// The choice is per question: a server question leaves no state behind
    /// that sends the next one there too.
    @Test("one question sent to Apple's servers doesn't send the next")
    func choiceIsPerQuestion() async throws {
        let rig = try Self.rig(
            device: [.answer(Self.deviceAnswer)], cloud: [.answer(Self.cloudAnswer)])
        defer { rig.cleanUp() }
        _ = try await Self.ask(rig, .cloud)
        rig.coordinator.discard(bookUUID: try AskCoordinatorTests.source().bookUUID)
        let next = try await Self.ask(rig)
        #expect(next.answerer == .device)
        #expect(await rig.device.received.count == 1)
        #expect(await rig.cloud.received.count == 1)
    }

    @Test("Try again asks the same place", arguments: [AskAnswerer.device, .cloud])
    func tryAgainKeepsThePlace(place: AskAnswerer) async throws {
        let failure = ScriptedAnswerModel.Turn(failure: AskFailure.busy)
        let rig = try Self.rig(
            device: [failure, .answer(Self.deviceAnswer)], cloud: [failure, .answer(Self.cloudAnswer)])
        defer { rig.cleanUp() }
        let first = try await Self.ask(rig, place)
        guard case .failed(.busy) = first.state else {
            Issue.record("expected the scripted failure, got \(first.state)")
            return
        }
        // What the sheet's Try again does: the job's own answerer.
        let again = try await Self.ask(rig, first.answerer)
        #expect(again.answeredBy == place)
        let device = await rig.device.received.count
        let cloud = await rig.cloud.received.count
        #expect(place == .device ? (device == 2 && cloud == 0) : (cloud == 2 && device == 0))
    }

    // MARK: - When Apple's servers can't answer

    /// Apple's advice, and the only silent fallback: the device answers, and
    /// the job records that it did so the sheet can say it.
    @Test("unreachable servers: the device answers, and the job says so")
    func unreachableFallsBack() async throws {
        let rig = try Self.rig(cloud: [ScriptedAnswerModel.Turn(failure: AskFailure.cloudUnreachable)])
        defer { rig.cleanUp() }
        let job = try await Self.ask(rig, .cloud)
        #expect(job.answerer == .cloud)
        #expect(job.answeredBy == .device)
        #expect(job.fellBackToDevice)
        #expect(job.fallback == .unreachable)
        #expect(Self.answerText(job)?.hasPrefix("On the device") == true)
        #expect(AskSheet.fellBackSentence(for: .unreachable).contains("Couldn't reach Apple's servers"))
    }

    /// The servers' guardrails cannot be relaxed for fiction; the device's
    /// can. A declined question is answered there, and the answer says why.
    @Test("declined by the servers: the device answers, and the job says so")
    func declinedFallsBack() async throws {
        let rig = try Self.rig(cloud: [ScriptedAnswerModel.Turn(failure: AskFailure.declined)])
        defer { rig.cleanUp() }
        let job = try await Self.ask(rig, .cloud)
        #expect(job.answeredBy == .device)
        #expect(job.fallback == .declined)
        #expect(Self.answerText(job)?.hasPrefix("On the device") == true)
        #expect(await rig.device.received.count == 1)
        #expect(AskSheet.fellBackSentence(for: .declined).contains("declined"))
    }

    /// A spent allowance is the reader's to decide about: no question goes to
    /// the device behind their back, and the failure offers it.
    @Test("out of allowance: no silent fallback, but the device is offered",
          arguments: [AskFailure.cloudLimitReached(resetDate: nil)])
    func noSilentFallback(failure: AskFailure) async throws {
        let rig = try Self.rig(cloud: [ScriptedAnswerModel.Turn(failure: failure)])
        defer { rig.cleanUp() }
        let job = try await Self.ask(rig, .cloud)
        guard case let .failed(reported) = job.state else {
            Issue.record("expected a failure, got \(job.state)")
            return
        }
        #expect(reported == failure)
        #expect(reported.offersDeviceInstead)
        #expect(await rig.device.received.isEmpty)
        #expect(!job.fellBackToDevice)
    }

    /// The sheet's switch can be out of date, and "Try again" on a question
    /// the allowance stopped asks the servers again. With the allowance spent
    /// that is the reader's to decide: nothing is asked of either model, and
    /// the sheet says so with the device offered. Answered on the device, as
    /// it once was, "Try again" did what "Answer on this iPhone" does, without
    /// a word.
    @Test("a question for servers whose allowance is spent fails with it, and reaches no model")
    func spentAllowanceIsSaid() async throws {
        let rig = try Self.rig(availability: .limitReached(resetDate: nil))
        defer { rig.cleanUp() }
        let job = try await Self.ask(rig, .cloud)
        guard case let .failed(failure) = job.state else {
            Issue.record("expected a failure, got \(job.state)")
            return
        }
        #expect(failure == .cloudLimitReached(resetDate: nil))
        #expect(failure.offersDeviceInstead)
        #expect(job.answerer == .cloud)
        #expect(await rig.cloud.received.isEmpty)
        #expect(await rig.device.received.isEmpty)
    }

    /// Servers that can't be reached from here right now: answered on the
    /// device, as an unreachable request is, and the job says so.
    @Test("a question for servers that can't be reached goes to the device, and says so")
    func unreachableServersMeanTheDevice() async throws {
        let rig = try Self.rig(availability: .unavailable(reason: "test"))
        defer { rig.cleanUp() }
        let job = try await Self.ask(rig, .cloud)
        #expect(job.answerer == .cloud)
        #expect(job.answeredBy == .device)
        #expect(job.fallback == .unreachable)
        #expect(job.fellBackToDevice)
        #expect(await rig.cloud.received.isEmpty)
        #expect(await rig.device.received.count == 1)
    }

    // MARK: - Warming

    /// Warming the server model is itself a request to Apple, so it waits for
    /// the reader's choice, and happens once.
    @Test("the server model is warmed only once chosen, and only once")
    func warmsOnlyWhenChosen() async throws {
        let rig = try Self.rig()
        defer { rig.cleanUp() }
        _ = try await Self.ask(rig)
        #expect(await rig.cloud.prewarmCount == 0)
        await rig.coordinator.prepareCloud()?.value
        await rig.coordinator.prepareCloud()?.value
        #expect(await rig.cloud.prewarmCount == 1)
    }

    @Test("servers that can't take a question are never warmed")
    func unusableNeverWarmed() async throws {
        let rig = try Self.rig(availability: .limitReached(resetDate: nil))
        defer { rig.cleanUp() }
        #expect(rig.coordinator.prepareCloud() == nil)
        #expect(await rig.cloud.prewarmCount == 0)
    }

    // MARK: - The setting

    @Test("the default is off, and nothing is stored for a reader who never chose")
    func settingOffByDefault() {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        #expect(!PlaybackSettings(suiteName: suite).askUsesAppleServers)
        #expect(UserDefaults(suiteName: suite)?.object(forKey: "issa.ask.appleServersByDefault") == nil)
    }

    @Test("the default is what a relaunch restores, and independent of Ask itself",
          arguments: [true, false])
    func settingPersists(on: Bool) {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings(suiteName: suite)
        settings.askUsesAppleServers = on
        settings.askEnabled = !on
        let relaunched = PlaybackSettings(suiteName: suite)
        #expect(relaunched.askUsesAppleServers == on)
        #expect(relaunched.askEnabled == !on)
    }

    // MARK: - Words

    @Test("the switch's caption says what leaves the device and where it goes")
    func captionSaysWhatLeaves() {
        let caption = AskSheet.appleServersCaption(
            for: .available(CloudQuota(isLimitReached: false, isApproachingLimit: false, resetDate: nil)))
        #expect(caption.contains("question"))
        #expect(caption.contains("passages"))
        #expect(caption.contains("Apple"))
        // What leaves and to whom, and nothing said on Apple's behalf.
        #expect(!caption.contains("doesn't keep"))
        #expect(!caption.contains("PCC"))
    }

    /// No time is promised: in the 1.8.0 study the reset Apple reported moved
    /// fifteen minutes on with every request, so a time on screen would be a
    /// promise the servers do not keep.
    @Test("a spent allowance says so, offers the device, and promises no time")
    func captionWhenSpent() throws {
        let reset = try #require(Calendar.current.date(byAdding: .minute, value: 15, to: .now))
        let caption = AskSheet.appleServersCaption(for: .limitReached(resetDate: reset))
        #expect(caption.contains("answers from Apple's servers"))
        #expect(caption.contains("Try again later"))
        #expect(caption.contains("answer on this"))
        #expect(!caption.contains(reset.formatted(date: .omitted, time: .shortened)))
    }

    @Test("Settings explains the default, links Apple's page, and offers it only where it works")
    func settingsCopy() {
        let footer = AskSettingsSection.footer(for: .available, askEnabled: true, cloudOffered: true)
        #expect(footer.contains("nothing leaves it"))
        #expect(footer.contains("your question and parts of the book are sent to Apple"))
        // What leaves and to whom, and nothing said on Apple's behalf: what
        // Apple does with it is on the page the link opens.
        #expect(!footer.contains("Apple says"))
        #expect(!footer.contains("aren't stored"))
        #expect(!footer.contains("PCC"))
        #expect(AskSettingsSection.cloudLinkTitle == "About Apple's AI Servers")
        #expect(AskSettingsSection.privateCloudComputeURL.host() == "www.apple.com")
        let usable = CloudAvailability.available(
            CloudQuota(isLimitReached: false, isApproachingLimit: false, resetDate: nil))
        #expect(AskSettingsSection.offersCloudSwitch(availability: .available, cloud: usable, askEnabled: true))
        #expect(!AskSettingsSection.offersCloudSwitch(availability: .available, cloud: usable, askEnabled: false))
        #expect(!AskSettingsSection.offersCloudSwitch(
            availability: .available, cloud: .unavailable(reason: "test"), askEnabled: true))
        #expect(!AskSettingsSection.offersCloudSwitch(
            availability: .appleIntelligenceOff, cloud: usable, askEnabled: true))
    }

    @Test("with a key, Settings says what goes to the provider, and nothing on its behalf")
    func settingsCopyWithAKey() {
        let withDevice = AskSettingsSection.note(
            for: .available, askEnabled: true, cloudOffered: false, providers: [.anthropic])
        #expect(withDevice.contains("nothing leaves it"))
        #expect(withDevice.contains("go to Anthropic, with the text of the book up to where you've read"))
        let keyOnly = AskSettingsSection.note(
            for: .unsupportedDevice, askEnabled: true, cloudOffered: false, providers: [.anthropic])
        #expect(keyOnly.contains("sent to Anthropic, using your own key"))
        for footer in [withDevice, keyOnly] {
            #expect(footer.contains("Settings › Advanced"))
            #expect(!footer.contains("says"))
            #expect(!footer.contains("30 days"))
            #expect(!footer.contains("train"))
        }
    }

    @Test("failures name the place that was asked")
    func failureNamesThePlace() {
        #expect(AskFailure.declined.message(deviceNoun: "iPhone", answerer: .cloud)
            .contains("Apple's servers"))
        #expect(AskFailure.declined.message(deviceNoun: "iPhone")
            .contains("Apple Intelligence"))
        #expect(!AskFailure.couldNotAnswer.contains("Apple Intelligence"),
                "the engine says this for either place")
    }
}
