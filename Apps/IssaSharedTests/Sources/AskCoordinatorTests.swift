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
    static func coordinator(
        turns: [ScriptedAnswerModel.Turn] = [.answer("Alice followed a white rabbit.\nSources: 1")],
    ) throws -> (AskCoordinator, URL, UserDefaults, String) {
        let directory = URL.temporaryDirectory
            .appending(path: "issa-ask-coordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (defaults, name) = SharedFixtures.scratchDefaults()
        let coordinator = AskCoordinator(
            store: AskIndexStore(directory: directory),
            model: ScriptedAnswerModel(turns: turns),
            // No notifier: a permission prompt is a real system alert in front
            // of a real runner.
            notifier: nil,
            defaults: defaults,
        )
        return (coordinator, directory, defaults, name)
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
        let (coordinator, directory, _, suite) = try Self.coordinator()
        defer { Self.cleanUp(directory, suite) }
        let source = try Self.source()

        let job = try #require(coordinator.ask("What did Alice follow?", source: source,
                                               boundary: Self.boundary()))
        coordinator.sheetDismissed(bookUUID: source.bookUUID)
        #expect(job.wasDismissedWhileWorking, "the job has to know it was left running")
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
        let (coordinator, directory, _, suite) = try Self.coordinator()
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
        let (coordinator, directory, _, suite) = try Self.coordinator()
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
        let (coordinator, directory, _, suite) = try Self.coordinator()
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
        let (coordinator, directory, _, suite) = try Self.coordinator()
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

    // MARK: - Being asked about notifications

    /// Once, ever. A reader who has said no should not be asked again every
    /// time they close a sheet.
    @Test("the notification prompt is offered once and remembered")
    func notificationPromptIsAskedOnce() async throws {
        let (coordinator, directory, defaults, suite) = try Self.coordinator()
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
