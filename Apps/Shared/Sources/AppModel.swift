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
    /// The shelves this server defines. Fetched once per sign-in; an admin can
    /// add their own beyond the default To read / Reading / Read.
    public var statuses: [Status] = []
    /// This user's own ratings, keyed by book, kept alongside the catalogue so
    /// the library and detail screens agree without extra requests.
    public var ratings: [String: Double] = [:]
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

    /// A sentence a person can act on, with the recovery hint appended.
    static func message(for error: any Error) -> String {
        guard let described = (error as? LocalizedError)?.errorDescription else {
            return "Something went wrong."
        }
        let hint = (error as? LocalizedError)?.recoverySuggestion
        return [described, hint].compactMap { $0 }.joined(separator: " ")
    }

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
            let service = LibraryService(client: session.client)
            books = try await service.allBooks()
            statuses = (try? await service.statuses()) ?? statuses
            ratings = (try? await service.myRatings()) ?? ratings
            loadError = nil
        } catch {
            loadError = Self.message(for: error)
        }
    }

    // MARK: - Per-user state

    /// Moves a book to a shelf.
    ///
    /// The local copy is updated first so the shelf changes under the finger,
    /// and rolled back if the server refuses — a status that silently reverts on
    /// the next refresh is worse than one that never appeared to change.
    public func setStatus(_ status: Status, for book: Book) async {
        guard let session, let index = books.firstIndex(where: { $0.uuid == book.uuid }) else { return }
        let previous = books[index].status
        books[index].status = status
        do {
            try await LibraryMutationService(client: session.client)
                .setStatus(status.uuid, for: book.uuid)
        } catch {
            books[index].status = previous
            loadError = "Couldn't change the status. " + Self.message(for: error)
        }
    }

    public func setRating(_ value: Double?, for book: Book) async {
        guard let session else { return }
        let previous = ratings[book.uuid]
        if let value { ratings[book.uuid] = value } else { ratings.removeValue(forKey: book.uuid) }
        do {
            try await LibraryMutationService(client: session.client)
                .setRating(value, for: book.uuid)
        } catch {
            if let previous { ratings[book.uuid] = previous } else { ratings.removeValue(forKey: book.uuid) }
            loadError = "Couldn't save the rating. " + Self.message(for: error)
        }
    }

    /// Re-reads one book after something changed it server-side.
    ///
    /// Writing a reading position moves the status on the server, so after a
    /// reading session the local copy is stale in a way the user can see.
    public func refresh(book: Book) async {
        guard let session,
              let index = books.firstIndex(where: { $0.uuid == book.uuid }),
              let fresh = try? await LibraryService(client: session.client).book(book.uuid)
        else { return }
        books[index] = fresh
    }
}
