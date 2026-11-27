#if !os(tvOS)
import Foundation
import IssaAsk
import IssaCore
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Every question in flight, and the machinery that outlives the sheets.
///
/// Owned above the reader — `AppServices` on iOS, `@State` in the Mac app —
/// because `AppModel.readerDidClose` evicts the `ReaderModel` the moment the
/// screen goes away, and a job hung off the reader would die with it. The
/// reader is a source of two values (the boundary and the file); it is not the
/// owner of the answer.
@Observable
@MainActor
final class AskCoordinator {
    /// One job per book. A second question about the same book replaces the
    /// first, which is what "Ask another" means; a question about a different
    /// book is a different job, because a Mac reader can have three books open.
    private(set) var jobs: [String: AskJob] = [:]

    /// A book whose answer a notification tap asked to be reopened. Cleared by
    /// whichever reader picks it up.
    var reopenRequest: String?

    /// One store per process. Two would open the same SQLite file twice, and
    /// the app also deletes indexes through it when a download goes.
    let store: AskIndexStore
    /// Apple's on-device model: the default, and the only one that keeps
    /// everything on the device.
    private let model: any AnswerModel
    /// Apple's server model, when this OS has one. Used only for a question the
    /// reader sent there (`AskAnswerer.cloud`); nil before 27, on tvOS, and in
    /// tests that do not hand one over.
    private let cloudModel: (any AnswerModel)?
    /// Where "Use Apple's servers" stands right now. Injectable so a test can
    /// say what the switch would show without a server.
    private let cloudAvailabilityProvider: @MainActor () -> CloudAvailability
    /// One turn at the on-device model, for the whole app.
    ///
    /// Held here because this is the only object that outlives a question. The
    /// engines do not: one is built per question, so a turnstile living on an
    /// engine serialised that engine against itself and nothing else, and two
    /// books meant two concurrent generations and a "busy" the reader had done
    /// nothing to deserve. It is passed to **both** construction sites below.
    private let turnstile = AskTurnstile()
    /// One turn at Apple's servers, separately: a question there does not hold
    /// up one on the device, and the server has its own concurrency limits.
    private let cloudTurnstile = AskTurnstile()
    /// Whether the server model has been warmed this session. Only once the
    /// reader has chosen it: warming it is a request to Apple's servers.
    private var cloudPrepared = false
    /// For index building, prewarming and chips — everything that has no
    /// boundary of its own, so it needs no tool. Always Apple's on-device model,
    /// and never a reader's provider: nothing here may send a request before
    /// the reader has asked something.
    private let preparer: AskEngine

    /// The reader's own AI keys, from Settings › Advanced.
    let keys: AIKeys
    /// Builds the model for a reader's key. Injectable so a test can answer
    /// from a script instead of a provider.
    private let makeProviderModel: @MainActor (ProviderKind, ProviderModel, String) -> any AnswerModel
    /// Lists the models a key can use. Injectable for the same reason.
    private let catalog: @Sendable (ProviderKind, String) async throws -> [ProviderModel]
    /// One model per registered provider, rebuilt when its key or model changes.
    private var providerModels: [ProviderKind: (registration: AIKeys.Registration, credentialID: String, model: any AnswerModel, tokenProvider: OpenAITokenProvider?)] = [:]
    /// Removes a provider's key or OAuth session, and the model built with it:
    /// a removed credential does not stay in memory.
    func removeKey(_ kind: ProviderKind) {
        if let oauth = keys.oauthSession(for: kind) {
            Task { await OpenAIOAuth.revoke(oauth) }
        }
        keys.remove(kind)
        providerModels[kind] = nil
    }

    /// One turn per provider: a question to Anthropic does not wait on one to
    /// OpenAI, or on the device.
    private var providerTurnstiles: [ProviderKind: AskTurnstile] = [:]
    /// Whether the on-device model can answer right now. Injectable so a test
    /// can stand in a device without Apple Intelligence.
    private let deviceAvailabilityProvider: @MainActor () -> AskAvailability

    private let defaults: UserDefaults
    /// Nil or a counting stand-in in tests: a permission prompt is a real
    /// system alert in front of a real runner, and `UNUserNotificationCenter`
    /// has no stand-in of its own.
    private let notifier: (any AskNotifying)?

    /// Books whose index has been built and whose model has been warmed this
    /// session, so opening the sheet a second time costs nothing.
    private var prepared: Set<String> = []
    private var preparing: [String: Task<Void, Never>] = [:]

    /// Optional on-device CoreML embedding model (nil in unit tests that script
    /// `model` without passing an explicit `embeddingModel`).
    private let coreMLEmbedder: CoreMLEmbeddingModel?
    private let injectedEmbedder: (any EmbeddingModel)?
    /// Whether this device meets the hardware floor (6 GB+ RAM and 16-core+
    /// Apple Neural Engine) to run the on-device search model cleanly.
    let isEmbeddingModelHardwareSupported: Bool
    /// Observable installation state of the optional on-device search model.
    private(set) var embeddingModelState: EmbeddingModelState = .notInstalled
    /// Books currently running a background embedding pass (only populated when
    /// unembedded read spans remain, so already-indexed books never flash a spinner).
    private(set) var indexingBooks: Set<String> = []
    private var embeddingDownloadTask: Task<Void, Never>?
    private var embeddingDownloadToken: UUID?
    private var pendingModelRemoval: Task<Void, Never>?
    /// Single-loop, three-tier foreground scheduler for on-device book embeddings.
    private var embeddingScheduler: EmbeddingScheduler!

