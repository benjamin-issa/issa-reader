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

        /// A reader who has moved to HTTPS leaves no cleartext-era token behind
        /// for a later connect to fall back on.
        @Test("a sign-in adopted over HTTPS removes the same host's HTTP sign-in, and no other host's")
        func httpsAdoptRetiresTheCleartextSignIn() async throws {
            let server = LifecycleServer.make("adopt-https")
            defer { LifecycleServer.forget(server) }
            let host = try #require(server.host())
            let sameHost = "http://\(host):8001"
            let otherHost = "http://other-\(host):8001"
            let tokens = LifecycleTokens()
            tokens.write("cleartext", account: sameHost)
            tokens.write("elsewhere", account: otherHost)
            let app = AppModel(keychain: tokens, notificationCentre: NotificationCenter())
            app.session = LifecycleServer.session(on: server)

            await app.adopt(token: "token-A")

            guard case .signedIn = app.session?.state else {
                Issue.record("did not sign in: \(String(describing: app.session?.state))")
                return
            }
            #expect(tokens.read(account: sameHost) == nil, "the same host's HTTP sign-in was kept")
            #expect(tokens.read(account: otherHost) == "elsewhere", "another host's sign-in was removed")
        }

        @Test("a sign-in refused over HTTPS, or adopted over HTTP, leaves the HTTP sign-in alone")
        func otherAdoptsLeaveTheCleartextSignIn() async throws {
            let server = LifecycleServer.make("adopt-other")
            defer { LifecycleServer.forget(server) }
            let host = try #require(server.host())
            let http = try #require(URL(string: "http://\(host):8001"))

            let refusedTokens = LifecycleTokens()
            refusedTokens.write("cleartext", account: http.absoluteString)
            let refused = AppModel(keychain: refusedTokens, notificationCentre: NotificationCenter())
            refused.session = LifecycleServer.session(on: server)
            await refused.adopt(token: "token-X")
            #expect(refusedTokens.read(account: http.absoluteString) == "cleartext",
                    "a sign-in the server refused removed the one that works")

            let plainTokens = LifecycleTokens()
            plainTokens.write("cleartext", account: http.absoluteString)
            let plain = AppModel(keychain: plainTokens, notificationCentre: NotificationCenter())
            plain.session = LifecycleServer.session(on: http)
            await plain.adopt(token: "token-A")
            guard case .signedIn = plain.session?.state else {
                Issue.record("did not sign in over HTTP: \(String(describing: plain.session?.state))")
                return
            }
            #expect(plainTokens.read(account: http.absoluteString) == "cleartext")
        }

        @Test("a device code that fails names the address it was asked of")
        func deviceCodeFailureNamesTheAddress() throws {
            let url = try #require(URL(string: "https://library.example"))
            #expect(DeviceCodeView.failureTitle(for: url) == "Couldn't sign in to https://library.example")
            #expect(DeviceSignInModel(serverURL: url).serverURL == url)
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
