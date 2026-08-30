import Foundation
import IssaCore
import Observation
import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Top-level app state: which server we are talking to, whether we are signed
/// in, and the catalogue once we are.
@Observable
@MainActor
public final class AppModel {
    public enum Phase: Equatable {
        case chooseServer
        case signingIn
        case ready
        /// The token expired mid-use. The server is remembered, so signing in
        /// again is one tap rather than retyping an address.
        case expired
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
    /// The on-device catalogue. Present as soon as a server is chosen, so the
    /// shelf is populated before any request is made.
    public private(set) var store: LibraryStore?
    private var mutations: MutationQueue?
    public let reachability = Reachability()
    /// Streams books to disk in the background. Created with the session, since
    /// it needs the server URL and the bearer token.
    public private(set) var downloads: DownloadManager?
    /// Queued writes still waiting for a connection, for the sync row.
    public private(set) var pendingWrites = 0

    public init(keychain: any TokenPersisting = KeychainStorage()) {
        self.keychain = keychain
        serverAddress = UserDefaults.standard.string(forKey: Self.lastServerKey) ?? ""
        reachability.onBecameOnline = { [weak self] in
            Task { await self?.drainPendingWrites() }
        }
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
        let hadScheme = text.contains("://")
        if !hadScheme { text = "http://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty
        else { return nil }
        // Storyteller's default port, but only when the address was bare. Given
        // a full URL, guessing a port would break every install behind a proxy
        // on 80 or 443.
        if components.port == nil, !hadScheme { components.port = 8001 }
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

        // Open the local store first and show what is already known. A reader
        // opening the app on a train should see their shelf, not a spinner that
        // resolves to an error.
        downloads = DownloadManager(baseURL: url, tokens: session.tokenProvider) { job in
            BookContentService.defaultDirectory()
                .appending(path: "\(job.bookUUID)-\(job.format.rawValue).epub")
        }
        await downloads?.reattach()

        store = try? LibraryStore(serverKey: url.absoluteString)
        if let store {
            mutations = try? await MutationQueue(store: store)
            if let cached = try? await store.allBooks(), !cached.isEmpty {
                books = cached
                phase = .ready
            }
        }

        if phase != .ready { phase = .signingIn }
        await session.restore()
        if case .signedIn = session.state { await enterLibrary() }
        else if phase == .ready {
            // Cached shelf, no working token: usable offline, honest about it.
            loadError = books.isEmpty ? nil : nil
        }
    }

    public func adopt(token: String) async {
        guard let session else { return }
        await session.adopt(token: token)
        if case .signedIn = session.state { await enterLibrary() }
    }

    /// Signs out and leaves nothing behind.
    ///
    /// - Parameter keepDownloads: books already on the device are expensive to
    ///   fetch again, so the choice is offered rather than assumed.
    public func signOut(keepDownloads: Bool = false) async {
        await session?.signOut()
        books = []
        statuses = []
        ratings = [:]
        loadError = nil

        CoverCache.shared.clear()
        // The widget keeps showing the last book on a signed-out device unless
        // its snapshot is cleared and its timeline reloaded.
        CurrentBookSnapshotStore.clear()
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif

        if !keepDownloads {
            let manager = FileManager.default
            let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            for folder in ["Books", "Audio"] {
                try? manager.removeItem(at: support.appending(path: folder, directoryHint: .isDirectory))
            }
        }
        phase = .chooseServer
    }

    private func enterLibrary() async {
        phase = .ready
        await refreshLibrary()
    }

    /// Watches for the token going stale while the app is in use.
    ///
    /// The device grant's token lasts 30 days and there is nothing to refresh
    /// it with, so this happens to every install eventually. Without it the
    /// library simply stops loading and nothing explains why.
    public func watchForExpiry() async {
        guard let session else { return }
        while !Task.isCancelled {
            if session.state == .expired, phase == .ready {
                phase = .expired
                loadError = nil
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    public func refreshLibrary() async {
        guard let session else { return }
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        do {
            let service = LibraryService(client: session.client)
            let fetched = try await service.allBooks()
            books = fetched
            statuses = (try? await service.statuses()) ?? statuses
            ratings = (try? await service.myRatings()) ?? ratings
            loadError = nil
            try? await store?.replaceCatalogue(fetched)
        } catch {
            // A failed refresh is not an empty library when something is cached.
            if books.isEmpty, let cached = try? await store?.allBooks(), !cached.isEmpty {
                books = cached
            }
            loadError = books.isEmpty ? Self.message(for: error) : nil
        }
        await drainPendingWrites()
    }

    /// Sends anything written while there was no connection.
    public func drainPendingWrites() async {
        guard let session, let mutations else { return }
        _ = await MutationDrain(queue: mutations, client: session.client).drain()
        pendingWrites = (try? await mutations.count) ?? 0
    }

    /// Records a write locally, then attempts it.
    ///
    /// The queue is written first so that losing the connection mid-request
    /// still leaves the intent recorded.
    public func enqueue(_ kind: MutationQueue.Kind, bookUUID: String, payload: some Encodable) async {
        guard let mutations, let data = try? JSONEncoder().encode(payload) else { return }
        try? await mutations.enqueue(kind, bookUUID: bookUUID, payload: data)
        pendingWrites = (try? await mutations.count) ?? 0
        await drainPendingWrites()
    }

    /// Pending transfers, in a form the Downloads screen can list.
    public var downloadsPending: [(job: DownloadManager.Job, state: DownloadManager.State)] {
        downloads?.pending ?? []
    }

    public var wifiOnlyDownloads: Bool {
        get { downloads?.wifiOnly ?? false }
        set { downloads?.wifiOnly = newValue }
    }

    /// Restarts a paused or failed transfer, looking the book back up so the
    /// free-space check still has an expected size to work with.
    public func resumeDownload(_ job: DownloadManager.Job) async {
        guard let book = books.first(where: { $0.uuid == job.bookUUID }) else {
            await downloads?.start(job)
            return
        }
        await download(book, format: job.format)
    }

    /// Starts a download, refusing early if it plainly will not fit.
    public func download(_ book: Book, format: BookContentService.Format) async {
        guard let downloads else { return }
        let expected: Int64? = switch format {
        case .readaloud: book.readaloud?.fileSize.map(Int64.init)
        case .audiobook: book.audiobook?.fileSize.map(Int64.init)
        case .ebook: book.ebook?.fileSize.map(Int64.init)
        }
        // Holding back a multi-gigabyte readaloud on cellular is the whole point
        // of the preference; a small ebook is not worth blocking.
        if downloads.wifiOnly, reachability.isExpensive, (expected ?? 0) > 20_000_000 {
            loadError = "Waiting for Wi-Fi to download this."
            return
        }
        await downloads.start(.init(bookUUID: book.uuid, format: format), expectedBytes: expected)
    }

    /// Search, using the store's full-text index when there is one.
    public func search(_ query: String) async -> [Book] {
        guard let store, let hits = try? await store.search(query) else {
            return LibraryDerivation(books: books).search(query)
        }
        return hits
    }

    // MARK: - Per-user state

    /// Moves a book to a shelf.
    ///
    /// The local copy is updated first so the shelf changes under the finger,
    /// and rolled back if the server refuses — a status that silently reverts on
    /// the next refresh is worse than one that never appeared to change.
    public func setStatus(_ status: Status, for book: Book) async {
        guard let session, let index = books.firstIndex(where: { $0.uuid == book.uuid }) else { return }
        books[index].status = status
        try? await store?.upsert(books[index])
        // Queued, not sent directly: a shelf change made offline must survive,
        // and rolling it back under the reader's finger was the old behaviour.
        await enqueue(.status, bookUUID: book.uuid,
                      payload: MutationDrain.StatusPayload(status: status.uuid))
        _ = session
    }

    public func setRating(_ value: Double?, for book: Book) async {
        guard let session else { return }
        if let value { ratings[book.uuid] = value } else { ratings.removeValue(forKey: book.uuid) }
        await enqueue(.rating, bookUUID: book.uuid,
                      payload: MutationDrain.RatingPayload(rating: value))
        _ = session
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
