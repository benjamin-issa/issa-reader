#if !os(tvOS)
import Foundation
import IssaAsk
import IssaCore
import Observation

/// The reader's own AI keys: which providers they registered, with which model.
///
/// Advanced and opt-in. Nothing here exists until a reader adds a key in
/// Settings › Advanced and agrees to the screen that says what will be sent,
/// and to whom. Until then the Ask sheet has no picker and nothing changes.
///
/// - **The key is in the Keychain, on this device only**
///   (`AfterFirstUnlockThisDeviceOnly`, under its own service). It is never
///   synced, never in a backup, never in the defaults, never logged.
/// - **The registration — provider, model, when — is in the defaults**, which
///   do travel in a backup. So a provider counts as registered only while its
///   key is in the Keychain: a backup restored to another device brings the
///   registration and not the key, and that device has no key.
/// - **Removed only by the reader**, or with the app (`InstallMarker` purges
///   this service on a fresh install). Signing out of the server does not
///   touch it: the key is the reader's account with the provider, not with
///   the server.
@Observable
@MainActor
final class AIKeys {
    struct Registration: Codable, Hashable, Sendable {
        var kind: ProviderKind
        var model: ProviderModel
        var added: Date
    }

    /// The Keychain service the keys live under, apart from the server's token.
    nonisolated static let service = InstallMarker.aiKeyService
    private static let registrationsKey = "issa.ask.providerKeys"

    /// Registered providers whose key the Keychain gave back, oldest first.
    private(set) var registrations: [Registration] = []
    /// Every registration in the defaults, readable key or not. What is
    /// saved: a key the Keychain would not give up this once — before first
    /// unlock, say — is not a registration to forget for good.
    private var stored: [Registration] = []

    private let keychain: any TokenPersisting
    private let defaults: UserDefaults

    init(
        keychain: any TokenPersisting = KeychainStorage(service: AIKeys.service),
        defaults: UserDefaults = .standard,
    ) {
        self.keychain = keychain
        self.defaults = defaults
        stored = (defaults.data(forKey: Self.registrationsKey)
            .flatMap { try? JSONDecoder().decode([Registration].self, from: $0) } ?? [])
            .sorted { $0.added < $1.added }
        refresh()
    }

    /// Reads again which keys the Keychain has. Called when Ask or Settings
    /// opens, so a key unreadable at launch counts once it can be read.
    func refresh() {
        let readable = stored.filter { keychain.read(account: $0.kind.rawValue) != nil }
        if readable != registrations { registrations = readable }
    }

    /// The providers a question can be sent to, in the order they were added.
    var registered: [ProviderKind] { registrations.map(\.kind) }

    var hasAny: Bool { !registrations.isEmpty }

    func registration(for kind: ProviderKind) -> Registration? {
        registrations.first { $0.kind == kind }
    }

    /// The key, read when a question is sent and at no other time.
    func key(for kind: ProviderKind) -> String? {
        guard registration(for: kind) != nil else { return nil }
        return keychain.read(account: kind.rawValue)
    }

    /// Saves a key the reader has agreed to use, with the model they chose.
    /// False when the Keychain refused it, and nothing is registered then.
    @discardableResult
    func register(_ kind: ProviderKind, key: String, model: ProviderModel) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, keychain.write(trimmed, account: kind.rawValue) else {
            IssaLog.error("ask key could not be saved", ["provider": kind.rawValue])
            return false
        }
        let added = stored.first { $0.kind == kind }?.added ?? Date()
        stored.removeAll { $0.kind == kind }
        stored.append(Registration(kind: kind, model: model, added: added))
        stored.sort { $0.added < $1.added }
        save()
        refresh()
        IssaLog.info("ask key registered", ["provider": kind.rawValue, "model": model.id])
        return true
    }

    /// Another model for a key already registered.
    func choose(_ model: ProviderModel, for kind: ProviderKind) {
        guard let index = stored.firstIndex(where: { $0.kind == kind }) else { return }
        stored[index].model = model
        save()
        refresh()
        IssaLog.info("ask key model changed", ["provider": kind.rawValue, "model": model.id])
    }

    /// Deletes the key from the Keychain and forgets the registration.
    func remove(_ kind: ProviderKind) {
        _ = keychain.delete(account: kind.rawValue)
        stored.removeAll { $0.kind == kind }
        save()
        refresh()
        IssaLog.info("ask key removed", ["provider": kind.rawValue])
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.registrationsKey)
        }
    }
}

/// A key store that holds nothing and keeps nothing: what a coordinator built
/// for a test gets unless the test hands it keys of its own.
struct NoKeys: TokenPersisting {
    func read(account _: String) -> String? { nil }
    @discardableResult
    func write(_: String, account _: String) -> Bool { false }
    @discardableResult
    func delete(account _: String) -> Bool { true }
}

/// Where a new question starts.
///
/// As it always has, unless the reader has said otherwise: on the device.
/// Apple's servers when the reader turned that default on and they can take a
/// question. A registered provider when the reader made it the default — and
/// on a device that can **never** run Apple Intelligence, the first provider
/// they added, because there it is the only thing that can.
///
/// A device whose Apple Intelligence is merely off, or still downloading, is
/// not that device. Its reader's default stays where they left it: a question
/// goes to a provider only because they chose it, and the sheet says why the
/// device cannot answer yet rather than quietly sending it elsewhere.
@MainActor
enum AskDefaults {
    /// - Parameter deviceSupported: whether this device can run Apple
    ///   Intelligence at all — ready, off or downloading.
    static func answerer(
        settings: PlaybackSettings, registered: [ProviderKind], deviceSupported: Bool, cloudUsable: Bool,
    ) -> AskAnswerer {
        if let name = settings.askDefaultProvider, let kind = ProviderKind(rawValue: name),
           registered.contains(kind) {
            return AskAnswerer(kind)
        }
        guard deviceSupported else {
            return registered.first.map(AskAnswerer.init) ?? .device
        }
        if settings.askUsesAppleServers, cloudUsable { return .cloud }
        return .device
    }

    /// Every place a question could go from here, in the order the picker
    /// lists them. The device is listed wherever it could ever answer, so a
    /// reader whose Apple Intelligence is downloading still sees it chosen.
    static func choices(
        registered: [ProviderKind], deviceSupported: Bool, cloudUsable: Bool,
    ) -> [AskAnswerer] {
        var choices: [AskAnswerer] = []
        if deviceSupported { choices.append(.device) }
        if deviceSupported, cloudUsable { choices.append(.cloud) }
        choices += registered.map(AskAnswerer.init)
        return choices
    }

    /// Whether this availability is a device that could answer at all.
    static func supported(_ availability: AskAvailability) -> Bool {
        switch availability {
        case .available, .appleIntelligenceOff, .modelDownloading: true
        case .unsupportedDevice, .unsupportedOnThisPlatform: false
        }
    }

    /// The picker's label for a place.
    static func choiceTitle(_ answerer: AskAnswerer, model: String? = nil) -> String {
        switch answerer {
        case .device: "This \(AskDevice.noun)"
        case .cloud: "Apple's servers"
        case .anthropic, .openAI:
            model.map { "\(answerer.placeName) · \($0)" } ?? answerer.placeName
        }
    }

    /// The sentence under the picker: what leaves the device, and to whom.
    static func caption(for answerer: AskAnswerer) -> String {
        switch answerer {
        case .device:
            "Answered on this \(AskDevice.noun). Nothing leaves it."
        case .cloud:
            AskSheet.appleServersSentence
        case .anthropic, .openAI:
            "Sends your question and the book so far to \(answerer.placeName), using your key."
        }
    }
}
#endif
