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
        case failed(String)
    }

    public private(set) var state: State = .signedOut
    public private(set) var capabilities: ServerCapabilities = .baseline

    public let serverURL: URL
    public let client: APIClient
    private let tokens: TokenStore

    public init(serverURL: URL, keychain: any TokenPersisting) {
        self.serverURL = serverURL
        let store = TokenStore(serverKey: serverURL.absoluteString, keychain: keychain)
        tokens = store
        client = APIClient(baseURL: serverURL, tokens: store)
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

    /// Restores a previously stored token, if there is one that still works.
    public func restore() async {
        guard await tokens.hasToken else { state = .signedOut; return }
        state = .signingIn
        await loadIdentity()
    }

    public func signOut() async {
        await tokens.invalidate()
        state = .signedOut
    }

    private func loadIdentity() async {
        do {
            let user: User = try await client.get(Endpoint.user)
            capabilities = await Self.probeCapabilities(using: client)
            state = .signedIn(user)
        } catch StorytellerError.notAuthenticated {
            state = .signedOut
        } catch {
            state = .failed(String(describing: error))
        }
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
