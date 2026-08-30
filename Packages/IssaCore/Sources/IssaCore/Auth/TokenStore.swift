import Foundation

/// Holds the bearer token for one server.
///
/// The server's `/api/v2/token` response carries an `expires_in` of
/// `epochMillis * 1000`, which is not a duration and not usable for anything.
/// Token validity is therefore established by calling `GET /api/v2/validate`
/// rather than by arithmetic on a bogus number.
public actor TokenStore: TokenProviding {
    private var token: String?
    private let keychain: any TokenPersisting
    private let serverKey: String

    public init(serverKey: String, keychain: any TokenPersisting) {
        self.serverKey = serverKey
        self.keychain = keychain
        token = keychain.read(account: serverKey)
    }

    public func currentToken() async -> String? { token }

    public func set(_ newToken: String) {
        token = newToken
        keychain.write(newToken, account: serverKey)
    }

    /// Called on any 401. Drops the token so the UI can prompt for a new sign-in;
    /// there is no refresh token to exchange.
    public func invalidate() async {
        token = nil
        keychain.delete(account: serverKey)
    }

    public var hasToken: Bool { token != nil }
}

/// Persistence for a token. Backed by the keychain in the apps, and by an
/// in-memory dictionary in tests.
public protocol TokenPersisting: Sendable {
    func read(account: String) -> String?
    func write(_ token: String, account: String)
    func delete(account: String)
}

/// Non-persistent store, for tests and for a "don't remember me" sign-in.
public final class EphemeralTokenStorage: TokenPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func read(account: String) -> String? {
        lock.withLock { storage[account] }
    }

    public func write(_ token: String, account: String) {
        lock.withLock { storage[account] = token }
    }

    public func delete(account: String) {
        _ = lock.withLock { storage.removeValue(forKey: account) }
    }
}
