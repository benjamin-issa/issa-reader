import Foundation
import IssaCore
import Testing

@testable import IssaReader_iOS

extension WidgetStorage {
    /// A launch where nothing answers the probe.
    ///
    /// Both candidates of a bare host failing used to hand back the first one, and
    /// `connect` stored it as the server address, though nothing had answered: a
    /// plain-HTTP host was pinned to HTTPS from then on, and the sign-in kept under
    /// the HTTP address was not found, so the offline shelf gave way to the form.
    @Suite("Launching with no server answering", .serialized)
    @MainActor
    struct OfflineLaunchTests {
        /// Refused at once on both schemes, so no probe waits out its timeout.
        static let host = "localhost:1"

        private func withStoredAddress(_ address: String, _ body: () async throws -> Void) async rethrows {
            let key = "issa.lastServer"
            let before = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(address, forKey: key)
            defer {
                if let before { UserDefaults.standard.set(before, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            try await body()
        }

        @Test("nothing answering leaves the stored address as it was and opens the stored sign-in")
        func nothingAnsweringKeepsTheStoredAddress() async throws {
            try await withStoredAddress(Self.host) {
                let tokens = LifecycleTokens()
                // Where a bare host that answered over HTTP filed its token.
                tokens.write("token", account: "http://\(Self.host)")
                let app = AppModel(keychain: tokens, notificationCentre: NotificationCenter())
                #expect(app.serverAddress == Self.host)

                await app.connect(to: Self.host)

                #expect(UserDefaults.standard.string(forKey: "issa.lastServer") == Self.host,
                        "an address nothing answered was stored")
                #expect(app.serverAddress == Self.host)
                #expect(app.session?.serverURL.absoluteString == "http://\(Self.host)",
                        "the sign-in kept under the HTTP address was not the one opened")
            }
        }

        @Test("nothing answering and nothing stored says so, and stores nothing")
        func nothingAnsweringAndNothingStored() async throws {
            try await withStoredAddress("somewhere.else") {
                let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())

                await app.connect(to: Self.host)

                #expect(app.loadError == "Couldn't reach a Storyteller server at that address.")
                #expect(UserDefaults.standard.string(forKey: "issa.lastServer") == "somewhere.else")
                #expect(app.session == nil)
                #expect(app.phase == .chooseServer)
            }
        }
    }
}
