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

    public init(serverURL: URL, keychain: any TokenPersisting) {
        self.serverURL = serverURL
        let store = TokenStore(serverKey: serverURL.absoluteString, keychain: keychain)
        tokens = store
        client = APIClient(baseURL: serverURL, tokens: store)

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
        await loadIdentity()
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

    private func loadIdentity() async {
        for attempt in 1 ... Self.identityAttempts {
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
                // The token is genuinely bad; retrying cannot help.
                state = .signedOut
                return
            } catch let error as StorytellerError where error.isRetryable
                && attempt < Self.identityAttempts {
                try? await Task.sleep(for: .milliseconds(300 * attempt))
            } catch {
                state = .failed(AppFacingError.text(for: error))
                return
            }
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
