import Foundation
import IssaAsk
import IssaCore
import Testing

@testable import IssaReader_iOS

/// A reader's own Anthropic or OpenAI key: where a question goes, and where it
/// must not.
///
/// One scripted model per place — the device, Apple's servers, and each
/// provider — so every test says which one was reached. The keys live in
/// memory; nothing here touches the Keychain or a network.
@Suite("A reader's own AI key")
@MainActor
struct AskProviderTests {
    final class MemoryKeychain: TokenPersisting, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: String] = [:]
        func read(account: String) -> String? { lock.withLock { stored[account] } }
        @discardableResult
        func write(_ token: String, account: String) -> Bool {
            lock.withLock { stored[account] = token }
            return true
        }
        @discardableResult
        func delete(account: String) -> Bool {
            lock.withLock { _ = stored.removeValue(forKey: account) }
            return true
        }
    }

    @MainActor
    final class Rig {
        let coordinator: AskCoordinator
        let device: ScriptedAnswerModel
        let cloud: ScriptedAnswerModel
        var providers: [ProviderKind: ScriptedAnswerModel] = [:]
        /// Every model the coordinator built for a key, in order: (provider, model id, key).
        var built: [(ProviderKind, String, String)] = []
        let keychain: MemoryKeychain
        let directory: URL
        let suite: String

        init(
            deviceReady: Bool = true,
            providerTurns: [ProviderKind: [ScriptedAnswerModel.Turn]] = [:],
        ) throws {
            directory = URL.temporaryDirectory.appending(path: "issa-ask-provider-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let (defaults, suite) = SharedFixtures.scratchDefaults()
            self.suite = suite
            device = ScriptedAnswerModel(turns: [.answer("On the device: a rabbit.\nSources: 1")])
            cloud = ScriptedAnswerModel(turns: [.answer("On the server: a rabbit.\nSources: 1")], contextSize: 32_768)
            keychain = MemoryKeychain()
            let keys = AIKeys(keychain: keychain, defaults: defaults)
            for kind in ProviderKind.allCases {
                providers[kind] = ScriptedAnswerModel(
                    // Lowercase: a capitalised "Anthropic" is a name the book never
                    // used, and the engine's spoiler guard would withhold it.
                    turns: providerTurns[kind] ?? [.answer("via \(kind.rawValue): Alice followed a white rabbit.\nSources: 1")],
                    contextSize: 200_000,
                )
            }
            var builder: ((ProviderKind, ProviderModel, String) -> any AnswerModel)!
            coordinator = AskCoordinator(
                store: AskIndexStore(directory: directory),
                model: device,
                cloudModel: cloud,
                cloudAvailability: { .available(CloudQuota(isLimitReached: false, isApproachingLimit: false, resetDate: nil)) },
                notifier: nil,
                defaults: defaults,
                keys: keys,
                providerModel: { kind, model, key in builder(kind, model, key) },
                catalog: { _, _ in [] },
                deviceAvailability: { deviceReady ? .available : .unsupportedDevice },
            )
            builder = { [unowned self] kind, model, key in
                built.append((kind, model.id, key))
                return providers[kind]!
            }
        }

        func register(_ kind: ProviderKind, model id: String = "model-a") {
            coordinator.keys.register(
                kind, key: "key-\(kind.rawValue)",
                model: ProviderModel(id: id, displayName: "Model \(id)", contextSize: 200_000),
            )
        }

        func ask(_ answerer: AskAnswerer) async throws -> AskJob {
            let job = try #require(coordinator.ask(
                "What did Alice follow?", source: try AskCoordinatorTests.source(),
                boundary: AskCoordinatorTests.boundary(), answerer: answerer,
            ))
            await job.task?.value
            return job
        }

        func cleanUp() { AskCoordinatorTests.cleanUp(directory, suite) }
    }

    static func text(_ job: AskJob) -> String? {
        if case let .answered(answer) = job.state { return answer.text }
        return nil
    }

    // MARK: - Routing

    @Test("without a key, a question for a provider is not sent anywhere")
    func noKeyNoSend() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let job = try await rig.ask(.anthropic)
        guard case let .failed(failure) = job.state else {
            Issue.record("expected a failure, got \(job.state)")
            return
        }
        #expect(failure.message(deviceNoun: "iPhone", answerer: .anthropic).contains("Settings › Advanced"))
        #expect(await rig.device.received.isEmpty)
        #expect(await rig.cloud.received.isEmpty)
        #expect(await rig.providers[.anthropic]!.received.isEmpty)
        #expect(rig.built.isEmpty)
    }

    @Test("a question sent to the reader's provider reaches it, with its key, and nothing else")
    func providerWhenChosen() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        rig.register(.anthropic)
        let job = try await rig.ask(.anthropic)
        #expect(job.answeredBy == .anthropic)
        #expect(Self.text(job)?.hasPrefix("via anthropic") == true)
        #expect(job.providerModelName == "Model model-a")
        #expect(rig.built.count == 1)
        #expect(rig.built.first?.2 == "key-anthropic")
        let received = try #require(await rig.providers[.anthropic]!.received.first)
        #expect(received.options.maximumResponseTokens == AskProfile.provider().responseTokens)
        #expect(await rig.device.received.isEmpty, "the device was not chosen")
        #expect(await rig.cloud.received.isEmpty, "Apple's servers were not chosen")
    }

    @Test("each provider gets its own question — OpenAI's row as well as the first")
    func eachProviderByIdentity() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        rig.register(.anthropic)
        rig.register(.openAI)
        let job = try await rig.ask(.openAI)
        #expect(Self.text(job)?.hasPrefix("via openai") == true)
        #expect(await rig.providers[.openAI]!.received.count == 1)
        #expect(await rig.providers[.anthropic]!.received.isEmpty)
        #expect(rig.built.map(\.0) == [.openAI])
        #expect(rig.built.first?.2 == "key-openai")
    }

    @Test("a provider that fails says why, and the device is not asked behind the reader's back")
    func failureIsNotFallenBackFrom() async throws {
        let rig = try Rig(providerTurns: [.anthropic: [ScriptedAnswerModel.Turn(failure: AskFailure.outOfCredit)]])
        defer { rig.cleanUp() }
        rig.register(.anthropic)
        let job = try await rig.ask(.anthropic)
        guard case .failed(.outOfCredit) = job.state else {
            Issue.record("expected out of credit, got \(job.state)")
            return
        }
        #expect(job.answeredBy == .anthropic)
        #expect(AskFailure.outOfCredit.offersDeviceInstead)
        #expect(await rig.device.received.isEmpty, "no silent switch to the device")
    }

    @Test("changing the model builds a new one; asking again with the same reuses it")
    func modelChangeRebuilds() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        rig.register(.anthropic, model: "model-a")
        _ = try await rig.ask(.anthropic)
        _ = try await rig.ask(.anthropic)
        #expect(rig.built.map(\.1) == ["model-a"])
        rig.coordinator.keys.choose(
            ProviderModel(id: "model-b", displayName: "Model B", contextSize: 200_000), for: .anthropic,
        )
        _ = try await rig.ask(.anthropic)
        #expect(rig.built.map(\.1) == ["model-a", "model-b"])
    }

    @Test("a replaced key is used at once, even with the same model")
    func replacedKeyTakesEffect() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        rig.register(.anthropic, model: "model-a")
        _ = try await rig.ask(.anthropic)
        rig.coordinator.keys.register(
            .anthropic, key: "key-replaced",
            model: ProviderModel(id: "model-a", displayName: "Model model-a", contextSize: 200_000),
        )
        _ = try await rig.ask(.anthropic)
        #expect(rig.built.map(\.2) == ["key-anthropic", "key-replaced"])
    }

    @Test("a device whose Apple Intelligence is off or downloading keeps the reader's device default")
    func notReadyIsNotUnsupported() throws {
        let (_, suite) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings(suiteName: suite)
        #expect(AskDefaults.answerer(settings: settings, registered: [.anthropic], deviceSupported: true, cloudUsable: false) == .device,
                "a question goes to a provider only because the reader chose it")
        #expect(AskDefaults.supported(.modelDownloading) && AskDefaults.supported(.appleIntelligenceOff))
        #expect(!AskDefaults.supported(.unsupportedDevice))
    }

    @Test("removing the OpenAI key leaves the Anthropic one, and OpenAI can no longer be asked")
    func removeSecondKey() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        rig.register(.anthropic)
        rig.register(.openAI)
        rig.coordinator.keys.remove(.openAI)
        #expect(rig.coordinator.keys.registered == [.anthropic])
        #expect(rig.keychain.read(account: "openai") == nil)
        #expect(rig.keychain.read(account: "anthropic") == "key-anthropic")
        let job = try await rig.ask(.openAI)
        guard case .failed = job.state else {
            Issue.record("OpenAI was asked after its key was removed")
            return
        }
        #expect(await rig.providers[.openAI]!.received.isEmpty)
    }

    // MARK: - Where a question starts

    @Test("a new question starts on the device unless the reader set a default")
    func defaults() throws {
        let (_, suite) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings(suiteName: suite)
        let both: [ProviderKind] = [.anthropic, .openAI]
        #expect(AskDefaults.answerer(settings: settings, registered: both, deviceSupported: true, cloudUsable: true) == .device)
        settings.askUsesAppleServers = true
        #expect(AskDefaults.answerer(settings: settings, registered: both, deviceSupported: true, cloudUsable: true) == .cloud)
        settings.askDefaultProvider = ProviderKind.openAI.rawValue
        #expect(AskDefaults.answerer(settings: settings, registered: both, deviceSupported: true, cloudUsable: true) == .openAI)
        // A default naming a provider whose key has gone is ignored.
        #expect(AskDefaults.answerer(settings: settings, registered: [.anthropic], deviceSupported: true, cloudUsable: true) == .cloud)
    }

    @Test("on a device that cannot answer, a key is what answers: the first added")
    func noDeviceModel() async throws {
        let (_, suite) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings(suiteName: suite)
        #expect(AskDefaults.answerer(settings: settings, registered: [.openAI, .anthropic], deviceSupported: false, cloudUsable: false) == .openAI)
        #expect(AskDefaults.choices(registered: [.anthropic], deviceSupported: false, cloudUsable: true) == [.anthropic],
                "neither the device nor Apple's servers are offered where the device cannot run Apple Intelligence")

        let rig = try Rig(deviceReady: false)
        defer { rig.cleanUp() }
        #expect(!rig.coordinator.canAsk(deviceReady: false))
        rig.register(.anthropic)
        #expect(rig.coordinator.canAsk(deviceReady: false))
    }

    @Test("getting ready never warms an unready device model or contacts a provider")
    func preparingSendsNothing() async throws {
        let rig = try Rig(deviceReady: false)
        defer { rig.cleanUp() }
        rig.register(.anthropic)
        let source = try AskCoordinatorTests.source()
        rig.coordinator.prepare(source: source)
        await rig.coordinator.warmUp(for: source.bookUUID)?.value
        #expect(await rig.device.prewarmCount == 0)
        #expect(rig.built.isEmpty, "no provider model was even built")
        #expect(await rig.providers[.anthropic]!.received.isEmpty)
    }

    @Test("a registration restored from a backup without its key is not a key")
    func registrationWithoutKey() throws {
        let (store, suite) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let first = MemoryKeychain()
        let keys = AIKeys(keychain: first, defaults: store)
        keys.register(.anthropic, key: "k", model: ProviderModel(id: "m", displayName: "M", contextSize: 1))
        // Another device: the same defaults, an empty Keychain.
        let restored = AIKeys(keychain: MemoryKeychain(), defaults: store)
        #expect(!restored.hasAny)
        #expect(restored.key(for: .anthropic) == nil)
    }

    @Test("the origin pill names the provider and the model, never Apple, for a key's answer")
    func pillLabels() {
        let before = AskOriginLabel.forState(.unanswered(.anthropic), providerModel: "Claude Sonnet 5.5")
        #expect(before?.phrase == "Anthropic · Claude Sonnet 5.5")
        let after = AskOriginLabel.forState(.answered(.model, .openAI), providerModel: "GPT-6.2 Sol")
        #expect(after?.phrase == "Answered by OpenAI · GPT-6.2 Sol")
        #expect(AskOriginLabel.forState(.answered(.withheld, .anthropic)) == nil)
    }
}
