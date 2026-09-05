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

    /// Whether this server offers the route at all, asked before the row that
    /// uses it is offered.
    ///
    /// Not every Storyteller server has `/api/v2/token/app` — it is newer than
    /// the device grant — and the chooser offered "In your browser"
    /// unconditionally, so on a server without it the reader tapped, watched a
    /// browser open on a 404, and came back to the chooser with nothing said.
    /// The same change that introduced this route deleted the two probes that
    /// could have answered the question.
    ///
    /// Unauthenticated, on a session of the caller's choosing so this is
    /// testable: a server that has the route redirects to
    /// `/login?callbackUrl=…` and resolves 200, and one that does not answers
    /// 404. There is no token to send and none is sent — a browser session
    /// belongs to the browser, not to `URLSession`, so this can only ever be
    /// the unauthenticated leg and can never mint anything.
    ///
    /// **Fails open**, and deliberately: only a definite 404 or 405 answers
    /// "no". A timeout, a refused connection, a captive portal — anything that
    /// is not the server saying the route is absent — answers "yes". A wrong
    /// "unavailable" hides the fastest way in from someone who has it; a wrong
    /// "available" costs one tap and lands on an error that now says what
    /// happened.
    public static func isOffered(by server: URL, using session: URLSession) async -> Bool {
        var request = URLRequest(url: startURL(server: server))
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return true }
        return http.statusCode != 404 && http.statusCode != 405
    }

    /// `isOffered(by:using:)` on a session of its own, invalidated afterwards.
    ///
    /// The first version handed the view `probingSession()` and nothing ever
    /// invalidated it, so every probe leaked a `URLSession` — `AppModel.probe`,
    /// the function it was copied from, has `defer { invalidateAndCancel() }`
    /// for exactly this. The two-argument form stays for the tests.
    public static func isOffered(by server: URL) async -> Bool {
        let session = probingSession()
        defer { session.invalidateAndCancel() }
        return await isOffered(by: server, using: session)
    }

    /// Ephemeral, so nothing it touches joins the shared cookie jar or cache,
    /// and short-timeout, because this runs while someone is looking at the
    /// screen.
    private static func probingSession(timeout: TimeInterval = 6) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
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
