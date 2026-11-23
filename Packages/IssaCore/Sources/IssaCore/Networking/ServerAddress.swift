import Foundation

/// Turning what someone typed into a server URL.
///
/// Lives here rather than on the app model so it can be tested: it is the very
/// first thing every reader does, and getting it wrong looks like the server is
/// down rather than like the address was misread.
public enum ServerAddress {
    /// Storyteller's own default when nothing else is known.
    static let defaultPort = 8001

    /// The single URL an address means, cleaned up.
    public static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let hadScheme = text.contains("://")
        if !hadScheme { text = "http://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty
        else { return nil }
        // Storyteller's default port, but only when the address was bare. Given
        // a full URL, guessing a port would break every install behind a proxy
        // on 80 or 443.
        if components.port == nil, !hadScheme { components.port = defaultPort }
        // Keep the path: a reverse proxy commonly mounts Storyteller under a
        // subdirectory, and dropping it made every such server unreachable.
        // Trailing slashes and a pasted API path are noise, though.
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/api/v2", "/api"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        // Userinfo goes the same way as the query and the fragment, and for a
        // sharper reason. A reader behind HTTP basic auth types
        // `https://ben:hunter2@library.home.arpa`, and the whole string used to
        // survive into three places that store or show it in the clear: the
        // `issa.lastServer` preference, which is in the backed-up preferences
        // plist; the keychain *account* attribute, which is unencrypted
        // metadata rather than protected item data; and the Settings screen,
        // rendered verbatim over the reader's shoulder. `IssaLog.Redaction`
        // has a dedicated rule for this exact shape, so the log — the one sink
        // nobody reads — was the only one protected.
        components.user = nil
        components.password = nil
        return components.url
    }

    /// Every address worth trying, in the order to try them.
    ///
    /// A bare hostname is genuinely ambiguous. Storyteller's default is port
    /// 8001 over plain HTTP, which is right for `storyteller.home.arpa` on a
    /// LAN — but a server behind a reverse proxy answers on 443, and guessing
    /// 8001 there connects to a port with nothing on it. That does not fail
    /// fast; it hangs until the timeout while the app says only "Contacting
    /// your server…".
    ///
    /// An address that carries a scheme is taken at its word: someone who typed
    /// one has said what they meant, and second-guessing it would break a
    /// deliberate `http://` on a LAN.
    public static func candidates(for input: String) -> [URL] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if text.contains("://") {
            return [normalize(text)].compactMap { $0 }
        }
        // HTTPS first: a bare host that is reachable at all is more likely to
        // be proxied than to be exposing Storyteller's raw port.
        var seen = Set<URL>()
        return [normalize("https://" + text), normalize(text)]
            .compactMap { $0 }
            .filter { seen.insert($0).inserted }
    }

    /// Whether settling on `url` means speaking cleartext for an address that
    /// never asked for it: no scheme was typed, HTTPS was the first candidate,
    /// and plain HTTP is what answered.
    ///
    /// An explicit `http://` is not a downgrade — someone who typed one has
    /// said what they meant, and a LAN install depends on being believed.
    public static func isCleartextFallback(_ url: URL, forTyped input: String) -> Bool {
        guard !input.contains("://") else { return false }
        return url.scheme?.lowercased() == "http"
    }

    /// The address to remember once `url` has answered for `input`.
    ///
    /// Normally the resolved URL, so every later call is taken at its word.
    /// For a bare address that fell back to plain HTTP it is what was typed
    /// instead: persisting the `http://` URL would make the downgrade
    /// permanent — every later connect would honour the stored scheme and
    /// never try HTTPS again — while the typed text probes HTTPS first on the
    /// next connect. Keeping raw text is safe precisely here, because for a
    /// bare host `normalize(typed)` *is* the fallback URL, so nothing
    /// downstream re-derives a different one. The downgrade is logged, so an
    /// unencrypted connection at least shows up in a diagnostics export.
    ///
    /// Raw text is not raw all the way: `normalize` drops userinfo, a query and
    /// a fragment, and so does this. A reader who typed `ben:hunter2@host` must
    /// not have the password land in `issa.lastServer` and on the sign-in
    /// screen because the host happened to need the fallback.
    public static func addressToStore(for input: String, connectedTo url: URL) -> String {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCleartextFallback(url, forTyped: typed) else { return url.absoluteString }
        IssaLog.warning(
            "connected over cleartext HTTP after HTTPS failed",
            ["server": url.absoluteString],
        )
        return withoutUserinfo(typed)
    }

    /// `url` with its scheme taken off: what a reader would have typed for it
    /// bare, so that `candidates` and `normalize` read it the way they read a
    /// bare address.
    public static func bare(_ url: URL) -> String {
        let text = url.absoluteString
        guard let scheme = url.scheme, text.lowercased().hasPrefix(scheme.lowercased() + "://")
        else { return text }
        return String(text.dropFirst(scheme.count + 3))
    }

    /// The plain-HTTP address a bare form of this `https` URL also means: the
    /// one a sign-in was filed under when the same host, typed bare, answered
    /// only over HTTP. Storyteller's port is added only when the URL names no
    /// port of its own, as `candidates` does. Nil for anything but `https`.
    public static func cleartextCounterpart(of url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        return candidates(for: bare(url)).first { $0.scheme?.lowercased() == "http" }
    }

    /// `typed` as it was, less what `normalize` strips from an address: the
    /// scheme-less text, so the next connect still leads with HTTPS.
    private static func withoutUserinfo(_ typed: String) -> String {
        guard typed.contains(where: { "@?#".contains($0) }) else { return typed }
        let scheme = "http://"
        guard var components = URLComponents(string: scheme + typed) else { return "" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        guard let text = components.string, text.hasPrefix(scheme) else { return "" }
        return String(text.dropFirst(scheme.count))
    }
}

