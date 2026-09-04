import Foundation

/// Holds the bearer token for one server.
///
/// The server's `/api/v2/token` response carries an `expires_in` of
/// `epochMillis * 1000`, which is not a duration and not usable for anything.
/// Token validity is therefore established by calling the API — `GET
/// /api/v2/user` on adopt — never by arithmetic on that number. (`/validate`
/// was named here for years and nothing ever called it; it is now used, but as
/// the corroborating leg of the pre-auth password-login probe, which is a
/// different question.)
public actor TokenStore: TokenProviding {
    private var token: String?
    private let keychain: any TokenPersisting
    private let serverKey: String
    /// Called when the token stops working, so the app can ask for a new one
    /// instead of quietly failing every request.
    private var onInvalidated: (@Sendable () -> Void)?

    public init(serverKey: String, keychain: any TokenPersisting) {
        self.serverKey = serverKey
        self.keychain = keychain
        token = keychain.read(account: serverKey)
    }

    public func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        onInvalidated = handler
    }

    public func currentToken() async -> String? { token }

    public func set(_ newToken: String) {
        token = newToken
        keychain.write(newToken, account: serverKey)
    }

    /// Called on any 401. Drops the token so the UI can prompt for a new sign-in;
    /// there is no refresh token to exchange.
    ///
    /// This matters more than it looks: the device grant mints a 30-day token
    /// and the server offers no refresh, so every install reaches this path
    /// eventually. Announcing it is the difference between "sign in again" and
    /// an app where nothing loads and nothing says why.
    public func invalidate() async {
        guard token != nil else { return }
        token = nil
        keychain.delete(account: serverKey)
        onInvalidated?()
    }

    public var hasToken: Bool { token != nil }
}

/// Persistence for a token. Backed by the keychain in the apps, and by an
/// in-memory dictionary in tests.
public protocol TokenPersisting: Sendable {
    func read(account: String) -> String?
    /// Whether the token actually reached storage.
    ///
    /// Not `Void`. The keychain can refuse a write — a background task
    /// refreshing a token before first unlock gets `errSecInteractionNotAllowed`
    /// — and a caller that cannot tell the difference reports a successful
    /// sign-in over a credential that was never saved.
    @discardableResult
    func write(_ token: String, account: String) -> Bool
    /// Whether the token is now definitely gone.
    ///
    /// A silent failure here is worse than a silent failed write: the UI shows
    /// the reader signed out while a working credential stays on disk, and the
    /// next launch restores into the library they believed they had left.
    @discardableResult
    func delete(account: String) -> Bool
}

