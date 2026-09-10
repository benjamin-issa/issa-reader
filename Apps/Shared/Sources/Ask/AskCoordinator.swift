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
    /// The kill switch for the model's own `searchBook` tool.
    ///
    /// A constant rather than a preference: the choice is whether the 3B model
    /// may refine the app's search, and the honest concern is that it is only
    /// moderately reliable at deciding when to — and each round trip is another
    /// three to six seconds on a phone. If the measurement goes against it,
    /// this is the one line that changes, and the pipeline is otherwise
    /// identical with and without it.
    static let usesSearchTool = true

    /// Remembers that the reader has been asked about notifications once, so
    /// they are never asked twice for the same thing.
    static let askedForNotificationsKey = "issa.askNotificationsAsked"

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
    private let model: any AnswerModel
    /// One turn at the on-device model, for the whole app.
    ///
    /// Held here because this is the only object that outlives a question. The
    /// engines do not: one is built per question, so a turnstile living on an
    /// engine serialised that engine against itself and nothing else, and two
    /// books meant two concurrent generations and a "busy" the reader had done
    /// nothing to deserve. It is passed to **both** construction sites below.
    private let turnstile = AskTurnstile()
    /// For index building, prewarming and chips — everything that has no
    /// boundary of its own, so it needs no tool.
    private let preparer: AskEngine

    private let defaults: UserDefaults
    /// Nil in tests. Everything else about a job can be driven deterministically
    /// with a scripted model, but a permission prompt is a real system alert in
    /// front of a real runner, and `UNUserNotificationCenter` has no stand-in.
    private let notifier: AskNotifier?

    /// Books whose index has been built and whose model has been warmed this
    /// session, so opening the sheet a second time costs nothing.
    private var prepared: Set<String> = []
    private var preparing: [String: Task<Void, Never>] = [:]

    /// The observer token, in a box `deinit` can reach.
    ///
    /// A nonisolated `deinit` cannot read a main-actor property, and dropping
    /// the removal instead is how a released object leaves a live observer
    /// behind. `PlaybackSettings` solves the same problem the same way.
    private final class ObserverBox: @unchecked Sendable {
        var token: (any NSObjectProtocol)?
        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    private let signOutObserver = ObserverBox()

    init(
        store: AskIndexStore = AskIndexStore(),
        model: (any AnswerModel)? = nil,
        notifier: AskNotifier? = AskNotifier(),
        defaults: UserDefaults = .standard,
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
        self.notifier = notifier
        self.defaults = defaults
        preparer = AskEngine(model: self.model, store: store, turnstile: turnstile)

        // The indexes are per book and the books are per account, so an account
        // leaving takes its indexes with it. Through the same notification
        // `PlaybackSettings` uses, because this object is not owned by
        // `AppModel` either and there is nothing to call it directly.
        signOutObserver.token = centre.addObserver(
            forName: PlaybackSettings.signOutNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.purgeAll() }
        }
    }

    func job(for bookUUID: String) -> AskJob? { jobs[bookUUID] }

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
        let uuid = source.bookUUID
        guard !prepared.contains(uuid), preparing[uuid] == nil else { return }
        preparing[uuid] = Task { [preparer] in
            // Failures are not surfaced: nothing has been asked yet, and a
            // sheet that opens onto an error before the reader has typed a word
            // is worse than one that quietly retries when they do. The question
            // itself builds the index again and reports properly.
            try? await preparer.prepareIndex(source: source)
            await preparer.prewarm()
            guard !Task.isCancelled else { return }
            prepared.insert(uuid)
            preparing[uuid] = nil
        }
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
    func ask(_ question: String, in model: ReaderModel) -> AskJob? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let source = model.askSource(),
              let boundary = model.readingBoundary()
        else { return nil }
        return ask(trimmed, source: source, boundary: boundary)
    }

    @discardableResult
    func ask(_ question: String, source: BookSource, boundary: ReadingBoundary) -> AskJob? {
        let uuid = source.bookUUID
        // A second question replaces the first, and the first is cancelled
        // rather than left to finish into a job nothing is showing.
        jobs[uuid]?.task?.cancel()
        let job = AskJob(
            bookUUID: uuid, question: question, boundary: boundary,
            bookTitle: source.package.metadata.title,
        )
        jobs[uuid] = job

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

        // Built per question because the tool captures the boundary, which is
        // what makes it unable to reach past it whatever the model asks for.
        var tools: [any AskTool] = []
        #if canImport(FoundationModels)
        if Self.usesSearchTool {
            tools = [SearchBookTool(store: store, bookUUID: uuid, boundary: boundary)]
        }
        #endif
        let engine = AskEngine(model: model, store: store, tools: tools, turnstile: turnstile)

        job.task = Task { [weak self] in
            // Costs nothing when the sheet's build has already finished, and
            // when it has not this is the build this question was going to do
            // anyway — `AskEngine.perform` calls `prepareIndex` first thing.
            await preparation?.value
            var answered = false
            do {
                for try await event in engine.ask(
                    question: question, source: source, boundary: boundary,
                ) {
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
                    releaseAssertionIfIdle()
                    return
                }
                // Written again here, and not only in `backgroundTimeExpired`:
                // a snapshot the engine yielded before the cancel can still be
                // delivered after it, and one `.phase` event would put the job
                // back into `.working` — pulsing "Asking…" until the next
                // launch, which is the exact thing that method exists to stop.
                job.state = .failed(.backgroundExpired)
                releaseAssertionIfIdle()
                return
            }
            finished(job)
        }
        return job
    }

    /// Stops a job and forgets it. What Cancel does.
    func cancel(bookUUID: String) {
        jobs[bookUUID]?.task?.cancel()
        jobs.removeValue(forKey: bookUUID)
        releaseAssertionIfIdle()
    }

    /// Throws the answer away. What Done and "Ask another" do — nothing about a
    /// question or an answer is ever persisted.
    func discard(bookUUID: String) {
        cancel(bookUUID: bookUUID)
    }

    /// The sheet closed. A working job carries on.
    func sheetDismissed(bookUUID: String) {
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

    /// Asks for notification permission the first time — and only the first
    /// time — a reader closes a sheet with a question still running.
    ///
    /// Contextual on purpose: a permission sheet at launch, for a feature that
    /// is off by default, is the prompt everybody denies. This one arrives at
    /// the moment the reader has just expressed the wish to be told later.
    private func requestNotificationsOnce() {
        guard !defaults.bool(forKey: Self.askedForNotificationsKey) else { return }
        defaults.set(true, forKey: Self.askedForNotificationsKey)
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
        prepared.remove(bookUUID)
        preparing.removeValue(forKey: bookUUID)?.cancel()
        Task { [store] in await store.remove(bookUUID: bookUUID) }
    }

    /// Every index, on sign-out or when downloads are deleted with the account.
    func purgeAll() {
        for job in jobs.values { job.task?.cancel() }
        jobs.removeAll()
        prepared.removeAll()
        for task in preparing.values { task.cancel() }
        preparing.removeAll()
        reopenRequest = nil
        releaseAssertion()
        // Including anything already on the lock screen: the account's data is
        // going, and a banner about one of its answers is that data.
        if let notifier { Task { await notifier.removeAllDelivered() } }
        Task { [store] in await store.removeAll() }
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
}
#endif
