import Foundation
import IssaCore
// For `SMILTimeline`: the listening resolver takes an overlay by name, so the
// type has to be spelled out here rather than inferred from a reader's.
import IssaEPUB
import IssaPlayback
// For `CustomFonts`: a removal has to take the publisher face the reader model
// extracted with it, and that directory is IssaUI's to name.
import IssaUI
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
    /// Books with at least one file on disk *and* not on their way off it.
    ///
    /// The download shelf and its count both need this for the whole library,
    /// and asking `isDownloaded` per book per format is a `stat` per format per
    /// book — thousands of syscalls in a scrolled frame.
    ///
    /// A removal waiting out its undo window is subtracted, because for those
    /// six seconds this set was the app's only answer to "is this on the
    /// device" and it was the wrong one. `DownloadsSection` filtered its own
    /// rows and nothing else did — so the shelf, the offline filter, CarPlay's
    /// catalogue and the reader all went on offering a file that was about to
    /// be deleted underneath them. In a car, in a tunnel, that is silence.
    ///
    /// Only when the pending removal is the book's *last* edition: it is keyed
    /// by book, and a book that has lost one of two has not left the device.
    public private(set) var downloadedUUIDs: Set<String> = [] { didSet { rebuildDerived() } }
    /// What the last directory read actually found, before the undo window is
    /// applied. The disk's own answer, kept so the window can be taken back
    /// without another read.
    private var downloadedOnDisk: Set<String> = []
    /// Bumped every time the app has reason to think the Books directory has
    /// changed, for the screens that walk it themselves.
    ///
    /// Those screens keyed their scans on collection *counts*, and a count
    /// cannot see the change that matters most here: removing one edition of a
    /// two-edition book leaves `downloadedUUIDs` — which is keyed by book —
    /// exactly equal, and the transfer list never held it. So the row kept its
    /// old size, the header kept its old total, and nothing re-ran until some
    /// unrelated number happened to move. On the Apple TV, which has no undo
    /// window either, nothing ever did.
    ///
    /// A counter rather than a richer key because the question is "has the disk
    /// changed", and the only honest answer to that is from the code that
    /// changed it. `refreshDownloadedSet` is called on exactly those occasions
    /// — a finish, a removal, a cancel, a sign-in, the app coming forward, a car
    /// connecting — and on no render path, so bumping it there is bounded.
    public private(set) var downloadsRevision = 0
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
    /// The Browse screen's rails. Rebuilt with the facets: a series, a tag
    /// or an arrival date cannot change with a page turn.
    public private(set) var rails: LibraryRails = .empty
    /// The Reading tab. Rebuilt whenever a position moves, because the
    /// Continue book and the order beneath it are what a position moves.
    public private(set) var readingHome: ReadingHome = .empty

    private let keychain: any TokenPersisting
    /// Where sign-out's broadcast goes. `.default` in the app; a test's own, so
    /// one suite's sign-out cannot clear another suite's state.
    private let notificationCentre: NotificationCenter
    /// The on-device catalogue. Present as soon as a server is chosen, so the
    /// shelf is populated before any request is made.
    public private(set) var store: LibraryStore?
    private var mutations: MutationQueue?
    public let reachability = Reachability()
    private var listeningProgressTask: Task<Void, Never>?
    /// Whether the fifteen-second position writer is armed.
    ///
    /// Internal rather than private for the same reason as `keepsScreenAwake`:
    /// a writer nothing re-arms is an hour of listening written nowhere, and
    /// the paths that drop one — a hand-off that failed, a stop, a start — are
    /// indistinguishable from outside unless the model can be asked.
    var isWritingListeningPosition: Bool { listeningProgressTask != nil }
    private var isConnecting = false
    /// Streams books to disk in the background. Created with the session, since
    /// it needs the server URL and the bearer token.
    public private(set) var downloads: DownloadManager?
    /// Queued writes still waiting for a connection, for the sync row.
    public private(set) var pendingWrites = 0

    /// `notificationCentre` is injectable for one reason: sign-out broadcasts a
    /// process-wide notification, and `PlaybackSettings` and `AskCoordinator`
    /// both observe it on the default centre with `object: nil` — neither is
    /// owned by an `AppModel`, which is why the message is a notification at
    /// all. swift-testing runs suites in parallel, so a test that signs out
    /// reached into unrelated suites and cleared their per-book styles, their
    /// volume trims and their whole question index mid-run. That is a plausible
    /// cause of `swift test` failing once with a single issue and passing on an
    /// identical re-run. A test hands over a centre of its own, and the message
    /// is then scoped to the instance under test without being weakened: it is
    /// still posted, and still assertable.
    public init(
        keychain: any TokenPersisting = KeychainStorage(),
        notificationCentre: NotificationCenter = .default,
    ) {
        self.keychain = keychain
        self.notificationCentre = notificationCentre
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

    /// The launch restore, started rather than awaited.
    ///
    /// Deliberately not bound to any view's lifetime, and that is the whole
    /// point. `restoreIfPossible` moves `phase` — `connect` sets `.signingIn`
    /// — and on the Mac and the television that phase change swaps the branch
    /// of the root `switch` the calling `.task` was attached to. SwiftUI tears
    /// the old branch down, the `.task` is cancelled, and the restore is
    /// killed by the very state change it just made. The reader then saw three
    /// `/api/v2/user` requests fail with `-999 cancelled` inside 153ms — both
    /// backoffs skipped, because a cancelled `Task.sleep` returns at once — and
    /// was told "Couldn't reach your server", a network diagnosis for an app
    /// that had hung up on itself.
    ///
    /// The phone never had this: `AppServices` already starts the restore in an
    /// unstructured `Task`. This gives the other two platforms the same thing.
    ///
    /// Once per launch. The guard also retires the accidental second attempt —
    /// the sign-in branch's own `.task` re-firing — that had been quietly
    /// papering over the first one being killed.
    public func startRestore() {
        guard restoreTask == nil else { return }
        restoreTask = Task { [weak self] in await self?.restoreIfPossible() }
    }

    /// Held so `startRestore` can tell "already ran" from "never ran". Never
    /// cancelled: nothing should ever cancel the launch restore, which is the
    /// bug this exists to close.
    private var restoreTask: Task<Void, Never>?


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

        // Cleared up front. Without this a failed connect to a *new* address
        // left the previous attempt's sentence on screen beside the previous
        // server's name, so the chooser described a server the reader had just
        // moved away from.
        loadError = nil
        let candidates = Self.candidateServerURLs(for: address)
        guard !candidates.isEmpty else {
            loadError = "That doesn't look like a server address."
            // `.chooseServer`, not left at `.launching`. Both of these returns
            // used to leave the phase where it started, and the launch path
            // renders that as a bare `Palette.paper` with no content and no
            // controls — so a stored address this cannot parse gave a blank app
            // on every launch, with the reason written to a `loadError` only
            // the library screen displays. Uninstalling was the way out.
            if phase == .launching { phase = .chooseServer }
            return
        }
        guard let url = await Self.firstReachable(of: candidates) else {
            loadError = "Couldn't reach a Storyteller server at that address."
            if phase == .launching { phase = .chooseServer }
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
        // Ratings come back with the cached shelf, so a rating set offline is
        // on screen at launch rather than only after a refresh succeeds.
        if let stored = try? await store?.ratings(), !stored.isEmpty { ratings = stored }
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
                // The same funnel `BookContentService.localURL(for:format:)`
                // uses. This was a second copy of the filename rule, which is
                // how a validated read path and an unvalidated write path came
                // to disagree about where a book lives.
                BookContentService.localURL(
                    in: BookContentService.defaultDirectory(),
                    bookUUID: job.bookUUID, format: job.format)
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
        guard let session else {
            // Not reachable through either route as they stand — both resolve a
            // server before offering a way in — but a token adopted with no
            // session went nowhere and said nothing, which is the same
            // "sign-in did nothing" the branches below were fixed for.
            IssaLog.error("adopted a token with no session")
            loadError = "Connect to your server before signing in."
            phase = .chooseServer
            return
        }
        await session.adopt(token: token)
        switch session.state {
        case let .signedIn(user):
            await handOverIfTheAccountChanged(to: user, on: session.serverURL)
            await enterLibrary()
        case let .failed(reason):
            // The grant worked and the token is in the keychain — only the
            // identity call failed. Saying so is the whole fix: this used to
            // leave `phase` at .signingIn, which renders as the blank server
            // form, so a successful sign-in looked like a silent failure.
            loadError = reason
            phase = .chooseServer
        default:
            // The same fault as `.failed` above, in the branch next door, left
            // there when that one was fixed. `.signedOut` is the state
            // `loadIdentity` sets when the server *refuses* a token — a real
            // outcome, and the one a browser callback carrying somebody else's
            // or a stale token produces — and it arrived here as a bare
            // `phase = .chooseServer`: no message, no log line, the chooser
            // simply reappearing. Indistinguishable from the app doing nothing.
            IssaLog.error("adopted token was not accepted", [
                "state": String(describing: session.state),
            ])
            loadError = "Your server didn't accept that sign-in. Try again, or use a device code."
            phase = .chooseServer
        }
    }

    /// The only binding available on a token that arrives through the browser
    /// route: is the identity it resolves to the identity this server was last
    /// signed in as?
    ///
    /// The callback carries no `state` and no nonce, and cannot — the server
    /// echoes nothing back, so there is nothing to bind at the moment it
    /// arrives. `ASWebAuthenticationSession` intercepts its callback scheme only
    /// from navigations inside its own web view, so over https there is no way
    /// in; over http, which this app still permits by decision, an on-path
    /// attacker can inject `302 Location: storyteller://x?token=…` into the
    /// login chain. This check does not prevent that. It bounds it.
    ///
    /// A mismatch is **not** refused. A second reader on a household iPad is
    /// entirely legitimate, and from here it is indistinguishable from an
    /// injected token. What a mismatch *is* is a fact about the state already
    /// in memory: the catalogue, the ratings, the download set, the high-water
    /// marks, the queued position writes and any pending deep link all belong
    /// to the previous account — and `enterLibrary` walked straight into them,
    /// so the arriving reader was shown the departing one's shelf until the
    /// first refresh returned, and the departing one's undrained writes were
    /// posted under the arriving one's token.
    private func handOverIfTheAccountChanged(to user: User, on server: URL) async {
        let previous = UserDefaults.standard.string(forKey: Self.accountKey(for: server))
        guard let previous, previous != user.id else { return }
        // Ids and the server, never the token. Worth a warning rather than an
        // info: on a shared device this is an ordinary hand-over, and on an
        // unencrypted network it is the only trace an injected token leaves.
        IssaLog.warning("adopted token resolves to a different account", [
            "server": server.absoluteString,
            "from": previous,
            "to": user.id,
        ])
        await clearAccountScopedState(nowPlaying: nowPlayingController)
    }

    /// Signs out and leaves nothing behind.
    ///
    /// - Parameter keepDownloads: books already on the device are expensive to
    ///   fetch again, so the choice is offered rather than assumed.
    public func signOut(keepDownloads: Bool = false, nowPlaying: NowPlayingController? = nil) async {
        // Before anything else, and before the state it acts on is torn down.
        // A removal still inside its undo window is a decision the reader has
        // already made; leaving it to a timer that fires after the account has
        // gone would delete a file belonging to whoever signs in next.
        commitPendingRemoval()
        await session?.signOut()
        await clearAccountScopedState(nowPlaying: nowPlaying)

        // What only a sign-out lets go of. A switch between accounts on this
        // same server keeps all three: the store file is per server, the
        // session is about to be reused, and the reader is going to a library
        // rather than back to the form.
        store = nil
        session = nil
        if !keepDownloads {
            // Through StorageRoot, or "delete my downloads" would look at
            // Application Support on an Apple TV and delete nothing.
            for folder in ["Books", "Audio"] {
                try? FileManager.default.removeItem(at: StorageRoot.directory(folder))
            }
            // The publisher faces those downloads left behind. Not `Fonts/`
            // itself: a face the reader imported lives at its root, this is
            // the only copy of it, and it belongs to them the way their
            // annotations do rather than to the account that is leaving.
            CustomFonts.removeAllExtracted()
        }
        phase = .chooseServer
    }

    /// Everything held in memory, on the lock screen or on the device that
    /// belongs to the account being left — and to no other.
    ///
    /// Shared by `signOut` and by an account *switch*: adopting a token whose
    /// identity is not the one this server was last signed in as. The two
    /// differ only in what they keep, and agree completely on what has to go,
    /// so they are one method rather than two lists. A second list written
    /// later would be missing fields, and every field missing from it is one
    /// account's data shown to another.
    private func clearAccountScopedState(nowPlaying: NowPlayingController?) async {
        // First, before anything suspends. This is the fence every detached
        // catalogue write checks, and it sat after two awaits — the server
        // sign-out and the store's DELETE — so a refresh resuming in that
        // window captured the old generation, passed every guard, and wrote
        // the departed account's catalogue back over the DELETE.
        catalogueGeneration += 1
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
        // keep narrating the departed account's library out loud.
        releaseAllReaders()
        // The catalogue belongs to the account, so it goes with it. Annotations
        // do not: they are device-local and this is their only copy.
        //
        // This clears the `mutation` table too, which is what stops the
        // departed account's undrained position writes being posted under the
        // arriving account's token.
        try? await store?.clearAccountData()
        mutations = nil
        // The high-water marks go too. They are keyed by book uuid, and the
        // same server hands the same uuids to a different account — so without
        // this, account A's finished book refuses every derived write account B
        // makes against it.
        positionGuards = [:]
        books = []
        rebuildDerived()
        // Both, or the next refresh would derive the visible set from the
        // departing account's disk reading.
        downloadedOnDisk = []
        downloadedUUIDs = []
        statuses = []
        ratings = [:]
        loadError = nil
        // Everything else keyed by a value the next account shares. The server
        // hands the same book uuids to a different reader, which is why
        // positionGuards is cleared two lines up — and `pendingBook` is a book
        // uuid, so a widget tap left unconsumed would open in the next
        // account's library.
        pendingBook = nil
        readerRequest = nil
        visibleReaderUUID = nil
        listeningError = nil
        notificationCentre.post(name: PlaybackSettings.signOutNotification, object: nil)

        // The account's transfers go with it. The manager itself stays: its
        // background session owns its identifier for the life of the process,
        // and tearing it down here made the session the next sign-in built
        // invalid from birth — its first task raised an uncatchable
        // `NSGenericException`. `connect` points this one at the new account,
        // and on a switch it needs no re-pointing: same server, and the token
        // provider reads the keychain, which now holds the arriving account's.
        downloads?.stop()
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
        // for up to 30 days after it stopped being the account signed in.
        await SpotlightIndex.clear()
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

    /// Bumped whenever the catalogue stops belonging to this account.
    ///
    /// A detached write that outlives its account is not a hypothetical: the
    /// one below took a full merged catalogue and could put it back after
    /// sign-out had deleted it.
    private(set) var catalogueGeneration = 0

    /// Re-seeds the write guards when the server's position moved backwards.
    ///
    /// `PositionGuard.decide` does re-baseline, but only for a `.chosen` write;
    /// nothing re-seeded the guard when `reconciled(with:)` legitimately adopted
    /// a *lower* server position. So after restarting a finished book on another
    /// device, pressing Play here — which produces `.derived` writes — failed
    /// the high-water test on every tick and returned before both the queue and
    /// the store, for the rest of the process. The widget went on advertising
    /// progress that was persisted nowhere, and only an explicit scrub could
    /// clear it.
    func reseedGuards(against catalogue: [Book]) {
        for book in catalogue {
            // Only the guard on the same clock as the stored position. The
            // guards are keyed by book *and* scale now (see writePosition), and
            // reseeding by book alone silently matched nothing at all -- which
            // would have looked exactly like reseeding working.
            guard let locator = book.position?.locator, let progress = locator.totalProgression
            else { continue }
            let key = Self.positionGuardKey(book.uuid, isAudioScaled: locator.isAudioScaled)
            guard let guardState = positionGuards[key], progress < guardState.highWater
            else { continue }
            // The hold travels with the mark. A re-seed answers "where is this
            // book on the server", which is a different question from "does
            // this app know where the listener was" — dropping `awaitingChoice`
            // here would have let the next fifteen-second tick through on a
            // resume nobody had steered.
            positionGuards[key] = PositionGuard(
                highWater: progress, duration: LibraryArrangement.duration(of: book),
                awaitingChoice: guardState.awaitingChoice)
        }
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
            reseedGuards(against: merged)
            rebuildDerived()
            statuses = fetchedStatuses
            // Reconciled against the queue, not assigned verbatim. A rating
            // changed offline is still pending, so taking the server's answer
            // wholesale put the old value back on screen — and the drain
            // kicked off below then removed it again a moment later.
            var mergedRatings = fetchedRatings
            for uuid in await pendingRatingBookUUIDs() {
                if let local = ratings[uuid] { mergedRatings[uuid] = local }
                else { mergedRatings[uuid] = nil }
            }
            ratings = mergedRatings
            loadError = nil
            IssaLog.info("library refreshed", ["books": String(fetched.count)])

            // Off the refresh gesture entirely: a full catalogue rewrite and a
            // serial drain of queued writes have no business holding the
            // spinner open.
            //
            // `weak self` for the store as well as the model. `store` used to
            // be captured by value, so `store = nil` in signOut did not stop
            // this — sign-out suspends on its network POST, this Task
            // interleaved, `clearAccountData()` ran its DELETE, and then a full
            // catalogue was written back. The next launch read it with only a
            // `hasCredential` gate in front, which is the leak that gate exists
            // to prevent.
            let generation = catalogueGeneration
            let ratingsToPersist = mergedRatings
            Task { [weak self] in
                guard let self, self.catalogueGeneration == generation else { return }
                try? await self.store?.replaceCatalogue(merged)
                // Behind the same fence as the catalogue. This write sat in
                // the body above, outside every generation check, and the
                // `rating` table has no account column — so a refresh racing
                // a sign-out persisted the departed account's ratings for the
                // next one to read back at launch.
                guard self.catalogueGeneration == generation else { return }
                try? await self.store?.replaceRatings(ratingsToPersist)
                guard self.catalogueGeneration == generation else { return }
                await self.drainPendingWrites()
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
    ///
    /// - Parameter waitingForInFlight: wait for a drain already running rather
    ///   than declining. `true` only from `flushOpenReaders`, the exit path,
    ///   where declining meant sending nothing and there is no next enqueue to
    ///   try again.
    public func drainPendingWrites(waitingForInFlight: Bool = false) async {
        guard let session, let mutations else { return }
        _ = await MutationDrain(queue: mutations, client: session.client)
            .drain(waitingForInFlight: waitingForInFlight)
        pendingWrites = (try? await mutations.count) ?? 0
    }

    /// Books whose rating is still waiting to reach the server.
    ///
    /// A refresh that assigns `myRatings()` verbatim overwrites a change the
    /// queue has not drained yet, so the old value flashes back on screen and
    /// is then removed again when the drain lands.
    private func pendingRatingBookUUIDs() async -> Set<String> {
        guard let mutations else { return [] }
        let rows = (try? await mutations.pending()) ?? []
        return Set(rows.filter { $0.kind == .rating }.map(\.bookUUID))
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

    /// Author name to their books, for the book screen's "More by…" rail.
    ///
    /// `LibraryDerivation.byAuthor` builds this by grouping the whole library,
    /// and it is a computed property — so reading it from a view body grouped
    /// the whole library, and `relatedRails` read two of them. That body
    /// re-runs on every debounced position save, which while narrating is
    /// every two seconds. Authors do not change with a page turn.
    public private(set) var booksByAuthor: [String: [Book]] = [:]
    public private(set) var booksByNarrator: [String: [Book]] = [:]

    /// The catalogue by uuid.
    ///
    /// `BookDetailView` re-resolves its book from `app.books` on every line it
    /// draws — deliberately, so status, rating and progress stay honest — and
    /// that was a linear scan of the library, fifty-two times per body. Rebuilt
    /// with the position-dependent state rather than with the facets, because
    /// the whole point of re-resolving is that a position change must show.
    public private(set) var bookByUUID: [String: Book] = [:]

    /// Recomputes everything derived from the catalogue.
    func rebuildDerived() {
        facets = LibraryFacets(books: books, downloadedUUIDs: downloadedUUIDs)
        rails = LibraryRails(books: books)
        let derivation = LibraryDerivation(books: books)
        booksByAuthor = derivation.byAuthor
        booksByNarrator = derivation.byNarrator
        rebuildAfterPositionChange()
    }

    /// The part of the above a position can move: the Continue card, the
    /// Reading tab's order, and the arrangement when it sorts by recency or
    /// progress. The facets and the rails — shelves, tags, series, what is
    /// downloaded — cannot change with a page turn, and this path runs on
    /// every debounced save while narrating.
    private func rebuildAfterPositionChange() {
        readingHome = ReadingHome(books: books, rails: rails)
        bookByUUID = Dictionary(books.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        rebuildArranged()
    }

    /// Whether the Library shows its browse rails or the flat, sortable grid.
    ///
    /// On the model rather than in the view, because the Reading tab's "See
    /// all" and every rail's "See all" have to set it and the Library has to
    /// notice. Deliberately not a field of `LibraryArrangement`: a mode flip
    /// must not persist and re-sort the grid.
    public enum LibraryMode: String, Sendable { case browse, all }

    public var libraryMode: LibraryMode = AppModel.restoredLibraryMode() {
        didSet { UserDefaults.standard.set(libraryMode.rawValue, forKey: AppModel.libraryModeKey) }
    }

    private static let libraryModeKey = "issa.library.mode"

    private static func restoredLibraryMode() -> LibraryMode {
        UserDefaults.standard.string(forKey: libraryModeKey).flatMap(LibraryMode.init) ?? .browse
    }

    /// Opens the flat grid on one shelf — what every "See all" does.
    ///
    /// One assignment to `arrangement`, so its observer stores and re-sorts
    /// once rather than once per field. Fields not named keep their values,
    /// except the tags: a shelf asked for by name is that shelf, not that
    /// shelf narrowed by whatever tags were last picked.
    public func showAllBooks(
        shelf: LibraryArrangement.Shelf, tags: Set<String> = [], sort: LibraryArrangement.Sort? = nil,
    ) {
        arrangement = LibraryArrangement(
            sort: sort ?? arrangement.sort, ascending: sort == nil ? arrangement.ascending : false,
            shelf: shelf, tags: tags,
        )
        libraryMode = .all
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
        removeDownload(bookUUID: book.uuid, format: format)
    }

    /// The same, named by uuid, for a file whose book is no longer in the
    /// catalogue.
    ///
    /// Those files are precisely the ones with no row on any screen: the
    /// storage headline counts the whole Books directory while every band sums
    /// books still in the library, so a download whose book has left was in the
    /// total, absent from the bar, and impossible to delete from the interface
    /// at all. Nothing in a removal ever needed the `Book`.
    public func removeDownload(bookUUID: String, format: BookContentService.Format) {
        // Before a byte is touched, and before `BookContentService.removeDownload`
        // in particular: the EPUB a reader is narrating from goes in that call,
        // not only the derived files below it.
        stopPlayback(of: bookUUID)
        let job = DownloadManager.Job(bookUUID: bookUUID, format: format)
        // Cancel, then clear — and both before the file is touched.
        //
        // `clear` only forgets the state row; the transfer carries on, and when
        // it lands `didFinishDownloadingTo` moves the file into place. So
        // removing a download that was still arriving deleted nothing and the
        // book reappeared a minute later. The Downloads section lists in-flight
        // and on-disk items together, which puts that one tap away.
        downloads?.cancel(job)
        downloads?.clear(job)
        // No session needed: this is a file being deleted, and requiring an
        // `APIClient` for it is why a reader who had signed out keeping their
        // downloads could not remove one.
        BookContentService.removeDownload(bookUUID: bookUUID, format: format)
        releaseDerivedFiles(for: bookUUID, format: format)
        refreshDownloadedSet()
    }

    /// Stops a transfer that has not finished, and takes nothing else with it.
    ///
    /// The X on a transfer row called `removeDownload`, which is a *book*
    /// removal: it released the publisher face and the question index as well.
    /// So cancelling a download started by mistake destroyed derived data
    /// belonging to a different edition of that book already on the device —
    /// the reader tapped a cross on a progress bar and lost the index of the
    /// copy they were reading.
    ///
    /// What a cancel legitimately touches is this job: the transfer, its row,
    /// and its own file if one somehow landed. `DownloadManager.cancel` fences
    /// the job's in-flight completion, so a file that arrives immediately after
    /// this is discarded rather than moved into place.
    ///
    /// The file is removed rather than assumed absent because a transfer can
    /// complete between the tap and this line, and a download the reader
    /// stopped must not be left on the device unmentioned.
    public func cancelDownload(_ job: DownloadManager.Job) {
        downloads?.cancel(job)
        downloads?.clear(job)
        BookContentService.removeDownload(bookUUID: job.bookUUID, format: job.format)
        refreshDownloadedSet()
    }

    /// Everything a download leaves behind on disk once its file has gone.
    ///
    /// Idempotent — every step is "remove it if it is there" — because it runs
    /// from `removeDownload` and again from the reconciliation sweep below,
    /// and on the ordinary path it runs from both.
    ///
    /// Called *after* the file has been deleted, which is what lets the check
    /// below be a question about the disk rather than about intent.
    private func releaseDerivedFiles(for bookUUID: String, format: BookContentService.Format?) {
        // Narration extracted from the read-along for playback. Keyed on the
        // format when one is named, because it is derived from that file
        // specifically; the sweep names none, because by then it cannot tell
        // which file went.
        if format == nil || format == .readaloud {
            AudioExtraction.removeExtractedAudio(for: bookUUID)
        }

        // The remaining two belong to the book, not to the edition that just
        // went, and this method deleted them unconditionally. A book with a
        // read-along *and* an ebook on the device therefore lost its publisher
        // face and its whole question index when either one was removed — data
        // derived from the copy still sitting on disk, and discovered only on
        // the next open, when the book was set in the fallback face and the
        // questions it had been indexed for started again from nothing.
        //
        // `DownloadsInventory.departed` states the rule this has to honour: "a
        // book that lost one of two editions has not departed". So the disk is
        // asked, and these go only when the last edition carrying the book's
        // text has gone. The sweep reaches here for books with no file left at
        // all, so it is unaffected.
        guard !BookContentService.hasDownloadedText(bookUUID: bookUUID) else { return }

        // The publisher's own face, extracted on every open of a book that
        // ships one. Nothing removed these: `Fonts/<uuid>/` accumulated one
        // directory per book for the life of the install, uncounted by the
        // storage screen and unreachable from the interface. Only the
        // subdirectory — faces at the root of `Fonts/` were imported by the
        // reader and are theirs.
        CustomFonts.removeExtracted(bookUUID: bookUUID)
        #if !os(tvOS)
        // The question index is derived from the file that has just gone, so it
        // is orphaned the moment this returns — and it is text out of the
        // reader's book sitting in a database nothing will ever open again.
        ask?.remove(bookUUID: bookUUID)
        #endif
    }

    /// Silences whatever is playing a book whose files are about to be deleted.
    ///
    /// The extracted narration is played straight out of the directory
    /// `releaseDerivedFiles` removes, through a `.files` source, and nothing
    /// asked whether anything was reading from it. The current item played on
    /// and the next `advance()` found the file gone: mid-drive the book stopped
    /// dead, leaving a log line, a Now Playing tile for a book that would not
    /// resume, and no transport control anywhere that could put it right.
    ///
    /// The same two lines sign-out uses, for the same reason — see
    /// `clearAccountScopedState` — and both are needed: an audiobook plays
    /// through `listening`, a read-along through the reader's own coordinator,
    /// and a removal cannot know which the listener chose.
    private func stopPlayback(of bookUUID: String) {
        if listeningBook?.uuid == bookUUID { stopListening(nowPlaying: nowPlayingController) }
        if narratingBookUUID == bookUUID { stopNarration() }
    }

    /// Re-reads which books have files on disk, and cleans up after any that
    /// went without being removed.
    ///
    /// Called when a download finishes, when one is deleted, on sign-out, when
    /// the app comes forward — a transfer can complete while backgrounded — and
    /// when a car connects.
    /// A directory this cannot read leaves both the set and the sweep alone.
    /// The read used to be coalesced to an empty set, and every caller below
    /// then agreed that the reader had deleted their entire library: the shelf
    /// emptied, and `reconcileDownloads` deleted every book's question index,
    /// extracted narration and publisher font, none of which comes back. An
    /// unreadable directory is a fact about this moment, not about the disk —
    /// the last set it did read is a better answer than a wrong one, and the
    /// next refresh is a few seconds away.
    public func refreshDownloadedSet() {
        let previous = downloadedOnDisk
        guard let current = try? BookContentService.downloadedBookUUIDs() else {
            IssaLog.warning("could not read the downloads directory; keeping the last set",
                            ["kept": String(previous.count)])
            return
        }
        downloadedOnDisk = current
        applyPendingRemovalToDownloadedSet()
        // After a successful read, so a screen does not re-scan a directory
        // this call could not read either.
        downloadsRevision &+= 1
        // Against the disk's own reading, both times. The sweep asks which
        // books lost their last *file*, and a removal inside its undo window has
        // deliberately lost none yet — reconciling against the set the window
        // has already been subtracted from would delete the very derived files
        // the deferral exists to keep recoverable.
        reconcileDownloads(previouslyDownloaded: previous)
    }

    /// Recomputes `downloadedUUIDs` from the disk's answer and the open window.
    ///
    /// Called whenever either changes. The pending removal costs at most three
    /// `stat`s and only while a toast is up, which is the price of the shelf and
    /// the car agreeing with the screen the reader is looking at.
    private func applyPendingRemovalToDownloadedSet() {
        guard let pending = pendingRemoval else {
            downloadedUUIDs = downloadedOnDisk
            return
        }
        let remaining = BookContentService
            .downloadedFormats(bookUUID: pending.bookUUID)
            .subtracting([pending.format])
        downloadedUUIDs = remaining.isEmpty
            ? downloadedOnDisk.subtracting([pending.bookUUID])
            : downloadedOnDisk
    }

    /// Whether this edition is on the device and staying there.
    ///
    /// The per-edition question, which `downloadedUUIDs` cannot answer: it is
    /// keyed by book, and a book with a read-along and an ebook on the device is
    /// one entry. Everything in the app that asks about a *format* should ask
    /// here rather than `BookContentService.isDownloaded`, which knows only
    /// about the filesystem and so cannot see a removal that has been decided
    /// but not yet carried out.
    public func isDownloaded(_ book: Book, format: BookContentService.Format) -> Bool {
        isDownloaded(bookUUID: book.uuid, format: format)
    }

    public func isDownloaded(bookUUID: String, format: BookContentService.Format) -> Bool {
        guard pendingRemoval?.bookUUID != bookUUID || pendingRemoval?.format != format
        else { return false }
        return BookContentService.downloadedFormats(bookUUID: bookUUID).contains(format)
    }

    /// Runs the rest of a removal for every book whose files went behind the
    /// app's back.
    ///
    /// `downloadedUUIDs` is read from the disk rather than maintained, because
    /// a download can leave without this app deleting it. On an Apple TV every
    /// download lives in Caches, which the system may reclaim under storage
    /// pressure — that is the platform's contract, not a choice (see
    /// `StorageRoot`). A restore, a failed move, a file removed underneath us:
    /// same shape. In each case the extracted narration, the publisher's font
    /// and the question index stay behind, and the index in particular is the
    /// text of the reader's book — which PRIVACY.md promises is "deleted when
    /// you delete the download or sign out".
    ///
    /// It is also what keeps a car honest. CarPlay is its own scene and can be
    /// alive while the phone app never goes active, and the offline shelf
    /// filters on nothing but this set: the car offered a book whose file had
    /// gone, playback fell back to streaming, and in a tunnel that is silence.
    ///
    /// Takes the previous set rather than keeping one of its own, so there is
    /// exactly one definition of "what is downloaded" and it is the disk.
    func reconcileDownloads(previouslyDownloaded previous: Set<String>) {
        let departed = DownloadsInventory.departed(from: previous, to: downloadedUUIDs)
        guard !departed.isEmpty else { return }
        for bookUUID in departed {
            // The sweep deletes the same narration directory a removal does, so
            // it needs the same courtesy: a book whose file left behind the
            // app's back can still be the one playing. See `stopPlayback`.
            stopPlayback(of: bookUUID)
            releaseDerivedFiles(for: bookUUID, format: nil)
        }
        IssaLog.info("reconciled downloads", ["gone": String(departed.count)])
    }

    // MARK: - Removing a download the reader can take back

    /// A removal waiting out its undo window.
    public struct PendingRemoval: Identifiable, Sendable, Equatable {
        public let bookUUID: String
        public let format: BookContentService.Format
        /// For the toast — "Removed Dracula" — because the row it came from is
        /// off the screen by the time the toast is drawn.
        public let title: String
        public var id: String { "\(bookUUID)-\(format.rawValue)" }
    }

    /// The one removal that can still be taken back, if any.
    ///
    /// One at a time, like Mail's undo send: a second removal commits the first
    /// rather than queueing, because a toast that could mean any of three rows
    /// is not an undo.
    ///
    /// The `didSet` rather than a call at each of the four sites that assign
    /// this. Missing one is precisely the bug being fixed here: `pendingRemoval`
    /// was honoured by the rows of one section and by nothing else, so every
    /// other surface in the app spent the window offering a file that was about
    /// to be deleted.
    public private(set) var pendingRemoval: PendingRemoval? {
        didSet { applyPendingRemovalToDownloadedSet() }
    }
    private var pendingRemovalTask: Task<Void, Never>?

    /// How long the toast stands.
    public static let removalUndoWindow: Duration = .seconds(6)

    /// Hides an edition now and deletes it when the undo window closes.
    ///
    /// Deferred rather than undone, and that is the whole point. The section
    /// this serves must offer an undo *and* must never start a download —
    /// re-fetching 612 MB of read-along over cellular because a thumb brushed a
    /// row is not an undo — so the only honest way to have both is for the
    /// bytes to still be there while the toast is up.
    ///
    /// The timer lives here rather than in the view because the view is a row
    /// in a `LazyVStack`: scroll it off screen, or leave the tab, and a task
    /// owned by it is cancelled with it — leaving the file on disk and the
    /// reader believing it gone.
    ///
    /// If the app is killed inside the window the removal simply does not
    /// happen and the row is back next launch. That is the safe direction: a
    /// book still there costs storage, a book deleted by a crash costs a
    /// download.
    public func removeDownload(
        bookUUID: String, format: BookContentService.Format, title: String,
        undoWindow: Duration = AppModel.removalUndoWindow,
    ) {
        commitPendingRemoval()
        pendingRemoval = PendingRemoval(bookUUID: bookUUID, format: format, title: title)
        pendingRemovalTask = Task { [weak self] in
            try? await Task.sleep(for: undoWindow)
            guard !Task.isCancelled else { return }
            self?.commitPendingRemoval()
        }
    }

    /// Takes back a pending removal when the very edition it is holding starts
    /// downloading again.
    ///
    /// Nothing cleared `pendingRemoval` when a transfer began, so a download
    /// restarted inside the six-second window was cancelled and deleted the
    /// moment the window closed — by a timer armed before the reader changed
    /// their mind. On screen it looked like a download that simply stopped:
    /// the row appeared, the bar moved, and then both were gone with no error
    /// anywhere, because from the app's point of view nothing had failed.
    ///
    /// Starting a download of an edition is the clearest possible statement
    /// that it should be on the device, so it wins over a removal that has not
    /// happened yet. Only for the same job: a removal of one book has nothing
    /// to say about a download of another.
    private func cancelPendingRemoval(matching job: DownloadManager.Job) {
        guard pendingRemoval?.bookUUID == job.bookUUID,
              pendingRemoval?.format == job.format else { return }
        undoPendingRemoval()
    }

    /// Puts the row back. Nothing was deleted, so there is nothing to fetch.
    public func undoPendingRemoval() {
        pendingRemovalTask?.cancel()
        pendingRemovalTask = nil
        pendingRemoval = nil
    }

    /// Deletes what the window was holding, now.
    ///
    /// Called when the window closes, when a second removal displaces this one,
    /// and by anything that must not leave a half-done removal behind.
    public func commitPendingRemoval() {
        pendingRemovalTask?.cancel()
        pendingRemovalTask = nil
        guard let pending = pendingRemoval else { return }
        pendingRemoval = nil
        removeDownload(bookUUID: pending.bookUUID, format: pending.format)
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

    /// Which surface is driving playback right now.
    ///
    /// Platform-neutral on purpose: only the iOS target has a CarPlay scene, so
    /// only it ever pushes `.carPlay` in, and every other target keeps the
    /// `.phone` default and gets the ordinary behaviour rather than a `#if`
    /// around the decision that reads it.
    public private(set) var controlSurface: ControlSurface = .phone

    /// Pushed in by the CarPlay bridge as the car comes and goes.
    ///
    /// The car going away is itself a reason to reconsider the hand-off: the
    /// driver has parked, and if the reader is already on screen the book
    /// should move to the page rather than carry on through the phone's
    /// speaker.
    public func setControlSurface(_ surface: ControlSurface) {
        guard controlSurface != surface else { return }
        controlSurface = surface
        if surface == .phone { considerListeningHandoff(trigger: .carDisconnected) }
    }

    /// Re-entrancy guard. The four triggers overlap — waking a phone onto an
    /// open reader fires three of them within a frame — and a second pass while
    /// the first is awaiting an audio load would stop the engine out from under
    /// it.
    private var isHandingOff = false

    /// Cheap enough to call from anywhere a trigger fires, which is the point:
    /// the decision itself is a ladder in `ListeningHandoff`, and the call
    /// sites should not each carry a copy of "is anything even playing".
    private func considerListeningHandoff(trigger: ListeningHandoff.Trigger) {
        // `isStartingListening` as well as `isHandingOff`, because the two move
        // the same slot from opposite ends. `attachListening` publishes
        // `listening` and then suspends twice — a resume to resolve, an
        // AVFoundation item to load — and a hand-off firing in that window
        // stops a coordinator the start is still holding. The start re-checks
        // the slot after every await; this is the other half, so the two cannot
        // interleave in the first place.
        guard listening != nil, !isHandingOff, !isStartingListening else { return }
        Task { await handOffListeningToReader(trigger: trigger) }
    }

    /// Moves a book playing through the audiobook engine onto the reader that
    /// is looking at it.
    ///
    /// The end of a drive. `AudiobookCoordinator` is what CarPlay and the lock
    /// screen start, and for a downloaded read-along it plays the EPUB's own
    /// narration chunks — so it knows exactly where it is, and the page knows
    /// nothing. Picking the phone up used to leave the reader sitting an hour
    /// behind the voice coming out of it. See `ListeningHandoff` for the ladder
    /// and for why every rung of it is somebody's ordinary Tuesday.
    ///
    /// - Returns: what was decided, so a test can name it. Callers that just
    ///   want the behaviour ignore it.
    @discardableResult
    func handOffListeningToReader(
        trigger: ListeningHandoff.Trigger,
    ) async -> ListeningHandoff.Decision {
        guard !isHandingOff else { return .skip(.alreadyHandingOff) }
        isHandingOff = true
        defer { isHandingOff = false }

        let coordinator = listening
        let model = visibleReaderUUID.flatMap { readers[$0] }
        // The audio clock's own guard, asked rather than re-derived: it is
        // `prepareListeningGuard` that decided this book started from nowhere,
        // and a second copy of that judgement here is a second thing to keep in
        // step. Held means the car is playing from zero because nothing could be
        // resolved, so its anchor says nothing about the novel — see
        // `ListeningHandoff.Skip.resumeUnresolved`.
        let held = listeningBook.map {
            positionGuards[Self.positionGuardKey($0.uuid, isAudioScaled: true)]?
                .awaitingChoice ?? false
        } ?? false
        let decision = ListeningHandoff.decide(
            listeningBookUUID: listeningBook?.uuid,
            visibleBookUUID: visibleReaderUUID,
            surface: controlSurface,
            isForeground: isForeground,
            resumeWasUnresolved: held,
            anchor: coordinator?.currentAnchor,
            isPlaying: coordinator?.player.isPlaying ?? false,
            package: model?.package,
            timeline: model?.timeline,
            hasReadalong: model?.readalong != nil,
        )
        guard case let .handOff(target) = decision else {
            if case let .skip(reason) = decision, reason != .notListening {
                // `notListening` is the resting state — three of the four
                // triggers fire on every wake — so logging it would bury the
                // eight reasons worth reading.
                IssaLog.info("listening hand-off skipped", [
                    "book": listeningBook?.title ?? "none",
                    "trigger": trigger.rawValue, "reason": reason.rawValue,
                ])
            }
            return decision
        }
        // Unreachable: `.handOff` needs an anchor, which needs a coordinator,
        // and a package, which needs a model. Spelled out rather than forced.
        guard let coordinator, let model, let book = listeningBook else { return decision }

        // Before anything moves. The fifteen-second writer is bound to the
        // audiobook's clock, and leaving it running while the read-along takes
        // the book over means two engines writing positions for one novel.
        listeningProgressTask?.cancel()
        listeningProgressTask = nil
        coordinator.player.pause()

        let took = await model.resumeNarration(at: target.entry, playing: target.wasPlaying)
        guard took else {
            // The sentence's audio is not on disk. Nothing moved, and the car
            // engine still knows exactly where it is — so give the book back to
            // it rather than leaving a listener in silence with a page that did
            // not turn either.
            IssaLog.warning("listening hand-off failed", [
                "book": book.title, "trigger": trigger.rawValue,
                "reason": "audioFileMissing", "fragment": target.entry.fragmentID,
                "audioHref": target.entry.audioHref,
            ])
            if target.wasPlaying {
                coordinator.player.play()
            }
            // The writer, whatever the car was doing — and this used to be
            // inside the branch above. A *paused* car whose hand-off failed was
            // left with `listening` still installed, Now Playing still attached
            // and nothing writing positions at all: neither `startListening`'s
            // same-book fast path nor a lock-screen play re-arms it, so an hour
            // of listening from that pause onwards was written nowhere. It
            // costs nothing to arm on a paused book, because the loop only
            // writes when the progress actually moved.
            watchListeningProgress(book: book, coordinator: coordinator)
            return .skip(.audioFileMissing)
        }

        // Explicitly, and not only on the playing path. On that path
        // `play(from:)` has already driven the rate observer through
        // `narrationDidStart`; on the paused path `prepare(at:)` changes no
        // rate, so nothing had run at all.
        //
        // This used to be a bare `stopListening(nowPlaying: nowPlayingController)`,
        // which does take the paused audiobook off Now Playing — and takes the
        // book off everything else with it. `narratingBookUUID` was still nil,
        // so `playback` and `playbackBook` both went nil too: no mini bar, no
        // player sheet, no sleep timer, and a car whose `playingBookUUID`,
        // chapters and current chapter had all gone empty. The driver who
        // parked and paused got the right page and not one transport control
        // anywhere.
        //
        // `narrationDidStart` is exactly the transfer that was missing: it
        // pauses any other narrating book, calls `stopListening(nowPlaying: nil)`
        // — deliberately *without* the controller, so Now Playing is handed
        // over rather than stripped — claims `narratingBookUUID`, attaches Now
        // Playing to the reader's own coordinator and recomputes the display
        // hold. Every one of its guards passes here, and on the playing path it
        // has already run, where its first guard makes this a no-op.
        narrationDidStart(for: book.uuid)
        // Defensive only, now: `narrationDidStart` has emptied the slot on both
        // paths. Kept because a coordinator left in it would own the lock
        // screen for a book the reader is now narrating.
        if listening != nil { stopListening(nowPlaying: nowPlayingController) }

        IssaLog.info("listening handed off to reader", [
            "book": book.title, "trigger": trigger.rawValue,
            "fragment": target.entry.fragmentID,
            "chapter": String(target.spineIndex),
            "atOffset": String(format: "%.1f", target.anchor.offset),
            "wasPlaying": String(target.wasPlaying),
        ])
        // The read-along may now be narrating a visible page, which is the one
        // combination that holds the display awake.
        updateScreenAwake()
        return decision
    }

    /// Puts a coordinator in the listening slot and nothing else.
    ///
    /// A test seam. `startListening` fetches a manifest, resolves a resume
    /// point and claims Now Playing before it gets here, none of which a test
    /// about the hand-off has any use for — and the alternative is a suite that
    /// needs a server to assert what happens when a car is unplugged.
    func installListening(_ coordinator: AudiobookCoordinator, book: Book) {
        listening = coordinator
        listeningBook = book
    }

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
        // Both directions: a reader appearing over running narration is what
        // takes the hold, and one being dismissed is what gives it back.
        updateScreenAwake()
        // A reader arriving on the book the car is playing is the commonest way
        // a drive ends.
        if visible { considerListeningHandoff(trigger: .readerVisible) }
    }

    /// Whether the app is frontmost, pushed in by each target's scene-phase
    /// handler.
    ///
    /// Not derivable here: `AppModel` is not a view and has no `scenePhase`,
    /// and this is the one input to `ScreenAwake` it cannot see for itself. It
    /// starts true because the model is built while a scene is coming up, and a
    /// launch that never reported would otherwise be treated as backgrounded
    /// for the life of the process.
    private var isForeground = true

    /// The single holder of the display assertion. See `ScreenAwakeAssertion`
    /// for why there is exactly one, and `ScreenAwake` for the decision it
    /// applies.
    private let screenAwake = ScreenAwakeAssertion()

    /// Whether the display is being held awake for a read-along right now.
    ///
    /// Internal rather than private so `IssaSharedTests` can assert the release
    /// paths — a keep-awake nothing releases is a flat battery, which is the
    /// worse of the two bugs on offer here.
    var keepsScreenAwake: Bool { screenAwake.isHeld }

    /// Told when the app goes to and comes back from the background.
    ///
    /// The reader is a full-screen cover on iOS and being backgrounded does not
    /// dismiss it — the same fact `flushOpenReaders()` exists for — so without
    /// this a phone pocketed mid-read-along would go on holding its own display
    /// awake until the book ended.
    public func setForeground(_ foreground: Bool) {
        guard isForeground != foreground else { return }
        isForeground = foreground
        updateScreenAwake()
        // The phone being picked up, with the reader already where it was left.
        if foreground { considerListeningHandoff(trigger: .foreground) }
    }

    /// Recomputes whether the display should be held awake, and holds or
    /// releases it.
    ///
    /// Called from every place any of the four inputs can move:
    /// `setReaderVisible`, `setForeground`, `stopNarration`,
    /// `narrationDidStart`, and the rate observer installed in
    /// `reader(for:session:)` — which is the one that catches a pause,
    /// whichever surface asked for it, the sleep timer included.
    private func updateScreenAwake() {
        // `listening` is checked rather than assumed away: an audiobook and a
        // read-along cannot both be audible (`startListening` stops narration
        // first), but the decision must not rest on that invariant holding
        // somewhere else in the file.
        let narrated = listening == nil ? narratingBookUUID : nil
        screenAwake.apply(ScreenAwake.shouldKeepAwake(
            isPlaying: playback?.player.isPlaying ?? false,
            isReaderVisible: visibleReaderUUID != nil,
            followsText: narrated != nil && narrated == visibleReaderUUID,
            isForeground: isForeground,
        ))
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

    #if !os(tvOS)
    /// The question machinery, handed over at launch for the same reason and on
    /// the same terms: deleting a download has to take that book's index with
    /// it, and this object is not the owner of either.
    weak var ask: AskCoordinator?
    #endif

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
        model.recordAudioAnchor = { [weak self] anchor in
            try? await self?.store?.setAudioAnchor(anchor, forBook: bookUUID)
        }
        model.loadAudioAnchor = { [weak self] in
            try? await self?.store?.audioAnchor(forBook: bookUUID)
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
                guard let self else { return }
                if rate > 0 { narrationDidStart(for: bookUUID) }
                // Not inside the `rate > 0` branch, which is what this observer
                // used to be entirely: a rate of zero is the *release* signal,
                // and it is the only one that reaches every way a read-along
                // stops — the reader's own button, the player sheet, a headphone
                // click, a phone call, a lost route, and the sleep timer's
                // `pause()`, which is the case a reader who set one most cares
                // about. `AudioPlayer.pause()` writes `isPlaying` before it
                // notifies, so the value read here is already the new one.
                updateScreenAwake()
            }
            // On a cold open the extraction finishes long after the screen
            // appeared, so the reader was not yet somewhere the car could hand
            // a book to when `readerVisible` fired.
            self?.considerListeningHandoff(trigger: .readerReady)
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
        await drainPendingWrites(waitingForInFlight: true)
        // The log too, and here rather than in each scene-phase handler,
        // because all three platforms already route their exit through this
        // one method — which is the arrangement `TerminationDelegate` exists to
        // guarantee. `IssaLog.append` buffers and flushes on a utility-priority
        // detached task, so the entries immediately before a suspension the
        // system then kills are exactly the ones that never reached the file:
        // the entries the log exists to capture. Awaited off the main actor:
        // the flush is lock-held file I/O, and this runs inside the background
        // assertion and the terminate deadline.
        await IssaLog.flush()
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
        // The pause above already fired the rate observer, but this runs after
        // `narratingBookUUID` was cleared, and that is the field the decision
        // reads. Idempotent, so the second call costs nothing.
        updateScreenAwake()
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
        // `narratingBookUUID` has just moved, and it is half of `followsText`.
        // The other half — a reader on screen for this same book — is normally
        // already true, because this is reached by a reader pressing play.
        updateScreenAwake()
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
        let content = BookContentService(client: session.client)
        // An aligned read-along already on the device plays from its *own*
        // narration chunks, through a manifest synthesised over them.
        //
        // This is the whole fix for the car. The server's manifest for the same
        // book lists the original upload — one file named after the book —
        // while everything this app has ever stored about it names the EPUB's
        // chunks, so `AudioAnchor` matched nothing, the resume ladder ran out,
        // and the drive started at chapter one. Playing the chunks the anchor
        // already names means there is nothing left to match: the two engines
        // share a track list by construction.
        //
        // Downloaded only. Streaming a book chunk by chunk is a different
        // feature, and this path is exactly as offline as the read-along it
        // borrows the audio from.
        if book.readaloud?.isAligned == true, isDownloaded(book, format: .readaloud),
           let built = await synthesisedListening(for: book, content: content) {
            let attached = await attachListening(
                manifest: built.manifest, source: .files(built.files),
                chapters: built.chapters, timeline: built.timeline,
                manifestKind: .synthesised,
                book: book, nowPlaying: nowPlaying, settings: settings)
            // `.wouldNotPlay` is the only outcome with anywhere left to go. A
            // start that worked is finished, and a slot that changed hands
            // belongs to whatever took it — trying the server's manifest there
            // would stop the read-along a hand-off has just begun.
            guard attached == .wouldNotPlay else { return }
            // The chunks are on disk and the manifest built over them, and they
            // still would not load — a half-deleted extraction is the ordinary
            // way. The server has the original upload, so the book is not out
            // of options: falling back is what this path already does when the
            // manifest cannot be *built*, and a manifest that builds and then
            // will not play is the same outcome arriving one step later.
            IssaLog.warning("chunk playback would not start; trying the server's manifest", [
                "book": book.title,
            ])
            // The coordinator that would not play still holds Now Playing and
            // its own rate observer, and the fall-back is about to install
            // another. The same call the "different book already playing"
            // branch above makes, for the same reason.
            stopListening(nowPlaying: nowPlaying)
            // Cleared because this is a second genuine attempt and CarPlay
            // reads `listeningError` back as the outcome of the whole call.
            // Whatever happens below will speak for itself.
            listeningError = nil
        }
        let service = AudiobookService(client: session.client, baseURL: url, tokens: session.tokenProvider)
        do {
            let manifest = try await service.manifest(for: book.uuid)
            guard !manifest.playableTracks.isEmpty else {
                listeningError = "This audiobook has no playable tracks on the server."
                return
            }
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
            //
            // Through the model, so an audiobook inside its undo window is
            // streamed rather than played from a file about to be deleted.
            let playableAsOneFile = manifest.playableTracks.count == 1
                && isDownloaded(book, format: .audiobook)
            let source: AudiobookCoordinator.Source = playableAsOneFile
                ? .local(content.localURL(for: book, format: .audiobook))
                : .streaming(
                    base: service.trackBase(for: book.uuid),
                    cookies: await service.playbackCookies(for: book.uuid),
                )
            let attached = await attachListening(
                manifest: manifest, source: source, chapters: [], timeline: nil,
                manifestKind: .original,
                book: book, nowPlaying: nowPlaying, settings: settings)
            // A start that produced no audio must not leave the book sitting in
            // the listening slot. `declined` has already set `listeningError`,
            // which is what CarPlay reads back — but `playingBookUUID`, the
            // mini bar and the lock screen all read `listeningBook`, and a
            // coordinator holding nothing would keep claiming the book until
            // the next start. There is nowhere left to fall back to here: this
            // *is* the fall-back.
            if attached == .wouldNotPlay { stopListening(nowPlaying: nowPlaying) }
        } catch {
            IssaLog.failure("start listening", error, ["book": book.title])
            listeningError = Self.message(for: error)
        }
    }

    /// Builds a manifest over this book's own narration chunks, off the main
    /// actor.
    ///
    /// Returns nil for every way this can honestly fail — a read-along with no
    /// narration in it, an archive that will not open, an extraction that ran
    /// out of disk — and the caller falls back to the server's manifest, which
    /// is today's behaviour. Falling back is always safe: the chunk path is an
    /// improvement on the resume, not a requirement for playing at all.
    private func synthesisedListening(
        for book: Book, content: BookContentService,
    ) async -> (
        manifest: AudiobookManifest, chapters: [AudiobookChapter],
        files: [String: URL], timeline: SMILTimeline
    )? {
        let epubURL = content.localURL(for: book, format: .readaloud)
        let bookID = book.uuid
        let title = book.title
        // The reader's, when a reader is open — the archive is already inflated
        // and the overlay already parsed, and doing both again for a book on
        // screen is seconds of work for an answer in memory. Both are `Sendable`.
        let openPackage = readers[book.uuid]?.package
        let openTimeline = readers[book.uuid]?.timeline
        let started = Date()

        let built = await Task.detached(priority: .userInitiated) {
            () -> (result: ChunkManifest.Result, timeline: SMILTimeline)? in
            do {
                let source = try ReadaloudSource.load(
                    epubURL: epubURL, bookID: bookID,
                    package: openPackage, timeline: openTimeline)
                guard !source.timeline.isEmpty, !source.audioFiles.isEmpty else {
                    // A read-along whose alignment the server claims but whose
                    // EPUB carries no overlay. The server's own manifest is
                    // then the only track list there is.
                    IssaLog.warning("read-along has no narration; playing original", [
                        "book": title,
                    ])
                    return nil
                }
                let cached = ChunkDurations.load(bookID: bookID)
                let measured = await ChunkDurations.measure(source.audioFiles, cached: cached)
                // Only when it grew. A book whose lengths are all known already
                // must not rewrite the file on every play.
                if measured.count > cached.count {
                    try? ChunkDurations.save(measured, bookID: bookID)
                }
                return (
                    ChunkManifest.make(
                        timeline: source.timeline, package: source.package,
                        audioFiles: source.audioFiles, durations: measured, title: title),
                    source.timeline
                )
            } catch {
                IssaLog.failure("chunk manifest", error, ["book": title])
                return nil
            }
        }.value

        guard let built, !built.result.manifest.playableTracks.isEmpty else { return nil }
        IssaLog.info("chunk manifest built", [
            "book": title,
            "tracks": String(built.result.manifest.playableTracks.count),
            "chapters": String(built.result.chapters.count),
            "ms": String(format: "%.1f", Date().timeIntervalSince(started) * 1_000),
        ])
        return (built.result.manifest, built.result.chapters, built.result.files, built.timeline)
    }

    /// How an attach ended, for the one caller that has somewhere else to go.
    enum ListeningAttachment: Equatable {
        /// Positioned, owned by this call, and playing unless the resume said
        /// otherwise.
        case started
        /// The audio this manifest names would not load. The book is silent and
        /// `listeningError` says so; another manifest for the same book is
        /// worth trying.
        case wouldNotPlay
        /// The listening slot changed hands while this call was suspended — a
        /// hand-off took the book. Nothing to retry and nothing to tidy: what
        /// is in the slot now owns it, and it is not ours.
        case slotTaken
    }

    /// Hands a manifest to a coordinator, the Now Playing centre and the
    /// position writer, and starts it where the resume ladder says.
    ///
    /// One tail for both track lists. The two paths above differ only in what
    /// they are playing and how they name it, and the moment the second one
    /// existed, every fix to the order of these lines — the guard before the
    /// seek, the publish after it — would otherwise have had to be made twice.
    ///
    /// Internal rather than private so `IssaSharedTests` can reach it, on the
    /// same terms as `installListening`: reaching it through `startListening`
    /// needs a signed-in session and a server holding a manifest, and the two
    /// things worth asserting here — that a book which will not load says so,
    /// and that a hand-off mid-flight is not overrun — are about this method
    /// alone.
    ///
    /// - Returns: what became of it. See `ListeningAttachment`.
    @discardableResult
    func attachListening(
        manifest: AudiobookManifest,
        source: AudiobookCoordinator.Source,
        chapters: [AudiobookChapter],
        timeline: SMILTimeline?,
        manifestKind: ListeningResume.ManifestKind,
        book: Book,
        nowPlaying: NowPlayingController,
        settings: PlaybackSettings,
    ) async -> ListeningAttachment {
        // The `stopNarration()` in `startListening` ran before a network round
        // trip and an extraction; a read-along the reader tapped *during* either
        // would otherwise still be playing when the audiobook starts, two voices
        // at once. Stop again now that the suspensions are over, just before
        // this coordinator takes over Now Playing.
        stopNarration()
        let coordinator = AudiobookCoordinator(
            manifest: manifest, source: source, chapters: chapters)
        coordinator.player.rate = Float(settings.playbackRate)
        // The level belongs to the book, not to the surface it is played
        // from: Listening, CarPlay and the lock screen all arrive here, and
        // a trim set in the reader has to survive the move.
        coordinator.player.gain = VolumeTrim.gain(settings.volumeTrim(for: book.uuid))
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
        let resume = await resolveListeningStart(
            for: book, coordinator: coordinator,
            timeline: timeline, manifestKind: manifestKind)
        // The slot, after every suspension. `listening` was published before
        // the two awaits in this method — a resume to resolve, then an
        // AVFoundation item to load, which is seconds — and a hand-off firing
        // in that window pauses this coordinator, starts the read-along and
        // calls `stopListening`. Without this the start woke up and played the
        // orphan anyway: two voices on one book and two position writers
        // arguing over it. Identity, not the book's uuid, because starting the
        // same book twice is exactly the case that has to lose. The precedent
        // is `watchListeningProgress`'s own check on resume, and `load`'s
        // generation counter one layer down.
        guard listening === coordinator else {
            return slotChangedHands(book, coordinator, at: "resolvedStart")
        }
        IssaLog.info("listening started", [
            "book": book.title,
            "from": resume.reason.rawValue,
            "atBookTime": String(format: "%.1f", resume.bookTime ?? -1),
            "storedProgress": String(format: "%.4f", book.progress ?? -1),
            "manifestKind": manifestKind.rawValue,
            "trackCount": String(coordinator.tracks.count),
            "source": manifestKind == .synthesised ? "chunks" : "original",
        ])
        // Before a note of audio plays: an unresolved start plays from zero,
        // and the fifteen-second writer must not be allowed to persist that
        // zero over a place this app simply could not find.
        prepareListeningGuard(for: book, resolved: resume.isResolved)
        if let time = resume.bookTime {
            // Only if the seek actually landed. `start(atProgress:)` below
            // already refuses to play a player holding nothing; a resolved
            // start whose chunk is missing deserves the same silence, logged
            // by `load`, rather than a book that claims to be playing.
            let landed = await coordinator.seek(toBookTime: time)
            guard listening === coordinator else {
                return slotChangedHands(book, coordinator, at: "seeked")
            }
            guard landed else { return declined(book, reason: "seekDeclined") }
            coordinator.player.play()
        } else {
            await coordinator.start(atProgress: 0)
            guard listening === coordinator else {
                return slotChangedHands(book, coordinator, at: "started")
            }
            // `start(atProgress:)` returns nothing and declines in silence, so
            // the player is what has to be asked. The href rather than the
            // anchor: the anchor is being worked on elsewhere, and this is the
            // plainer fact anyway — a player holding no audio at all.
            guard coordinator.player.currentAudioHref != nil else {
                return declined(book, reason: "nothingLoaded")
            }
        }
        // After the seek, never before: a coordinator one line old still
        // reads bookTime 0, so publishing here would have announced every
        // resumed audiobook at 0% and left that on disk if the listener
        // paused inside the next fifteen seconds.
        publishListeningSnapshot(book: book, coordinator: coordinator)
        watchListeningProgress(book: book, coordinator: coordinator)
        return .started
    }

    /// Says out loud that a start produced no audio, and stops before it can
    /// look like one that did.
    ///
    /// The publish and the position writer both used to run here regardless, on
    /// a player holding nothing — and `listeningError` was left at the nil
    /// `startListening` set on the way in. CarPlay reads that value back
    /// verbatim as its success signal, so a silent failure pushed the row
    /// straight to Now Playing with no audio behind it: the exact outcome
    /// `startListening`'s own note says must never happen again.
    private func declined(_ book: Book, reason: String) -> ListeningAttachment {
        IssaLog.warning("listening produced no audio", [
            "book": book.title, "reason": reason,
        ])
        listeningError = "That book's audio would not play. Try downloading it again."
        return .wouldNotPlay
    }

    /// Silences a start that woke up to find the book already somewhere else.
    ///
    /// Silenced, not merely abandoned: `start(atProgress:)` plays as part of
    /// starting, so by the time this is reached the orphan can already be
    /// audible — which is the second voice the re-check exists to prevent. Its
    /// rate observers go too, or they would keep republishing this book to the
    /// widget and the lock screen over whatever took the slot.
    ///
    /// Now Playing is deliberately left alone. Whatever took the book has
    /// claimed it — a hand-off attaches the reader's own coordinator — and
    /// detaching here would take it straight back off the lock screen, which is
    /// the same trap `narrationDidStart` avoids by passing no controller.
    private func slotChangedHands(
        _ book: Book, _ coordinator: AudiobookCoordinator, at stage: String,
    ) -> ListeningAttachment {
        coordinator.player.removeRateObservers()
        coordinator.player.pause()
        IssaLog.info("listening slot changed hands while starting", [
            "book": book.title, "stage": stage,
        ])
        return .slotTaken
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
    ///
    /// Internal, and with the interval in the signature, for the reason
    /// `installListening` is internal: the only way to see what a cancelled
    /// tick does is to cancel one mid-sleep, and a suite that had to wait
    /// fifteen real seconds per assertion is a suite nobody runs.
    /// - Parameter interval: how long between writes. Production passes
    ///   nothing; a test drives it in milliseconds.
    func watchListeningProgress(
        book: Book, coordinator: AudiobookCoordinator, every interval: Duration = .seconds(15),
    ) {
        listeningProgressTask?.cancel()
        listeningProgressTask = Task { [weak self, weak coordinator] in
            var lastWritten: Double = -1
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                // `try?` swallows the `CancellationError`, and the loop test
                // above only runs at the top — so a cancel landing inside the
                // sleep used to run this whole body regardless. That matters
                // because the body *spends* things: `consumeSteering()` below
                // is read-and-clear, so the stray tick could label its write
                // `.chosen`, which re-baselines the high-water mark and clears
                // any hold. The hand-off cancels this task and then suspends at
                // `resumeNarration`, which is exactly the window the stray tick
                // lands in — and its write is audio-scaled, so it also flips the
                // stored locator's clock out from under the reader.
                guard !Task.isCancelled else { return }
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
                let accepted = await writePosition(
                    Self.audioLocator(for: coordinator, book: book),
                    timestamp: ProgressService.now(),
                    for: book.uuid,
                    origin: origin,
                )
                // And the anchor, which is the half the *other* engine can
                // act on. The locator above is a fraction of this engine's
                // clock and means nothing to the read-along; a file and an
                // offset mean the same thing to both. See `AudioAnchor`.
                //
                // Only when the position was accepted. A refused write must not
                // leave its anchor behind: the anchor is the *more* durable
                // half — the reader opens the book from it — so writing one for
                // a position the guard has just rejected replaces the last good
                // place with a track and an offset from a playback that started
                // at zero. That overwrite is what sent the reader to chapter
                // one on the phone after a drive.
                //
                // And asked again first. `writePosition` records locally and
                // then drains the queue, which is one POST per row at
                // URLSession's sixty-second default — seconds, by its own
                // comment — so a cancel arriving during the write must not
                // still land the anchor afterwards.
                guard !Task.isCancelled else { return }
                if accepted, let anchor = coordinator.currentAnchor {
                    try? await store?.setAudioAnchor(anchor, forBook: book.uuid)
                }
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

    /// Where an audiobook should resume, and why.
    ///
    /// The ladder itself lives in `ListeningResume`, which is a pure function
    /// and testable against the manifests that break it. This is the part that
    /// has to reach the store and the open readers, and the part that has to
    /// leave a log line good enough to diagnose the next one of these without
    /// the phone in hand.
    /// - Parameter timeline: an overlay the caller already has, for a manifest
    ///   synthesised from one. Falls back to an open reader's, which a cold
    ///   launch straight into CarPlay does not have.
    private func resolveListeningStart(
        for book: Book,
        coordinator: AudiobookCoordinator,
        timeline: SMILTimeline?,
        manifestKind: ListeningResume.ManifestKind,
    ) async -> ListeningResume.Resolution {
        let anchor = try? await store?.audioAnchor(forBook: book.uuid)
        let stored = book.position?.locator
        let overlay = timeline ?? readers[book.uuid]?.timeline
        let resolution = ListeningResume.resolve(
            anchor: anchor, stored: stored, timeline: overlay, manifest: coordinator.manifest)

        // The fields that say *why*, rather than only that it failed. The old
        // line said "no audio anchor for this book yet" in the one case where
        // there certainly was one — it named a file this manifest has never
        // heard of — which is how a report about resuming at chapter one read
        // as a book that had simply never been played.
        var fields: [String: String] = [
            "book": book.title,
            "manifestKind": manifestKind.rawValue,
            "trackCount": String(coordinator.tracks.count),
            "firstTrack": coordinator.manifest.playableTracks.first?.href ?? "none",
            "storedScale": stored.map { $0.isAudioScaled ? "audio" : "text" } ?? "none",
            "storedHrefMatchesTrack": stored.map { locator in
                locator.isAudioScaled
                    ? String(coordinator.manifest.trackIndex(matching: locator.href) != nil)
                    : "n/a"
            } ?? "n/a",
            "timeline": overlay == nil ? "absent" : "present",
        ]
        switch resolution.reason {
        case .anchorNamesUnknownFile:
            if let anchor {
                fields["anchorHref"] = anchor.audioHref
                fields["anchorOffset"] = String(format: "%.1f", anchor.offset)
            }
            IssaLog.warning("audio anchor names no track in this manifest", fields)
        case .noAnchorStored:
            IssaLog.warning("no audio anchor stored for this book", fields)
        case .anchor, .audioPosition, .readingPositionViaOverlay, .noStoredPosition:
            break
        }
        return resolution
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
        // The chapter the listener is in, which on a manifest synthesised over
        // narration chunks is not the same as the track: `title(of:at:)` would
        // hand back "Track 87" for a place the reader knows as chapter twelve,
        // and this locator is what every other client — Storyteller's own web
        // player included — reads to say where the book was left.
        let chapter = coordinator.chapterTitle
        return ReadiumLocator(
            href: track?.href ?? "",
            type: track?.type ?? "audio/mpeg",
            title: track.map { chapter.isEmpty ? coordinator.manifest.title(of: $0, at: index) : chapter },
            locations: .init(
                progression: (within.asProgression ?? 0),
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
        // Through the model: the bytes of an edition inside its undo window are
        // still on disk, and returning them here would hand the reader a book
        // that is deleted from under them six seconds later. Falling through
        // takes the download path, which cancels that removal first.
        if isDownloaded(book, format: format) { return destination }

        let job = DownloadManager.Job(bookUUID: book.uuid, format: format)
        // `download` can refuse to start at all — the Wi-Fi-only guard, most
        // often — in which case `states[job]` is never populated and the loop
        // below would wait on a state that can never arrive. It used to: this
        // is what left the reader stuck on "Downloading…" forever, with the
        // real reason sitting unseen in `loadError`.
        guard await download(book, format: format) else {
            throw StorytellerError.download(loadError ?? "Couldn't start the download.")
        }

        // The last real byte counts seen, for a pause to keep showing.
        var lastReported: (written: Int64, total: Int64) = (0, 0)
        while !Task.isCancelled {
            switch downloads.state(for: job) {
            case .finished:
                return destination
            case let .failed(reason):
                throw StorytellerError.download(reason)
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
                throw StorytellerError.download("Download cancelled.")
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
            cancelPendingRemoval(matching: job)
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
            // On a Mac this fires *while on Wi-Fi* — a Low Data Mode network is
            // constrained, and constrained counts as expensive — so naming
            // Wi-Fi there describes the connection the reader already has.
            #if os(macOS)
            loadError = "Waiting for an unmetered connection to download this."
            #else
            loadError = "Waiting for Wi-Fi to download this."
            #endif
            return false
        }
        let job = DownloadManager.Job(bookUUID: book.uuid, format: format)
        // After the guard above, so a download the Wi-Fi rule refused does not
        // quietly take back a removal it is not going to replace — but before
        // the transfer starts, so the timer cannot fire between the two.
        cancelPendingRemoval(matching: job)
        await downloads.start(job, expectedBytes: expected)
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
        guard session != nil else { return }
        if let value { ratings[book.uuid] = value } else { ratings.removeValue(forKey: book.uuid) }
        // Persisted the way `setStatus` persists a shelf change. Without this
        // the map lived only in memory and was repopulated solely from
        // `myRatings()`, so a rating set offline vanished on the next cold
        // launch — the queued write still reached the server eventually, but
        // the reader had every reason to think it was lost and enter it again.
        try? await store?.setRating(value, forBook: book.uuid)
        await enqueue(.rating, bookUUID: book.uuid,
                      payload: MutationDrain.RatingPayload(rating: value))
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
    /// Internal, not private, for `PositionWritingTests` — which used to build
    /// its own `PositionGuard` and assert on that, proving nothing about the
    /// re-seed it was named for. Nothing outside the tests writes this.
    var positionGuards: [String: PositionGuard] = [:]

    /// The key a position guard is filed under: the book, and which clock the
    /// position is on.
    ///
    /// Two clocks share `totalProgression` in this app — a fraction of the text
    /// from the reader, a fraction of the audio from the audiobook — so one
    /// guard per book compared the two against each other as though they were
    /// the same quantity. Named rather than spelled out at each site, because a
    /// test that builds the key by hand and a production path that changes it
    /// is exactly how `reseedGuards` would come to match nothing while still
    /// looking correct.
    static func positionGuardKey(_ bookUUID: String, isAudioScaled: Bool) -> String {
        "\(bookUUID)#\(isAudioScaled ? "audio" : "text")"
    }

    /// Puts one candidate position to this book's guard for that clock, seeding
    /// the guard first if it has never been used.
    ///
    /// Split out of `writePosition` so a test can ask the question without a
    /// mutation queue, a store or a network behind it — the guard is the part
    /// that decides whether a reader keeps their place, and it was reachable
    /// only through a method that suspends four times before answering.
    func admitPosition(
        _ locator: ReadiumLocator, origin: PositionOrigin, for bookUUID: String,
    ) -> PositionGuard.Decision {
        let book = books.first { $0.uuid == bookUUID }
        // With the narration length, where there is one: the guard's absolute
        // bound — five minutes — only exists for long audiobooks, and without
        // the duration it was never applied, leaving a forty-hour book two
        // hours of undetected slack.
        let duration = book.map(LibraryArrangement.duration(of:)).flatMap { $0 > 0 ? $0 : nil }
        // Keyed by book *and* by clock. `PositionGuard` is a high-water mark on
        // `totalProgression`, and this app writes that field on two different
        // scales -- a fraction of the text from the reader, a fraction of the
        // audio from the audiobook. Sharing one guard between them meant a
        // reading position and a listening position were compared against each
        // other as if they were the same quantity, so one could refuse the
        // other for going "backwards" when neither had moved at all. See
        // AudioAnchor.
        let guardKey = Self.positionGuardKey(bookUUID, isAudioScaled: locator.isAudioScaled)
        // Seeded only from a stored position on this same clock, for the same
        // reason: the book's own progress is whichever scale wrote last.
        let seed = (book?.position?.locator).flatMap {
            $0.isAudioScaled == locator.isAudioScaled ? $0.totalProgression : nil
        } ?? 0
        var state = positionGuards[guardKey] ?? PositionGuard(highWater: seed, duration: duration)
        let decision = state.decide(locator.locations?.totalProgression, origin: origin)
        positionGuards[guardKey] = state
        // A steer names a place in the *book*, and the book has one of those
        // however many clocks are measuring it. The other clock cannot be told
        // where that place is — there is no arithmetic between the two, which
        // is why they are keyed apart — but it can be told that whatever it was
        // holding is no longer true. Without this, hours the listener steered
        // in the car were measured against the page they left off at before the
        // drive, every write after the drive was refused, and the anchor went
        // with them. See `PositionGuard.forgettingItsMark`.
        //
        // Gated on the decision, not on the origin alone: a `.chosen` write
        // carrying a non-finite progression falls to `.refuse` and is not a
        // place named at all, so it must invalidate nothing.
        if origin == .chosen, decision.isAllowed {
            let other = Self.positionGuardKey(bookUUID, isAudioScaled: !locator.isAudioScaled)
            // Only a guard that already exists. Creating one here would invent a
            // rule about a clock this app has never written a position on, and
            // the seeding rules deliberately say nothing about such a clock.
            if let sibling = positionGuards[other] {
                positionGuards[other] = sibling.forgettingItsMark()
            }
        }
        return decision
    }

    /// Arms — or releases — the audio clock's guard as an audiobook starts.
    ///
    /// The half of the 2026-09-09 loss that the ladder alone does not fix.
    /// When nothing could be resolved, playback begins at zero, and fifteen
    /// seconds later the periodic writer offers 0.0001 on the audio clock. That
    /// clock has no mark of its own — the stored position was the reader's, on
    /// the text clock — so the write reads as ordinary forward progress, and
    /// `recordPosition` then replaces a part-read novel's place with the front
    /// of the book. Holding the clock until the listener names somewhere is the
    /// only honest answer: the app genuinely does not know where they were.
    /// - Parameter resolved: whether `ListeningResume` found a place to start.
    func prepareListeningGuard(for book: Book, resolved: Bool) {
        let key = Self.positionGuardKey(book.uuid, isAudioScaled: true)
        let narration = LibraryArrangement.duration(of: book)
        let duration: TimeInterval? = narration > 0 ? narration : nil
        let stored = book.position?.locator
        // The same seed rule as `admitPosition`: only a stored position on this
        // clock says anything about this clock.
        let seed = (stored?.isAudioScaled ?? false) ? (stored?.totalProgression ?? 0) : 0
        let mark = positionGuards[key]?.highWater ?? seed

        if resolved {
            // Released at the mark it already held, never lowered to wherever
            // this resume landed. A stale anchor can resolve to somewhere
            // earlier than a good same-clock position — that is exactly what a
            // high-water mark is for — and re-baselining here would hand the
            // regression back through the front door.
            if positionGuards[key]?.awaitingChoice == true {
                positionGuards[key] = PositionGuard(highWater: mark, duration: duration)
            }
            return
        }
        // A book with no stored position anywhere has nothing to lose, and
        // holding its clock would mean a pure audiobook opened for the first
        // time recorded no position at all until the listener scrubbed.
        guard book.position != nil else { return }
        positionGuards[key] = PositionGuard(
            highWater: mark, duration: duration, awaitingChoice: true)
        IssaLog.warning("listening resume unresolved, derived writes held until the listener steers", [
            "book": book.uuid,
            "storedScale": (stored?.isAudioScaled ?? false) ? "audio" : "text",
            "held": String(format: "%.4f", mark),
        ])
    }

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
        switch admitPosition(locator, origin: origin, for: bookUUID) {
        case .allow:
            break
        case let .refuse(held, candidate):
            IssaLog.warning("position write refused", [
                "book": bookUUID,
                "held": String(format: "%.4f", held),
                "candidate": String(format: "%.4f", candidate),
                "origin": origin.rawValue,
                "reason": "belowHighWater",
            ])
            return false
        case let .awaitChoice(candidate):
            // A held clock, not a regression: the app could not work out where
            // this listener was, so nothing a clock arrives at may be persisted
            // until they say. `held` is what the mark would have been, which is
            // the number worth having in the log.
            let key = Self.positionGuardKey(bookUUID, isAudioScaled: locator.isAudioScaled)
            IssaLog.warning("position write refused", [
                "book": bookUUID,
                "held": String(format: "%.4f", positionGuards[key]?.highWater ?? 0),
                "candidate": candidate.map { String(format: "%.4f", $0) } ?? "none",
                "origin": origin.rawValue,
                "reason": "awaitingChoice",
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
        // Locally first, then the queue. `enqueue` ends in `drainPendingWrites()`
        // — one POST per queued item at URLSession's 60-second default — so with
        // this pair the other way round, a page turned offline wrote the queue
        // row, blocked on the drain, and was suspended by iOS before
        // `recordPosition` ever ran. The in-memory catalogue and the store were
        // never updated, which is exactly the failure this method's own doc
        // comment says the code was changed to prevent: "a chapter read offline
        // and then killed came back at the old percentage."
        await recordPosition(locator, timestamp: timestamp, for: bookUUID)
        await enqueue(
            .position, bookUUID: bookUUID,
            payload: MutationDrain.PositionPayload(locator: locator, timestamp: timestamp),
            supersedes: timestamp,
        )
        return true
    }

    /// Re-reads one book after something changed it server-side.
    ///
    /// Writing a reading position moves the status on the server, so after a
    /// reading session the local copy is stale in a way the user can see.
    public func refresh(book: Book) async {
        guard let session,
              books.contains(where: { $0.uuid == book.uuid }),
              let fresh = try? await LibraryService(client: session.client).book(book.uuid)
        else { return }
        // Resolved *after* the await, not before it. The index used to be bound
        // in the same guard that then suspends on a network round trip, and
        // `books` can be replaced entirely during that suspension — signing out
        // empties it, and a refresh can return a shorter catalogue — so the
        // subscript trapped. The quieter variant was worse: a merely reordered
        // catalogue wrote this book's server data into whichever book had taken
        // its place, and then persisted that.
        guard let index = books.firstIndex(where: { $0.uuid == book.uuid }) else { return }
        books[index] = books[index].reconciled(with: fresh)
        rebuildDerived()
    }
}
