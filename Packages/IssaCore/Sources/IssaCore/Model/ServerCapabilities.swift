import Foundation

/// Which line of Storyteller is answering.
///
/// Established by feature, never by the version string. A 3.x image built from
/// source has no release tag to read, falls back to its `package.json`, and
/// reports "2.14.21" — so the one thing the string cannot be trusted to say is
/// which generation it came from.
public enum ServerGeneration: String, Codable, Hashable, Sendable {
    case v2
    case v3
}

/// Which optional server features are present, and which line of Storyteller
/// is serving them.
///
/// This client's baseline is 2.14.21, and it runs at parity with the 3.0.0 beta
/// line. Storyteller 3.x adds around fifty endpoints that 2.x lacks —
/// server-side home sections, shelves, a sidebar, library facets and counts —
/// and the client derives all of those locally from the one catalogue fetch, so
/// their absence costs nothing. The flags below record which of them a server
/// has, for Settings to show.
///
/// An upgrade is not free of client changes, though. 3.x serves covers from a
/// new content-addressed route behind a redirect, and no longer advances a book
/// that has no status when a position is written. The places that differ ask
/// `generation`, which is detected by feature — `GET /api/v2/server/public`
/// answers on 3.x and 404s on 2.x — rather than read from a version string.
///
/// Probed once per sign-in and held on the session; a probe is a cheap
/// unauthenticated or authenticated GET that either 200s or 404s. Not
/// persisted: nothing that runs before the probe needs the answer, and the
/// cover route is chosen from the book's own data first.
public struct ServerCapabilities: Codable, Hashable, Sendable {
    /// `GET /api/v2/server/public` — unauthenticated server identity and branding.
    /// True exactly when `generation` is `.v3`.
    public var serverDiscovery: Bool = false
    /// `GET /api/v2/home/sections` and `/home/stats`.
    public var homeSections: Bool = false
    /// `GET /api/v2/shelves`.
    public var shelves: Bool = false
    /// `GET /api/v2/sidebar`.
    public var sidebar: Bool = false
    /// `GET /api/v2/library/facets` and `/library/counts`.
    public var libraryFacets: Bool = false
    /// `GET /api/v2/books/next-up`.
    public var nextUp: Bool = false
    /// `GET /api/v2/events` — the 3.x consolidated event stream.
    public var unifiedEvents: Bool = false

    /// nil until `/server/public` has answered with either a Storyteller 3.x
    /// identity or a 404. A transport failure, a 5xx, or a 200 that is somebody
    /// else's page — a proxy's login screen — decides nothing, and saying "2.x"
    /// on the strength of one would be a guess presented as a finding.
    public var generation: ServerGeneration?
    /// `version` from `GET /api/v2/server/details`, e.g. "3.0.0-beta.40".
    /// Display only: see `ServerGeneration` for why nothing keys on it. 2.x has
    /// no route that exposes its running version, so it is always nil there.
    public var reportedVersion: String?

    public init() {}

    /// Everything this client can derive on its own, so a 2.x server loses no
    /// user-visible capability — only the chance to offload the work.
    public static let baseline = ServerCapabilities()

    /// The server version, as the Settings row states it.
    ///
    /// A 3.x server's own string is shown verbatim when it agrees with the
    /// detected generation. When it does not — a self-built image reporting its
    /// `package.json` fallback — both facts are shown, because either one alone
    /// would mislead whoever is reading the row to diagnose something.
    public var displayVersion: String {
        switch generation {
        case nil:
            return "Not detected"
        case .v2:
            return "2.x (not reported)"
        case .v3:
            guard let reportedVersion else { return "3.x" }
            let major = reportedVersion.split(separator: ".", maxSplits: 1).first
            return major == "3" ? reportedVersion : "3.x (reports \(reportedVersion))"
        }
    }
}