    /// The observer token, in a box `deinit` can reach.
    ///
    /// A nonisolated `deinit` cannot read a main-actor property, and dropping
    /// the removal instead is how a released object leaves a live observer
    /// behind. `PlaybackSettings` solves the same problem the same way.
    private final class ObserverBox: @unchecked Sendable {
        weak var centre: NotificationCenter?
        var token: (any NSObjectProtocol)?
        deinit {
            if let token { (centre ?? .default).removeObserver(token) }
        }
    }

    private let signOutObserver = ObserverBox()
    private let thermalObserver = ObserverBox()
    private let powerObserver = ObserverBox()
    #if os(iOS)
    private let memoryObserver = ObserverBox()
    #endif

    init(
        store: AskIndexStore = AskIndexStore(),
        model: (any AnswerModel)? = nil,
        cloudModel: (any AnswerModel)? = nil,
        cloudAvailability: (@MainActor () -> CloudAvailability)? = nil,
        notifier: (any AskNotifying)? = AskNotifier(),
        defaults: UserDefaults = .standard,
        keys: AIKeys? = nil,
        providerModel: (@MainActor (ProviderKind, ProviderModel, String) -> any AnswerModel)? = nil,
        catalog: (@Sendable (ProviderKind, String) async throws -> [ProviderModel])? = nil,
        deviceAvailability: (@MainActor () -> AskAvailability)? = nil,
        embeddingModel: (any EmbeddingModel)? = nil,
        embeddingHardwareSupported: Bool? = nil,
        // Injectable for the same reason `PlaybackSettings`'s is: this observer
        // registers with `object: nil`, so a sign-out posted by any suite in a
        // parallel test run purged the index of every coordinator alive
        // anywhere in the process.
        centre: NotificationCenter = .default,
    ) {
        self.store = store
        // The real one unless a test hands over a scripted stand-in.
        #if canImport(FoundationModels)
        self.model = model ?? SystemAnswerModel()
        #else
        self.model = model ?? ScriptedAnswerModel()
        #endif
        // A test that scripts the device model and says nothing about the
        // server gets no server, so nothing it does can reach Apple.
        if let cloudModel {
            self.cloudModel = cloudModel
        } else if model == nil {
            self.cloudModel = Self.systemCloudModel()
        } else {
            self.cloudModel = nil
        }
        let hasCloud = self.cloudModel != nil
        cloudAvailabilityProvider = cloudAvailability
            ?? { hasCloud ? CloudAvailability.current() : .unavailable(reason: "none") }
        self.notifier = notifier
        self.defaults = defaults
        // A test that scripts the device model and hands over no keys gets a
        // key store with nothing in it, so nothing it does reads the Keychain.
        self.keys = keys ?? (model == nil ? AIKeys(defaults: defaults) : AIKeys(keychain: NoKeys(), defaults: defaults))
        makeProviderModel = providerModel ?? { kind, model, key in
            ProviderAnswerModel(kind: kind, model: model, key: key)
        }
        self.catalog = catalog ?? { kind, key in try await ProviderCatalog.models(kind, key: key) }
        deviceAvailabilityProvider = deviceAvailability ?? { AskAvailability.current() }

        let hardwareSupported = embeddingHardwareSupported
            ?? (embeddingModel != nil ? true : CoreMLEmbeddingModel.isSupportedOnCurrentDevice())
        self.isEmbeddingModelHardwareSupported = hardwareSupported

        if let embeddingModel {
            self.injectedEmbedder = embeddingModel
            self.coreMLEmbedder = embeddingModel as? CoreMLEmbeddingModel
            if let coreML = self.coreMLEmbedder {
                coreML.sweepIncompleteDownloads()
                self.embeddingModelState = coreML.isInstalledOnDisk() ? .ready : .notInstalled
            } else {
                self.embeddingModelState = .ready
            }
        } else if model == nil {
            let client = CoreMLEmbeddingModel()
            client.sweepIncompleteDownloads()
            self.coreMLEmbedder = client
            self.injectedEmbedder = nil
            self.embeddingModelState = client.isInstalledOnDisk() ? .ready : .notInstalled
        } else {
            self.coreMLEmbedder = nil
            self.injectedEmbedder = nil
            self.embeddingModelState = .notInstalled
        }
        preparer = AskEngine(model: self.model, store: store, turnstile: turnstile)
        embeddingScheduler = EmbeddingScheduler(
            store: store,
            preparer: preparer,
            defaults: defaults,
            coreMLEmbedder: coreMLEmbedder,
            activeEmbedder: { [weak self] in self?.activeEmbedder },
            onIndexingBooksChanged: { [weak self] books in self?.indexingBooks = books },
            centre: centre,
        )

        // The indexes are per book and the books are per account, so an account
        // leaving takes its indexes with it. Through the same notification
        // `PlaybackSettings` uses, because this object is not owned by
        // `AppModel` either and there is nothing to call it directly.
        signOutObserver.centre = centre
        signOutObserver.token = centre.addObserver(
            forName: PlaybackSettings.signOutNotification, object: nil, queue: .main,
        ) { [weak self] notification in
            // The device's own books keep theirs: they are not the account's.
            let kept = PlaybackSettings.keptBookUUIDs(in: notification)
            MainActor.assumeIsolated { self?.purgeAll(keeping: kept) }
        }
        thermalObserver.centre = centre
        thermalObserver.token = centre.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnvironmentChange() }
        }
        powerObserver.centre = centre
        powerObserver.token = centre.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnvironmentChange() }
        }
        #if os(iOS)
        memoryObserver.centre = centre
        memoryObserver.token = centre.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMemoryWarning() }
        }
        #endif
    }

    func job(for bookUUID: String) -> AskJob? { jobs[bookUUID] }

    /// Apple's server model where this OS has one.
    private static func systemCloudModel() -> (any AnswerModel)? {
        #if canImport(FoundationModels) && !os(tvOS)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) { return CloudAnswerModel() }
        #endif
        return nil
    }

    // MARK: - Apple's servers

    /// Where "Use Apple's servers" stands: offered or not, usable or not.
    /// Read fresh, because the daily allowance changes while the app is open.
    func cloudAvailability() -> CloudAvailability { cloudAvailabilityProvider() }

    /// Warms the server model, once, after the reader has turned on "Use
    /// Apple's servers" — never before, because warming it is itself a request
    /// to Apple. Only the instructions go: nothing from any book.
    @discardableResult
    func prepareCloud() -> Task<Void, Never>? {
        guard !cloudPrepared, let cloudModel, cloudAvailability().isUsable else { return nil }
        cloudPrepared = true
        return Task { await cloudModel.prewarm() }
    }

    // MARK: - The reader's own providers

    /// Whether the on-device model can answer right now.
    func deviceAvailability() -> AskAvailability { deviceAvailabilityProvider() }

    /// Where a question can be asked from here: the device when it is ready,
    /// or a reader's own key when there is one. A key unlocks Ask on a device
    /// that cannot run Apple Intelligence; Apple's servers never do.
    func canAsk(deviceReady: Bool) -> Bool { deviceReady || keys.hasAny }

    /// The model for a registered provider, built once per credential and model.
    private func providerModel(for kind: ProviderKind) -> (model: any AnswerModel, entry: ProviderModel)? {
        // The credential is read every time and matched: a credential replaced
        // with the same model must be used at once, and a removed one must not
        // stay in memory.
        guard let registration = keys.registration(for: kind) else {
            providerModels[kind] = nil
            return nil
        }
        switch registration.authMethod {
        case .apiKey:
            guard let key = keys.key(for: kind) else {
                providerModels[kind] = nil
                return nil
            }
            if let cached = providerModels[kind], cached.registration == registration, cached.credentialID == key {
                return (cached.model, registration.model)
            }
            let model = makeProviderModel(kind, registration.model, key)
            providerModels[kind] = (registration, key, model, nil)
            return (model, registration.model)
        case .chatGPTOAuth:
            guard let oauth = keys.oauthSession(for: kind) else {
                providerModels[kind] = nil
                return nil
            }
            // Key the cache on stable `clientID` + `hostID` (not the rotating
            // refresh token) so silent rotations keep reusing the exact same
            // single-flight `OpenAITokenProvider` actor.
            let credentialID = "oauth:\(oauth.clientID):\(oauth.hostID)"
            if let cached = providerModels[kind], cached.registration == registration,
               cached.credentialID == credentialID {
                return (cached.model, registration.model)
            }
            let keysStore = keys
            let tokenProvider = OpenAITokenProvider(session: oauth) { updated in
                Task { @MainActor in
                    keysStore.updateOAuthSession(updated, for: kind)
                }
            }
            let model = ProviderAnswerModel(
                kind: kind,
                model: registration.model,
                tokenProvider: { forceRefresh in
                    try await tokenProvider.accessToken(forceRefresh: forceRefresh)
                },
            )
            providerModels[kind] = (registration, credentialID, model, tokenProvider)
            return (model, registration.model)
        }
    }

    /// Runs Sign in with ChatGPT in the system browser and exchanges the code
    /// for access and refresh tokens. Nothing is saved until the reader picks a
    /// model and agrees on the consent screen.
    func signInWithChatGPT() async throws(OpenAIOAuth.Failure) -> OpenAIOAuthSession {
        let auth = OpenAIBrowserAuth()
        return try await auth.signIn(
            hostID: keys.openAIHostID(),
            existingClientID: keys.openAIClientID(),
        )
    }

    /// Returns a current bearer token for a registered provider (refreshing an
    /// OAuth access token through the shared single-flight token provider if
    /// needed), for reading the model list.
    func validToken(for kind: ProviderKind) async throws -> String? {
        guard let registration = keys.registration(for: kind) else { return nil }
        switch registration.authMethod {
        case .apiKey:
            return keys.key(for: kind)
        case .chatGPTOAuth:
            _ = providerModel(for: kind)
            guard let tokenProvider = providerModels[kind]?.tokenProvider else { return nil }
            return try await tokenProvider.accessToken(forceRefresh: false)
        }
    }

    /// The models a key can use, newest first — which also checks the key.
    func models(for kind: ProviderKind, key: String) async throws -> [ProviderModel] {
        try await catalog(kind, key)
    }

    private func providerTurnstile(for kind: ProviderKind) -> AskTurnstile {
        if let turnstile = providerTurnstiles[kind] { return turnstile }
        let turnstile = AskTurnstile()
        providerTurnstiles[kind] = turnstile
        return turnstile
    }

    // MARK: - Getting ready

    /// Builds this book's index and warms the model, once.
    ///
    /// Called when the sheet opens, so the work happens while the reader is
    /// still reading the chips and typing. On a long illustrated book the index
    /// build is the larger half of the first question's latency, and doing it
    /// after the question is asked is the difference between a seven-second
    /// wait and a thirty-second one.
    func prepare(for model: ReaderModel) {
        guard let source = model.askSource() else { return }
        prepare(source: source)
    }

    func prepare(source: BookSource) {
        // Prewarm `embed_512` and boost Tier 1 catch-up while the reader is in
        // the Ask sheet (even when this book's SQLite index is already prepared).
        embeddingScheduler.askSheetOpened(bookUUID: source.bookUUID)
        let uuid = source.bookUUID
        guard !prepared.contains(uuid), preparing[uuid] == nil else { return }
        // The device's model is warmed only where it can answer; a reader's
        // provider is never warmed — that would be a request to it.
        let warms = deviceAvailability().isReady
        preparing[uuid] = Task { [preparer] in
            // Failures are not surfaced: nothing has been asked yet, and a
            // sheet that opens onto an error before the reader has typed a word
            // is worse than one that quietly retries when they do. The question
            // itself builds the index again and reports properly.
            let built = (try? await preparer.prepareIndex(source: source)) != nil
            if warms { await preparer.prewarm() }
            guard !Task.isCancelled else { return }
            preparing[uuid] = nil
            // Only a warm-up that worked is remembered. A failed one was put in
            // `prepared` all the same, so the guard above turned every later
            // opening of the sheet away for the rest of the session — no
            // warm-up was ever tried again, and each question paid for the
            // whole build itself.
            if built { prepared.insert(uuid) }
        }
    }

    /// The warm-up in flight for this book, if there is one — for a test to
    /// wait on, as `suggestions(for:)` does.
    func warmUp(for bookUUID: String) -> Task<Void, Never>? { preparing[bookUUID] }

    // MARK: - On-device search model

    /// Active embedder when hardware is eligible and model is installed; nil
    /// otherwise so older hardware and uninstalled devices run upstream cleanly.
    private var activeEmbedder: (any EmbeddingModel)? {
        guard isEmbeddingModelHardwareSupported, embeddingModelState.isReady else { return nil }
        return injectedEmbedder ?? coreMLEmbedder
    }

    /// Downloads the optional on-device search model (~307 MB) from GitHub Releases.
    func downloadEmbeddingModel() {
        guard isEmbeddingModelHardwareSupported, let client = coreMLEmbedder else { return }
        if case .downloading = embeddingModelState { return }

        let token = UUID()
        embeddingDownloadToken = token
        embeddingDownloadTask?.cancel()
        embeddingModelState = .downloading(progress: 0)

        let removalToAwait = pendingModelRemoval
        let reportProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, self.embeddingDownloadToken == token,
                      case .downloading = self.embeddingModelState
                else { return }
                self.embeddingModelState = .downloading(progress: fraction)
            }
        }
        embeddingDownloadTask = Task { [weak self] in
            // Wait for any in-flight `removeModel()` to finish so removing and
            // immediately re-downloading cannot delete files out from under `.ready`.
            await removalToAwait?.value
            guard !Task.isCancelled else { return }
            if client.isInstalledOnDisk() {
                guard self?.embeddingDownloadToken == token else { return }
                self?.embeddingModelState = .ready
                self?.embeddingDownloadTask = nil
                self?.embeddingDownloadToken = nil
                return
            }
            do {
                try await client.downloadModel(progress: reportProgress)
                guard !Task.isCancelled, self?.embeddingDownloadToken == token else { return }
                self?.embeddingModelState = .ready
                self?.embeddingDownloadTask = nil
                self?.embeddingDownloadToken = nil
                self?.embeddingScheduler.modelBecameReady()
            } catch {
                guard self?.embeddingDownloadToken == token else { return }
                self?.embeddingDownloadTask = nil
                self?.embeddingDownloadToken = nil
                if Self.isCancellation(error) {
                    self?.embeddingModelState = client.isInstalledOnDisk() ? .ready : .notInstalled
                } else {
                    IssaLog.info("ask embedding model download failed", [
                        "kind": String(describing: type(of: error)),
                    ])
                    self?.embeddingModelState = .failed(Self.downloadErrorMessage(for: error))
                }
            }
        }
    }

    func cancelEmbeddingModelDownload() {
        embeddingDownloadToken = nil
        embeddingDownloadTask?.cancel()
        embeddingDownloadTask = nil
        if let client = coreMLEmbedder {
            embeddingModelState = client.isInstalledOnDisk() ? .ready : .notInstalled
        }
    }

    func removeEmbeddingModel() {
        cancelEmbeddingModelDownload()
        embeddingScheduler.modelRemoved()
        embeddingModelState = .notInstalled
        if let client = coreMLEmbedder {
            let previous = pendingModelRemoval
            pendingModelRemoval = Task {
                await previous?.value
                await client.removeModel()
            }
        }
    }

    /// Called by `ReaderView` when its scene becomes active, avoiding a firing-
    /// order race against `IssaReaderApp.appDidBecomeActive()`.
    func readerDidBecomeActive(for model: ReaderModel, askEnabled: Bool = true) {
        embeddingScheduler.appDidBecomeActive()
        if askEnabled {
            indexEmbeddingsInBackground(for: model)
        } else {
            stopBackgroundEmbeddings(for: model.book.uuid)
        }
    }

    /// Quietly indexes semantic spans via the three-tier foreground scheduler
    /// (full-speed catch-up up to `chapterIndex`, then cool look-ahead through
    /// the rest of the book).
    func indexEmbeddingsInBackground(for model: ReaderModel) {
        guard model.phase == .ready, let source = model.askSource() else { return }
        indexEmbeddingsInBackground(source: source, upToSpine: model.chapterIndex)
    }

    /// True while Tier 1 catch-up is actively embedding unindexed read spans
    /// for `bookUUID` (debounced so quick chapter turns never flash).
    func isIndexingEmbeddings(for bookUUID: String) -> Bool {
        indexingBooks.contains(bookUUID)
    }

    func indexEmbeddingsInBackground(source: BookSource, upToSpine: Int) {
        embeddingScheduler.activateBook(
            source: source,
            chapterIndex: upToSpine,
            preparation: preparing[source.bookUUID],
        )
    }

    func stopBackgroundEmbeddings(for bookUUID: String) {
        embeddingScheduler.deactivateBook(bookUUID)
    }

    private func handleEnvironmentChange() {
        embeddingScheduler.handleEnvironmentChange()
    }

    private func handleMemoryWarning() {
        embeddingScheduler.handleMemoryWarning(hasWorkingJob: hasWorkingJob)
    }

    private var hasWorkingOnDeviceEmbeddingJob: Bool {
        jobs.values.contains { $0.state.isWorking && ($0.answeredBy == .device || $0.answeredBy == .cloud) }
    }

    private func syncEmbeddingAskState() {
        embeddingScheduler.updateAskJobState(
            onDeviceRunning: hasWorkingOnDeviceEmbeddingJob,
            anyJobRunning: hasWorkingJob,
        )
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    static func downloadErrorMessage(for error: any Error) -> String {
        if let modelError = error as? CoreMLEmbeddingModel.ModelError {
            return modelError.userFacingMessage
        }
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return "No internet connection. Try again when you're back online."
        }
        return "Couldn't download the search model. Check your connection and try again."
    }

    /// The reader is looking at this book's answer again, so the banner that
    /// was standing in for it has done its job.
    ///
    /// Called when the sheet opens rather than when a notification is tapped,
    /// because a tap is only one of the ways here: the reader who sees the
    /// banner, ignores it, opens the app themselves and then opens the sheet
    /// left a delivered notification on disk with nothing to remove it.
    func reopened(bookUUID: String) {
        guard let notifier else { return }
        Task { await notifier.removeDelivered(bookUUID: bookUUID) }
    }

    /// The two chips under the field.
    ///
    /// Waits for the index build it just started, because otherwise it never
    /// sees one: `prepare` is deliberately fire-and-forget, so asking straight
    /// after it always found an unbuilt index and always returned the generic
    /// pair — the chip naming the book's own most-mentioned character could
    /// only ever appear on a *second* visit to the sheet. The caller draws the
    /// generic pair meanwhile and replaces it when this answers, which is the
    /// right way round: two capsules immediately, better ones a second later.
    func suggestions(for model: ReaderModel) async -> [String] {
        guard let source = model.askSource(), let boundary = model.readingBoundary() else {
            return AskSuggestions.chips(topNames: [])
        }
        await preparing[source.bookUUID]?.value
        return await preparer.suggestions(source: source, boundary: boundary)
    }

    // MARK: - Asking

    /// Starts a question about the book on screen.
    ///
    /// The boundary and the file are read *here*, synchronously, before any
    /// await: they are main-actor state that the reader is free to change the
    /// moment this returns, and an answer bounded by wherever the reader
    /// happened to turn to while it was being written would be bounded by
    /// nothing at all.
    @discardableResult
    func ask(_ question: String, in model: ReaderModel, answerer: AskAnswerer = .device) -> AskJob? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let source = model.askSource(),
              let boundary = model.readingBoundary()
        else { return nil }
        return ask(trimmed, source: source, boundary: boundary, answerer: answerer)
    }

    @discardableResult
    func ask(
        _ question: String, source: BookSource, boundary: ReadingBoundary,
        answerer requested: AskAnswerer = .device,
    ) -> AskJob? {
        let uuid = source.bookUUID
        // A second question replaces the first, and the first is cancelled
        // rather than left to finish into a job nothing is showing.
        jobs[uuid]?.task?.cancel()
        // Apple's servers only when they can take it.
        let availability = requested == .cloud ? cloudAvailability() : nil
        let cloud: (any AnswerModel)? = availability?.isUsable == true ? cloudModel : nil
        let job = AskJob(
            bookUUID: uuid, question: question, boundary: boundary,
            bookTitle: source.package.metadata.title, answerer: requested,
        )
        jobs[uuid] = job
        if requested == .cloud, cloud == nil {
            // A spent allowance is the reader's to decide, as it is when it
            // runs out part-way through a question: said, with the device
            // offered as a button. "Try again" on such a question used to be
            // answered on the device without a word, so the two buttons did
            // the same thing.
            if case let .limitReached(resetDate) = availability {
                IssaLog.info("ask not sent: the allowance from Apple's servers is spent")
                job.state = .failed(.cloudLimitReached(resetDate: resetDate))
                finished(job)
                return job
            }
            // Otherwise the servers cannot be reached from here right now:
            // answered on the device, as an unreachable request is, and said.
            IssaLog.info("ask sent to the device instead", ["reason": "cloud unavailable"])
            job.fallback = .unreachable
            job.answeredBy = .device
        }
        let answerer = job.answeredBy

        // The build the sheet started when it opened, if it is still running.
        // Awaited below rather than raced, and *not* claimed as finished here.
        //
        // This line used to be `prepared.insert(uuid)`, which asserted a fact
        // that was not yet true: the index build this question needs had not
        // run. The damage was to `suggestions(for:)`, which waits on
        // `preparing[uuid]` — with the book already in `prepared`, the guard in
        // `prepare(source:)` returned early, no task was ever put in
        // `preparing`, and the chips then awaited nothing and probed the store
        // in the middle of a build. `AskIndexStore.queue(for:)` no longer
        // caches a handle across the rename that ends one, but a question that
        // waits for the build it is about is also the cheaper order: two builds
        // for one book would otherwise be in flight over the same
        // `<uuid>.building.sqlite`.
        let preparation = preparing[uuid]

        // Pause background embedding only while an on-device or Apple-cloud Ask
        // runs (OpenAI / Anthropic requests leave the Neural Engine idle).
        syncEmbeddingAskState()

        // Per question, with the `searchBook` tool bound to this boundary: the
        // same factory `RegressionRun` asks the real model through. When the
        // on-device search model is ready, layer `.semantic` onto the upstream
        // profiles so mid-book fallback stays 100% identical to upstream.
        let embedder = activeEmbedder
        let deviceProfile: AskProfile = embedder != nil
            ? AskProfile.device.withSemantic(.device(forContextSize: model.contextSize))
            : .device
        let cloudProfile: AskProfile = embedder != nil ? AskProfile.cloud.withSemantic(.cloud) : .cloud
        let deviceEngine = AskEngine.forQuestion(
            model: model, store: store, bookUUID: uuid, boundary: boundary, turnstile: turnstile,
            profile: deviceProfile, embedder: embedder,
        )
        var engine = cloud.map {
            AskEngine.forQuestion(
                model: $0, store: store, bookUUID: uuid, boundary: boundary,
                turnstile: cloudTurnstile, profile: cloudProfile, embedder: embedder,
            )
        } ?? deviceEngine
        if answerer == .cloud {
            // Never the question or the book: that a question went, and nothing else.
            IssaLog.info("ask sent to Apple's servers")
        }
        // The reader's own key. Never fallen back from: a failure says why,
        // and the sheet offers the device where it can answer.
        if let kind = requested.provider {
            guard let provider = providerModel(for: kind) else {
                IssaLog.info("ask not sent: no key", ["provider": kind.rawValue])
                job.state = .failed(.other(
                    "Add your \(kind.displayName) key in Settings › Advanced to ask \(kind.displayName)."
                ))
                finished(job)
                return job
            }
            // Layer optional on-device semantic retrieval onto upstream's exact
            // provider profile (keeping upstream's prompt style, instructions,
            // reminder, and `searchBook` tool untouched). Whenever the search
            // model is not installed or read spans are still catching up
            // (> 16 missing), `AskEngine` falls straight back to upstream's
            // whole-book `everythingRead` path.
            let baseProviderProfile = AskProfile.provider(for: provider.entry, kind: kind)
            let providerProfile = embedder != nil
                ? baseProviderProfile.withSemantic(.provider)
                : baseProviderProfile
            engine = AskEngine.forQuestion(
                model: provider.model, store: store, bookUUID: uuid, boundary: boundary,
                turnstile: providerTurnstile(for: kind), profile: providerProfile,
                package: source.package, embedder: embedder,
            )
            job.providerModelName = provider.entry.displayName
        }

        job.task = Task { [weak self] in
            // Costs nothing when the sheet's build has already finished, and
            // when it has not this is the build this question was going to do
            // anyway — `AskEngine.perform` calls `prepareIndex` first thing.
            await preparation?.value
            // The server model's window and languages are read before the
            // engine builds a prompt from them.
            await cloud?.prepare()
            var answered = false
            do {
                answered = try await Self.drive(
                    engine, question: question, source: source, boundary: boundary, into: job,
                )
            } catch let failure as AskFailure
                where job.answeredBy == .cloud && !Task.isCancelled
                && (failure == .cloudUnreachable || failure == .declined) {
                // Answered on the device instead, and said so. Unreachable is
                // Apple's own advice. Declined is the servers' guardrails
                // stopping an answer about something dark the book has shown —
                // about one question in six on fiction in the 1.8.0 study, and
                // the on-device model, with its permissive setting, usually
                // answers it. Neither is ever less private. A spent allowance is
                // not fallen back on: that is the reader's to decide, and the
                // sheet offers the device as a button.
                let reason: AskJob.Fallback = failure == .declined ? .declined : .unreachable
                IssaLog.info("ask fell back to the device", [
                    "reason": reason == .declined ? "cloud declined" : "cloud unreachable",
                ])
                job.fallback = reason
                job.answeredBy = .device
                job.partial = ""
                do {
                    answered = try await Self.drive(
                        deviceEngine, question: question, source: source, boundary: boundary,
                        into: job,
                    )
                } catch {
                    job.state = .failed(AskCoordinator.failure(for: error))
                    self?.finished(job)
                    return
                }
            } catch {
                job.state = .failed(AskCoordinator.failure(for: error))
                self?.finished(job)
                return
            }
            guard let self else { return }
            // A stream that ends without an answer is a cancellation. *Whose*
            // it was decides what happens next, and for a while this did not
            // ask.
            //
            // The reader's — Cancel, or a second question — leaves nothing to
            // show and nothing to tell them, so the job goes.
            //
            // The system's does not. `backgroundTimeExpired` cancels the task
            // and writes `.failed(.backgroundExpired)`, and this tail then
            // deleted the job three lines later. Not a race: both run on the
            // main actor, in that order, every time. So the one message written
            // for that case — "iOS paused the app before the answer finished.
            // Ask again." — could never be shown, and the reader came back to a
            // blank compose field with no sign anything had happened.
            guard answered else {
                guard job.wasExpired else {
                    if jobs[uuid] === job { jobs.removeValue(forKey: uuid) }
                    syncEmbeddingAskState()
                    releaseAssertionIfIdle()
                    return
                }
                // Written again here, and not only in `backgroundTimeExpired`:
                // a snapshot the engine yielded before the cancel can still be
                // delivered after it, and one `.phase` event would put the job
                // back into `.working` — pulsing "Asking…" until the next
                // launch, which is the exact thing that method exists to stop.
                job.state = .failed(.backgroundExpired)
                syncEmbeddingAskState()
                releaseAssertionIfIdle()
                return
            }
            finished(job)
        }
        return job
    }

    /// Runs one engine's events into the job. True when an answer arrived.
    private static func drive(
        _ engine: AskEngine, question: String, source: BookSource, boundary: ReadingBoundary,
        into job: AskJob,
    ) async throws -> Bool {
        var answered = false
        for try await event in engine.ask(question: question, source: source, boundary: boundary) {
            switch event {
            case let .phase(phase):
                job.state = .working(phase)
            case let .partial(text):
                job.partial = text
            case let .answered(answer):
                answered = true
                job.state = .answered(answer)
            }
        }
        return answered
    }

    /// Stops a job and forgets it. What Cancel does.
    func cancel(bookUUID: String) {
        jobs[bookUUID]?.task?.cancel()
        jobs.removeValue(forKey: bookUUID)
        syncEmbeddingAskState()
        releaseAssertionIfIdle()
    }

    /// Throws the answer away. What Done and "Ask another" do — nothing about a
    /// question or an answer is ever persisted.
    func discard(bookUUID: String) {
        cancel(bookUUID: bookUUID)
    }

    /// The sheet closed. A working job carries on.
    func sheetDismissed(bookUUID: String) {
        embeddingScheduler.askSheetClosed(bookUUID: bookUUID)
        guard let job = jobs[bookUUID] else { return }
        guard job.state.isWorking else {
            // An answer nobody is looking at is not worth keeping: it exists
            // only to be read, and the next open should start on a blank field
            // rather than on the last answer.
            discard(bookUUID: bookUUID)
            return
        }
        job.owesNotification = true
        requestNotificationsOnce()
    }

    /// Asks for notification permission when a reader closes a sheet with a
    /// question still running, and only if the system has never been asked.
    ///
    /// Contextual on purpose: a permission sheet at launch, for a feature the
    /// reader has not yet used, is the prompt everybody denies. This one
    /// arrives at the moment the reader has just expressed the wish to be told
    /// later.
    ///
    /// Whether to ask is the system's to say, not a flag of ours. A flag in the
    /// defaults travels in a backup to a device whose notification setting does
    /// not, and a restored device was then never asked at all. The notifier
    /// reads the authorisation status and prompts only while it is
    /// undetermined, which the system itself makes a once-only question.
    private func requestNotificationsOnce() {
        guard let notifier else { return }
        Task { await notifier.requestAuthorizationIfNeeded() }
    }

    /// A job that has stopped: post the notification if one is owed, then let
    /// the background assertion go if nothing else is running.
    private func finished(_ job: AskJob) {
        if job.owesNotification, job.state.isAnswered, let notifier {
            Task { await notifier.postAnswerReady(job: job) }
        } else if notifier != nil {
            // The other half of the notifier's own log line, so the two
            // together say why nothing arrived. Never the question.
            IssaLog.info("ask job finished quietly", [
                "owed": String(job.owesNotification),
                "answered": String(job.state.isAnswered),
            ])
        }
        syncEmbeddingAskState()
        releaseAssertionIfIdle()
    }

    /// Everything the engine can throw, as something the sheet can say.
    static func failure(for error: any Error) -> AskFailure {
        error as? AskFailure ?? .other("Something went wrong answering that. Try again.")
    }

    // MARK: - Leaving and coming back

    var hasWorkingJob: Bool { jobs.values.contains { $0.state.isWorking } }

    /// Holds the app awake long enough to finish an answer the reader has been
    /// promised a notification about — and makes the promise, which is the part
    /// that was missing.
    ///
    /// The assertion was taken on a path that could never notify. It guards on
    /// `hasWorkingJob` alone, while `finished()` posts only when the job owes a
    /// notification — and that was set solely by `sheetDismissed`. So a reader
    /// who backgrounded the app with the sheet still open held the process
    /// awake for up to thirty seconds of inference, and the run ended by
    /// logging "ask job finished quietly". Leaving the app mid-question is
    /// exactly who the notification is for; the flag is set here too.
    func appDidEnterBackground() {
        embeddingScheduler.appDidEnterBackground(hasWorkingJob: hasWorkingJob)
        #if os(iOS)
        guard hasWorkingJob else { return }
        // Before the assertion guard, so a second backgrounding while one is
        // already held still makes the promise.
        //
        // The flag only; `requestNotificationsOnce` deliberately stays on the
        // sheet-dismissal path. A permission alert cannot be put in front of
        // somebody who has just left the app, and one that surfaced on their
        // return, attached to nothing they were doing, is the prompt everybody
        // denies — which is the whole reason it is contextual.
        for job in jobs.values where job.state.isWorking {
            job.owesNotification = true
        }
        guard assertion == nil else { return }
        let held = BackgroundAssertion()
        held.begin(name: "issa.askAnswer") { [weak self] in
            // Assumed rather than hopped: UIKit documents the expiration
            // handler as called synchronously on the main thread, and there are
            // milliseconds left before the process is suspended — a hop would
            // be scheduled and never run, leaving the job pulsing "Asking…"
            // until the next launch.
            MainActor.assumeIsolated { self?.backgroundTimeExpired() }
        }
        assertion = held
        #endif
    }

    func appDidBecomeActive() {
        releaseAssertion()
        embeddingScheduler.appDidBecomeActive()
    }

    #if os(iOS)
    private var assertion: BackgroundAssertion?

    /// iOS is about to suspend the app whether the answer is finished or not.
    ///
    /// The job is cancelled and said so, rather than left in `.working` for
    /// ever: a pill that pulses "Asking…" until the app is relaunched is a lie,
    /// and the reader can ask again in a second.
    ///
    /// Not private, so a test can drive it. Nothing else calls it — the only
    /// caller in the app is the expiration handler installed above, which is
    /// UIKit's to run and cannot be provoked from a test at all.
    func backgroundTimeExpired() {
        for job in jobs.values where job.state.isWorking {
            // Set *before* the cancel. The flag is what tells the stream's own
            // tail that this cancellation was the system's and not the
            // reader's, and the tail is the thing the cancel sets off.
            job.wasExpired = true
            job.task?.cancel()
            job.state = .failed(.backgroundExpired)
        }
        syncEmbeddingAskState()
        releaseAssertion()
    }
    #endif

    private func releaseAssertionIfIdle() {
        guard !hasWorkingJob else { return }
        releaseAssertion()
    }

    private func releaseAssertion() {
        #if os(iOS)
        assertion?.end()
        assertion = nil
        #endif
    }

    // MARK: - Deletion

    /// One book's index, when its download goes.
    func remove(bookUUID: String) {
        cancel(bookUUID: bookUUID)
        stopBackgroundEmbeddings(for: bookUUID)
        prepared.remove(bookUUID)
        preparing.removeValue(forKey: bookUUID)?.cancel()
        Task { [store] in await store.remove(bookUUID: bookUUID) }
    }

    /// Every index but those of `kept`, on sign-out or when downloads are
    /// deleted with the account: `kept` is the books the reader added from
    /// their own files, which belong to the device and outlive the account.
    /// Their jobs, warm-ups and delivered answers are left as they are.
    ///
    /// The one way to purge. A short form that kept nothing had no caller at
    /// all, and was one more way to sweep the device's books with the account's.
    func purgeAll(keeping kept: Set<String>) {
        for (uuid, job) in jobs where !kept.contains(uuid) { job.task?.cancel() }
        jobs = jobs.filter { kept.contains($0.key) }
        prepared = prepared.filter { kept.contains($0) }
        for (uuid, task) in preparing where !kept.contains(uuid) { task.cancel() }
        preparing = preparing.filter { kept.contains($0.key) }
        embeddingScheduler.purgeBooks(keeping: kept)
        if let request = reopenRequest, !kept.contains(request) { reopenRequest = nil }
        // Only when nothing kept is still answering: the assertion is what lets
        // a question finish in the background.
        if jobs.isEmpty { releaseAssertion() }
        // Including anything already on the lock screen: the account's data is
        // going, and a banner about one of its answers is that data. A kept
        // book's banner is the device's, and stays.
        if let notifier { Task { await notifier.removeAllDelivered(keeping: kept) } }
        Task { [store] in await store.removeAll(keeping: kept) }
    }
}

