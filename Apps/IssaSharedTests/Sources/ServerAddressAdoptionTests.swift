import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

extension WidgetStorage {
    /// An address is adopted only after something answered at it.
    ///
    /// A typed address with its scheme has one candidate, and `firstReachable`
    /// used to hand a lone candidate back unprobed: a typo such as
    /// `https://libary.example` was stored as the server and the working one's
    /// account left behind.
    @Suite("Adopting a server address", .serialized)
    @MainActor
    struct ServerAddressAdoptionTests {
        private static let typo = URL(string: "https://libary-\(UUID().uuidString.prefix(6).lowercased()).invalid")!

        @Test("a lone candidate is handed back unprobed unless it is new")
        func aLoneCandidateIsProbedOnlyWhenNew() async {
            #expect(await AppModel.firstReachable(of: [Self.typo], timeout: 2) == Self.typo,
                    "the stored address opens offline, with no probe")
            #expect(await AppModel.firstReachable(of: [Self.typo], timeout: 2, probesAlone: true) == nil,
                    "a typed address nothing answers at was adopted")
        }

        @Test("a new address nothing answers at leaves the working server alone")
        func aTypoLeavesTheWorkingServerAlone() async throws {
            let stored = "https://library-\(UUID().uuidString.prefix(6).lowercased()).test"
            // Put back, not removed: the key is the process's, and what was in it
            // before is what the next test to read it expects.
            let key = "issa.lastServer"
            let before = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(stored, forKey: key)
            defer {
                if let before { UserDefaults.standard.set(before, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
            let session = LifecycleServer.session(on: URL(string: stored)!, storing: "token-A")
            app.session = session
            app.phase = .ready
            try #require(app.serverAddress == stored)

            await app.connect(to: Self.typo.absoluteString)

            #expect(app.serverAddress == stored, "the typo was stored in memory")
            #expect(UserDefaults.standard.string(forKey: "issa.lastServer") == stored, "the typo was stored")
            #expect(app.session === session, "the working server's session was replaced")
            #expect(app.loadError != nil, "nothing said the address was not reached")
        }

        /// Both suites write the process-wide `issa.lastServer` across an awaited
        /// connect, and `.serialized` orders the tests inside one suite only, so
        /// two top-level suites raced in the release run. Under `WidgetStorage`,
        /// which is serialised, they run one after the other.
        @Test("this suite and the offline launch suite share the stored address, so they are serialised together")
        func serialisedWithTheOtherAddressSuite() {
            for type in [Self.self, OfflineLaunchTests.self] as [Any.Type] {
                #expect(String(reflecting: type).contains("WidgetStorage."),
                        "\(type) is a suite of its own, and runs beside the other one")
            }
        }
    }
}
