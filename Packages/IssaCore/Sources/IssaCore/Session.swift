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
    private let logoutTimeout: Duration
    /// The transport, kept for the logout, which is sent through a client
    /// of its own (see `revokeOnServer(_:)`).
    private let transport: URLSession

    /// A hold seam: awaited by the revoke just before its request is handed
    /// to the transport, so a test can start it after the deadline has passed
    /// — the race a loaded machine produces — on purpose rather than by luck.
    var logoutWillSend: (@Sendable () async -> Void)?

    /// The same token the API client uses, for the background download session,
    /// which builds its own requests rather than going through APIClient.
    public var tokenProvider: any TokenProviding { tokens }

    /// - Parameter session: the transport, so a test can answer without a
    ///   server. The same seam `LibraryStore` has for its directory and
    ///   `DownloadManager` for its destination — without one, the states this
    ///   type exists to distinguish can only be reached by running the app.
    /// - Parameter logoutTimeout: how long sign-out waits for the server to
    ///   revoke the token before going on without it. A seam for the same
    ///   reason: a test cannot wait five seconds per case.
    public init(
        serverURL: URL,
        keychain: any TokenPersisting,
        session: URLSession = .shared,
        logoutTimeout: Duration = .seconds(5),
    ) {
        self.logoutTimeout = logoutTimeout
        transport = session
        self.serverURL = serverURL
        let store = TokenStore(serverKey: serverURL.absoluteString, keychain: keychain)
        tokens = store
        client = APIClient(baseURL: serverURL, tokens: store, session: session)

        Task { [weak self] in
            await store.setInvalidationHandler { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    // `.failed` too: a restore that could not reach the server
                    // leaves the session there with the token still in use,
                    // and nothing re-runs the identity call. A 401 then is the
                    // same lapse as one while signed in — left in `.failed`,
                    // the token was gone and nothing ever said so.
                    switch self.state {
                    case .signedIn, .failed:
                        self.state = .expired
                    case .signedOut, .signingIn, .expired:
                        return
                    }
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
        // A token the device would not keep is a sign-in that ends at the
        // next launch, back at the form with nothing saying why. Said now,
        // and before the identity call: there is no point asking who a token
        // belongs to when it is not going to be kept.
        guard await tokens.set(token) else {
            IssaLog.error("sign-in token could not be saved", ["server": serverURL.absoluteString])
            state = .failed(Self.unsavedTokenMessage)
            return
        }
        await loadIdentity()
    }

    static let unsavedTokenMessage = "Your sign-in couldn't be saved on this device. Try again."

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
        // Tell the server, with the token it is to revoke. A token minted
        // through /token/app lasts thirty-five years; dropping it locally
        // without revoking it leaves a working credential behind on a device
        // the reader may be signing out of precisely because they lost it.
        // Best effort: no network must ever trap someone in a signed-in state.
        //
        // The token is read before it is forgotten and travels with the
        // request, so the revoke is authorised whenever it is sent — even
        // after this method has returned.
        let token = await tokens.currentToken()
        let forgotten = await tokens.forget()
        if let token {
            await revokeOnServer(token)
        } else {
            // A 401 already dropped it: the server refused that token, so
            // there is nothing left to revoke.
            IssaLog.info("no token held at sign-out; nothing to revoke")
        }
        if !forgotten {
            // Signed out all the same — the reader asked to be — but a
            // credential may still be on disk, and the next launch would
            // restore it. The log is the only place that can say so.
            IssaLog.error("sign-out could not delete the stored token", [
                "server": serverURL.absoluteString,
            ])
        }
        state = .signedOut
    }

    /// The logout POST, bounded by `logoutTimeout`.
    ///
    /// Unbounded, it waited out URLSession's sixty seconds against a server
    /// that does not answer — one switched off, or at a LAN address while the
    /// reader is on cellular, where a SYN gets no reply at all — and the
    /// reader stayed signed in, library open, for all of it. On the timeout
    /// sign-out goes on locally and the revoke goes on without it.
    ///
    /// The revoke is never cancelled. It used to be — the loser of a task
    /// group's race — and on a loaded machine the deadline could pass before
    /// the request had even reached URLSession, so it was cancelled unsent and
    /// the server never revoked a token that lasts thirty-five years. It now
    /// runs in a task of its own, carrying the token it revokes through a
    /// client of its own: `forget()` has emptied the store by the time it may
    /// be sent, and a 401 on it must not reach the store either. `/logout` is
    /// a route 2.14.21 and every 3.x serve.
    private func revokeOnServer(_ token: String) async {
        let revoker = APIClient(
            baseURL: serverURL, tokens: RevokedToken(token: token), session: transport)
        let hold = logoutWillSend
        let timeout = logoutTimeout
        let finished = await BoundedWait.run(for: timeout) {
            await hold?()
            // Nothing cancels this task. Were anything to, the revoke would
            // be lost — and whether URLSession still sends a request from a
            // cancelled task is a race it sometimes wins, which is how the
            // task-group version passed alone and failed under load. Decided
            // here instead, every time, and said.
            guard !Task.isCancelled else {
                IssaLog.error("logout cancelled before it was sent; the token was not revoked")
                return
            }
            _ = try? await revoker.post(Endpoint.logout, body: [String: String]())
        }
        if !finished {
            IssaLog.warning("logout not answered in time; signing out locally, revoke still running", [
                "timeout": String(describing: timeout),
            ])
        }
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

    /// Establishes which generation of Storyteller this is, and which optional
    /// 3.x endpoints it has.
    ///
    /// The generation comes from `/server/public`, by feature: a 3.x server
    /// answers it with its identity, 2.14.21 answers 404 (and so do 3.x
    /// betas before beta.21, which the home, shelves and sidebar probes tell
    /// apart — see `generation(fromPublicProbe:threeXRoutesAnswer:)`), and anything else —
    /// no answer, a 5xx, a proxy's HTML page with a 200 on it — leaves the
    /// generation undetermined rather than guessed. On 3.x, `/server/details`
    /// then supplies the version string, for display only: a self-built image
    /// reports "2.14.21" there, so it cannot be what decides.
    ///
    /// 2.14.21 answers 404 for the five feature routes too; the client derives
    /// the same information locally from the full catalogue, so a missing
    /// endpoint costs no functionality. Probed once per sign-in and held on
    /// the session.
    static func probeCapabilities(using client: APIClient) async -> ServerCapabilities {
        var caps = ServerCapabilities()
        async let discovery = client.probeResponse(Endpoint.V3.serverPublic)
        async let home = client.probeStatus(Endpoint.V3.homeSections)
        async let shelves = client.probeStatus(Endpoint.V3.shelves)
        async let sidebar = client.probeStatus(Endpoint.V3.sidebar)
        async let facets = client.probeStatus(Endpoint.V3.libraryFacets)
        async let nextUp = client.probeStatus(Endpoint.V3.nextUp)

        func present(_ status: Int) -> Bool { (200 ..< 300).contains(status) }
        caps.homeSections = present(await home)
        caps.shelves = present(await shelves)
        caps.sidebar = present(await sidebar)
        caps.libraryFacets = present(await facets)
        caps.nextUp = present(await nextUp)
        caps.generation = generation(
            fromPublicProbe: await discovery,
            threeXRoutesAnswer: caps.homeSections || caps.shelves || caps.sidebar)
        caps.serverDiscovery = caps.generation == .v3

        if caps.generation == .v3,
           let details = await client.probeResponse(Endpoint.V3.serverDetails),
           present(details.status)
        {
            caps.reportedVersion = try? JSONDecoder().decode(ServerDetails.self, from: details.data).version
        }

        IssaLog.info("server detected", [
            "generation": caps.generation?.rawValue ?? "undetermined",
            "version": caps.reportedVersion ?? "unreported",
        ])
        return caps
    }

    /// What one `/server/public` answer says about the generation.
    ///
    /// A 2xx counts only if it is shaped like Storyteller's identity: a
    /// reverse proxy that serves its own sign-in page with a 200 for every
    /// unknown path would otherwise make every 2.x server behind it "3.x".
    ///
    /// A 404 counts as 2.x only when nothing else says otherwise. 3.x betas
    /// up to beta.20 have no `/server/public` either, and 404 it just as
    /// 2.14.21 does — but they answer home, shelves and the sidebar, which
    /// no 2.x serves. Filed as `.v2`, such a server never had a null-status
    /// book filed; undetermined, it does, which is what nil is for.
    ///
    /// - Parameter threeXRoutesAnswer: whether any of home, shelves or the
    ///   sidebar answered 2xx.
    nonisolated static func generation(
        fromPublicProbe probe: (status: Int, data: Data)?,
        threeXRoutesAnswer: Bool = false,
    ) -> ServerGeneration? {
        guard let probe else { return nil }
        switch probe.status {
        case 200 ..< 300:
            return (try? JSONDecoder().decode(ServerPublic.self, from: probe.data)) != nil ? .v3 : nil
        case 404:
            return threeXRoutesAnswer ? nil : .v2
        default:
            return nil
        }
    }

    /// The two fields that make a `/server/public` answer Storyteller's.
    /// `publicUrl` and `publicKey` come too; nothing here needs them.
    private struct ServerPublic: Decodable {
        let id: String
        let capabilities: [String]
    }

    /// `/server/details` carries name, icon and capabilities as well; only the
    /// version is shown, and anything more would be new functionality.
    private struct ServerDetails: Decodable {
        let version: String
    }
}

/// The one token a sign-out revokes, held apart from the store it has
/// already been dropped from. A 401 on the revoke changes nothing: the token
/// is being let go of either way.
private struct RevokedToken: TokenProviding {
    let token: String
    func currentToken() async -> String? { token }
    func invalidate() async {}
}