// MARK: -

/// "iPhone", "iPad" or "Mac" — the machine the reader is holding.
///
/// Every sentence this feature shows names it, because "this device" reads as a
/// support article and the promise being made is about *their* machine.
enum AskDevice {
    static var noun: String {
        #if os(macOS)
        "Mac"
        #elseif canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        "device"
        #endif
    }

    /// Where Apple Intelligence is switched on, which is not the same place on
    /// the two platforms.
    static var settingsPath: String {
        #if os(macOS)
        "System Settings › Apple Intelligence & Siri"
        #else
        "Settings › Apple Intelligence & Siri"
        #endif
    }

    /// Where Issa Reader's own switch for Ask is, which is not the same place on
    /// the two platforms either: the phone's Settings is a tab of the app, the
    /// Mac's is a window with Reading among its tabs (`MacSettingsView`).
    ///
    /// Named as the app's own, never as plain "Settings", because the sentence
    /// that uses it also names `settingsPath` — the system's — and two
    /// "Settings" in one breath is how somebody goes looking in the wrong one.
    static var appSwitchPath: String {
        #if os(macOS)
        "Issa Reader › Settings › Reading"
        #else
        "Issa Reader’s Settings tab"
        #endif
    }

    /// How to take the button away again, said wherever the button is
    /// explained.
    ///
    /// Ask is on from the first launch for any reader whose device can answer,
    /// so a reader who does not want it, and whose device is not ready, meets
    /// a sparkle that does nothing yet. The switch is always theirs; this is
    /// the sentence that says where it is. One copy, so the sheet behind the
    /// sparkle and Settings cannot give two different routes to it.
    static var hideButtonSentence: String {
        "To hide this button, turn off “\(switchTitle)” in \(appSwitchPath)."
    }

    /// The switch's own label, which the sentence above quotes. One string, so
    /// a rename in Settings cannot leave the sheet pointing at a switch that no
    /// longer exists.
    static let switchTitle = "Ask about your book"

    /// How Apple Intelligence gets switched on, and what happens next.
    ///
    /// Turning it on is what starts the model's download, so "then come back"
    /// was leaving out the part that takes a while.
    static var turnOnSentence: String {
        "Turn it on in \(settingsPath), and this \(noun) will download the model. Asking will work once it finishes."
    }
}
#endif
