import Foundation
import Observation

/// One signed-in connection to a Storyteller server.
///
/// Multi-server is modelled from the start — the keychain account, the local
/// store and the widget snapshot are all keyed by server — because retrofitting
/// it later means migrating all three.
@Observable
@MainActor
public final class Session {
    public enum State: Equatable, Sendable {
        case signedOut
        case signingIn
        case signedIn(User)
        /// Signed in once, but the token stopped working. Distinct from
        /// `signedOut` so the app can keep the server and say what happened
        /// rather than dropping the reader back to a blank form.
        case expired
        /// Authenticated, but the identity call did not come back. The reason
        /// is carried so the app can say it rather than dropping the reader on
        /// a blank form with nothing to go on.
        case failed(String)
    }

    public private(set) var state: State = .signedOut
    public private(set) var capabilities: ServerCapabilities = .baseline

    public let serverURL: URL
    public let client: APIClient
    private let tokens: TokenStore

    /// The same token the API client uses, for the background download session,
    /// which builds its own requests rather than going through APIClient.
    public var tokenProvider: any TokenProviding { tokens }

    /// - Parameter session: the transport, so a test can answer without a
    ///   server. The same seam `LibraryStore` has for its directory and
    ///   `DownloadManager` for its destination — without one, the states this
    ///   type exists to distinguish can only be reached by running the app.
    public init(
        serverURL: URL,
        keychain: any TokenPersisting,
        session: URLSession = .shared,
    ) {
        self.serverURL = serverURL
        let store = TokenStore(serverKey: serverURL.absoluteString, keychain: keychain)
        tokens = store
        client = APIClient(baseURL: serverURL, tokens: store, session: session)

        Task { [weak self] in
            await store.setInvalidationHandler { [weak self] in
                Task { @MainActor in
                    guard let self, case .signedIn = self.state else { return }
                    self.state = .expired
                }
            }
        }
    }

    /// Adopts a token obtained from either sign-in path and confirms it works.
    ///
    /// The server's `expires_in` is unusable (it is `epochMillis * 1000`), so
    /// validity is established by calling the API, never by arithmetic.
    public func adopt(token: String) async {
        state = .signingIn
        await tokens.set(token)
        await loadIdentity()
    }

    /// Whether a credential is stored for this server at all.
    ///
    /// Asked *before* showing the cached shelf: the offline-first path used to
    /// present a whole library on the strength of the local database alone,
    /// which meant signing out left every book still readable.
    public var hasStoredCredential: Bool {
        get async { await tokens.hasToken }
    }

    /// Restores a previously stored token, if there is one that still works.
    public func restore() async {
        guard await tokens.hasToken else { state = .signedOut; return }
        state = .signingIn
        // Restoring, not signing in fresh: we had a token and the server
        // refused it, which is a *lapsed session*, not "never signed in".
        // `loadIdentity` hard-coded `.signedOut` for both, so a returning
        // reader whose token had expired was dropped to a blank server form
        // with their address forgotten — which is precisely the state
        // `.expired` exists to avoid.
        await loadIdentity(rejectionMeans: .expired)
    }

    public func signOut() async {
        // Tell the server first, while the token still works. A token minted
        // through /token/app lasts thirty-five years; dropping it locally
        // without revoking it leaves a working credential behind on a device
        // the reader may be signing out of precisely because they lost it.
        // Best effort: no network must ever trap someone in a signed-in state.
        _ = try? await client.post(Endpoint.logout, body: [String: String]())
        await tokens.invalidate()
        state = .signedOut
    }

    /// How many times to ask for the identity before giving up.
    ///
    /// The device grant ends with the app returning from Safari after a minute
    /// or so of the user approving in a browser, and the very next request
    /// reuses a pooled connection that idled through all of it. A half-closed
    /// one fails as "network connection lost" and works immediately on retry —
    /// which is exactly the "sign-in always fails the first time" report. A
    /// token that was just minted deserves more than one attempt.
    private static let identityAttempts = 3

    private func loadIdentity(rejectionMeans rejection: State = .signedOut) async {
        for attempt in 1 ... Self.identityAttempts {
            // Cancellation is not a network fault and must not be retried as
            // one. A cancelled task fails every request instantly with -999 and
            // returns from every `try? await Task.sleep` at once, so the three
            // attempts and both backoffs were spent inside 153ms — and the
            // reader was then told to check they were on the same network as
            // their server. Leaving `state` alone is the point: whatever
            // cancelled this knows more about why than a guess at the network
            // does.
            if Task.isCancelled {
                IssaLog.warning("identity check cancelled", ["attempt": String(attempt)])
                return
            }
            do {
                let user: User = try await client.get(Endpoint.user)
                state = .signedIn(user)
                // Off the critical path: six probes that all 404 on a 2.x server
                // used to run before the reader was considered signed in, and
                // every one widened the window for the failure above.
                let apiClient = client
                Task { [weak self] in
                    let caps = await Self.probeCapabilities(using: apiClient)
                    self?.capabilities = caps
                }
                return
            } catch StorytellerError.notAuthenticated {
                // The token is genuinely bad; retrying cannot help. *What* that
                // means differs by caller: a fresh sign-in that is refused
                // never had a session, while a restore that is refused had one
                // that lapsed — and the second keeps the reader's server.
                state = rejection
                return
            } catch let error as StorytellerError where error.isRetryable
                && attempt < Self.identityAttempts {
                try? await Task.sleep(for: .milliseconds(300 * attempt))
            } catch {
                IssaLog.failure("identity", error, ["attempt": String(attempt)])
                state = .failed(AppFacingError.text(for: error))
                return
            }
        }
        // The same reason as above: three transport failures caused by
        // cancellation must not arrive as a sentence about the reader's
        // network.
        guard !Task.isCancelled else {
            IssaLog.warning("identity check cancelled", ["attempt": "final"])
            return
        }
        state = .failed("Couldn't reach your server. Check that you're on the same network as your server.")
    }

    /// Establishes which optional 3.x endpoints this server has.
    ///
    /// Storyteller 2.14.21 answers 404 for all of them; the client derives the
    /// same information locally from the full catalogue, so a missing endpoint
    /// costs no functionality. Probed once per sign-in and cached on the session.
    static func probeCapabilities(using client: APIClient) async -> ServerCapabilities {
        var caps = ServerCapabilities()
        async let discovery = client.probeStatus(Endpoint.V3.serverPublic)
        async let home = client.probeStatus(Endpoint.V3.homeSections)
        async let shelves = client.probeStatus(Endpoint.V3.shelves)
        async let sidebar = client.probeStatus(Endpoint.V3.sidebar)
        async let facets = client.probeStatus(Endpoint.V3.libraryFacets)
        async let nextUp = client.probeStatus(Endpoint.V3.nextUp)

        func present(_ status: Int) -> Bool { (200 ..< 300).contains(status) }
        caps.serverDiscovery = present(await discovery)
        caps.homeSections = present(await home)
        caps.shelves = present(await shelves)
        caps.sidebar = present(await sidebar)
        caps.libraryFacets = present(await facets)
        caps.nextUp = present(await nextUp)
        return caps
    }
}
