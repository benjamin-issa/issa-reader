import Foundation

/// Fetches an audiobook's manifest and prepares authenticated playback.
public struct AudiobookService: Sendable {
    private let client: APIClient
    private let baseURL: URL
    private let tokens: any TokenProviding

    public init(client: APIClient, baseURL: URL, tokens: any TokenProviding) {
        self.client = client
        self.baseURL = baseURL
        self.tokens = tokens
    }

    public func manifest(for bookUUID: String) async throws -> AudiobookManifest {
        try await client.get(Endpoint.listen(bookUUID))
    }

    /// Where the manifest's relative track hrefs resolve against.
    public func trackBase(for bookUUID: String) -> URL {
        baseURL.appending(path: "/api/v2/books/\(bookUUID)/listen/")
    }

    /// Credentials for `AVURLAsset`.
    ///
    /// AVFoundation makes its own requests, so a bearer header never reaches
    /// them. Storyteller's auth layer accepts the same session token as an
    /// `st_token` cookie, and `AVURLAssetHTTPCookiesKey` is public API — unlike
    /// the header-fields key, which is private and an App Review risk.
    public func playbackCookies(for bookUUID: String) async -> [HTTPCookie] {
        guard let token = await tokens.currentToken(),
              let host = baseURL.host()
        else { return [] }
        let cookie = HTTPCookie(properties: [
            .name: "st_token",
            .value: token,
            .domain: host,
            .path: "/",
            // Session-scoped: the token is already stored in the keychain, and
            // writing a second durable copy into the cookie jar would outlive a
            // sign-out.
            .discard: true,
        ])
        return [cookie].compactMap(\.self)
    }
}
