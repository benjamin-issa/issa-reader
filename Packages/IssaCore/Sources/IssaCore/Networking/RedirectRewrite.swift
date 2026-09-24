import Foundation
import Synchronization

/// How a redirected asset request is followed.
///
/// Storyteller 3.x answers `GET /api/v2/books/{uuid}/cover` with a 307 whose
/// `Location` is root-relative — `/api/v2/images/{sha256}?s=…` — and the image
/// route demands the same bearer the cover route accepted. URLSession follows
/// the redirect but drops `Authorization` while doing it, even to the same
/// origin: reproduced against a plain HTTP server, where `Origin` survived the
/// hop and the bearer did not. The image route then 401s, and in 1.2.0 that
/// 401 signed the reader out. Re-attaching the bearer is half the answer; the
/// other half is that a 401 at the end of a redirect is no verdict on the
/// token — the request it answered was URLSession's, not this client's — so
/// `RedirectFollower` counts the hops and `APIClient.getData` does not
/// invalidate on a 401 from a redirected task.
///
/// Pure, so each rule can be proved without a network; `RedirectFollower` is
/// the delegate that applies it to a task.
enum RedirectRewrite {
    /// The headers this client sets on every request and wants on the next hop.
    /// `Origin` and `Accept` survive a redirect today; they are copied anyway,
    /// so the rule does not depend on which ones URLSession happens to keep.
    private static let carried = ["Authorization", "Origin", "Accept"]

    /// The request to follow a redirect with.
    ///
    /// Three rules, in order:
    ///
    /// 1. A root-relative `Location` on a server mounted under a sub-path is
    ///    re-rooted under that path. See `mounted(_:location:baseURL:)`.
    /// 2. A target on the reader's own server — same scheme, host (in any
    ///    case) and effective port as `baseURL` — gets `Authorization`,
    ///    `Origin` and `Accept` back from the original request.
    /// 3. Anything else is followed as URLSession proposed it, minus any
    ///    `Authorization`: the bearer is a credential for this server alone,
    ///    and a redirect is not the server vouching for somewhere else.
    ///
    /// - Parameters:
    ///   - proposed: what URLSession would send next.
    ///   - response: the 3xx, for its raw `Location`, which URLSession has
    ///     already resolved away by the time `proposed` exists.
    ///   - original: the request as this client built it, bearer included.
    ///   - baseURL: the server address the reader entered, mount path included.
    /// - Returns: always a request. Refusing to follow would hand the caller a
    ///   bodiless 307 in place of a cover, which helps nobody.
    static func request(
        following proposed: URLRequest,
        response: HTTPURLResponse,
        original: URLRequest,
        baseURL: URL,
    ) -> URLRequest {
        var next = proposed
        let location = response.value(forHTTPHeaderField: "Location")
        if let mounted = mounted(proposed.url, location: location, baseURL: baseURL) {
            next.url = mounted
        }
        guard let target = next.url, sameOrigin(target, baseURL) else {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
            return next
        }
        for field in carried {
            next.setValue(original.value(forHTTPHeaderField: field), forHTTPHeaderField: field)
        }
        return next
    }

    /// A root-relative `Location` re-rooted under the server's mount path.
    ///
    /// The server does not know a reverse proxy has put it at `/storyteller`,
    /// so it writes `/api/v2/images/…`, and URLSession resolves that against
    /// the origin — outside the mount, onto whatever else the proxy serves
    /// there, which is a 404 at best.
    ///
    /// - Returns: nil when there is nothing to fix: no mount, a `Location` that
    ///   is absolute, protocol-relative or relative to the current path, a
    ///   target on another origin, or one already under the mount — a server
    ///   that does know its prefix must not have it doubled.
    static func mounted(_ proposed: URL?, location: String?, baseURL: URL) -> URL? {
        guard let proposed, let location,
              location.hasPrefix("/"), !location.hasPrefix("//")
        else { return nil }
        let mount = mountPath(of: baseURL)
        guard !mount.isEmpty, sameOrigin(proposed, baseURL) else { return nil }

        let path = proposed.path(percentEncoded: true)
        guard path != mount, !path.hasPrefix(mount + "/") else { return nil }

        guard var rebuilt = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let relative = URLComponents(string: location)
        else { return nil }
        rebuilt.percentEncodedPath = mount + relative.percentEncodedPath
        rebuilt.percentEncodedQuery = relative.percentEncodedQuery
        rebuilt.fragment = nil
        return rebuilt.url
    }

    /// The base URL's path without trailing slashes: "" for a server at the
    /// root of its host, "/storyteller" for one mounted beneath it.
    private static func mountPath(of baseURL: URL) -> String {
        var path = baseURL.path(percentEncoded: true)
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The browser's definition, because it is the one that says where a
    /// credential may go: scheme, host and port, with the host compared
    /// case-insensitively and an omitted port read as the scheme's default —
    /// `http://Storyteller.test` and `http://storyteller.test:80` are one server.
    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let leftScheme = lhs.scheme?.lowercased(),
              let rightScheme = rhs.scheme?.lowercased(),
              leftScheme == rightScheme,
              let leftHost = lhs.host(percentEncoded: false)?.lowercased(),
              let rightHost = rhs.host(percentEncoded: false)?.lowercased(),
              leftHost == rightHost
        else { return false }
        return effectivePort(lhs, scheme: leftScheme) == effectivePort(rhs, scheme: rightScheme)
    }

    private static func effectivePort(_ url: URL, scheme: String) -> Int? {
        if let port = url.port { return port }
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

/// Applies `RedirectRewrite` to one task, and remembers whether it had to.
///
/// Handed to `URLSession.data(for:delegate:)` per task rather than set on the
/// session: the session is shared with every JSON route and is usually
/// `URLSession.shared`, which has no delegate to give, and only an asset fetch
/// is redirected on purpose. One is made per request, so the count below is
/// that request's alone.
final class RedirectFollower: NSObject, URLSessionTaskDelegate, Sendable {
    let baseURL: URL
    /// Behind a `Mutex`, not a plain `var`: URLSession calls the delegate on a
    /// queue of its own choosing, and `APIClient` reads the count from its
    /// actor once the task has finished.
    private let hops = Mutex(0)

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Whether the task was redirected at all — so whether the response it
    /// ended on answered a request URLSession built rather than the one this
    /// client did. `APIClient.failure(for:)` says why that decides what a 401
    /// means.
    var wasRedirected: Bool {
        hops.withLock { $0 > 0 }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void,
    ) {
        // Counted first: every call here is a hop, whether or not there is an
        // original request to rewrite it from.
        hops.withLock { $0 += 1 }
        // The task's own first request is the one this client built, bearer
        // and all; every later hop is URLSession's.
        guard let original = task.originalRequest else {
            completionHandler(request)
            return
        }
        completionHandler(RedirectRewrite.request(
            following: request, response: response, original: original, baseURL: baseURL))
    }
}
