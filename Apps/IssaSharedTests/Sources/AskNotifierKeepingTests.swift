import Foundation
import IssaAsk
import IssaCore
import Testing

@testable import IssaReader_iOS

/// A sign-out takes the account's delivered answers off the lock screen and
/// leaves the device's own books' — the ones added from the reader's files.
///
/// The notifier used to have two ways to remove them all, one of which
/// dropped `kept` by default, and the only test double implemented that one as
/// a no-op: deleting the kept set from the coordinator's purge turned no test
/// red.
@Suite("Delivered answers at sign-out")
@MainActor
struct AskNotifierKeepingTests {
    @Test("sign-out asks the notifier to keep the device's books' answers")
    func signOutKeepsLocalBanners() async throws {
        let directory = URL.temporaryDirectory.appending(path: "issa-ask-keeping-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (defaults, suite) = SharedFixtures.scratchDefaults()
        defer {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let centre = NotificationCenter()
        let notifier = AskCoordinatorTests.CountingNotifier()
        let coordinator = AskCoordinator(
            store: AskIndexStore(directory: directory), model: ScriptedAnswerModel(turns: []),
            notifier: notifier, defaults: defaults, centre: centre)
        let kept: Set<String> = ["local-book"]

        centre.post(
            name: PlaybackSettings.signOutNotification, object: nil,
            userInfo: [PlaybackSettings.keptBookUUIDsKey: kept])

        for _ in 0 ..< 200 where notifier.removedAllKeeping.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(notifier.removedAllKeeping == [kept], "the device's own books' answers were swept with the account's")
        _ = coordinator
    }
}
