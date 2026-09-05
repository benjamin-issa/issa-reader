import Foundation

/// Signing in through the server's own page, and getting a token back directly.
///
/// `GET /api/v2/token/app` is the route the Storyteller apps use, and it does
/// the whole job in one hop:
///
/// - with a browser session already in hand, it answers `302` straight to
///   `storyteller://settings?token=…`;
/// - without one, it answers `302` to `/login?callbackUrl=/api/v2/token/app`,
///   which shows the server's own login page — password and every configured
///   identity provider — and comes back here once that succeeds.
///
/// So the reader who is already signed in to their library in Safari taps once
/// and is done, and the reader who is not signs in exactly where they would
/// have anyway. No device code, no approval screen, and no polling.
///
/// This supersedes running the device grant behind a browser, which was built
/// on the belief that no such route existed. That flow asked someone to approve
/// the very phone they were holding, which is the right question only when the
/// approving device is a different one — a television. The device grant stays
/// for exactly that.
public enum AppTokenGrant: Sendable {
    /// The scheme the server redirects to. The server's, not this app's: it is
    /// hard-coded server-side and cannot be asked for a different one.
    ///
    /// Deliberately *not* registered in any Info.plist.
    /// `ASWebAuthenticationSession` intercepts its callback scheme itself,
    /// before the system opener ever sees it, so claiming `storyteller://`
    /// would buy nothing and would fight the real Storyteller app for it on any
    /// device that has both installed.
    public static let callbackScheme = "storyteller"

    public static func startURL(server: URL) -> URL {
        server.appending(path: Endpoint.appToken)
    }

    /// Ephemeral, so nothing it touches joins the shared cookie jar or cache,
    /// and short-timeout, because this runs while someone is looking at the
    /// screen.
    ///
    /// One caller left: the token exchange. It also served `isOffered`, the
    /// probe that greyed out the browser row when a server had no
    /// `/api/v2/token/app` — deleted with the chooser that row lived on. The
    /// collapsed screen has no window to run a probe in, and the answer that
    /// probe existed to give is now a sentence the reader gets after one
    /// browser trip: "Your server sent this app back without a sign-in token.
    /// Try a device code instead."
    private static func probingSession(timeout: TimeInterval = 6) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    /// Trades the callback's short-lived token for a session token.
    ///
    /// **The callback does not carry a session token**, and this is the step
    /// that was missing. `GET /api/v2/token/app` signs a JWT whose only claim
    /// is `sub` and which expires in *five minutes*
    /// (`addMinutes(new Date(), 5)` in the server's own route), and redirects
    /// with it. `POST` to the same path, `{"token": …}`, verifies that and
    /// creates the real session — `createSessionTokenForUserId`, a fresh
    /// `randomUUID` row in the `session` table, good for thirty-five years —
    /// and answers with `access_token`.
    ///
    /// Sending the callback token as a bearer instead gets a flat 401 from
    /// every endpoint, because it is not a session token and was never in the
    /// session table. That is exactly what build 26 did: the browser opened,
    /// the token arrived, and `GET /api/v2/user` refused it 110ms later. The
    /// server's own comment beside `maxAge` — "Leave mobile app logged in
    /// basically indefinitely" — describes the token this call returns, not the
    /// one in the callback.
    ///
    /// Unauthenticated: the short-lived token *is* the credential, in the body.
    public static func exchange(
        _ callbackToken: String, on server: URL, using session: URLSession,
    ) async -> Result<String, AppTokenFailure> {
        var request = URLRequest(url: startURL(server: server))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONEncoder().encode(["token": callbackToken])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // A timeout here is fatal in a way it is not elsewhere: the token
            // being traded is good for five minutes and there is no way to ask
            // for another without sending the reader back through the browser.
            IssaLog.failure("app token exchange", error, [:])
            return .failure(.couldNotExchange(status: nil))
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            IssaLog.error("app token exchange refused", ["status": String(status)])
            return .failure(.couldNotExchange(status: status))
        }
        guard let token = try? JSONDecoder().decode(AccessTokenResponse.self, from: data),
              !token.accessToken.isEmpty
        else {
            IssaLog.error("app token exchange returned no access token", [
                "bytes": String(data.count),
            ])
            return .failure(.couldNotExchange(status: status))
        }
        return .success(token.accessToken)
    }

    /// `exchange(_:on:using:)` on a session of its own, invalidated afterwards.
    public static func exchange(
        _ callbackToken: String, on server: URL,
    ) async -> Result<String, AppTokenFailure> {
        let session = probingSession(timeout: 15)
        defer { session.invalidateAndCancel() }
        return await exchange(callbackToken, on: server, using: session)
    }

    /// The token out of the callback the browser was redirected to.
    ///
    /// Tolerant about the path — the server sends `storyteller://settings`
    /// today and the app has no stake in which screen it names — and strict
    /// about the scheme and the parameter, because this is the credential.
    ///
    /// Note what this returns: the *short-lived* token, which still has to go
    /// through `exchange(_:on:)`. It is not usable as a bearer token.
    public static func token(from callback: URL) -> String? {
        guard callback.scheme?.lowercased() == callbackScheme else { return nil }
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty
        else { return nil }
        return token
    }
}