/// What one unauthenticated probe of `server/public` heard.
///
/// Three ways, not two. The connect path only ever needed "is a Storyteller
/// there", and folded a 5xx in with silence. The cleartext rescue needs the
/// difference: an `https` address that answers anything at all, a 503
/// included, exists, and is never given up for plain HTTP.
public enum ServerProbe: Equatable, Sendable {
    /// Something spoke HTTP back, with this status.
    case answered(status: Int)
    /// Nothing did: refused, timed out, or a TLS failure.
    case noResponse

    /// What the connect path has always counted as a server being there: any
    /// answer from 200 to 499, since an unauthenticated probe may
    /// legitimately be refused.
    public var isReachable: Bool {
        guard case let .answered(status) = self else { return false }
        return (200 ... 499).contains(status)
    }

    /// One unauthenticated `server/public` probe, and what it heard.
    ///
    /// No token and no cookie go with it: an ephemeral session of its own,
    /// with no cookie store and no credential store.
    ///
    /// - Parameter followsRedirects: whether a 3xx is followed. The connect
    ///   path follows, as it always has. The cleartext rescue does not: a
    ///   redirect is an answer, so HTTPS is there, and followed to somewhere
    ///   unreachable it used to come back as silence.
    public static func probe(
        _ url: URL, timeout: TimeInterval, followsRedirects: Bool = true,
    ) async -> ServerProbe {
        var request = URLRequest(url: url.appending(path: "api/v2/server/public"))
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(
            configuration: configuration, delegate: followsRedirects ? nil : RedirectRefusal(),
            delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .noResponse }
        return .answered(status: http.statusCode)
    }
}

/// Hands a redirect back as the answer instead of following it.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
    ) async -> URLRequest? {
        nil
    }
}

