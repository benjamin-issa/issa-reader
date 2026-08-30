import Foundation
import IssaCore
import Observation
import SwiftUI

/// Top-level app state: which server we are talking to, whether we are signed
/// in, and the catalogue once we are.
@Observable
@MainActor
public final class AppModel {
    public enum Phase: Equatable {
        case chooseServer
        case signingIn
        case ready
    }

    public var phase: Phase = .chooseServer
    public var serverAddress: String = ""
    public var session: Session?
    public var books: [Book] = []
    public var loadError: String?
    public var isLoadingLibrary = false

    /// Derived rails and facets, all computed from the single catalogue fetch.
    public var derivation: LibraryDerivation { LibraryDerivation(books: books) }

    private let keychain: any TokenPersisting

    public init(keychain: any TokenPersisting = KeychainStorage()) {
        self.keychain = keychain
        serverAddress = UserDefaults.standard.string(forKey: Self.lastServerKey) ?? ""
    }

    private static let lastServerKey = "issa.lastServer"

    /// Accepts what a person would actually type — "storyteller.home.arpa",
    /// "192.168.1.10:8001", or a full URL — and produces a usable base URL.
    public static func normalizeServerURL(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty
        else { return nil }
        // Storyteller's default port, applied when the user gave a bare host.
        if components.port == nil, components.scheme == "http" { components.port = 8001 }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Reconnects to the last server on launch when a token is already stored,
    /// so a returning reader lands in their library rather than on a form.
    public func restoreIfPossible() async {
        guard !serverAddress.isEmpty, phase == .chooseServer else { return }
        await connect(to: serverAddress)
    }

    public func connect(to address: String) async {
        guard let url = Self.normalizeServerURL(address) else {
            loadError = "That doesn't look like a server address."
            return
        }
        UserDefaults.standard.set(address, forKey: Self.lastServerKey)
        let session = Session(serverURL: url, keychain: keychain)
        self.session = session
        phase = .signingIn
        await session.restore()
        if case .signedIn = session.state { await enterLibrary() }
    }

    public func adopt(token: String) async {
        guard let session else { return }
        await session.adopt(token: token)
        if case .signedIn = session.state { await enterLibrary() }
    }

    public func signOut() async {
        await session?.signOut()
        books = []
        phase = .chooseServer
    }

    private func enterLibrary() async {
        phase = .ready
        await refreshLibrary()
    }

    public func refreshLibrary() async {
        guard let session else { return }
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        do {
            books = try await LibraryService(client: session.client).allBooks()
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }
}
