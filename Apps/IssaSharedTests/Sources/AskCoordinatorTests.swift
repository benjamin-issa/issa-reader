import Foundation
import IssaAsk
import Testing

@testable import IssaReader_iOS

/// The job model, driven by a model whose answers are a function of nothing.
///
/// What is asserted here is the part that is genuinely hard to see by hand: a
/// job has to outlive the sheet that started it, because a first question about
/// a long book on a phone takes half a minute and the reader is expected to
/// close the sheet and carry on reading. Everything else in this file exists so
/// that property cannot be broken quietly by a later tidy-up.
@Suite("Asking about a book")
@MainActor
struct AskCoordinatorTests {
    private final class BundleMarker {}

    static func source(uuid: String = "alice-uuid") throws -> BookSource {
        let bundle = Bundle(for: BundleMarker.self)
        let url = try #require(bundle.url(forResource: "alice", withExtension: "epub"),
                               "the fixture is not in the test bundle")
        return try BookSource(bookUUID: uuid, fileURL: url)
    }

    /// The end of Chapter I — far enough in that questions about Alice and the
    /// rabbit retrieve something, and short of everything the story spoils.
    static func boundary(spine: Int = 2) -> ReadingBoundary {
        ReadingBoundary(
            spineIndex: spine, charOffset: .max, chapterTitle: "Chapter I", pageNumber: 6,
        )
    }

    /// A coordinator with a scripted model, its own index directory and its own
    /// defaults — nothing it does can reach the simulator's real app.
    /// - Returns: the coordinator, the scripted model it was built with, its
    ///   index directory, its defaults, and the defaults suite name to purge.
    ///   The model comes back because the turnstile is only observable through
    ///   it — what the coordinator did with it is a fact about what the model
    ///   was asked to do, and when.
    static func coordinator(
        turns: [ScriptedAnswerModel.Turn] = [.answer("Alice followed a white rabbit.\nSources: 1")],
    ) throws -> (AskCoordinator, ScriptedAnswerModel, URL, UserDefaults, String) {
        let directory = URL.temporaryDirectory
            .appending(path: "issa-ask-coordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (defaults, name) = SharedFixtures.scratchDefaults()
        let model = ScriptedAnswerModel(turns: turns)
        let coordinator = AskCoordinator(
            store: AskIndexStore(directory: directory),
            model: model,
            // No notifier: a permission prompt is a real system alert in front
            // of a real runner.
            notifier: nil,
            defaults: defaults,
        )
        return (coordinator, model, directory, defaults, name)
    }

    static func cleanUp(_ directory: URL, _ suite: String) {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    /// Waits for a job to stop working, without racing a sleep.
    static func settle(_ job: AskJob) async {
        await job.task?.value
    }

    // MARK: - The job outlives the sheet

    @Test("closing the sheet does not stop the answer")
    func jobOutlivesTheSheet() async throws {
        let (coordinator, _, directory, _, suite) = try Self.coordinator()
        defer { Self.cleanUp(directory, suite) }
        let source = try Self.source()

        let job = try #require(coordinator.ask("What did Alice follow?", source: source,
                                               boundary: Self.boundary()))
        coordinator.sheetDismissed(bookUUID: source.bookUUID)
        #expect(job.owesNotification, "the job has to know it was left running")
        #expect(coordinator.job(for: source.bookUUID) === job, "and it has to still be there")

        await Self.settle(job)
        #expect(job.state.isAnswered)
        #expect(coordinator.job(for: source.bookUUID) === job,
                "the answer is what the reader comes back to")
    }

    /// The other half: a sheet closed on a *finished* answer keeps nothing. An
    /// answer nobody is looking at exists only to be read, and reopening onto
    /// last week's answer instead of a blank field would be a small betrayal.
    @Test("closing the sheet on a finished answer clears it")
    func finishedAnswerIsNotKept() async throws {
        let (coordinator, _, directory, _, suite) = try Self.coordinator()
        defer { Self.cleanUp(directory, suite) }
        let source = try Self.source()

        let job = try #require(coordinator.ask("What did Alice follow?", source: source,
                                               boundary: Self.boundary()))
        await Self.settle(job)
        #expect(job.state.isAnswered)

        coordinator.sheetDismissed(bookUUID: source.bookUUID)
        #expect(coordinator.job(for: source.bookUUID) == nil)
    }

    @Test("discard empties the coordinator")
    func discardEmpties() async throws {
        let (coordinator, _, directory, _, suite) = try Self.coordinator()
        defer { Self.cleanUp(directory, suite) }
        let source = try Self.source()

        let job = try #require(coordinator.ask("What did Alice follow?", source: source,
                                               boundary: Self.boundary()))
        coordinator.discard(bookUUID: source.bookUUID)
        #expect(coordinator.job(for: source.bookUUID) == nil)
        #expect(coordinator.jobs.isEmpty)
        // The pipeline goes with it: a job nothing is showing must not be left
        // running against the on-device model, which answers one at a time.
        await Self.settle(job)
        #expect(job.task?.isCancelled == true)
    }

    // MARK: - One job per book

    @Test("a second question about the same book replaces the first")
    func oneJobPerBook() async throws {
        let (coordinator, _, directory, _, suite) = try Self.coordinator()
        defer { Self.cleanUp(directory, suite) }
        let source = try Self.source()

        let first = try #require(coordinator.ask("What did Alice follow?", source: source,
                                                 boundary: Self.boundary()))
        let second = try #require(coordinator.ask("Who is Alice?", source: source,
                                                  boundary: Self.boundary()))
        #expect(coordinator.jobs.count == 1)
        #expect(coordinator.job(for: source.bookUUID) === second)
        #expect(first !== second)
        await Self.settle(second)
    }

    /// Two books open at once is the ordinary Mac case, and their answers must
    /// not overwrite each other.
    @Test("two books each keep their own job")
    func oneJobPerBookNotPerApp() async throws {
        let (coordinator, _, directory, _, suite) = try Self.coordinator()
        defer { Self.cleanUp(directory, suite) }
        let alice = try Self.source(uuid: "alice-uuid")
        let other = try Self.source(uuid: "other-uuid")

        let first = try #require(coordinator.ask("What did Alice follow?", source: alice,
                                                 boundary: Self.boundary()))
        let second = try #require(coordinator.ask("What did Alice follow?", source: other,
                                                  boundary: Self.boundary()))
        #expect(coordinator.jobs.count == 2)
        await Self.settle(first)
        await Self.settle(second)
    }

    /// The only test that catches the coordinator forgetting to share its
    /// turnstile.
    ///
    /// The engine cannot serialise this by itself, and for a while nothing did:
    /// a fresh `AskEngine` is built per question, so two books were two engines,
    /// two turnstiles and two concurrent generations — and the reader asking
    /// about the second book was told Apple Intelligence was busy for a question
    /// that should have queued behind the first.
    @Test("two books asked at once are answered one after the other")
    func twoBooksShareOneTurnAtTheModel() async throws {
        let (coordinator, model, directory, _, suite) = try Self.coordinator(turns: [
            .init(partials: ["first"], holdsAfterPartials: 1),
            .answer("The other book's answer.\nSources: 1"),
        ])
        defer { Self.cleanUp(directory, suite) }
        let alice = try Self.source(uuid: "alice-uuid")
        let other = try Self.source(uuid: "other-uuid")

        let first = try #require(coordinator.ask("What did Alice follow?", source: alice,
                                                 boundary: Self.boundary()))
        await model.waitUntilHolding()
        let second = try #require(coordinator.ask("Who is Alice?", source: other,
                                                  boundary: Self.boundary()))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await model.received.count == 1, "the second book's question must be waiting")

        await model.release()
        await Self.settle(first)
        await Self.settle(second)
        #expect(await model.received.count == 2)
        #expect(await model.peakConcurrency == 1)
    }

    // MARK: - Citations

    /// The whole apparatus, end to end, in the place the sheet reads it from.
    ///
    /// Every piece of this existed and none of them were joined up: the prompt
    /// numbered its excerpts, the model was instructed to cite them, the parser
    /// stripped the `Sources:` line into `citations` — and nothing under `Apps/`
    /// ever read it, so the sheet had no way to show a reader what an answer
    /// rested on.
    @Test("an answered job carries the excerpts it rests on, inside the captured boundary")
    func answeredJobCarriesItsSources() async throws {
        let (coordinator, _, directory, _, suite) = try Self.coordinator(turns: [
            .answer("Alice followed a white rabbit down a hole.\nSources: 1, 2"),
        ])
        defer { Self.cleanUp(directory, suite) }
        let source = try Self.source()
        let boundary = Self.boundary()

        let job = try #require(coordinator.ask("What did Alice follow?", source: source,
                                               boundary: boundary))
        await Self.settle(job)
        guard case let .answered(answer) = job.state else {
            Issue.record("expected an answer, got \(job.state)")
            return
        }
        #expect(answer.sources.map(\.ordinal) == [1, 2])
        for cited in answer.sources {
            // Bounded by the reader's own position by construction — the excerpt
            // only exists because a query bounded by this boundary returned it —
            // which is why the vetting pass deliberately does not re-check them.
            #expect(cited.passage.spineIndex <= boundary.spineIndex)
            #expect(!cited.passage.displayText.isEmpty)
        }
    }

    // MARK: - Leaving the app mid-question

    /// The first test to reach this path at all, and it fails without the fix.
    ///
    /// `backgroundTimeExpired` cancels the task and writes
    /// `.failed(.backgroundExpired)`; the stream's own tail then read "ended
    /// without an answer" as a cancellation and deleted the job three lines
    /// later. Both run on the main actor in that order every time, so the one
    /// message written for this case could never be shown and the reader came
    /// back to a blank compose field.
    @Test("a question iOS cut short says so, rather than vanishing")
    func expiredJobSurvivesItsOwnCancellation() async throws {
        let (coordinator, model, directory, _, suite) = try Self.coordinator(turns: [
            .init(partials: ["Alice"], holdsAfterPartials: 1),
        ])
        defer { Self.cleanUp(directory, suite) }
        let source = try Self.source()

        let job = try #require(coordinator.ask("What did Alice follow?", source: source,
                                               boundary: Self.boundary()))
        await model.waitUntilHolding()
        coordinator.backgroundTimeExpired()
        await Self.settle(job)

        #expect(coordinator.job(for: source.bookUUID) === job,
                "the reader has to be told what happened to their question")
        guard case let .failed(failure) = job.state else {
            Issue.record("expected a failure, got \(job.state)")
            return
        }
        #expect(failure == .backgroundExpired)
        #expect(job.wasExpired)
    }

    /// The reader's own Cancel is the other side of the same branch, and it must
    /// still take the job with it.
    @Test("a question the reader cancelled still goes")
    func readerCancellationStillEmpties() async throws {
        let (coordinator, model, directory, _, suite) = try Self.coordinator(turns: [
            .init(partials: ["Alice"], holdsAfterPartials: 1),
        ])
        defer { Self.cleanUp(directory, suite) }
        let source = try Self.source()

        let job = try #require(coordinator.ask("What did Alice follow?", source: source,
                                               boundary: Self.boundary()))
        await model.waitUntilHolding()
        coordinator.cancel(bookUUID: source.bookUUID)
        await Self.settle(job)

        #expect(coordinator.job(for: source.bookUUID) == nil)
        #expect(!job.wasExpired)
    }

    /// The assertion used to be taken where it could never notify.
    ///
    /// `appDidEnterBackground` guards on `hasWorkingJob` alone, but `finished()`
    /// posts only when the job owes a notification — and that was set solely by
    /// `sheetDismissed`. So backgrounding with the sheet *open* held the process
    /// awake for up to thirty seconds of inference and then logged "ask job
    /// finished quietly".
    @Test("leaving the app mid-question owes the reader a notification")
    func backgroundingPromisesTheNotification() async throws {
        let (coordinator, model, directory, _, suite) = try Self.coordinator(turns: [
            .init(partials: ["Alice"], holdsAfterPartials: 1),
        ])
        defer { Self.cleanUp(directory, suite) }
        let source = try Self.source()

        let job = try #require(coordinator.ask("What did Alice follow?", source: source,
                                               boundary: Self.boundary()))
        await model.waitUntilHolding()
        #expect(!job.owesNotification, "nothing has been promised yet")

        coordinator.appDidEnterBackground()
        #expect(job.owesNotification, "the reader who leaves mid-question is who it is for")

        await model.release()
        await Self.settle(job)
        coordinator.appDidBecomeActive()
    }

    // MARK: - Being asked about notifications

    /// Once, ever. A reader who has said no should not be asked again every
    /// time they close a sheet.
    @Test("the notification prompt is offered once and remembered")
    func notificationPromptIsAskedOnce() async throws {
        let (coordinator, _, directory, defaults, suite) = try Self.coordinator()
        defer { Self.cleanUp(directory, suite) }
        let source = try Self.source()
        #expect(!defaults.bool(forKey: AskCoordinator.askedForNotificationsKey))

        let job = try #require(coordinator.ask("What did Alice follow?", source: source,
                                               boundary: Self.boundary()))
        coordinator.sheetDismissed(bookUUID: source.bookUUID)
        #expect(defaults.bool(forKey: AskCoordinator.askedForNotificationsKey))
        await Self.settle(job)
    }

    // MARK: - The setting

    @Test("the Ask switch is off until it is turned on, and survives a relaunch")
    func askEnabledPersists() {
        let (defaults, name) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let settings = PlaybackSettings(suiteName: name)
        #expect(!settings.askEnabled, "a feature nobody has asked for is off")
        #expect(defaults.object(forKey: "issa.askAboutBook") == nil,
                "and writes nothing until it is touched")

        settings.askEnabled = true
        #expect(defaults.bool(forKey: "issa.askAboutBook"))
        // A fresh instance is what the next launch builds.
        #expect(PlaybackSettings(suiteName: name).askEnabled)

        settings.askEnabled = false
        #expect(!PlaybackSettings(suiteName: name).askEnabled)
    }
}