/// A sign-in that can be reached again over plain HTTP, offered and never
/// taken without the reader's say.
///
/// The device it exists for: an earlier build, launched once with the server
/// off, stored `https://host` over a bare host whose server is plain HTTP on
/// :8001. The sign-in is filed under the HTTP address, every connect goes to
/// the dead HTTPS one, and nothing heals it, because a single stored address
/// is taken at its word.
public struct CleartextRescue: Equatable, Sendable {
    /// The stored `https` address that gave no answer.
    public let tried: URL
    /// The plain-HTTP address the saved sign-in is filed under.
    public let offered: URL
    /// The stored address with its scheme taken off. What is stored once the
    /// offer has been taken and signed in, so the next launch still tries
    /// HTTPS first.
    public let bare: String

    public init(tried: URL, offered: URL, bare: String) {
        self.tried = tried
        self.offered = offered
        self.bare = bare
    }

    /// What the sign-in form says. Both addresses, and what the second one
    /// costs, before anything is sent to it.
    ///
    /// - Parameter device: the platform's own word for itself ("iPhone",
    ///   "Mac", "Apple TV").
    public func message(device: String) -> String {
        "Couldn't reach \(tried.absoluteString). This \(device) has a saved sign-in for \(offered.absoluteString), which is not encrypted."
    }

    /// The button that takes the offer. It says "not encrypted" because
    /// pressing it is the only way anything carrying a credential reaches a
    /// plain-HTTP address for want of HTTPS.
    public var buttonTitle: String {
        "Use \(offered.absoluteString) (not encrypted)"
    }

    /// The server at the HTTP address answered, and refused the saved sign-in.
    /// The address is stored by then, so the form already shows it, with its
    /// "Not encrypted" line, ready to sign in afresh.
    public static func refusedMessage(for offered: URL) -> String {
        "Your saved sign-in for \(offered.absoluteString) is no longer accepted. Sign in again."
    }

    /// Whether every condition for offering the HTTP address holds.
    ///
    /// Checked in this order so that a healthy device pays nothing: the first
    /// five are a string comparison, a record lookup and two keychain reads,
    /// and only a device that is already locked out reaches either probe.
    ///
    /// 1. `address` is the stored address, not one just typed.
    /// 2. It means exactly one URL, and that URL is `https`.
    /// 3. No sign-in is saved under it.
    /// 4. This device has never been signed in at it. A locked-out device
    ///    never has; a reader who moved to HTTPS on an earlier build has, and
    ///    the HTTP token that build left behind must not be offered to them
    ///    when their HTTPS session lapses on a network where HTTPS fails.
    /// 5. A sign-in is saved under the same host's plain-HTTP address.
    /// 6. The `https` address gets no HTTP response at all. Any status, a 5xx
    ///    or a redirect included, means HTTPS is there, and it is never given
    ///    up.
    /// 7. The HTTP address answers. The probe carries no token and no cookie.
    ///
    /// - Parameter signedInBefore: whether this device has ever been signed in
    ///   at an address.
    /// - Parameter probe: an unauthenticated probe of one address, which does
    ///   not follow redirects.
    public static func offer(
        connecting address: String,
        stored: String,
        keychain: any TokenPersisting,
        signedInBefore: @Sendable (URL) -> Bool,
        probe: @Sendable (URL) async -> ServerProbe,
    ) async -> CleartextRescue? {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed == stored.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let candidates = ServerAddress.candidates(for: typed)
        guard candidates.count == 1, let tried = candidates.first,
              tried.scheme?.lowercased() == "https"
        else { return nil }
        guard keychain.read(account: tried.absoluteString) == nil else { return nil }
        guard !signedInBefore(tried) else { return nil }
        guard let offered = ServerAddress.cleartextCounterpart(of: tried),
              keychain.read(account: offered.absoluteString) != nil
        else { return nil }
        guard await probe(tried) == .noResponse else { return nil }
        guard await probe(offered).isReachable else { return nil }
        return CleartextRescue(tried: tried, offered: offered, bare: ServerAddress.bare(tried))
    }
}
