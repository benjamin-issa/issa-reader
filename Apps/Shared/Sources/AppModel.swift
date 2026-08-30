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
    public var books: [Book] = [] { didSet { rebuildDerived() } }
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
        let resolved = url.absoluteString
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
        // Only for someone who is actually signed in. Showing the cached shelf
        // on the strength of the database alone meant signing out left the
        // entire library readable: the token went, the rows did not, and the
        // next launch walked straight past the sign-in screen into the grid.
        let hasCredential = await session.hasStoredCredential
        if let store, hasCredential {
            mutations = try? MutationQueue(store: store)
            if let cached = try? await store.allBooks(), !cached.isEmpty {
                books = cached
                phase = .ready
            }
        }

        // After the shelf is on screen, not before it. Building a background
        // URLSession is an XPC handshake and `reattach()` is a second round trip
        // to a daemon that may need waking — both used to run ahead of the few
        // milliseconds of SQLite that could have shown the library immediately.
        downloads = DownloadManager(baseURL: url, tokens: session.tokenProvider) { job in
            BookContentService.defaultDirectory()
                .appending(path: "\(job.bookUUID)-\(job.format.rawValue).epub")
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
            if phase != .ready { phase = .chooseServer }
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
    public func signOut(keepDownloads: Bool = false) async {
        await session?.signOut()
        // Stop the audio first. The progress loop holds the coordinator
        // strongly and publishes the widget snapshot every fifteen seconds, so
        // signing out while a book played wrote the ex-account's title and
        // position straight back into the App Group container — after the
        // clear below had already run.
        listeningProgressTask?.cancel()
        listeningProgressTask = nil
        listening?.player.pause()
        listening?.player.removeRateObservers()
        listening = nil
        listeningBook = nil
        // The catalogue belongs to the account, so it goes with it. Annotations
        // do not: they are device-local and this is their only copy.
        try? await store?.clearAccountData()
        store = nil
        mutations = nil
        books = []
        downloadedUUIDs = []
        statuses = []
        ratings = [:]
        loadError = nil

        // The download session outlived sign-out, so the next connect stacked
        // a second one on the same identifier.
        await downloads?.shutDown()
        downloads = nil
        session = nil
        CoverCache.shared.clear()
        // The widget keeps showing the last book on a signed-out device unless
        // its snapshot is cleared and its timeline reloaded.
        // Through the publisher, so the cover latch is forgotten too — leaving
        // it set meant signing back in and reopening the same book skipped the
        // cover fetch and left the widget with no art at all.
        CurrentBookPublisher.shared.clear()
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

            books = fetched
            statuses = fetchedStatuses
            ratings = fetchedRatings
            loadError = nil

            // Off the refresh gesture entirely: a full catalogue rewrite and a
            // serial drain of queued writes have no business holding the
            // spinner open.
            Task { [store, weak self] in
                try? await store?.replaceCatalogue(fetched)
                await self?.drainPendingWrites()
            }
        } catch {
            // A failed refresh is not an empty library when something is cached.
            if books.isEmpty, let cached = try? await store?.allBooks(), !cached.isEmpty {
                books = cached
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
    public func enqueue(_ kind: MutationQueue.Kind, bookUUID: String, payload: some Encodable) async {
        guard let mutations, let data = try? JSONEncoder().encode(payload) else { return }
        try? await mutations.enqueue(kind, bookUUID: bookUUID, payload: data)
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
        if format == .readaloud { AudioExtractionCleanup.removeAudio(for: book.uuid) }
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
    public var pendingBookID: String?

    /// Accepts `issareader://book/{uuid}`.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard url.scheme == "issareader" else { return false }
        let components = url.pathComponents.filter { $0 != "/" }
        switch url.host() {
        case "book":
            guard let uuid = components.first else { return false }
            pendingBookID = uuid
            return true
        default:
            return false
        }
    }

    /// The book a pending link refers to, once the library can answer.
    public func consumePendingBook() -> Book? {
        guard let pendingBookID else { return nil }
        guard let book = books.first(where: { $0.uuid == pendingBookID }) else { return nil }
        self.pendingBookID = nil
        return book
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

    /// Starts a plain audiobook: fetch the manifest, resume where the server
    /// says we were, and hand it to the Now Playing centre.
    public func startListening(
        to book: Book, nowPlaying: NowPlayingController, settings: PlaybackSettings,
    ) async {
        guard let session, let url = Self.normalizeServerURL(serverAddress) else { return }
        if listeningBook?.uuid == book.uuid, let coordinator = listening {
            coordinator.player.play()
            // The reader may have taken the snapshot and the cover while this
            // book sat paused, and nothing else republishes on a resume.
            publishListeningSnapshot(book: book, coordinator: coordinator)
            return
        }
        listeningError = nil
        let service = AudiobookService(client: session.client, baseURL: url, tokens: session.tokenProvider)
        do {
            let manifest = try await service.manifest(for: book.uuid)
            guard !manifest.playableTracks.isEmpty else {
                listeningError = "This audiobook has no playable tracks on the server."
                return
            }
            // Play the downloaded file when there is one; otherwise stream, with
            // the token travelling as a cookie because AVFoundation makes its
            // own requests and never sees our headers.
            let content = BookContentService(client: session.client)
            let source: AudiobookCoordinator.Source = content.isDownloaded(book, format: .audiobook)
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
            coordinator.player.addRateObserver { [weak self, weak coordinator] rate in
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
            await coordinator.start(atProgress: book.progress ?? 0)
            // After the seek, never before: a coordinator one line old still
            // reads bookTime 0, so publishing here would have announced every
            // resumed audiobook at 0% and left that on disk if the listener
            // paused inside the next fifteen seconds.
            publishListeningSnapshot(book: book, coordinator: coordinator)
            watchListeningProgress(book: book, coordinator: coordinator)
        } catch {
            listeningError = Self.message(for: error)
        }
    }

    public func stopListening(nowPlaying: NowPlayingController) {
        listening?.player.pause()
        listeningProgressTask?.cancel()
        listening = nil
        listeningBook = nil
        nowPlaying.attach(coordinator: nil, book: nil)
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
                await enqueue(
                    .position, bookUUID: book.uuid,
                    payload: MutationDrain.PositionPayload(
                        locator: Self.audioLocator(for: coordinator, book: book),
                        timestamp: ProgressService.now(),
                    ),
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
        await download(book, format: format)

        while !Task.isCancelled {
            switch downloads.state(for: job) {
            case .finished:
                return destination
            case let .failed(reason):
                throw StorytellerError.transport(reason)
            case let .downloading(_, written, total):
                onProgress(written, total)
            case let .paused(fraction):
                // Not a failure. Pausing from the Downloads screen used to
                // throw here, and the reader's .failed phase was a dead end —
                // resuming completed the file but never revived the screen.
                // Keep waiting; resuming picks straight back up.
                onProgress(Int64(fraction * 100), 100)
            case .queued, .none:
                break
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
