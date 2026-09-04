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

    /// The token out of the callback the browser was redirected to.
    ///
    /// Tolerant about the path — the server sends `storyteller://settings`
    /// today and the app has no stake in which screen it names — and strict
    /// about the scheme and the parameter, because this is the credential.
    public static func token(from callback: URL) -> String? {
        guard callback.scheme?.lowercased() == callbackScheme else { return nil }
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty
        else { return nil }
        return token
    }
}
