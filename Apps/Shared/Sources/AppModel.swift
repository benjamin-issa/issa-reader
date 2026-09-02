import Foundation
import IssaCore
import IssaPlayback
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
        /// Before anything has been decided. Distinct from `chooseServer`,
        /// which means "this reader has no server" — conflating the two forced
        /// the initial value to claim there was no server before anyone had
        /// looked, so the sign-in form was committed to the very first frame of
        /// every launch and flashed before the library replaced it.
        case launching
        case chooseServer
        case signingIn
        case ready
        /// The token expired mid-use. The server is remembered, so signing in
        /// again is one tap rather than retyping an address.
        case expired
    }

    public var phase: Phase = .launching
    public var serverAddress: String = ""
    public var session: Session?
    /// Rebuilt explicitly by whatever changes the catalogue, not from a
    /// `didSet`: a position write mutates one element, and the observer
    /// re-faceted and re-sorted the whole library on every debounced save —
    /// every two seconds while narrating. `recordPosition` recomputes only
    /// what a position can move.
    public var books: [Book] = []
    /// Books with at least one file on disk, from a single directory read.
    ///
    /// The download shelf and its count both need this for the whole library,
    /// and asking `isDownloaded` per book per format is a `stat` per format per
    /// book — thousands of syscalls in a scrolled frame.
    public private(set) var downloadedUUIDs: Set<String> = [] { didSet { rebuildDerived() } }
    /// The shelves this server defines. Fetched once per sign-in; an admin can
    /// add their own beyond the default To read / Reading / Read.
    public var statuses: [Status] = []
    /// This user's own ratings, keyed by book, kept alongside the catalogue so
    /// the library and detail screens agree without extra requests.
    public var ratings: [String: Double] = [:]
    public var loadError: String?
    public var isLoadingLibrary = false

    /// Derived rails, computed from the single catalogue fetch.
    ///
    /// Still a computed property for its remaining callers (CarPlay, the tvOS
    /// library); the library screen reads the memoised values below instead,
    /// because it used to allocate one of these twice per body.
    public var derivation: LibraryDerivation { LibraryDerivation(books: books) }

    /// Shelf and tag counts for the library header. Rebuilt when the catalogue
    /// or the downloaded set changes, never in a view body.
    public private(set) var facets: LibraryFacets = .empty
    /// The book the Continue card offers, if any.
    public private(set) var continueBook: Book?

    private let keychain: any TokenPersisting
    /// The on-device catalogue. Present as soon as a server is chosen, so the
    /// shelf is populated before any request is made.
    public private(set) var store: LibraryStore?
    private var mutations: MutationQueue?
    public let reachability = Reachability()
    private var listeningProgressTask: Task<Void, Never>?
    private var isConnecting = false
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
        // A property initialiser does not fire `didSet`, so without this the
        // first frame renders empty facets and an unarranged shelf.
        rebuildDerived()
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
    /// Which candidate actually has a Storyteller behind it.
    ///
    /// A short, unauthenticated probe rather than a full connect: building a
    /// session, a background download session and a store for an address that
    /// turns out to be wrong is expensive and leaves debris. `server/public` is
    /// the one endpoint that answers without a token.
    ///
    /// The timeout is the point. Connecting to a port with nothing listening
    /// does not fail fast — it hangs — and the sign-in screen has nothing to
    /// say while it does.
    static func firstReachable(of candidates: [URL], timeout: TimeInterval = 6) async -> URL? {
        guard candidates.count > 1 else { return candidates.first }
        for candidate in candidates {
            if await probe(candidate, timeout: timeout) { return candidate }
        }
        // Everything failed: fall back to what the reader typed, so the error
        // they get is the real one from a full attempt rather than ours.
        return candidates.first
    }

    private static func probe(_ url: URL, timeout: TimeInterval) async -> Bool {
        var request = URLRequest(url: url.appending(path: "api/v2/server/public"))
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        // Any answer at all means something is listening and speaking HTTP;
        // an unauthenticated probe may legitimately be refused.
        return (200...499).contains(http.statusCode)
    }

    /// Every address worth trying for what someone typed. See `ServerAddress`.
    static func candidateServerURLs(for input: String) -> [URL] {
        ServerAddress.candidates(for: input)
    }

    public static func normalizeServerURL(_ input: String) -> URL? {
        ServerAddress.normalize(input)
    }

    /// Reconnects to the last server on launch when a token is already stored,
    /// so a returning reader lands in their library rather than on a form.
    public func restoreIfPossible() async {
        guard !serverAddress.isEmpty, phase == .launching || phase == .chooseServer else {
            // Nothing stored: this really is a first run, so stop holding the
            // launch state and show the form.
            if phase == .launching { phase = .chooseServer }
            return
        }
        await connect(to: serverAddress)
    }

    public func connect(to address: String) async {
        // Re-entrancy guard. Two overlapping connects each built a Session and
        // a DownloadManager, and two background sessions cannot share one
        // identifier: the daemon hands the transfers to one and kills the
        // other's copies, which is what stalled downloads.
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        let candidates = Self.candidateServerURLs(for: address)
        guard !candidates.isEmpty else {
            loadError = "That doesn't look like a server address."
            return
        }
        guard let url = await Self.firstReachable(of: candidates) else {
            loadError = "Couldn't reach a Storyteller server at that address."
            return
        }
        // The RESOLVED address, not the raw text. Everything downstream —
        // the device flow, audiobook streaming, the expired notice — re-derives
        // a URL from `serverAddress`, and re-deriving from a bare hostname
        // undoes the probe above and lands back on the wrong port. Storing the
        // absolute URL means every later call is taken at its word.
        //
        // The one exception is a bare host that only answered over cleartext
        // HTTP after HTTPS failed: persisting `http://…` there would pin the
        // downgrade forever. `addressToStore` keeps the typed text in that one
        // case — where re-deriving lands on the same URL anyway — so the next
        // launch tries HTTPS first, and logs the fallback rather than baking
        // it in silently.
        let resolved = ServerAddress.addressToStore(for: address, connectedTo: url)
        UserDefaults.standard.set(resolved, forKey: Self.lastServerKey)
        // Also in memory. Only UserDefaults was written, so `serverAddress`
        // stayed empty for the whole first launch — which silently broke
        // audiobook playback (startListening guards on it) and left the expired
        // notice showing a blank server name.
        serverAddress = resolved
        let session = Session(serverURL: url, keychain: keychain)
        self.session = session

        // Open the local store first and show what is already known. A reader
        // opening the app on a train should see their shelf, not a spinner that
        // resolves to an error.
        store = try? LibraryStore(serverKey: url.absoluteString)
        // Whose annotations to show, before the identity call answers — which
        // offline it never does. Cached per server by `enterLibrary`.
        if let account = UserDefaults.standard.string(forKey: Self.accountKey(for: url)) {
            try? await store?.setAccount(account)
        }
        // A session again means the widget may be written again.
        CurrentBookPublisher.shared.resume()
        // The store was just reassigned, and the queue wraps the store's
        // database file — captured at construction, never re-read. Keeping the
        // old queue across a reconnect meant a corrected address wrote every
        // position into the previous server's file while the catalogue lived
        // in the new one — and rows left behind there could later drain into
        // the wrong account. Rebuilding over the same file is cheap.
        mutations = nil
        // The queue belongs with the store, not with the credential. It used to
        // sit inside the `hasCredential` branch below, which meant a first-time
        // sign-in — where `connect` runs *before* the device flow hands over a
        // token — spent its whole session with `mutations` nil, and `enqueue`
        // silently dropped every position, status and rating write. It looked
        // fine, because the in-memory book still moved; only the server knew.
        ensureMutationQueue()
        // Only for someone who is actually signed in. Showing the cached shelf
        // on the strength of the database alone meant signing out left the
        // entire library readable: the token went, the rows did not, and the
        // next launch walked straight past the sign-in screen into the grid.
        let hasCredential = await session.hasStoredCredential
        if let store, hasCredential {
            if let cached = try? await store.allBooks(), !cached.isEmpty {
                books = cached
                rebuildDerived()
                phase = .ready
            }
        }

        // After the shelf is on screen, not before it. Building a background
        // URLSession is an XPC handshake and `reattach()` is a second round trip
        // to a daemon that may need waking — both used to run ahead of the few
        // milliseconds of SQLite that could have shown the library immediately.
        //
        // The manager already alive is kept and re-pointed. Not every route
        // here follows a sign-out — the sign-in form's connect follows the
        // launch's, and an expired token's "Sign in again" and a corrected
        // address both arrive with the old manager alive — and a background
        // session is owned by its identifier for the whole process: tearing
        // one down while building the next on the same identifier left the
        // new one invalid too, and its first download raised and crashed
        // (see `DownloadManager.reconfigure`).
        if let downloads {
            downloads.reconfigure(baseURL: url, tokens: session.tokenProvider)
        } else {
            downloads = DownloadManager(baseURL: url, tokens: session.tokenProvider) { job in
                BookContentService.defaultDirectory()
                    .appending(path: "\(job.bookUUID)-\(job.format.rawValue).epub")
            }
        }
        // Declared on DownloadManager and never assigned until now, which is
        // why a finished download did not refresh anything that reads the disk.
        downloads?.onFinished = { [weak self] _ in self?.refreshDownloadedSet() }
        refreshDownloadedSet()
        Task { [weak self] in await self?.downloads?.reattach() }

        if phase != .ready { phase = .signingIn }
        await session.restore()
        // The same handling as adopt(). Fixing only that one left this path —
        // the one that runs on every cold launch — dropping the reason on the
        // floor and stranding phase at .signingIn, which renders as the blank
        // sign-in form: exactly the bug adopt() was fixed for.
        switch session.state {
        case .signedIn:
            await enterLibrary()
        case let .failed(reason):
            // A cached shelf is still worth showing; say why it may be stale
            // rather than replacing it with a form.
            loadError = reason
            if phase != .ready { phase = .chooseServer }
        case .signedOut, .signingIn, .expired:
            // With the cached shelf already up, restore() just rejected the
            // stored token — a revoked device grant, most often. Staying
            // `.ready` presented a signed-in library over a dead session:
            // every request 401'd silently and nothing offered a way back in.
            // `.expired` keeps the server and makes signing in again one tap.
            phase = phase == .ready ? .expired : .chooseServer
        }
    }

    public func adopt(token: String) async {
        guard let session else { return }
        await session.adopt(token: token)
        switch session.state {
        case .signedIn:
            await enterLibrary()
        case let .failed(reason):
            // The grant worked and the token is in the keychain — only the
            // identity call failed. Saying so is the whole fix: this used to
            // leave `phase` at .signingIn, which renders as the blank server
            // form, so a successful sign-in looked like a silent failure.
            loadError = reason
            phase = .chooseServer
        default:
            phase = .chooseServer
        }
    }

    /// Signs out and leaves nothing behind.
    ///
    /// - Parameter keepDownloads: books already on the device are expensive to
    ///   fetch again, so the choice is offered rather than assumed.
    public func signOut(keepDownloads: Bool = false, nowPlaying: NowPlayingController? = nil) async {
        await session?.signOut()
        // Stop the audio, and stop anything listening for it, before the
        // stopping itself is announced.
        //
        // Order matters twice over. `pause()` notifies its rate observers
        // synchronously, so pausing first republished the ex-account's book to
        // the App Group and to the lock screen — using a session whose token
        // had just been revoked. And detaching Now Playing is not optional:
        // it holds the coordinator strongly, so without this its refresh loop
        // kept the signed-out account's book on the lock screen and its Play
        // button resumed it.
        stopListening(nowPlaying: nowPlaying)
        // And the open book, which since it outlives its screen would otherwise
        // keep narrating the signed-out account's library out loud.
        releaseAllReaders()
        // The catalogue belongs to the account, so it goes with it. Annotations
        // do not: they are device-local and this is their only copy.
        try? await store?.clearAccountData()
        store = nil
        mutations = nil
        // The high-water marks go too. They are keyed by book uuid, and the
        // same server hands the same uuids to a different account — so without
        // this, account A's finished book refuses every derived write account B
        // makes against it.
        positionGuards = [:]
        books = []
        rebuildDerived()
        downloadedUUIDs = []
        statuses = []
        ratings = [:]
        loadError = nil

        // The account's transfers go with it. The manager itself stays: its
        // background session owns its identifier for the life of the process,
        // and tearing it down here made the session the next sign-in built
        // invalid from birth — its first task raised an uncatchable
        // `NSGenericException`. `connect` points this one at the new account.
        downloads?.stop()
        session = nil
        CoverCache.shared.clear()
        // The widget keeps showing the last book on a signed-out device unless
        // its snapshot is cleared and its timeline reloaded.
        // Through the publisher, so the cover latch is forgotten too — leaving
        // it set meant signing back in and reopening the same book skipped the
        // cover fetch and left the widget with no art at all.
        // Reloads the CurrentBook timeline itself; the accessory families
        // share it, so a second reloadAllTimelines here was redundant.
        CurrentBookPublisher.shared.clear()
        // And the device-wide Spotlight index, which otherwise keeps this
        // account's titles, bylines and blurbs answering Home Screen searches
        // for up to 30 days after sign-out.
        await SpotlightIndex.clear()

        if !keepDownloads {
            let manager = FileManager.default
            let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            for folder in ["Books", "Audio"] {
                try? manager.removeItem(at: support.appending(path: folder, directoryHint: .isDirectory))
            }
        }
        phase = .chooseServer
    }

    /// Opens the durable write queue, if it is not open already.
    ///
    /// Idempotent, and called from both `connect` and `enterLibrary` on purpose:
    /// `connect` runs before a first sign-in has a token, and `adopt` is the
    /// only other way into a signed-in library. Between them they are every
    /// route, and a route that arrives without a queue loses writes in silence.
    private func ensureMutationQueue() {
        guard mutations == nil, let store else { return }
        mutations = try? MutationQueue(store: store)
        if mutations == nil {
            IssaLog.warning("mutation queue unavailable", ["server": serverAddress])
        }
    }

    private func enterLibrary() async {
        // Belt and braces: whichever way we got here, writes must be durable
        // before the library — and therefore the reader — is reachable.
        ensureMutationQueue()
        // Annotations are kept per account. The store is per server, and a
        // second reader signing into the same server on a shared device used
        // to be shown the first one's highlights and quoted excerpts.
        if let session, case let .signedIn(user) = session.state {
            try? await store?.setAccount(user.id)
            UserDefaults.standard.set(user.id, forKey: Self.accountKey(for: session.serverURL))
        }
        phase = .ready
        await refreshLibrary()
    }

    /// Where the last signed-in account for a server is remembered, so an
    /// offline launch still knows whose annotations to show.
    private static func accountKey(for url: URL) -> String {
        "issa.account.\(url.absoluteString)"
    }

    /// Watches for the token going stale while the app is in use.
    ///
    /// The device grant's token lasts 30 days and there is nothing to refresh
    /// it with, so this happens to every install eventually. Without it the
    /// library simply stops loading and nothing explains why.
    public func watchForExpiry() async {
        // No `guard let session` here. This starts from a .task at launch, when
        // the session is still nil, so the guard returned immediately and
        // expiry was never watched in the launch where you actually signed in.
        // It also has to re-read `session` each pass, since connect() replaces it.
        while !Task.isCancelled {
            if session?.state == .expired, phase == .ready {
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
            // Everything fetched into locals and published in ONE assignment at
            // the end. Publishing `books` first and then continuing for two more
            // round trips rebuilt the scroll content — including whether the
            // Continue card exists, which is the first item and therefore
            // exactly where the refresh control's inset lives — while that
            // control was still expanded. The scroll view then re-measured and
            // adopted the inflated inset as its resting layout, leaving the
            // words permanently pushed down.
            let fetched = try await service.allBooks()
            let fetchedStatuses = (try? await service.statuses()) ?? statuses
            let fetchedRatings = (try? await service.myRatings()) ?? ratings

            // Reconciled, not assigned: a refetch that predates a write still in
            // the queue carries a stale position, and `replaceCatalogue` below
            // would then persist it for the next cold launch to read back.
            let known = Dictionary(books.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
            let merged = fetched.map { known[$0.uuid]?.reconciled(with: $0) ?? $0 }
            books = merged
            rebuildDerived()
            statuses = fetchedStatuses
            ratings = fetchedRatings
            loadError = nil
            IssaLog.info("library refreshed", ["books": String(fetched.count)])

            // Off the refresh gesture entirely: a full catalogue rewrite and a
            // serial drain of queued writes have no business holding the
            // spinner open.
            Task { [store, weak self] in
                try? await store?.replaceCatalogue(merged)
                await self?.drainPendingWrites()
            }
        } catch {
            IssaLog.failure("library refresh", error, ["server": serverAddress])
            // A failed refresh is not an empty library when something is cached.
            if books.isEmpty, let cached = try? await store?.allBooks(), !cached.isEmpty {
                books = cached
                rebuildDerived()
            }
            loadError = books.isEmpty ? Self.message(for: error) : nil
        }
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
    public func enqueue(
        _ kind: MutationQueue.Kind, bookUUID: String, payload: some Encodable,
        supersedes ordering: Double? = nil,
    ) async {
        // Both halves logged. A write that vanishes here leaves no other trace:
        // the in-memory book has already moved, `pendingWrites` stays at zero,
        // and the next refresh re-persists the position the server never took —
        // so nothing downstream can ever notice. That is how a whole build
        // shipped with no queue at all.
        guard let mutations else {
            IssaLog.warning("write dropped: no queue", [
                "book": bookUUID, "kind": String(describing: kind),
            ])
            return
        }
        guard let data = try? JSONEncoder().encode(payload) else {
            IssaLog.warning("write dropped: not encodable", [
                "book": bookUUID, "kind": String(describing: kind),
            ])
            return
        }
        do {
            let recorded = try await mutations.enqueue(
                kind, bookUUID: bookUUID, payload: data, supersedes: ordering)
            if !recorded {
                // Not a loss — a newer write for this book is already queued and
                // is the only remaining copy of where the reader is. Rare enough
                // (it takes a clock going backwards) to be worth a line when it
                // does happen.
                IssaLog.info("write superseded by a queued newer one", [
                    "book": bookUUID, "kind": String(describing: kind),
                ])
            }
        } catch {
            IssaLog.failure("write dropped: queue refused it", error, [
                "book": bookUUID, "kind": String(describing: kind),
            ])
            return
        }
        pendingWrites = (try? await mutations.count) ?? 0
        await drainPendingWrites()
    }

    // MARK: - Arranging the library

    /// How the shelf is sorted and filtered. Persisted, because a reader who
    /// prefers to sort by author means it next launch too.
    public var arrangement = LibraryArrangement.restored() {
        didSet {
            arrangement.store()
            rebuildArranged()
        }
    }

    /// The library as arranged, which is what every shelf view should show.
    ///
    /// Stored rather than computed: it was rebuilding a `BookContentService`
    /// and, for the downloaded shelf, stat-ing every book on every access — and
    /// a SwiftUI body reads it more than once per frame.
    public private(set) var arrangedBooks: [Book] = []

    /// Recomputes everything derived from the catalogue.
    func rebuildDerived() {
        facets = LibraryFacets(books: books, downloadedUUIDs: downloadedUUIDs)
        rebuildAfterPositionChange()
    }

    /// The part of the above a position can move: the Continue card, and the
    /// arrangement when it sorts by recency or progress. The facets — shelves,
    /// tags, what is downloaded — cannot change with a page turn.
    private func rebuildAfterPositionChange() {
        continueBook = LibraryDerivation(books: books).continueReading.first
        rebuildArranged()
    }

    private func rebuildArranged() {
        arrangedBooks = arrangement.apply(to: books) { downloadedUUIDs.contains($0.uuid) }
    }

    /// Deletes one downloaded edition, everything that came with it, and the
    /// record that it was ever downloading.
    ///
    /// Shared, because readaloud audio is extracted alongside the file and
    /// forgetting it silently orphans hundreds of megabytes — a second copy of
    /// this in another screen is a second chance to forget.
    public func removeDownload(_ book: Book, format: BookContentService.Format) {
        guard let session else { return }
        BookContentService(client: session.client).removeDownload(book, format: format)
        if format == .readaloud { AudioExtraction.removeExtractedAudio(for: book.uuid) }
        downloads?.clear(.init(bookUUID: book.uuid, format: format))
        refreshDownloadedSet()
    }

    /// Re-reads which books have files on disk.
    ///
    /// Called when a download finishes, when one is deleted, on sign-out, and
    /// when the app comes forward — a transfer can complete while backgrounded.
    public func refreshDownloadedSet() {
        downloadedUUIDs = BookContentService.downloadedBookUUIDs()
    }

    // MARK: - Deep links

    /// A book the app was asked to open — from a widget, Spotlight or Handoff.
    ///
    /// Held rather than acted on directly, because the link can arrive before
    /// the library has loaded, or before anyone is even signed in.
    /// A book something outside the app asked for, and what it asked for.
    ///
    /// The destination matters because the routes in do not mean the same
    /// thing. A widget tap, a Handoff from another device and an
    /// `issareader://` link all mean "carry on with this book"; a Spotlight
    /// result means "here is a book you searched for", where the description,
    /// the editions and the Listen button are the point.
    public struct PendingBook: Equatable, Sendable {
        public enum Destination: Sendable, Equatable { case read, details }
        public let uuid: String
        public let destination: Destination
    }

    public private(set) var pendingBook: PendingBook?

    /// Set when a `.read` request resolves to a book that has text, and
    /// consumed by that book's screen so it opens the reader straight away.
    private var readerRequest: String?

    public func requestBook(_ uuid: String, _ destination: PendingBook.Destination) {
        pendingBook = PendingBook(uuid: uuid, destination: destination)
    }

    /// Accepts `issareader://book/{uuid}`.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard url.scheme == "issareader" else { return false }
        let components = url.pathComponents.filter { $0 != "/" }
        switch url.host() {
        case "book":
            guard let uuid = components.first else { return false }
            // A link naming a book is a request to get on with it.
            requestBook(uuid, .read)
            return true
        default:
            return false
        }
    }

    /// The book a pending link refers to, once the library can answer.
    ///
    /// Asking to read a book with no text — an audiobook — falls back to its
    /// page rather than starting audio unasked.
    public func consumePendingBook() -> (book: Book, destination: PendingBook.Destination)? {
        guard let pendingBook else { return nil }
        guard let book = books.first(where: { $0.uuid == pendingBook.uuid }) else { return nil }
        self.pendingBook = nil
        let destination: PendingBook.Destination =
            pendingBook.destination == .read && book.isReadable ? .read : .details
        if destination == .read { readerRequest = book.uuid }
        return (book, destination)
    }

    /// Drops a pending request without acting on it.
    ///
    /// For a link to the book whose reader is already on screen: there is
    /// nothing to open, and `consumePendingBook` would arm the one-shot reader
    /// request on the way past, so the next visit to that book's screen —
    /// Back out of the reader and in again — reopened the reader unasked.
    public func discardPendingBook() {
        pendingBook = nil
    }

    /// Whether this book's screen should open the reader as it appears.
    ///
    /// One-shot: a later visit to the same book, arrived at by tapping through
    /// the library, must not reopen the reader on its own.
    public func consumeReaderRequest(for book: Book) -> Bool {
        guard readerRequest == book.uuid else { return false }
        readerRequest = nil
        return true
    }

    // MARK: - Annotations

    /// Saves a mark. Local only: the server has no annotations endpoint in any
    /// version, so this database is the only copy there is.
    public func save(_ annotation: Annotation) {
        // Fire and forget: the reader already holds the mark in memory, and
        // blocking a highlight on a disk write would be felt.
        Task { [store] in try? await store?.save(annotation) }
    }

    public func delete(_ annotation: Annotation) {
        Task { [store] in try? await store?.deleteAnnotation(id: annotation.id) }
    }

    public func annotations(for bookUUID: String) async -> [Annotation] {
        (try? await store?.annotations(for: bookUUID)) ?? []
    }

    public func allAnnotations() async -> [Annotation] {
        (try? await store?.allAnnotations()) ?? []
    }

    /// The audiobook currently playing, if any.
    ///
    /// Held here rather than in a view, because playback has to outlive the
    /// screen that started it — that is the whole point of an audiobook.
    public private(set) var listening: AudiobookCoordinator?
    public private(set) var listeningBook: Book?
    public private(set) var listeningError: String?

    /// Every open book's reader model, one per book, keyed by uuid.
    ///
    /// Narration used to be owned by `ReaderModel`, which was `@State` inside a
    /// view presented as a full-screen cover — so the back chevron destroyed the
    /// model, the coordinator and the player with it. What made that worse than
    /// a clean stop is that it did not actually stop: `NowPlayingController`
    /// holds its coordinator strongly, so the audio carried on while every
    /// callback into the model early-returned through a dead `weak self`. The
    /// book advanced and not one position was written for it.
    ///
    /// Keeping the whole model rather than writing a second, leaner off-screen
    /// writer is deliberate. The alternative means re-deriving the
    /// chosen/derived classification that `PositionGuard` depends on, in a
    /// second place, for the same book — and a position written with the wrong
    /// provenance is exactly what lost a place in a part-read novel once
    /// already. This way there is one classified path, one high-water mark, and
    /// the cost is a chapter's layout held per open book while the reader browses.
    ///
    /// Keyed by book rather than a single slot: macOS can have several reader
    /// windows open at once ("closing one does not disturb the library"), and a
    /// single slot evicted the wrong window's model the moment a second one was
    /// opened — pausing its narration out from under it, and if the reader
    /// swung back to the first window, recreating its model from scratch,
    /// discarding whatever position and layout it held. Each book keeps its own
    /// model until its own window closes; only which one is narrating is
    /// exclusive, tracked separately below.
    private var readers: [String: ReaderModel] = [:]

    /// The book whose reader is on screen right now, or nil. Set as the reader
    /// view appears and cleared as it goes away, so a deep link that arrives for
    /// the book already being read can avoid resetting the navigation stack out
    /// from under the open reader.
    public private(set) var visibleReaderUUID: String?

    /// An appearing reader claims the slot; a disappearing one releases it only
    /// if it still holds it, so an appear-before-disappear crossover during a
    /// book-to-book switch cannot leave the slot pointing at the book that left.
    public func setReaderVisible(_ uuid: String, _ visible: Bool) {
        if visible {
            visibleReaderUUID = uuid
            // The screen is back; the model no longer leaves with narration.
            // Done here rather than in `reader(for:)`, which is asked for the
            // model as the screen appears and must have no side effects on
            // observed state — see `ReaderScreen`.
            closedWhileNarrating.remove(uuid)
        } else if visibleReaderUUID == uuid {
            visibleReaderUUID = nil
        }
    }

    /// Which open book, if any, owns the active narration and Now Playing.
    ///
    /// Distinct from a model merely existing in `readers`, which is true of
    /// every narrated book anyone has opened a window on. Only the one that has
    /// actually started belongs on the mini bar, and only it may claim the lock
    /// screen.
    private var narratingBookUUID: String?

    /// Books whose reader screen closed while they were still narrating.
    ///
    /// `readerDidClose` must keep such a model — audio outliving its screen is
    /// the point — but that refusal used to be final: once another book took
    /// over narration nothing revisited the eviction, so the model, its
    /// chapter layout, decoded plates and player were pinned for the life of
    /// the process, and `flushOpenReaders` kept re-stamping their stale
    /// positions. Remembered here so each model is let go the moment its
    /// narration actually ends.
    private var closedWhileNarrating: Set<String> = []

    /// The model backing whichever book is currently narrating, if any.
    ///
    /// Not `private`: CarPlay's chapter list (`AppServices.connectCarPlay`)
    /// reads this to offer chapters for a book playing via the reader's
    /// `ReadalongCoordinator` rather than a CarPlay-started audiobook — the
    /// same information `playbackBook`/`playback` already expose, just at the
    /// model level those two don't reach. `AppServices.swift` compiles into
    /// this same module, so `internal` is enough; nothing outside the app
    /// target has a reason to see it.
    var reader: ReaderModel? {
        narratingBookUUID.flatMap { readers[$0] }
    }

    /// The Now Playing surface, handed over at launch.
    ///
    /// Weak, and a property rather than a parameter, because playback now
    /// starts and stops from places that have no view context to thread it
    /// through — a CarPlay list item, the end of a book, the reader closing.
    public weak var nowPlayingController: NowPlayingController?

    /// Whatever is playing, of either kind. Nil when nothing is.
    public var playback: (any PlaybackDriving)? {
        if let listening { return listening }
        if let readalong = reader?.readalong { return readalong }
        return nil
    }

    /// The chapter playing now, named the way the book names it.
    ///
    /// The read-along coordinator only knows which text document the sentence
    /// lives in, so asking it gives an archive path. The reader has the book's
    /// own table of contents, and while narration is what is playing the reader
    /// is alive — that is the whole point of holding it.
    public var playbackChapterTitle: String? {
        if let title = reader?.chapterTitle, ChapterNaming.isDisplayable(title) {
            return title
        }
        return playback?.displayChapterTitle
    }

    public var playbackBook: Book? {
        if listening != nil { return listeningBook }
        return reader?.book
    }

    /// The model for an open book, created once per book and kept.
    ///
    /// Idempotent, so re-presenting a book's reader hands back the same
    /// instance rather than a fresh one that would replace the coordinator and
    /// cut the audio off mid-sentence. Opening a *different* book's window does
    /// not touch this one's model at all — the two are independent entries in
    /// `readers`, which is the whole fix for the eviction bug above. This is
    /// also where the model's closures are installed — permanently, rather than
    /// in the view's `onAppear`, which had a matching `onDisappear` that broke
    /// them and left `saveProgress` writing straight to the network with no
    /// queue and no guard.
    public func reader(for book: Book, session: Session) -> ReaderModel {
        if let existing = readers[book.uuid] { return existing }

        let model = ReaderModel(book: book, session: session)
        model.downloadHost = self
        // The uuid by value, never `model` itself: reaching back through a
        // closure the model stores would retain it for the life of the process,
        // pinning the chapter layout, the decoded plates and the coordinator.
        let bookUUID = book.uuid
        model.enqueuePosition = { [weak self] locator, timestamp, origin in
            await self?.writePosition(
                locator, timestamp: timestamp, for: bookUUID, origin: origin) ?? false
        }
        model.onSaveAnnotation = { [weak self] in self?.save($0) }
        model.onDeleteAnnotation = { [weak self] in self?.delete($0) }
        model.onVisibilityChanged = { [weak self] visible in
            self?.setReaderVisible(bookUUID, visible)
        }
        // Every route into playback — the reader's own button, a tapped
        // sentence, the player sheet, a remote command — ends at the player's
        // rate, so watching that is what catches all of them. A callback on the
        // one method that happens to be named `startNarration` would not.
        //
        // Keyed by the coordinator, and carrying its own book uuid, rather than
        // by `self`: with one model per book there can be several coordinators
        // alive at once, and `narrationDidStart` has to know *which* book just
        // started rather than reading whatever the old single `reader` slot
        // happened to hold — which, with several windows open, was not
        // necessarily the one whose rate actually changed.
        model.onNarrationReady = { [weak self] coordinator in
            coordinator.player.setRateObserver(for: coordinator) { [weak self] rate in
                guard rate > 0 else { return }
                self?.narrationDidStart(for: bookUUID)
            }
        }
        readers[bookUUID] = model
        return model
    }

    /// Lets one book's reader go once its own screen has left it and it is not
    /// the one narrating.
    ///
    /// A book that is merely read should not pin its chapter layout for the
    /// rest of the session; one that is still being listened to must — but only
    /// until that narration ends, which `releaseIfScreenClosed` picks up.
    /// Identity is checked because the Mac can have several reader windows
    /// open: closing one must not evict a model a still-open window is using,
    /// and must not evict a later model already created for the same book uuid.
    public func readerDidClose(_ model: ReaderModel) {
        guard readers[model.book.uuid] === model else { return }
        if narratingBookUUID == model.book.uuid {
            closedWhileNarrating.insert(model.book.uuid)
            return
        }
        readers.removeValue(forKey: model.book.uuid)
    }

    /// Writes out every open book's position, then sends whatever is queued.
    ///
    /// For suspension. `ReaderView` flushes on `onDisappear`, but the reader is
    /// a full-screen cover and being backgrounded does not dismiss it — so the
    /// last two seconds of the debounce, and any queued write that had not yet
    /// reached the network, simply waited for a relaunch that might be days
    /// away. The caller is responsible for holding the app awake long enough;
    /// see the scene-phase handler.
    public func flushOpenReaders() async {
        for model in readers.values {
            await model.saveProgress()
        }
        await drainPendingWrites()
    }

    /// Releases every open reader and stops whichever is narrating. Every open
    /// book belongs to the account being left, unlike the per-window release
    /// above, which only ever concerns the one book that closed.
    private func releaseAllReaders() {
        // Dropped before narration stops: sign-out must not schedule one last
        // position save for the account being left.
        closedWhileNarrating.removeAll()
        stopNarration()
        // Nor run one already scheduled. The screen holds the model beyond
        // this, so a debounced save two seconds out still fired — with no
        // queue to take it, and until recently straight into the widget.
        for model in readers.values { model.cancelPendingSave() }
        readers.removeAll()
    }

    /// Silences narration and gives up the lock screen, if it held it.
    public func stopNarration() {
        guard let uuid = narratingBookUUID else { return }
        narratingBookUUID = nil
        readers[uuid]?.readalong?.player.pause()
        nowPlayingController?.attach(coordinator: nil, book: nil)
        releaseIfScreenClosed(uuid)
    }

    /// Lets go of a model whose screen already closed, now that the narration
    /// it was kept alive for has ended.
    private func releaseIfScreenClosed(_ uuid: String) {
        guard closedWhileNarrating.remove(uuid) != nil,
              let model = readers.removeValue(forKey: uuid) else { return }
        // Its screen flushed when it closed, but narration has moved the book
        // since; one last save so the tail of the debounce does not go with it.
        Task { await model.saveProgress() }
    }

    /// Called when one open book's narration actually begins.
    ///
    /// Playback is exclusive: each coordinator owns its own `AVQueuePlayer`, so
    /// letting a second one run would put two voices in the room. With one
    /// reader model per book there can be several coordinators alive — a
    /// listener can have two windows open on macOS — so exclusivity is enforced
    /// here, at the moment a *different* book actually starts, rather than by
    /// evicting other books' models just for being open.
    private func narrationDidStart(for bookUUID: String) {
        // Fires on every play, and most of them change nothing: re-attaching
        // would cancel the refresh loop and refetch the cover each time.
        guard narratingBookUUID != bookUUID else { return }
        guard let model = readers[bookUUID], let coordinator = model.readalong else { return }
        // Silence whatever else was audible — another book's narration, which
        // this book's window being open must never have paused on its own, or
        // the plain audiobook path.
        if let previous = narratingBookUUID, previous != bookUUID {
            readers[previous]?.readalong?.player.pause()
            releaseIfScreenClosed(previous)
        }
        if listening != nil { stopListening(nowPlaying: nil) }
        narratingBookUUID = bookUUID
        nowPlayingController?.attach(
            coordinator: coordinator,
            book: model.book,
            session: model.readerSession,
            // Weak: the controller outlives the screen deliberately, and holding
            // the reader through it would keep a whole book alive after the app
            // had let go of it.
            chapterTitle: { [weak model] in model?.chapterTitle },
        )
    }

    /// Re-entrancy guard for `startListening`, which suspends at the manifest
    /// fetch and again at `start(atProgress:)` while the Listen button has no
    /// in-flight state of its own. A double tap — or a tap racing CarPlay's
    /// `onPlay` — used to run the whole method twice: two coordinators, two
    /// audible AVQueuePlayers, and the fifteen-second position writer bound to
    /// whichever coordinator was about to be discarded.
    private var isStartingListening = false

    /// Starts a plain audiobook: fetch the manifest, resume where the server
    /// says we were, and hand it to the Now Playing centre.
    public func startListening(
        to book: Book, nowPlaying: NowPlayingController, settings: PlaybackSettings,
    ) async {
        // A concurrent duplicate is dropped, not queued: the first call is
        // already starting this same playback. `listeningError` is nil while
        // it is in flight, so CarPlay's success signal stays honest.
        guard !isStartingListening else { return }
        isStartingListening = true
        defer { isStartingListening = false }
        // Clear last time's error at the top of every genuine attempt, so no
        // later `return` — the resume fast-path below included — can leave a
        // stale message that CarPlay's `onPlay` would read back as this
        // attempt's outcome. Each attempt now speaks only for itself.
        listeningError = nil
        // This guard used to return with `listeningError` untouched — so a
        // failure here read as whatever the *previous* attempt happened to
        // leave behind, nil included. CarPlay's `onPlay` reports this value
        // back verbatim as its success signal, so a stale nil made this
        // attempt's early return look identical to nothing having gone wrong:
        // the row pushed straight to Now Playing with no audio behind it.
        guard let session, let url = Self.normalizeServerURL(serverAddress) else {
            listeningError = "Not signed in yet."
            return
        }
        // One player at a time. Each coordinator owns its own AVQueuePlayer, so
        // starting an audiobook over running narration is two voices at once —
        // and whichever attached to Now Playing second silently released the
        // other, which is the second way audio "disappeared".
        stopNarration()
        if listeningBook?.uuid == book.uuid, let coordinator = listening {
            coordinator.player.play()
            // The reader may have taken the snapshot and the cover while this
            // book sat paused, and nothing else republishes on a resume.
            publishListeningSnapshot(book: book, coordinator: coordinator)
            return
        }
        // A *different* audiobook already playing has to be stopped too — the
        // guard above only catches resuming the same one. Without this,
        // switching books mid-listen built a second AudiobookCoordinator with
        // its own AVQueuePlayer and left the first one playing, retained by its
        // own rate observer, with no control anywhere in the UI still pointing
        // at it.
        if listening != nil {
            stopListening(nowPlaying: nowPlaying)
        }
        listeningError = nil
        let service = AudiobookService(client: session.client, baseURL: url, tokens: session.tokenProvider)
        do {
            let manifest = try await service.manifest(for: book.uuid)
            guard !manifest.playableTracks.isEmpty else {
                listeningError = "This audiobook has no playable tracks on the server."
                return
            }
            // The `stopNarration()` at the top ran before this network round
            // trip; a read-along the reader tapped *during* the fetch would
            // otherwise still be playing when the audiobook starts, two voices
            // at once. Stop again now that the suspension is over, just before
            // this coordinator takes over Now Playing.
            stopNarration()
            // Play the downloaded file when it can stand in for the manifest;
            // otherwise stream, with the token travelling as a cookie because
            // AVFoundation makes its own requests and never sees our headers.
            //
            // "Stand in" means the manifest has exactly one playable track:
            // the download is the whole book as a single file, while the
            // coordinator drives playback track by track against the manifest.
            // Handing it one file for a 17-track book applied every per-track
            // offset to that same file — a resume at 50% seeked minutes in
            // instead of hours, and then persisted the double-counted clock.
            let content = BookContentService(client: session.client)
            let playableAsOneFile = manifest.playableTracks.count == 1
                && content.isDownloaded(book, format: .audiobook)
            let source: AudiobookCoordinator.Source = playableAsOneFile
                ? .local(content.localURL(for: book, format: .audiobook))
                : .streaming(
                    base: service.trackBase(for: book.uuid),
                    cookies: await service.playbackCookies(for: book.uuid),
                )

            let coordinator = AudiobookCoordinator(manifest: manifest, source: source)
            coordinator.player.rate = Float(settings.playbackRate)
            listening = coordinator
            listeningBook = book
            // Play and pause both have to reach the widget, and the only
            // recurring publish is behind a "progress moved" guard that a
            // paused book never passes — so isPlaying could be set true and
            // never set false again.
            coordinator.player.setRateObserver(for: self) { [weak self, weak coordinator] rate in
                guard let self, let coordinator else { return }
                // The rate the player just reported, not `effectiveRate`.
                // `play()` notifies before AVPlayer's timeControlStatus leaves
                // `waitingToPlayAtSpecifiedRate`, so re-reading it here would
                // publish "not playing" the instant someone pressed play.
                self.publishListeningSnapshot(
                    book: book, coordinator: coordinator, isPlaying: rate > 0)
            }
            nowPlaying.attach(
                coordinator: coordinator, book: book, session: session,
                chapterTitle: { [weak coordinator] in coordinator?.chapterTitle },
            )
            IssaLog.info("listening started", [
                "book": book.title,
                "atProgress": String(format: "%.4f", book.progress ?? 0),
                "source": book.progress == nil ? "noStoredPosition" : "libraryRow",
            ])
            await coordinator.start(atProgress: book.progress ?? 0)
            // After the seek, never before: a coordinator one line old still
            // reads bookTime 0, so publishing here would have announced every
            // resumed audiobook at 0% and left that on disk if the listener
            // paused inside the next fifteen seconds.
            publishListeningSnapshot(book: book, coordinator: coordinator)
            watchListeningProgress(book: book, coordinator: coordinator)
        } catch {
            IssaLog.failure("start listening", error, ["book": book.title])
            listeningError = Self.message(for: error)
        }
    }

    /// Stops playback and lets go of everything holding onto it.
    ///
    /// Order matters twice over. `pause()` notifies its rate observers
    /// synchronously, so pausing before dropping them republished the book —
    /// to the App Group and to the lock screen — which on sign-out meant doing
    /// so with a token that had just been revoked. And detaching Now Playing is
    /// not optional: it holds the coordinator strongly, so without it the
    /// refresh loop kept the book on the lock screen and its Play button
    /// resumed it.
    public func stopListening(nowPlaying: NowPlayingController?) {
        listeningProgressTask?.cancel()
        listeningProgressTask = nil
        listening?.player.removeRateObservers()
        nowPlaying?.attach(coordinator: nil, book: nil)
        listening?.player.pause()
        listening = nil
        listeningBook = nil
    }

    /// Writes the listening position back periodically.
    ///
    /// An hour of listening is as much progress as an hour of reading, and
    /// losing it on a crash or a battery death is just as annoying.
    private func watchListeningProgress(book: Book, coordinator: AudiobookCoordinator) {
        listeningProgressTask?.cancel()
        listeningProgressTask = Task { [weak self, weak coordinator] in
            var lastWritten: Double = -1
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, let coordinator else { return }
                let progress = coordinator.bookProgress
                // Only when it actually moved: a paused book must not generate
                // a write every fifteen seconds forever.
                guard abs(progress - lastWritten) > 0.0005 else { continue }
                lastWritten = progress
                // A scrub is the listener naming a place; the clock arriving
                // somewhere is not. The coordinator owns every seek entry point,
                // so it is the only thing that can tell them apart.
                let origin: PositionOrigin = coordinator.consumeSteering() ? .chosen : .derived
                await writePosition(
                    Self.audioLocator(for: coordinator, book: book),
                    timestamp: ProgressService.now(),
                    for: book.uuid,
                    origin: origin,
                )
                // `enqueue` suspends, and can drain the network for seconds.
                // Without this a tick belonging to a book the reader has since
                // left resumes and republishes it over whatever replaced it.
                guard !Task.isCancelled, self.listeningBook?.uuid == book.uuid else { return }
                self.publishListeningSnapshot(book: book, coordinator: coordinator)
            }
        }
    }

    /// Keeps the widget honest while an audiobook plays.
    ///
    /// Only the reader ever wrote a snapshot, so a pure audiobook left the
    /// widget showing whatever was read last — and `isPlaying` came from the
    /// read-along player, which for an audiobook is always false. That is
    /// precisely the case the square cover exists for.
    /// - Parameter isPlaying: what the player just reported, when this is
    ///   driven by a rate change. Left nil on the periodic tick, where the
    ///   player's real state is the honest answer — a stall should stop the
    ///   widget claiming to play.
    private func publishListeningSnapshot(
        book: Book, coordinator: AudiobookCoordinator, isPlaying: Bool? = nil,
    ) {
        let progress = coordinator.bookProgress
        let total = coordinator.totalDuration
        CurrentBookPublisher.shared.publish(
            book: book,
            session: session,
            progress: progress,
            chapter: coordinator.chapterTitle,
            remaining: total.isFinite && total > 0 ? total * (1 - progress) : nil,
            // The player's real rate, not a hand-kept flag: a stall, a route
            // change or an interruption all stop playback without asking us.
            isPlaying: isPlaying ?? (coordinator.player.effectiveRate > 0),
            as: .listening(book.uuid),
        )
    }

    /// A locator for a position inside an audiobook.
    ///
    /// The href is the track, since that is the only resource an audiobook has,
    /// and `totalProgression` is what every other client reads to show percent
    /// complete — including Storyteller's own web player.
    static func audioLocator(for coordinator: AudiobookCoordinator, book: Book) -> ReadiumLocator {
        let tracks = coordinator.tracks
        let index = min(coordinator.trackIndex, max(tracks.count - 1, 0))
        let track = tracks.indices.contains(index) ? tracks[index] : nil
        let trackStart = coordinator.manifest.startTime(ofTrackAt: index)
        let within = (track?.duration ?? 0) > 0
            ? (coordinator.bookProgress * coordinator.totalDuration - trackStart) / (track?.duration ?? 1)
            : 0
        return ReadiumLocator(
            href: track?.href ?? "",
            type: track?.type ?? "audio/mpeg",
            title: track.map { coordinator.manifest.title(of: $0, at: index) },
            locations: .init(
                progression: min(max(within, 0), 1),
                totalProgression: coordinator.bookProgress,
            ),
        )
    }

    /// Downloads a book and waits for it, reporting progress as it goes.
    ///
    /// The reader used to run its own foreground transfer on URLSession.shared
    /// with a sixty-second ceiling — fine for a small ebook, hopeless for a
    /// readaloud of several hundred megabytes, and it reported the timeout as
    /// "couldn't reach your server". Going through the same manager as every
    /// other download means progress, cancellation, resume-after-interruption,
    /// the Wi-Fi-only preference and the free-space check all apply here too.
    public func downloadAndWait(
        _ book: Book, format: BookContentService.Format,
        onProgress: @escaping (Int64, Int64) -> Void,
    ) async throws -> URL {
        guard let session, let downloads else { throw StorytellerError.notAuthenticated }
        let content = BookContentService(client: session.client)
        let destination = content.localURL(for: book, format: format)
        if content.isDownloaded(book, format: format) { return destination }

        let job = DownloadManager.Job(bookUUID: book.uuid, format: format)
        // `download` can refuse to start at all — the Wi-Fi-only guard, most
        // often — in which case `states[job]` is never populated and the loop
        // below would wait on a state that can never arrive. It used to: this
        // is what left the reader stuck on "Downloading…" forever, with the
        // real reason sitting unseen in `loadError`.
        guard await download(book, format: format) else {
            throw StorytellerError.transport(loadError ?? "Couldn't start the download.")
        }

        // The last real byte counts seen, for a pause to keep showing.
        var lastReported: (written: Int64, total: Int64) = (0, 0)
        while !Task.isCancelled {
            switch downloads.state(for: job) {
            case .finished:
                return destination
            case let .failed(reason):
                throw StorytellerError.transport(reason)
            case let .downloading(_, written, total):
                lastReported = (written, total)
                onProgress(written, total)
            case .paused:
                // Not a failure. Pausing from the Downloads screen used to
                // throw here, and the reader's .failed phase was a dead end —
                // resuming completed the file but never revived the screen.
                // Keep waiting; resuming picks straight back up. Reported in
                // the bytes the callback is defined in: a percentage pushed
                // through it rendered as "44 bytes of 100 bytes".
                onProgress(lastReported.written, lastReported.total)
            case .queued:
                break
            case .none:
                // `start` claims the job before its first await, so once
                // `download` has returned true there is only one way to no
                // state at all: the reader's Cancel, which clears it. This used
                // to wait on it forever, four times a second, and a Try Again
                // then ran a second open alongside the first.
                throw StorytellerError.transport("Download cancelled.")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw CancellationError()
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
    ///
    /// - Returns: whether a transfer was actually started. `false` means
    ///   `downloads.start` was never called at all — the Wi-Fi-only guard
    ///   refused first — so no `DownloadManager.State` will ever exist for this
    ///   job. A caller waiting on that state, like `downloadAndWait`, has to
    ///   know the difference between "not yet" and "never coming".
    @discardableResult
    public func download(_ book: Book, format: BookContentService.Format) async -> Bool {
        guard let downloads else { return false }
        let expected: Int64? = switch format {
        case .readaloud: book.readaloud?.fileSize.map(Int64.init)
        case .audiobook: book.audiobook?.fileSize.map(Int64.init)
        case .ebook: book.ebook?.fileSize.map(Int64.init)
        }
        // Holding back a multi-gigabyte readaloud on cellular is the whole point
        // of the preference; a small ebook is not worth blocking.
        //
        // An unknown size is not a known-small one. The server omits fileSize
        // occasionally, and `expected ?? 0` treated that exactly like a file of
        // zero bytes — letting the one case the preference exists for (a
        // multi-hundred-MB readaloud with no reported size) straight through on
        // cellular. Unknown fails safe: assumed large until proven otherwise.
        if downloads.wifiOnly, reachability.isExpensive, expected.map({ $0 > 20_000_000 }) ?? true {
            loadError = "Waiting for Wi-Fi to download this."
            return false
        }
        await downloads.start(.init(bookUUID: book.uuid, format: format), expectedBytes: expected)
        return true
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
        rebuildDerived()
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

    /// Records a position the app has just written, without asking the server.
    ///
    /// The Continue card, the library row and the book screen all read
    /// `book.progress`, which comes from `position` — and that was only ever
    /// updated by fetching the book again, from `BookDetailView`'s `.task`. So
    /// a whole reading session could pass with the card still showing where the
    /// reader started.
    ///
    /// Fetching on close would not have fixed it: the write is queued, so the
    /// server can legitimately still be a session behind, and the card would
    /// visibly walk backwards. The app wrote this locator; it does not need to
    /// be told what it is.
    ///
    /// Persisted as well as held, which it was not. The `book` row's `progress`
    /// and `positionTimestamp` used to wait for the next `replaceCatalogue`, so
    /// a chapter read offline and then killed came back at the old percentage —
    /// and worse, `refreshLibrary` fetches from the server *before* draining the
    /// queue, so the stale row won the merge. With the timestamp on disk,
    /// `reconciled(with:)` defends it.
    public func recordPosition(
        _ locator: ReadiumLocator, timestamp: Double, for bookUUID: String,
    ) async {
        guard let index = books.firstIndex(where: { $0.uuid == bookUUID }) else { return }
        books[index].adopt(position: locator, timestamp: timestamp)
        rebuildAfterPositionChange()
        try? await store?.upsert(books[index])
    }

    /// One high-water mark per book, for the life of the session.
    private var positionGuards: [String: PositionGuard] = [:]

    /// The single place a reading position is written.
    ///
    /// Both writers pass through here — the reader's own saves and the
    /// audiobook's fifteen-second loop — because the loop is exactly as capable
    /// of persisting a wrong position as the reader is, and guarding only
    /// `saveProgress` would leave half the app unprotected.
    ///
    /// A refused write is dropped, not deferred. Dropping a legitimate one costs
    /// a position that stops syncing until the reader touches anything; keeping
    /// a wrong one costs their place in the book on every device, and nothing
    /// gets it back. The refusal is self-clearing: it can only ever apply to a
    /// `.derived` write, and the reader's next deliberate move re-baselines the
    /// mark unconditionally.
    @discardableResult
    public func writePosition(
        _ locator: ReadiumLocator,
        timestamp: Double,
        for bookUUID: String,
        origin: PositionOrigin,
    ) async -> Bool {
        // No queue means no account: the flush a closing reader sends after a
        // sign-out lands here, and there is nothing to take it.
        guard mutations != nil else {
            IssaLog.warning("write dropped: no queue", ["book": bookUUID, "kind": "position"])
            return false
        }
        let book = books.first { $0.uuid == bookUUID }
        // With the narration length, where there is one: the guard's absolute
        // bound — five minutes — only exists for long audiobooks, and without
        // the duration it was never applied, leaving a forty-hour book two
        // hours of undetected slack.
        let duration = book.map(LibraryArrangement.duration(of:)).flatMap { $0 > 0 ? $0 : nil }
        var state = positionGuards[bookUUID]
            ?? PositionGuard(highWater: book?.progress ?? 0, duration: duration)
        let decision = state.decide(locator.locations?.totalProgression, origin: origin)
        positionGuards[bookUUID] = state

        if case let .refuse(held, candidate) = decision {
            IssaLog.warning("position write refused", [
                "book": bookUUID,
                "held": String(format: "%.4f", held),
                "candidate": String(format: "%.4f", candidate),
                "origin": origin.rawValue,
            ])
            return false
        }

        // Only a substantial move earns a line. `onFragmentChange` fires once a
        // sentence, and the debounce still lets a write through every few
        // seconds, so logging each one would push the six-hour window out of a
        // rotating 512 KB file within an afternoon.
        let previous = books.first { $0.uuid == bookUUID }?.progress
        if let candidate = locator.locations?.totalProgression,
           let previous, abs(candidate - previous) > 0.02 {
            IssaLog.info("position moved", [
                "book": bookUUID,
                "from": String(format: "%.4f", previous),
                "to": String(format: "%.4f", candidate),
                "origin": origin.rawValue,
            ])
        }
        await enqueue(
            .position, bookUUID: bookUUID,
            payload: MutationDrain.PositionPayload(locator: locator, timestamp: timestamp),
            supersedes: timestamp,
        )
        await recordPosition(locator, timestamp: timestamp, for: bookUUID)
        return true
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
        books[index] = books[index].reconciled(with: fresh)
        rebuildDerived()
    }
}
