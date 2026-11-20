#if ISSA_UITEST_FIXTURE
import Foundation
import IssaAsk
import IssaCore

/// A reader's own AI keys, for the layout sweep, without a provider or a key.
///
/// Excluded from Release with the rest of this directory (`project.yml`), and
/// every argument it answers to contains `UITestFixture`'s marker, so
/// `scripts/release.sh`'s binary grep fails a release that carried any of it.
///
/// - `-IssaUITestFixtureAskProviders` gives the coordinator an in-memory key
///   store, a stub model list and a scripted answer: the add-key flow, the
///   picker and the pill can be driven without a network or a real key. The
///   stub refuses any key that starts with "bad".
/// - `-IssaUITestFixtureAskKeys anthropic,openai` registers fake keys for
///   those providers before the first screen, for the sheet's tests.
/// - `-IssaUITestFixtureAskNoDeviceModel` stands in a device that cannot run
///   Apple Intelligence, which a simulator on an Apple-silicon Mac never is.
enum AskProviderFixture {
    static let providersArgument = "-IssaUITestFixtureAskProviders"
    static let keysArgument = "-IssaUITestFixtureAskKeys"
    static let noDeviceModelArgument = "-IssaUITestFixtureAskNoDeviceModel"

    static let models: [ProviderKind: [ProviderModel]] = [
        .anthropic: [
            ProviderModel(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", contextSize: 1_000_000, supportsEffort: true),
            ProviderModel(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", contextSize: 1_000_000, supportsEffort: true),
            ProviderModel(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5", contextSize: 1_000_000, supportsEffort: true),
        ],
        .openAI: [
            ProviderModel(id: "gpt-6.2-sol", displayName: "GPT-6.2 Sol", contextSize: 1_050_000, supportsEffort: true),
            ProviderModel(id: "gpt-6-luna", displayName: "GPT-6 Luna", contextSize: 1_050_000, supportsEffort: true),
        ],
    ]

    /// The coordinator the app runs with, when a launch argument asks.
    @MainActor
    static func coordinatorIfRequested() -> AskCoordinator? {
        let arguments = ProcessInfo.processInfo.arguments
        let stubsProviders = arguments.contains(providersArgument)
        let noDevice = arguments.contains(noDeviceModelArgument)
        guard stubsProviders || noDevice else { return nil }

        let suite = "issa-ask-provider-fixture"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let keys = AIKeys(keychain: MemoryKeys(), defaults: defaults)
        if let index = arguments.firstIndex(of: keysArgument), index + 1 < arguments.count {
            for name in arguments[index + 1].split(separator: ",") {
                guard let kind = ProviderKind(rawValue: String(name)), let model = models[kind]?.first else { continue }
                keys.register(kind, key: "fixture-\(kind.rawValue)-key", model: model)
            }
        }
        let answer: @MainActor (ProviderKind, ProviderModel, String) -> any AnswerModel = { _, _, _ in
            ScriptedAnswerModel(turns: [.answer("The rabbit hurried past, late for something.\nSources: 1")])
        }
        let list: @Sendable (ProviderKind, String) async throws -> [ProviderModel] = { kind, key in
            if key.hasPrefix("bad") { throw ProviderCatalog.Failure.keyRefused }
            return AskProviderFixture.models[kind] ?? []
        }
        if noDevice {
            return AskCoordinator(
                keys: keys, providerModel: answer, catalog: list, deviceAvailability: { .unsupportedDevice },
            )
        }
        return AskCoordinator(keys: keys, providerModel: answer, catalog: list)
    }
}

/// A key store that never touches the Keychain.
private final class MemoryKeys: TokenPersisting, @unchecked Sendable {
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
#endif
