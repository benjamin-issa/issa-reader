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

                #expect(app.loadError == "Couldn't reach a Storyteller server at https://\(Self.host) or http://\(Self.host). "
                    + "Check the address, and that you're on the same network as the server.")
                #expect(UserDefaults.standard.string(forKey: "issa.lastServer") == "somewhere.else")
                #expect(app.session == nil)
                #expect(app.phase == .chooseServer)
            }
        }

        // MARK: - The device an earlier build locked out

        /// Stored `https://host` over a bare host whose server is plain HTTP on
        /// :8001, the sign-in under `http://host:8001`, and HTTPS silent.
        private struct LockedOut {
            let server: URL
            let http: URL
            let tokens: LifecycleTokens
            let probed = ProbeLog()

            /// The app as it launches, with the address already stored: the
            /// model reads it once, when it is made.
            @MainActor
            func launch() -> AppModel {
                let app = AppModel(keychain: tokens, notificationCentre: NotificationCenter())
                // HTTPS gives no answer at all; HTTP answers an
                // unauthenticated probe the way 2.14.21 does.
                app.serverProbe = { [probed] url in
                    probed.append(url)
                    return url.scheme == "https" ? .noResponse : .answered(status: 404)
                }
                app.sessionTransport = LifecycleServer.transport()
                return app
            }
        }

        /// The probes the rescue sent, by address.
        final class ProbeLog: @unchecked Sendable {
            private let lock = NSLock()
            private var urls: [URL] = []
            func append(_ url: URL) { lock.withLock { urls.append(url) } }
            var all: [URL] { lock.withLock { urls } }
        }

        private func lockedOut(_ label: String, token: String) throws -> LockedOut {
            let server = LifecycleServer.make(label)
            let http = try #require(URL(string: "http://\(server.host() ?? ""):8001"))
            let tokens = LifecycleTokens()
            tokens.write(token, account: http.absoluteString)
            return LockedOut(server: server, http: http, tokens: tokens)
        }

        @Test("a locked-out launch offers the HTTP address and changes nothing until it is taken")
        func lockedOutLaunchIsOffered() async throws {
            let fixture = try lockedOut("rescue-offer", token: "token-A")
            defer { LifecycleServer.forget(fixture.server) }
            try await withStoredAddress(fixture.server.absoluteString) {
                let app = fixture.launch()

                await app.connect(to: app.serverAddress)

                let offer = try #require(app.cleartextOffer, "nothing was offered")
                #expect(offer.tried == fixture.server)
                #expect(offer.offered == fixture.http)
                #expect(app.loadError == offer.message(device: LocalDevice.noun))
                #expect(app.phase == .chooseServer)
                #expect(app.session == nil, "a session was opened before the reader said yes")
                #expect(UserDefaults.standard.string(forKey: "issa.lastServer") == fixture.server.absoluteString)
                #expect(app.serverAddress == fixture.server.absoluteString)
                #expect(fixture.tokens.read(account: fixture.http.absoluteString) == "token-A")
                #expect(fixture.tokens.read(account: fixture.server.absoluteString) == nil)
                #expect(LifecycleServer.requests(to: fixture.server).isEmpty,
                        "a request was sent before the offer was taken: \(LifecycleServer.requests(to: fixture.server))")
                #expect(fixture.probed.all == [fixture.server, fixture.http])
            }
        }

        @Test("taking the offer with a sign-in the server accepts stores the bare address")
        func acceptedOfferStoresTheBareAddress() async throws {
            let fixture = try lockedOut("rescue-accept", token: "token-A")
            defer { LifecycleServer.forget(fixture.server) }
            try await withStoredAddress(fixture.server.absoluteString) {
                let app = fixture.launch()
                await app.connect(to: app.serverAddress)
                try #require(app.cleartextOffer != nil)

                await app.acceptCleartextOffer()

                let bare = try #require(fixture.server.host())
                #expect(app.session?.serverURL == fixture.http)
                #expect(app.phase == .ready)
                #expect(app.cleartextOffer == nil)
                #expect(UserDefaults.standard.string(forKey: "issa.lastServer") == bare)
                #expect(app.serverAddress == bare)
                #expect(ServerAddress.candidates(for: bare).first?.scheme == "https",
                        "the next launch does not try HTTPS first")
                #expect(LifecycleServer.requests(to: fixture.server).contains {
                    $0.path == Endpoint.user && $0.bearer == "token-A"
                })
            }
        }

        /// Taking the offer is the reader's choice of that server, so the bare
        /// address is stored at once. Kept on the dead HTTPS address, a device
        /// whose saved sign-in had lapsed was locked out again with no offer
        /// left to take.
        @Test("taking the offer with a sign-in the server refuses stores the bare address and says to sign in again")
        func refusedOfferStoresTheBareAddress() async throws {
            let fixture = try lockedOut("rescue-refused", token: "token-X")
            defer { LifecycleServer.forget(fixture.server) }
            try await withStoredAddress(fixture.server.absoluteString) {
                let app = fixture.launch()
                await app.connect(to: app.serverAddress)
                try #require(app.cleartextOffer != nil)

                await app.acceptCleartextOffer()

                let bare = try #require(fixture.server.host())
                #expect(UserDefaults.standard.string(forKey: "issa.lastServer") == bare)
                #expect(app.serverAddress == bare)
                #expect(app.phase == .chooseServer)
                #expect(app.loadError
                    == "Your saved sign-in for \(fixture.http.absoluteString) is no longer accepted. Sign in again.")
                #expect(!app.isConnecting)
            }
        }

        /// While the offer is being taken the forms are busy: the model says
        /// so, and a second press reaching `connect` meanwhile changes nothing.
        @Test("while the offer is taken the model is busy, the address is already stored, and a connect changes nothing")
        func takingTheOfferIsBusy() async throws {
            let fixture = try lockedOut("rescue-busy", token: "token-A")
            defer { LifecycleServer.forget(fixture.server) }
            try await withStoredAddress(fixture.server.absoluteString) {
                let app = fixture.launch()
                await app.connect(to: app.serverAddress)
                try #require(app.cleartextOffer != nil)
                #expect(!app.isConnecting)
                LifecycleServer.hold(Endpoint.user, on: fixture.server)

                let taking = Task { await app.acceptCleartextOffer() }
                try #require(await waitUntil { LifecycleServer.held(Endpoint.user, on: fixture.server) == 1 },
                             "the identity call was never sent")

                let bare = try #require(fixture.server.host())
                #expect(app.isConnecting, "the forms would look idle while the offer is taken")
                #expect(UserDefaults.standard.string(forKey: "issa.lastServer") == bare,
                        "the address was not stored when the offer was taken")
                #expect(app.serverAddress == bare)
                let session = app.session
                await app.connect(to: "https://elsewhere-\(UUID().uuidString.prefix(6).lowercased()).test")
                #expect(app.session === session, "a connect during the offer replaced the session")
                #expect(app.serverAddress == bare)

                LifecycleServer.release(Endpoint.user, on: fixture.server)
                await taking.value
                #expect(!app.isConnecting)
                #expect(app.phase == .ready)
            }
        }

        /// A reader who moved to HTTPS on an earlier build has an account
        /// recorded under the HTTPS address, which a sign-out keeps.
        @Test("a device with an account recorded under the https address is not offered HTTP")
        func signedInOverHTTPSIsNotOffered() async throws {
            let fixture = try lockedOut("rescue-migrated", token: "token-A")
            defer { LifecycleServer.forget(fixture.server) }
            let record = "issa.account.\(fixture.server.absoluteString)"
            UserDefaults.standard.set("reader-A", forKey: record)
            defer { UserDefaults.standard.removeObject(forKey: record) }
            try await withStoredAddress(fixture.server.absoluteString) {
                let app = fixture.launch()

                await app.connect(to: app.serverAddress)

                #expect(app.cleartextOffer == nil, "the HTTP token was offered to a reader who signed in over HTTPS")
                #expect(fixture.probed.all.isEmpty, "a probe was sent for a device that signed in over HTTPS")
            }
        }
    }
}
