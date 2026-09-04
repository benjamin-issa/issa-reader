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
    public static func addressToStore(for input: String, connectedTo url: URL) -> String {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCleartextFallback(url, forTyped: typed) else { return url.absoluteString }
        IssaLog.warning(
            "connected over cleartext HTTP after HTTPS failed",
            ["server": url.absoluteString],
        )
        return typed
    }
}
