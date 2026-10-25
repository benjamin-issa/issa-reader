package com.benjaminissa.issareader.app.model

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.app.reader.ReaderPersistence
import com.benjaminissa.issareader.app.reader.ReaderServices
import com.benjaminissa.issareader.app.reader.publish
import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.KeyValueStore
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.StorageRoot
import com.benjaminissa.issareader.core.auth.TokenPersisting
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.download.DownloadManager
import com.benjaminissa.issareader.core.download.DownloadsInventory
import com.benjaminissa.issareader.core.model.Annotation
import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.AudiobookManifest
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.model.Status
import com.benjaminissa.issareader.core.model.User
import com.benjaminissa.issareader.core.model.asProgression
import com.benjaminissa.issareader.core.networking.AudiobookService
import com.benjaminissa.issareader.core.networking.MonitoredReachability
import com.benjaminissa.issareader.core.networking.Reachability
import com.benjaminissa.issareader.core.networking.ServerAddress
import com.benjaminissa.issareader.core.networking.StorytellerError
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.sync.LibraryArrangement
import com.benjaminissa.issareader.core.sync.LibraryDerivation
import com.benjaminissa.issareader.core.sync.LibraryFacets
import com.benjaminissa.issareader.core.sync.LibraryRails
import com.benjaminissa.issareader.core.sync.LibraryService
import com.benjaminissa.issareader.core.sync.MutationDrain
import com.benjaminissa.issareader.core.sync.MutationQueue
import com.benjaminissa.issareader.core.sync.PositionGuard
import com.benjaminissa.issareader.core.sync.PositionOrigin
import com.benjaminissa.issareader.core.sync.ProgressService
import com.benjaminissa.issareader.core.sync.ReadingHome
import com.benjaminissa.issareader.core.sync.StatusAdvance
import com.benjaminissa.issareader.epub.SmilTimeline
import com.benjaminissa.issareader.playback.AudioExtraction
import com.benjaminissa.issareader.playback.AudioPlayer
import com.benjaminissa.issareader.playback.AudiobookChapter
import com.benjaminissa.issareader.playback.AudiobookCoordinator
import com.benjaminissa.issareader.playback.ChapterNaming
import com.benjaminissa.issareader.playback.ChunkDurations
import com.benjaminissa.issareader.playback.ChunkManifest
import com.benjaminissa.issareader.playback.ControlSurface
import com.benjaminissa.issareader.playback.ListeningHandoff
import com.benjaminissa.issareader.playback.ListeningResume
import com.benjaminissa.issareader.playback.PlaybackDriving
import com.benjaminissa.issareader.playback.ReadaloudSource
import com.benjaminissa.issareader.playback.ReadalongCoordinator
import com.benjaminissa.issareader.playback.VolumeTrim
import com.benjaminissa.issareader.playback.displayChapterTitle
import com.benjaminissa.issareader.core.networking.TokenProviding
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.net.URI
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.min

/**
 * Something that keeps a per-book index the account's books must take with
 * them: the Ask machinery, which is ported separately and hands itself over
 * at launch. Swift's `AppModel.ask`.
 */
fun interface BookIndexes {
    fun remove(bookUuid: String)
}

/**
 * Something that keeps the library in the launcher: [ShortcutPublisher]. An
 * account's exit clears it.
 */
interface LibraryShortcuts {
    suspend fun clear()
}

/**
 * Top-level app state: which server we are talking to, whether we are signed
 * in, and the catalogue once we are.
 *
 * One class, as in Swift: its race fixes depend on a single owner. Observable
 * through Compose snapshot state — the screens read its properties directly,
 * and a non-Compose consumer (the media session, the car) uses `snapshotFlow`.
 * Main-thread confined, as the Swift class is `@MainActor`: every member is
 * called on [scope]'s dispatcher, which is the main thread in the app and a
 * single thread of the test's own in the suites.
 *
 * @param keychain where tokens are kept: the Keystore in the app.
 * @param defaults the small preferences: the last server, the account per
 *   server, the library's arrangement and mode, the downloads' switches.
 * @param notificationCentre where an account's exit is announced. The app's
 *   own by default; a test hands over a centre of its own, so its sign-out
 *   cannot reach another suite's settings.
 * @param scope the main thread's: where the work Swift ran in an unstructured
 *   `Task` runs.
 * @param makeSession builds the session `connect` adopts; a test's goes over a
 *   transport of its own.
 * @param makeDownloads builds the download manager when `connect` finds none.
 *   The app hands one over at launch ([useDownloads]), because its WorkManager
 *   backend has to exist before any worker runs.
 */
class AppModel(
    private val keychain: TokenPersisting,
    private val defaults: KeyValueStore,
    private val notificationCentre: SignOutCentre = SignOutCentre.default,
    val reachability: Reachability = MonitoredReachability(),
    internal val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main),
    private val makeSession: (URI) -> Session = { Session(it, keychain) },
    private val makeDownloads: ((URI, TokenProviding) -> DownloadManager)? = null,
) {
    enum class Phase {
        /**
         * Before anything has been decided. Distinct from [CHOOSE_SERVER],
         * which means "this reader has no server": conflating the two
         * committed the sign-in form to the first frame of every launch.
         */
        LAUNCHING,
        CHOOSE_SERVER,
        SIGNING_IN,
        READY,

        /** The token expired mid-use. The server is remembered, so signing in again is one tap. */
        EXPIRED,
    }

    var phase: Phase by mutableStateOf(Phase.LAUNCHING)
    var serverAddress: String by mutableStateOf(defaults.getString(LAST_SERVER_KEY) ?: "")
    var session: Session? by mutableStateOf(null)

    /**
     * Rebuilt explicitly by whatever changes the catalogue: a position write
     * mutates one element, and re-faceting the whole library on every
     * debounced save — every two seconds while narrating — was the cost of
     * doing it on every assignment. [recordPosition] recomputes only what a
     * position can move.
     */
    var books: List<Book> by mutableStateOf(emptyList())

    private var downloadedUuidsState by mutableStateOf(emptySet<String>())

    /**
     * Books with at least one file on disk *and* not on their way off it.
     *
     * A removal waiting out its undo window is subtracted, because for those
     * six seconds this set was the app's only answer to "is this on the
     * device", and the shelf, the offline filter, the car's catalogue and the
     * reader all went on offering a file about to be deleted underneath them.
     * Only when the pending removal is the book's *last* edition.
     *
     * Assigned the disk's answer on every foreground, car connection and
     * finished download, nearly always to the set it already was: only a
     * change is worth the rebuild.
     */
    var downloadedUuids: Set<String>
        get() = downloadedUuidsState
        private set(value) {
            if (value == downloadedUuidsState) return
            downloadedUuidsState = value
            rebuildDerived()
        }

    /** What the last directory read actually found, before the undo window is applied. */
    private var downloadedOnDisk: Set<String> = emptySet()

    /**
     * Bumped every time the app has reason to think the Books directory has
     * changed, for the screens that walk it themselves: a count cannot see one
     * edition of a two-edition book going.
     */
    var downloadsRevision: Int by mutableIntStateOf(0)
        private set

    /** The shelves this server defines. Fetched once per sign-in. */
    var statuses: List<Status> by mutableStateOf(emptyList())

    /** This user's own ratings, keyed by book. */
    var ratings: Map<String, Double> by mutableStateOf(emptyMap())
    var loadError: String? by mutableStateOf(null)

    /**
     * Whether a library refresh is in flight for the account signed in now. A
     * count rather than a flag: with two in flight the first to come back
     * took the spinner down while the other was still fetching.
     */
    val isLoadingLibrary: Boolean get() = libraryRefreshesInFlight > 0

    /**
     * The refreshes [isLoadingLibrary] counts: each counted in for the account
     * it fetches for, and out only while that account is still signed in.
     */
    internal var libraryRefreshesInFlight: Int by mutableIntStateOf(0)
        private set

    /** Derived rails, computed from the single catalogue fetch, for the callers that still want them whole. */
    val derivation: LibraryDerivation get() = LibraryDerivation(books)

    /** Shelf and tag counts for the library header. Rebuilt when the catalogue or the downloaded set changes. */
    var facets: LibraryFacets by mutableStateOf(LibraryFacets.empty)
        private set

    /** The Browse screen's rails. */
    var rails: LibraryRails by mutableStateOf(LibraryRails.empty)
        private set

    /** The Reading tab, rebuilt whenever a position moves. */
    var readingHome: ReadingHome by mutableStateOf(ReadingHome.empty)
        private set

    /** The on-device catalogue. Present as soon as a server is chosen. */
    var store: LibraryStore? by mutableStateOf(null)
        private set
    private var mutations: MutationQueue? = null
    private var listeningProgressTask: Job? = null

    /** Whether the fifteen-second position writer is armed. */
    internal val isWritingListeningPosition: Boolean get() = listeningProgressTask != null
    private var isConnecting = false

    /**
     * The session `connect` built whose stored token the server has not yet
     * been asked about. Nothing queued goes out with it until it has been.
     */
    private var unidentifiedSession: Session? = null

    /** The session of the server `connect` is leaving, between that exit and the new session being installed. */
    private var departingSession: Session? = null

    /** Streams books to disk in the background. */
    var downloads: DownloadManager? by mutableStateOf(null)
        private set

    /** Queued writes still waiting for a connection, for the sync row. */
    var pendingWrites: Int by mutableIntStateOf(0)
        private set

    init {
        reachability.onBecameOnline = { scope.launch { cameBackOnline() } }
        // A property initialiser does not rebuild, so without this the first
        // frame renders empty facets and an unarranged shelf.
        rebuildDerived()
        watchMetering()
    }

    /**
     * The launch restore, started rather than awaited, and not bound to any
     * screen's lifetime: the restore moves `phase`, and a phase change that
     * tears down the screen that started it killed the restore with it. Once
     * per launch.
     */
    fun startRestore() {
        if (restoreTask != null) return
        restoreTask = scope.launch { restoreIfPossible() }
    }

    /** Held so [startRestore] can tell "already ran" from "never ran". Never cancelled. */
    private var restoreTask: Job? = null

    /** Reconnects to the last server on launch when a token is already stored. */
    suspend fun restoreIfPossible() {
        if (serverAddress.isEmpty() || (phase != Phase.LAUNCHING && phase != Phase.CHOOSE_SERVER)) {
            // Nothing stored: a first run, so stop holding the launch state.
            if (phase == Phase.LAUNCHING) phase = Phase.CHOOSE_SERVER
            return
        }
        connect(serverAddress)
    }

    suspend fun connect(address: String) {
        // Re-entrancy guard: two overlapping connects each built a session and
        // a download manager.
        if (isConnecting) return
        isConnecting = true
        try {
            // Cleared up front: a failed connect to a new address left the
            // previous attempt's sentence beside the previous server's name.
            loadError = null
            val candidates = candidateServerUrls(address)
            if (candidates.isEmpty()) {
                loadError = "That doesn't look like a server address."
                // Not left at LAUNCHING, which renders as a blank screen with
                // no controls.
                if (phase == Phase.LAUNCHING) phase = Phase.CHOOSE_SERVER
                return
            }
            val url = firstReachable(candidates) ?: run {
                loadError = "Couldn't reach a Storyteller server at that address."
                if (phase == Phase.LAUNCHING) phase = Phase.CHOOSE_SERVER
                return
            }
            // Before anything below is replaced, while `session` still says
            // which server the state in memory came from.
            prepareForServer(url)
            // The resolved address, not the raw text — except a bare host that
            // only answered over cleartext, which keeps the typed text so the
            // next launch tries HTTPS first.
            val resolved = ServerAddress.addressToStore(address, url)
            defaults.putString(LAST_SERVER_KEY, resolved)
            serverAddress = resolved
            val session = makeSession(url)
            this.session = session
            departingSession = null
            // Its token is the keychain's, and nobody has asked whose it is yet.
            unidentifiedSession = session

            // The local store first, and what is already known on screen: a
            // reader opening the app on a train should see their shelf.
            store = runCatching { LibraryStore(url.toString()) }.getOrNull()
            runCatching { store?.ratings() }.getOrNull()?.takeIf { it.isNotEmpty() }?.let { ratings = it }
            defaults.getString(accountKey(url))?.let { account -> runCatching { store?.setAccount(account) } }
            // A session again means the widget may be written again.
            currentBookPublisher.resume()
            reopenMutationQueue()
            // Only for someone who is actually signed in: the cached shelf on
            // the strength of the database alone left the whole library
            // readable after sign-out.
            val hasCredential = session.hasStoredCredential()
            val store = store
            if (store != null && hasCredential) {
                val cached = runCatching { store.allBooks() }.getOrNull()
                if (!cached.isNullOrEmpty()) {
                    books = cached
                    rebuildDerived()
                    phase = Phase.READY
                }
            }

            // After the shelf is on screen. The manager already alive is kept
            // and re-pointed: its backend is owned for the process.
            val downloads = downloads
            if (downloads != null) {
                downloads.reconfigure(url, session.tokenProvider)
            } else {
                this.downloads = makeDownloads?.invoke(url, session.tokenProvider)
            }
            this.downloads?.onFinished = { scope.launch { refreshDownloadedSet() } }
            refreshDownloadedSet()
            scope.launch { this@AppModel.downloads?.reattach() }

            resumeStoredSession()
        } finally {
            isConnecting = false
        }
    }

    /**
     * Leaves the previous server's account behind, when `connect` is moving to
     * a different server — by the key its store and its account are filed
     * under. A first connect has nothing to leave, and a connect to the same
     * server is the same library.
     */
    internal suspend fun prepareForServer(url: URI) {
        val current = session ?: return
        if (current.serverUrl.toString() == url.toString()) return
        IssaLog.info("leaving server", mapOf("from" to current.serverUrl.toString(), "to" to url.toString()))
        // Before the exit moves the fence: a refresh started in the window
        // would take this session and the fence as it already stood.
        departingSession = current
        leaveAccount(AccountExit.SERVER_SWITCH, nowPlayingController)
    }

    /**
     * Restores the token stored for this server, and decides where that
     * leaves the reader — asking the hand-over question `adopt` asks, because
     * a stored token is no better known than one just handed over.
     */
    internal suspend fun resumeStoredSession() {
        val session = session ?: return
        if (phase != Phase.READY) phase = Phase.SIGNING_IN
        // Paused across the identity call: until the server has said whose
        // token this is, nothing queued may go out with it.
        val paused = mutations
        paused?.pauseDraining()
        session.restore()
        // Read once: the hand-over suspends.
        val state = session.state.value
        // Only for the session still in use.
        if (this.session === session && state is Session.State.SignedIn) {
            accountResolved(state.user, session.serverUrl)
            identified(session)
        }
        paused?.resumeDraining()
        if (this.session !== session) return
        when (state) {
            is Session.State.SignedIn -> enterLibrary()
            is Session.State.Failed -> {
                // A cached shelf is still worth showing; say why it may be stale.
                loadError = state.reason
                if (phase != Phase.READY) phase = Phase.CHOOSE_SERVER
            }
            // With the cached shelf up, restore just rejected the stored token:
            // `EXPIRED` keeps the server and makes signing in again one tap.
            else -> phase = if (phase == Phase.READY) Phase.EXPIRED else Phase.CHOOSE_SERVER
        }
    }

    suspend fun adopt(token: String) {
        val session = session ?: run {
            IssaLog.error("adopted a token with no session")
            loadError = "Connect to your server before signing in."
            phase = Phase.CHOOSE_SERVER
            return
        }
        // No drain may be running while the bearer changes hands: a drain
        // reads the token afresh for every request, and the new token is
        // installed before the identity call says whose it is.
        val paused = mutations
        paused?.pauseDraining()
        session.adopt(token)
        val state = session.state.value
        if (this.session === session && state is Session.State.SignedIn) {
            accountResolved(state.user, session.serverUrl)
            identified(session)
        }
        // Before `enterLibrary`, whose refresh drains what the same account
        // left queued.
        paused?.resumeDraining()
        if (this.session !== session) return
        when (state) {
            is Session.State.SignedIn -> enterLibrary()
            is Session.State.Failed -> {
                // The grant worked and the token is kept; only the identity
                // call failed. Saying so is the whole fix.
                loadError = state.reason
                phase = Phase.CHOOSE_SERVER
            }
            else -> {
                // The server refused the token: a real outcome, and one that
                // must not look like the app doing nothing.
                IssaLog.error("adopted token was not accepted", mapOf("state" to state.toString()))
                loadError = "Your server didn't accept that sign-in. Try again, or use a device code."
                phase = Phase.CHOOSE_SERVER
            }
        }
    }

    /**
     * What happens once the server has said whose token this is: is the
     * identity it resolves to the one this server was last signed in as?
     *
     * Every route that learns an identity asks here, before anything of the
     * account's is shown or sent. A mismatch is not refused — a second reader
     * on a household tablet is legitimate — but the state in memory belongs to
     * the previous account, and goes.
     */
    private suspend fun accountResolved(user: User, server: URI) {
        val previous = defaults.getString(accountKey(server)) ?: return
        if (previous == user.id) return
        IssaLog.warning(
            "token resolves to a different account",
            mapOf("server" to server.toString(), "from" to previous, "to" to user.id),
        )
        leaveAccount(AccountExit.ACCOUNT_SWITCH, nowPlayingController)
    }

    /** The server has said whose token [session] holds: what is queued may go out with it from here on. */
    private fun identified(session: Session) {
        if (unidentifiedSession === session) unidentifiedSession = null
    }

    /**
     * Signs out and leaves nothing behind.
     *
     * @param keepDownloads books already on the device are expensive to fetch
     *   again, so the choice is offered rather than assumed.
     */
    suspend fun signOut(keepDownloads: Boolean = false, nowPlaying: NowPlayingController? = null) {
        // Before anything else: a removal inside its undo window is a decision
        // already made, and a timer firing after the account has gone would
        // delete a file belonging to whoever signs in next.
        commitPendingRemoval()
        session?.signOut()
        leaveAccount(AccountExit.SIGN_OUT, nowPlaying)

        // What only a sign-out lets go of.
        store = null
        session = null
        if (!keepDownloads) {
            // By name, these two and nothing else: `Local/`, where the books
            // the reader added from their own files live, is the device's.
            // (Android registers a book's own faces from its archive in memory,
            // so no extracted `Fonts/` survive a download to be swept here.)
            for (folder in listOf("Books", "Audio")) File(storageRoot, folder).deleteRecursively()
            downloadedOnDisk = emptySet()
            downloadedUuids = emptySet()
        }
        phase = Phase.CHOOSE_SERVER
    }

    /** Why an account's state is being let go of, for [leaveAccount]. */
    private enum class AccountExit {
        /** The reader signed out. */
        SIGN_OUT,

        /** A token resolved to an account other than the one this server was last signed in as. */
        ACCOUNT_SWITCH,

        /** `connect` is moving to a different server: that account has not signed out. */
        SERVER_SWITCH,
    }

    /**
     * Lets go of everything held in memory that belongs to the account being
     * left — and to no other.
     *
     * One method for every way out, because the ways out differ only in what
     * they keep. The order is part of the contract: the fence first, before
     * anything suspends; then whatever could still make a sound; then memory,
     * all of it before the first suspension; and only then the queue, the
     * store and the rest of the device. The books the reader added from their
     * own files are the device's, and each step that would take one says so.
     */
    private suspend fun leaveAccount(exit: AccountExit, nowPlaying: NowPlayingController?) {
        // 1. The fence, before anything suspends: every detached catalogue
        // write checks it.
        catalogueGeneration += 1

        // 2. A removal still inside its undo window, carried out now: the
        // timer holding it knows nothing of accounts.
        commitPendingRemoval()

        // 3. A listening start that has claimed a book but not yet attached
        // it, and its extraction; and the hand-off's claim.
        startingListening = null
        listeningExtraction?.cancel()
        handingOffBook = null

        // 4. Anything audible, and anything listening for it, before the
        // stopping is announced. Not a book from the reader's own files that
        // is narrating: it is the device's, and the lock screen is its.
        val narratingLocal = narratingBookUuid?.let { readers[it] }?.isLocal == true
        stopListening(if (narratingLocal) null else nowPlaying)
        releaseServerReaders()

        // 5. Memory, all of it before anything below suspends.
        // The high-water marks are keyed by book uuid, and the same server
        // hands the same uuids to a different account.
        positionGuards = mutableMapOf()
        refusalsLogged.clear()
        books = emptyList()
        rebuildDerived()
        statuses = emptyList()
        autoFiledBookUuids.clear()
        localWrites.removeAll()
        ratings = emptyMap()
        loadError = null
        libraryRefreshesInFlight = 0
        downloadRefusals = emptyMap()
        pendingBook = null
        readerRequest = null
        // And "continue reading" asked while this account's token had lapsed.
        intentInbox.bookId = null
        // A re-identify still out for a session this exit lets go of — not on
        // an account switch, which is the session staying.
        if (exit != AccountExit.ACCOUNT_SWITCH) reidentifying = null
        // Unless the reader on screen is a book from the reader's own files.
        visibleReaderUuid?.let { visible -> if (readers[visible]?.isLocal != true) setVisibleReaderUuid(null) }
        listeningError = null

        // 6. The write queue, retired and put out of reach before its table is
        // emptied: a write already on its way in could otherwise land after
        // the DELETE and drain under the arriving account's bearer.
        val retiring = mutations
        mutations = null
        retiring?.let(::retire)

        // 7. The store's copy of the account. Annotations are device-local and
        // stay. Not on a server switch: that file is the server's being left.
        if (exit != AccountExit.SERVER_SWITCH) runCatching { store?.clearAccountData() }

        // 8. What the rest of the app keeps per book — reader styles, volume
        // trims, question indexes — told through the centre, carrying the
        // device's own books, once the local library's list is in.
        if (exit != AccountExit.SERVER_SWITCH) {
            localBooksLoaded()
            val kept = localBookUuids() + readers.values.filter { it.isLocal }.map { it.book.uuid } + localBookFolders()
            notificationCentre.post(kept)
        }

        // 9. Transfers, covers, the widget and the launcher's shortcuts. The
        // manager itself stays: its backend is owned for the process.
        downloads?.stop()
        coverCache().clear()
        currentBookPublisher.clear()
        shortcuts?.clear()

        // 10. The downloaded set, read again from the disk rather than emptied:
        // the files are the device's.
        refreshDownloadedSet()
    }

    /** The books the reader added from their own files, by the folders they keep under `Local/`. */
    private fun localBookFolders(): Set<String> {
        val entries = File(storageRoot, "Local").listFiles() ?: return emptySet()
        return entries.map { it.name }.filterNot { it.startsWith(".") }.toSet()
    }

    /** Retires a queue, and closes its connection once whatever holds its drain lock has let go. */
    private fun retire(queue: MutationQueue) {
        queue.retire()
        scope.launch {
            queue.pauseDraining()
            queue.resumeDraining()
            runCatching { queue.close() }
        }
    }

    /**
     * Builds the write queue over the store `connect` has just opened, and
     * retires the one it replaces — once the new one is in place, so no write
     * finds neither.
     */
    internal fun reopenMutationQueue() {
        val replaced = mutations
        mutations = null
        // The queue belongs with the store, not with the credential.
        ensureMutationQueue()
        replaced?.let(::retire)
    }

    /** The write queue in use, for the tests that ask whether a replaced queue was retired. */
    internal val currentMutationQueue: MutationQueue? get() = mutations

    /**
     * Opens the durable write queue, if it is not open already. Called from
     * both `connect` and `enterLibrary`: between them they are every route.
     */
    private fun ensureMutationQueue() {
        if (mutations != null) return
        val store = store ?: return
        mutations = runCatching { MutationQueue(store) }.getOrNull()
        if (mutations == null) IssaLog.warning("mutation queue unavailable", mapOf("server" to serverAddress))
    }

    /** Takes [store] as the catalogue and opens its write queue, as `connect` does. A test seam. */
    internal fun useStore(store: LibraryStore) {
        this.store = store
        mutations = null
        ensureMutationQueue()
    }

    private suspend fun enterLibrary() {
        // Writes must be durable before the library — and so the reader — is reachable.
        ensureMutationQueue()
        recordSignedInAccount()
        phase = Phase.READY
        refreshLibrary()
    }

    /**
     * Names the signed-in account to the store, and remembers it as the
     * account this server was last signed in as.
     */
    private suspend fun recordSignedInAccount() {
        val session = session ?: return
        val state = session.state.value as? Session.State.SignedIn ?: return
        // The widget's writer, which every account exit suspends; here
        // because this is every route that ends with an account signed in.
        currentBookPublisher.resume()
        runCatching { store?.setAccount(state.user.id) }
        defaults.putString(accountKey(session.serverUrl), state.user.id)
    }

    /**
     * Bumped whenever the catalogue stops belonging to this account: the fence
     * every write that can outlive its account checks. Observable, so a
     * reader screen of an account that has left closes ([hasLeft]).
     */
    var catalogueGeneration: Int by mutableIntStateOf(0)
        private set

    /**
     * Re-seeds the write guards when the server's position moved backwards —
     * a book restarted on another device — so the derived writes from the
     * restarted place are not refused for the rest of the process.
     */
    internal fun reseedGuards(catalogue: List<Book>) {
        for (book in catalogue) {
            val locator = book.position?.locator ?: continue
            val progress = locator.totalProgression ?: continue
            val key = positionGuardKey(book.uuid, locator.isAudioScaled)
            val guardState = positionGuards[key] ?: continue
            if (progress >= guardState.highWater) continue
            // The hold travels with the mark.
            positionGuards[key] = seededGuard(book, locator.isAudioScaled, progress, guardState.awaitingChoice)
        }
    }

    /**
     * Watches for the token going stale while the app is in use. Re-reads
     * `session` each pass, since `connect` replaces it.
     */
    suspend fun watchForExpiry() {
        while (currentCoroutineContext().isActive) {
            if (session?.state?.value == Session.State.Expired && phase == Phase.READY) {
                phase = Phase.EXPIRED
                loadError = null
            }
            delay(2_000)
        }
    }

    suspend fun refreshLibrary() {
        val session = session ?: return
        // Not for a server `connect` is leaving: its exit has moved the fence.
        if (session === departingSession) return
        var countedFor = catalogueGeneration
        libraryRefreshesInFlight += 1
        try {
            // Whose session this is, if the last time the server was asked it
            // gave no answer.
            if (!reidentifyIfFailed(session)) return
            // A re-identify that handed the device to another account started
            // the count again: count this one for the account it now fetches for.
            if (catalogueGeneration != countedFor) {
                countedFor = catalogueGeneration
                libraryRefreshesInFlight += 1
            }
            // Whose catalogue this is, and what this device has written that
            // the answer may not include — both before the request is sent.
            val generation = catalogueGeneration
            val fence = unsentFence()
            try {
                val service = LibraryService(session.client)
                // Everything fetched into locals and published in one go.
                val fetched = service.allBooks()
                val fetchedStatuses = runCatchingCancellable { service.statuses() } ?: statuses
                val fetchedRatings = runCatchingCancellable { service.myRatings() } ?: ratings
                // The in-memory half of the fence, for the session it was asked with.
                if (catalogueGeneration != generation || this.session !== session) return

                // Reconciled, not assigned: a refetch that predates a write
                // still in the queue carries a stale position, and a status
                // this device wrote and the server may not hold yet is kept.
                val known = LinkedHashMap<String, Book>()
                for (book in books) known.putIfAbsent(book.uuid, book)
                val merged = fetched.map { fresh ->
                    val mine = known[fresh.uuid] ?: return@map fresh
                    mine.reconciled(fresh, keepingStatus = keepsLocal(MutationQueue.Kind.STATUS, fresh.uuid, fence))
                }
                books = merged
                reseedGuards(merged)
                rebuildDerived()
                statuses = fetchedStatuses
                // Ratings reconciled against the queue, from the same fence.
                val mergedRatings = fetchedRatings.toMutableMap()
                for (uuid in fence.ratings + localWrites.books(MutationQueue.Kind.RATING, fence.mark)) {
                    val local = ratings[uuid]
                    if (local != null) mergedRatings[uuid] = local else mergedRatings.remove(uuid)
                }
                ratings = mergedRatings
                loadError = null
                IssaLog.info("library refreshed", mapOf("books" to fetched.size.toString()))

                // Off the refresh gesture entirely, and behind the same fence:
                // a full catalogue rewrite and a drain have no business holding
                // the spinner open, and a refresh racing a sign-out must not
                // write the departed account's catalogue back.
                val ratingsToPersist = mergedRatings.toMap()
                scope.launch {
                    if (catalogueGeneration != generation || this@AppModel.session !== session) return@launch
                    runCatching { store?.replaceCatalogue(merged) }
                    if (catalogueGeneration != generation) return@launch
                    runCatching { store?.replaceRatings(ratingsToPersist) }
                    if (catalogueGeneration != generation) return@launch
                    drainPendingWrites()
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                IssaLog.failure("library refresh", e, mapOf("server" to serverAddress))
                // A failed refresh is not an empty library when something is cached.
                val cached = if (books.isEmpty()) runCatching { store?.allBooks() }.getOrNull() ?: emptyList() else emptyList()
                // Nothing for an account that has since arrived.
                if (catalogueGeneration != generation || this.session !== session) return
                if (cached.isNotEmpty()) {
                    books = cached
                    rebuildDerived()
                }
                loadError = if (books.isEmpty()) message(e) else null
            }
        } finally {
            if (catalogueGeneration == countedFor) libraryRefreshesInFlight -= 1
        }
    }

    /**
     * The re-identify in flight, and the session it is asking about, which a
     * refresh of that same session waits for rather than asking again.
     */
    private var reidentifying: Pair<Session, Deferred<Unit>>? = null

    /**
     * Asks the server again whose token this is, when the last time it was
     * asked got no answer — and says whether the refresh should go on. In a
     * task of its own, so a refresh cancelled part-way cannot strand the
     * session half signed in.
     *
     * @return false when there is nothing to fetch for.
     */
    private suspend fun reidentifyIfFailed(session: Session): Boolean {
        val current = reidentifying
        if (current != null && current.first === session) {
            current.second.await()
        } else if (session.state.value is Session.State.Failed) {
            val asking = scope.async { reidentify(session) }
            reidentifying = session to asking
            asking.await()
            // Only its own: another session's may have taken the slot since.
            if (reidentifying?.second === asking) reidentifying = null
        } else {
            return true
        }
        if (this.session !== session) return false
        return when (session.state.value) {
            Session.State.Expired, Session.State.SignedOut -> false
            else -> true
        }
    }

    /** The identity call, the hand-over and what follows from the answer. */
    private suspend fun reidentify(session: Session) {
        val paused = mutations
        paused?.pauseDraining()
        session.restore()
        val state = session.state.value
        if (this.session === session && state is Session.State.SignedIn) {
            accountResolved(state.user, session.serverUrl)
            identified(session)
        }
        paused?.resumeDraining()
        if (this.session !== session) return
        when (state) {
            is Session.State.SignedIn -> {
                ensureMutationQueue()
                recordSignedInAccount()
            }
            Session.State.Expired, Session.State.SignedOut -> {
                // The server refused the token: the notice that keeps the
                // server is the honest screen.
                phase = Phase.EXPIRED
                loadError = null
            }
            else -> Unit
        }
    }

    /**
     * Sends anything written while there was no connection — not while nobody
     * knows whose token the session holds.
     *
     * @param waitingForInFlight wait for a drain already running rather than
     *   declining: only the exit path, where there is no next enqueue.
     */
    suspend fun drainPendingWrites(waitingForInFlight: Boolean = false) {
        val session = session ?: return
        val mutations = mutations ?: return
        if (!identityIsKnown(session)) return
        runCatchingCancellable { MutationDrain(mutations, session.client).drain(waitingForInFlight) }
        pendingWrites = runCatchingCancellable { mutations.count() } ?: 0
    }

    /**
     * Whether the server has said whose token [session] holds — or, for a
     * session no identity route has been through, at least not said that it
     * could not tell.
     */
    private fun identityIsKnown(session: Session): Boolean {
        if (unidentifiedSession === session) return false
        return when (session.state.value) {
            is Session.State.Failed, Session.State.SigningIn -> false
            else -> true
        }
    }

    /**
     * The network is back: send what waited for it — unless nobody has asked
     * whose token the session holds, when the refresh goes first.
     */
    internal suspend fun cameBackOnline() {
        val session = session
        if (session != null && phase == Phase.READY && session.state.value is Session.State.Failed) {
            refreshLibrary()
        } else {
            drainPendingWrites()
        }
    }

    /** The status and rating writes a server's answer may not include yet, as they stood before the request. */
    private class UnsentFence(
        /** Where [localWrites] stood. A write begun after this may not be in the answer either. */
        val mark: Int,
        val statuses: Set<String>,
        val ratings: Set<String>,
    )

    /**
     * Takes the fence, before the fetch it guards: the mark and the writes in
     * flight first, with nothing suspending between them, then one read of
     * the queue for both kinds.
     */
    private suspend fun unsentFence(): UnsentFence {
        val mark = localWrites.mark
        val statuses = localWrites.inFlight(MutationQueue.Kind.STATUS).toMutableSet()
        val ratings = localWrites.inFlight(MutationQueue.Kind.RATING).toMutableSet()
        for (row in runCatchingCancellable { mutations?.pending() } ?: emptyList()) {
            when (row.kind) {
                MutationQueue.Kind.STATUS -> statuses.add(row.bookUuid)
                MutationQueue.Kind.RATING -> ratings.add(row.bookUuid)
                MutationQueue.Kind.POSITION -> Unit
            }
        }
        return UnsentFence(mark, statuses, ratings)
    }

    /**
     * Whether a merge must keep this device's value over the server's: the
     * write was unsent when the fence was taken, or has begun since.
     */
    private fun keepsLocal(kind: MutationQueue.Kind, bookUuid: String, fence: UnsentFence): Boolean {
        val unsent = when (kind) {
            MutationQueue.Kind.STATUS -> fence.statuses
            MutationQueue.Kind.RATING -> fence.ratings
            MutationQueue.Kind.POSITION -> emptySet()
        }
        return bookUuid in unsent || bookUuid in localWrites.books(kind, fence.mark)
    }

    /**
     * Records a write locally, then attempts it. The queue is written first so
     * losing the connection mid-request still leaves the intent recorded.
     */
    suspend fun <T> enqueue(kind: MutationQueue.Kind, bookUuid: String, payload: T, serializer: KSerializer<T>, supersedes: Double? = null) {
        // Both halves logged: a write that vanishes here leaves no other trace.
        val mutations = mutations ?: run {
            IssaLog.warning("write dropped: no queue", mapOf("book" to bookUuid, "kind" to kind.rawValue))
            return
        }
        val data = runCatching { IssaJson.encodeToString(serializer, payload).encodeToByteArray() }.getOrNull() ?: run {
            IssaLog.warning("write dropped: not encodable", mapOf("book" to bookUuid, "kind" to kind.rawValue))
            return
        }
        try {
            val recorded = mutations.enqueue(kind, bookUuid, data, supersedes)
            if (!recorded) {
                IssaLog.info("write superseded by a queued newer one", mapOf("book" to bookUuid, "kind" to kind.rawValue))
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            IssaLog.failure("write dropped: queue refused it", e, mapOf("book" to bookUuid, "kind" to kind.rawValue))
            return
        }
        pendingWrites = runCatchingCancellable { mutations.count() } ?: 0
        drainPendingWrites()
    }

    // Arranging the library

    private var arrangementState by mutableStateOf(LibraryArrangement.restored(defaults))

    /** How the shelf is sorted and filtered. Persisted: a reader who sorts by author means it next launch too. */
    var arrangement: LibraryArrangement
        get() = arrangementState
        set(value) {
            arrangementState = value
            value.store(defaults)
            rebuildArranged()
        }

    /** The library as arranged, which is what every shelf view should show. Stored rather than computed. */
    var arrangedBooks: List<Book> by mutableStateOf(emptyList())
        private set

    /** Author name to their books, for the book screen's "More by…" rail. Memoised: authors do not change with a page turn. */
    var booksByAuthor: Map<String, List<Book>> by mutableStateOf(emptyMap())
        private set
    var booksByNarrator: Map<String, List<Book>> by mutableStateOf(emptyMap())
        private set

    /** Tag name to its books, each once. */
    var booksByTag: Map<String, List<Book>> by mutableStateOf(emptyMap())
        private set

    /** The catalogue by uuid: rebuilt with the position-dependent state, because a position change must show. */
    var bookByUuid: Map<String, Book> by mutableStateOf(emptyMap())
        private set

    /** How many times everything derived from the catalogue was rebuilt, for the tests that pin when it is not. */
    internal var derivedRebuilds = 0
        private set

    /** Recomputes everything derived from the catalogue. */
    internal fun rebuildDerived() {
        derivedRebuilds += 1
        facets = LibraryFacets(books, downloadedUuids)
        rails = LibraryRails(books)
        val derivation = LibraryDerivation(books)
        booksByAuthor = derivation.byAuthor
        booksByNarrator = derivation.byNarrator
        booksByTag = rails.byTag
        rebuildAfterPositionChange()
    }

    /** The part of the above a position can move: the Continue card, the Reading tab's order, the arrangement. */
    private fun rebuildAfterPositionChange() {
        readingHome = ReadingHome(books, rails)
        val byUuid = LinkedHashMap<String, Book>()
        for (book in books) byUuid.putIfAbsent(book.uuid, book)
        bookByUuid = byUuid
        rebuildArranged()
    }

    /** Whether the Library shows its browse rails or the flat, sortable grid. Not part of the arrangement. */
    enum class LibraryMode(val rawValue: String) { BROWSE("browse"), ALL("all") }

    private var libraryModeState by mutableStateOf(
        defaults.getString(LIBRARY_MODE_KEY)?.let { raw -> LibraryMode.entries.firstOrNull { it.rawValue == raw } }
            ?: LibraryMode.BROWSE,
    )
    var libraryMode: LibraryMode
        get() = libraryModeState
        set(value) {
            libraryModeState = value
            defaults.putString(LIBRARY_MODE_KEY, value.rawValue)
        }

    /**
     * Opens the flat grid on one shelf — what every "See all" does. One
     * assignment to the arrangement; the tags are cleared, because a shelf
     * asked for by name is that shelf.
     */
    fun showAllBooks(shelf: LibraryArrangement.Shelf, tags: Set<String> = emptySet(), sort: LibraryArrangement.Sort? = null) {
        arrangement = LibraryArrangement(
            sort = sort ?: arrangement.sort,
            ascending = if (sort == null) arrangement.ascending else false,
            shelf = shelf,
            tags = tags,
        )
        libraryMode = LibraryMode.ALL
    }

    private fun rebuildArranged() {
        val downloaded = downloadedUuids
        arrangedBooks = arrangement.apply(books) { it.uuid in downloaded }
    }

    /** Deletes one downloaded edition, everything that came with it, and the record that it was ever downloading. */
    fun removeDownload(book: Book, format: BookContentService.Format) = removeDownload(book.uuid, format)

    /**
     * The same, named by uuid, for a file whose book is no longer in the
     * catalogue. No session needed: this is a file being deleted.
     */
    fun removeDownload(bookUuid: String, format: BookContentService.Format) {
        // Before a byte is touched: the EPUB a reader is narrating from goes
        // in this call.
        stopPlayback(bookUuid, format)
        val job = DownloadManager.Job(bookUuid, format)
        // Cancel, then clear — and both before the file is touched, or a
        // transfer still arriving puts the book back a minute later.
        downloads?.cancel(job)
        downloads?.clear(job)
        downloadRefusals = downloadRefusals - job
        BookContentService.removeDownload(bookUuid, format)
        releaseDerivedFiles(bookUuid, format)
        refreshDownloadedSet(job)
    }

    /**
     * Stops a transfer that has not finished, and takes nothing else with it:
     * the X on a transfer row is not a book removal.
     */
    fun cancelDownload(job: DownloadManager.Job) {
        downloads?.cancel(job)
        downloads?.clear(job)
        downloadRefusals = downloadRefusals - job
        stopPlayback(job.bookUuid, job.format)
        BookContentService.removeDownload(job.bookUuid, job.format)
        refreshDownloadedSet(job)
    }

    /**
     * Everything a download leaves behind on disk once its file has gone.
     * Idempotent, and run after the file is deleted, so the check below is a
     * question about the disk.
     */
    private fun releaseDerivedFiles(bookUuid: String, format: BookContentService.Format?) {
        // Narration extracted from the read-along. Revoked before the
        // removal, never after: the removal would wait on the extraction's lock.
        if (format == null || format == BookContentService.Format.READALOUD) {
            readers[bookUuid]?.cancelNarrationExtraction()
            AudioExtraction.removeExtractedAudio(bookUuid)
        }
        // The rest belongs to the book, not the edition: only when the last
        // edition carrying its text has gone.
        if (BookContentService.hasDownloadedText(bookUuid)) return
        // The question index is derived from the file that has just gone.
        ask?.remove(bookUuid)
    }

    /**
     * Silences whatever is playing a book whose files are about to be deleted
     * — knowing which file is going, so deleting the ebook of a book whose
     * audiobook is streaming leaves the drive alone.
     *
     * @param format the edition being removed, or null for the reconciliation
     *   sweep, which cannot tell which file went.
     */
    private fun stopPlayback(bookUuid: String, format: BookContentService.Format?) {
        if (listeningBook?.uuid == bookUuid && removalSilencesListening(listeningFormat, format)) {
            stopListening(nowPlayingController)
        }
        if (narratingBookUuid == bookUuid && removalSilencesNarration(format)) stopNarration()
        // And the hand-off in flight, which owns neither yet: dropping the
        // claim is what makes it stand down.
        if (handingOffBook == bookUuid && removalSilencesNarration(format)) handingOffBook = null
        // And a start that has claimed the book but not yet attached it, with
        // its extraction, which would otherwise inflate the book back.
        val starting = startingListening
        if (starting != null && starting.first == bookUuid && removalSilencesListening(starting.second, format)) {
            startingListening = null
            listeningExtraction?.cancel()
        }
    }

    /**
     * Re-reads which books have files on disk, and cleans up after any that
     * went without being removed. A directory this cannot read leaves both
     * the set and the sweep alone: an unreadable directory is a fact about
     * this moment, not about the disk.
     */
    fun refreshDownloadedSet() = refreshDownloadedSet(null)

    /**
     * @param removal the edition `removeDownload` has just deleted, whose
     *   book's playback that removal has already settled.
     */
    private fun refreshDownloadedSet(removal: DownloadManager.Job?) {
        val previous = downloadedOnDisk
        val current = try {
            BookContentService.downloadedBookUuids()
        } catch (_: Exception) {
            IssaLog.warning("could not read the downloads directory; keeping the last set", mapOf("kept" to previous.size.toString()))
            return
        }
        downloadedOnDisk = current
        applyPendingRemovalToDownloadedSet()
        downloadsRevision += 1
        // Against the disk's own reading: a removal in its undo window has
        // deliberately lost no file yet.
        reconcileDownloads(previous, removal)
    }

    /** Recomputes [downloadedUuids] from the disk's answer and the open window. */
    private fun applyPendingRemovalToDownloadedSet() {
        val pending = pendingRemoval ?: run {
            downloadedUuids = downloadedOnDisk
            return
        }
        val remaining = BookContentService.downloadedFormats(pending.bookUuid) - pending.format
        downloadedUuids = if (remaining.isEmpty()) downloadedOnDisk - pending.bookUuid else downloadedOnDisk
    }

    /**
     * Whether this edition is on the device and staying there: the
     * per-edition question, which sees a removal decided but not yet carried
     * out.
     */
    fun isDownloaded(book: Book, format: BookContentService.Format): Boolean = isDownloaded(book.uuid, format)

    fun isDownloaded(bookUuid: String, format: BookContentService.Format): Boolean {
        val pending = pendingRemoval
        if (pending != null && pending.bookUuid == bookUuid && pending.format == format) return false
        return format in BookContentService.downloadedFormats(bookUuid)
    }

    /**
     * Runs the rest of a removal for every book whose files went behind the
     * app's back — a restore, a failed move, a file removed underneath us. It
     * is also what keeps a car honest: the offline shelf filters on this set.
     */
    internal fun reconcileDownloads(previouslyDownloaded: Set<String>, removal: DownloadManager.Job? = null) {
        val departed = DownloadsInventory.departed(previouslyDownloaded, downloadedOnDisk)
        if (departed.isEmpty()) return
        for (bookUuid in departed) {
            // Except for the book a removal has just taken its last edition
            // from: that removal stopped exactly what was reading it.
            if (removal?.bookUuid != bookUuid) stopPlayback(bookUuid, null)
            releaseDerivedFiles(bookUuid, null)
        }
        IssaLog.info("reconciled downloads", mapOf("gone" to departed.size.toString()))
    }

    // Removing a download the reader can take back

    /** A removal waiting out its undo window. */
    data class PendingRemoval(
        val bookUuid: String,
        val format: BookContentService.Format,
        /** For the toast — "Removed Dracula" — because the row it came from is gone. */
        val title: String,
    ) {
        val id: String get() = "$bookUuid-${format.rawValue}"
    }

    private var pendingRemovalState by mutableStateOf<PendingRemoval?>(null)

    /**
     * The one removal that can still be taken back. Every write recomputes the
     * downloaded set, so no surface spends the window offering a file that is
     * about to be deleted.
     */
    var pendingRemoval: PendingRemoval?
        get() = pendingRemovalState
        private set(value) {
            pendingRemovalState = value
            applyPendingRemovalToDownloadedSet()
        }
    private var pendingRemovalTask: Job? = null

    /**
     * Hides an edition now and deletes it when the undo window closes:
     * deferred rather than undone, so an undo never starts a download. The
     * timer lives here rather than in a row that can scroll away. If the app
     * is killed inside the window the removal simply does not happen.
     */
    fun removeDownload(bookUuid: String, format: BookContentService.Format, title: String, undoWindowMillis: Long = REMOVAL_UNDO_WINDOW_MILLIS) {
        commitPendingRemoval()
        pendingRemoval = PendingRemoval(bookUuid, format, title)
        // Said out loud, because the row simply vanishes.
        announce("Removed $title. Undo is available.")
        pendingRemovalTask = scope.launch {
            delay(undoWindowMillis)
            commitPendingRemoval()
        }
    }

    /** How the app says something to a screen reader: `View.announceForAccessibility`, wired by the activity. */
    var announce: (String) -> Unit = {}

    /**
     * Takes back a pending removal when the very edition it is holding starts
     * downloading again: starting a download is the clearest statement that it
     * should be on the device.
     *
     * @return whether there was one to take back.
     */
    private fun cancelPendingRemoval(job: DownloadManager.Job): Boolean {
        val pending = pendingRemoval ?: return false
        if (pending.bookUuid != job.bookUuid || pending.format != job.format) return false
        undoPendingRemoval()
        return true
    }

    /** Puts the row back. Nothing was deleted, so there is nothing to fetch. */
    fun undoPendingRemoval() {
        pendingRemovalTask?.cancel()
        pendingRemovalTask = null
        pendingRemoval = null
    }

    /** Deletes what the window was holding, now. */
    fun commitPendingRemoval() {
        pendingRemovalTask?.cancel()
        pendingRemovalTask = null
        val pending = pendingRemoval ?: return
        pendingRemoval = null
        removeDownload(pending.bookUuid, pending.format)
    }

    // Deep links

    /**
     * A book something outside the app asked for, and what it asked for. A
     * widget tap, a shortcut and an `issareader://` link mean "carry on with
     * this book".
     */
    data class PendingBook(val uuid: String, val destination: Destination) {
        enum class Destination { READ, DETAILS }
    }

    var pendingBook: PendingBook? by mutableStateOf(null)
        private set

    /** Set when a read request resolves to a book that has text, and consumed by that book's screen. */
    private var readerRequest: String? = null

    fun requestBook(uuid: String, destination: PendingBook.Destination) {
        pendingBook = PendingBook(uuid, destination)
    }

    /**
     * Accepts `issareader://book/{uuid}` and `issareader://continue` — the
     * latter is Android's "Continue reading": the book the widget shows.
     */
    fun open(url: URI): Boolean {
        if (url.scheme != "issareader") return false
        val components = (url.path ?: "").split('/').filter { it.isNotEmpty() }
        return when (url.host) {
            "book" -> {
                val uuid = components.firstOrNull() ?: return false
                requestBook(uuid, PendingBook.Destination.READ)
                true
            }
            "continue" -> {
                val notice = intentInbox.continueReading()
                if (notice != null) {
                    loadError = loadError ?: notice
                    false
                } else {
                    intentInbox.deliver(this)
                    true
                }
            }
            else -> false
        }
    }

    /**
     * The book a pending link refers to, once the library can answer. Asking
     * to read a book with no text falls back to its page.
     */
    fun consumePendingBook(): Pair<Book, PendingBook.Destination>? {
        val pending = pendingBook ?: return null
        val book = books.firstOrNull { it.uuid == pending.uuid } ?: return null
        pendingBook = null
        val destination = if (pending.destination == PendingBook.Destination.READ && book.isReadable) {
            PendingBook.Destination.READ
        } else {
            PendingBook.Destination.DETAILS
        }
        if (destination == PendingBook.Destination.READ) readerRequest = book.uuid
        return book to destination
    }

    /** Drops a pending request without acting on it: for a link to the book whose reader is already on screen. */
    fun discardPendingBook() {
        pendingBook = null
    }

    /** Arms the one-shot reader request for a book whose page is about to be pushed, as a deep link does. */
    fun requestReader(book: Book): Boolean {
        if (!book.isReadable) return false
        readerRequest = book.uuid
        return true
    }

    /** Whether this book's screen should open the reader as it appears. One-shot. */
    fun consumeReaderRequest(book: Book): Boolean {
        if (readerRequest != book.uuid) return false
        readerRequest = null
        return true
    }

    // Annotations

    /** Saves a mark. Local only: the server has no annotations endpoint in any version. */
    fun save(annotation: Annotation) {
        val store = store
        scope.launch { runCatching { store?.save(annotation) } }
    }

    fun delete(annotation: Annotation) {
        val store = store
        scope.launch { runCatching { store?.deleteAnnotation(annotation.id) } }
    }

    suspend fun annotations(bookUuid: String): List<Annotation> = runCatchingCancellable { store?.annotations(bookUuid) } ?: emptyList()

    suspend fun allAnnotations(): List<Annotation> = runCatchingCancellable { store?.allAnnotations() } ?: emptyList()

    /**
     * The audiobook currently playing, if any. Held here rather than in a
     * screen, because playback has to outlive the screen that started it.
     */
    var listening: AudiobookCoordinator? by mutableStateOf(null)
        private set
    var listeningBook: Book? by mutableStateOf(null)
        private set

    /**
     * Which downloaded edition the engine in the slot is reading, or null when
     * it reads nothing on this device: the only thing that lets a removal stop
     * the engine reading what went.
     */
    internal var listeningFormat: BookContentService.Format? = null
        private set
    var listeningError: String? by mutableStateOf(null)
        private set

    /** Which surface is driving playback right now. */
    private var controlSurfaceState by mutableStateOf(ControlSurface.PHONE)
    val controlSurface: ControlSurface get() = controlSurfaceState

    /**
     * Pushed in by the Android Auto bridge as the car comes and goes. The car
     * going away is itself a reason to reconsider the hand-off.
     */
    fun setControlSurface(surface: ControlSurface) {
        if (controlSurface == surface) return
        controlSurfaceState = surface
        if (surface == ControlSurface.PHONE) considerListeningHandoff(ListeningHandoff.Trigger.CAR_DISCONNECTED)
    }

    /** Re-entrancy guard: the triggers overlap. */
    private var isHandingOff = false

    /**
     * The book a hand-off is in the middle of moving, held across the one
     * suspension that makes this hard: a removal clears it, and the
     * hand-off's own transfer does not.
     */
    private var handingOffBook: String? = null

    /** Whether this book is in the middle of changing engines: the reader's play button waits. */
    fun isHandingOffToReader(bookUuid: String): Boolean = handingOffBook == bookUuid

    /**
     * Cheap enough to call from anywhere a trigger fires.
     *
     * @param duringStart whether the caller is the start itself, at the point
     *   where it has finished.
     */
    private fun considerListeningHandoff(trigger: ListeningHandoff.Trigger, duringStart: Boolean = false) {
        if (listening == null || isHandingOff || (!duringStart && isStartingListening)) return
        scope.launch { handOffListeningToReader(trigger) }
    }

    /**
     * Moves a book playing through the audiobook engine onto the reader that
     * is looking at it: the end of a drive.
     *
     * @return what was decided, so a test can name it.
     */
    internal suspend fun handOffListeningToReader(trigger: ListeningHandoff.Trigger): ListeningHandoff.Decision {
        if (isHandingOff) return ListeningHandoff.Decision.Skipped(ListeningHandoff.Skip.ALREADY_HANDING_OFF)
        isHandingOff = true
        try {
            val coordinator = listening
            val model = visibleReaderUuid?.let { readers[it] }
            // The audio clock's own guard, asked rather than re-derived.
            val held = listeningBook?.let { positionGuards[positionGuardKey(it.uuid, true)]?.awaitingChoice } ?: false
            val decision = ListeningHandoff.decide(
                listeningBookUuid = listeningBook?.uuid,
                visibleBookUuid = visibleReaderUuid,
                surface = controlSurface,
                isForeground = isForeground,
                resumeWasUnresolved = held,
                anchor = coordinator?.currentAnchor,
                isPlaying = coordinator?.player?.isPlaying ?: false,
                epubPackage = model?.epubPackage,
                timeline = model?.timeline,
                hasReadalong = model?.readalong != null,
            )
            if (decision !is ListeningHandoff.Decision.HandOff) {
                val skip = (decision as? ListeningHandoff.Decision.Skipped)?.skip
                if (skip != null && skip != ListeningHandoff.Skip.NOT_LISTENING) {
                    IssaLog.info(
                        "listening hand-off skipped",
                        mapOf("book" to (listeningBook?.title ?: "none"), "trigger" to trigger.rawValue, "reason" to skip.rawValue),
                    )
                }
                return decision
            }
            val target = decision.target
            val book = listeningBook
            if (coordinator == null || model == null || book == null) return decision

            // Before anything moves: two engines must not write positions for
            // one novel.
            listeningProgressTask?.cancel()
            listeningProgressTask = null
            coordinator.player.pause()

            // The claim, before the one suspension in this method.
            handingOffBook = book.uuid
            val took = model.resumeNarration(target.entry, target.wasPlaying)
            if (!took) {
                // Only to an engine that still owns the book.
                if (listening !== coordinator || handingOffBook != book.uuid) {
                    slotChangedHands(book, coordinator, "handOffFailed")
                    return ListeningHandoff.Decision.Skipped(ListeningHandoff.Skip.SLOT_CHANGED_HANDS)
                }
                // The sentence's audio is not on disk: give the book back to the
                // car engine rather than leave the listener in silence.
                IssaLog.warning(
                    "listening hand-off failed",
                    mapOf(
                        "book" to book.title, "trigger" to trigger.rawValue, "reason" to "audioFileMissing",
                        "fragment" to target.entry.fragmentId, "audioHref" to target.entry.audioHref,
                    ),
                )
                if (target.wasPlaying) coordinator.player.play()
                // The writer, whatever the car was doing.
                watchListeningProgress(book, coordinator)
                return ListeningHandoff.Decision.Skipped(ListeningHandoff.Skip.AUDIO_FILE_MISSING)
            }

            // On the playing path the slot legitimately empties as part of this
            // method's own transfer; on the paused path an empty slot is
            // somebody else's work.
            val slotIsOurs = if (target.wasPlaying) listening == null || listening === coordinator else listening === coordinator
            if (!slotIsOurs || handingOffBook != book.uuid) {
                model.readalong?.player?.pause()
                if (narratingBookUuid == book.uuid) stopNarration()
                slotChangedHands(book, coordinator, "handedOff")
                return ListeningHandoff.Decision.Skipped(ListeningHandoff.Skip.SLOT_CHANGED_HANDS)
            }

            // The transfer `narrationDidStart` makes, explicitly, on both paths.
            narrationDidStart(book.uuid)
            if (listening === coordinator) stopListening(nowPlayingController)

            IssaLog.info(
                "listening handed off to reader",
                mapOf(
                    "book" to book.title, "trigger" to trigger.rawValue, "fragment" to target.entry.fragmentId,
                    "chapter" to target.spineIndex.toString(), "atOffset" to format1(target.anchor.offset),
                    "wasPlaying" to target.wasPlaying.toString(),
                ),
            )
            updateScreenAwake()
            return decision
        } finally {
            isHandingOff = false
            handingOffBook = null
        }
    }

    /** Puts a coordinator in the listening slot and nothing else. A test seam. */
    internal fun installListening(
        coordinator: AudiobookCoordinator,
        book: Book,
        format: BookContentService.Format? = BookContentService.Format.READALOUD,
    ) {
        listening = coordinator
        listeningBook = book
        listeningFormat = format
    }

    /**
     * Every open book's reader model, one per book, keyed by uuid. Held here
     * because the reader outlives its screen: audio carrying on after the
     * screen is gone is the point.
     */
    private var readers: Map<String, ReaderModel> by mutableStateOf(emptyMap())

    private var visibleReaderUuidState by mutableStateOf<String?>(null)

    /**
     * The book whose reader is on screen right now, or null. A book on screen
     * is what holds the display awake, so every write recomputes.
     */
    val visibleReaderUuid: String? get() = visibleReaderUuidState

    private fun setVisibleReaderUuid(value: String?) {
        if (visibleReaderUuidState == value) return
        visibleReaderUuidState = value
        updateScreenAwake()
    }

    /**
     * An appearing reader claims the slot; a disappearing one releases it only
     * if it still holds it.
     */
    fun setReaderVisible(uuid: String, visible: Boolean) {
        if (visible) {
            setVisibleReaderUuid(uuid)
            // The screen is back; the model no longer leaves with narration.
            closedWhileNarrating.remove(uuid)
            // A book opened after the sleep timer ran out is the reader awake again.
            sleepTimerRanOut = false
        } else if (visibleReaderUuid == uuid) {
            setVisibleReaderUuid(null)
        }
        updateScreenAwake()
        // A reader arriving on the book the car is playing is the commonest way a drive ends.
        if (visible) considerListeningHandoff(ListeningHandoff.Trigger.READER_VISIBLE)
    }

    /**
     * Whether the app is frontmost, pushed in by the process lifecycle. Starts
     * true because the model is built while the app is coming up.
     */
    private var isForeground = true

    /** The single holder of the display decision. */
    val screenAwake: ScreenAwakeAssertion = ScreenAwakeAssertion()

    /** Whether the display is being held awake for an open book right now. */
    val keepsScreenAwake: Boolean get() = screenAwake.isHeld

    /** Whether the sleep timer has run out since the reader last opened a book, pressed play or picked the phone up. */
    private var sleepTimerRanOut = false

    /** Told by [NowPlayingController] when its sleep timer runs out. */
    internal fun sleepTimerDidExpire() {
        sleepTimerRanOut = true
        updateScreenAwake()
    }

    /** Told when the app goes to and comes back from the background. */
    fun setForeground(foreground: Boolean) {
        if (isForeground == foreground) return
        isForeground = foreground
        if (foreground) sleepTimerRanOut = false
        updateScreenAwake()
        if (foreground) considerListeningHandoff(ListeningHandoff.Trigger.FOREGROUND)
    }

    /** Recomputes whether the display should be held awake, and holds or releases it. */
    private fun updateScreenAwake() {
        val narrated = if (listening == null) narratingBookUuid else null
        screenAwake.apply(
            ScreenAwake.shouldKeepAwake(
                policy = ScreenAwake.platformPolicy,
                isPlaying = playback?.player?.isPlaying ?: false,
                isReaderVisible = visibleReaderUuid != null,
                followsText = narrated != null && narrated == visibleReaderUuid,
                isForeground = isForeground,
                sleepTimerRanOut = sleepTimerRanOut,
            ),
        )
    }

    /**
     * Which open book, if any, owns the active narration and Now Playing:
     * distinct from a model merely existing in [readers].
     */
    private var narratingBookUuid: String? by mutableStateOf(null)

    /** Books whose reader screen closed while they were still narrating, let go of when their narration ends. */
    private val closedWhileNarrating = mutableSetOf<String>()

    /** The model backing whichever book is currently narrating: what Android Auto's chapter list reads. */
    val reader: ReaderModel? get() = narratingBookUuid?.let { readers[it] }

    /** The Now Playing surface, handed over at launch. Its sleep timer running out lets an open book's screen lock. */
    var nowPlayingController: NowPlayingController? = null
        set(value) {
            field = value
            value?.onSleepTimerExpired = { sleepTimerDidExpire() }
        }

    /** The question machinery, handed over at launch: deleting a download takes that book's index with it. */
    var ask: BookIndexes? = null

    /** The books the reader added from their own files, by uuid. Handed over at launch. */
    var localBookUuids: () -> Set<String> = { emptySet() }

    /** Returns once the local library has read its store. An account's exit waits for it. */
    var localBooksLoaded: suspend () -> Unit = {}

    /** The folder "Sign out and delete downloads" deletes from. A test seam. */
    internal var storageRoot: File = StorageRoot.url

    /** The widget's one writer. The app hands its own over at launch. */
    var currentBookPublisher: CurrentBookPublisher = CurrentBookPublisher(scope)

    /** Where "continue reading" leaves its book. */
    var intentInbox: AppIntentInbox = AppIntentInbox.shared

    /** The launcher's shortcuts, cleared on an account's exit. */
    var shortcuts: LibraryShortcuts? = null

    /** The cover cache, cleared on an account's exit. */
    var coverCache: () -> CoverCache = { CoverCache.shared }

    /** What a reader needs that is not about the book: fonts, its engine, its thread. Handed over at launch. */
    var readerServices: ReaderServices? = null

    /** Whatever is playing, of either kind. Null when nothing is. */
    val playback: PlaybackDriving?
        get() = listening ?: reader?.readalong

    /** The chapter playing now, named the way the book names it. */
    val playbackChapterTitle: String?
        get() {
            reader?.chapterTitle?.let { if (ChapterNaming.isDisplayable(it)) return it }
            return playback?.displayChapterTitle
        }

    val playbackBook: Book?
        get() = if (listening != null) listeningBook else reader?.book

    /**
     * The model for an open book, created once per book and kept. This is
     * where its hooks are installed — permanently, and fenced to the account
     * it was opened under, so a reader an account has left writes and
     * publishes nothing.
     */
    fun reader(book: Book, session: Session): ReaderModel {
        readers[book.uuid]?.let { return it }
        val model = ReaderModel(book, session, requireReaderServices())
        model.downloadHost = this
        val bookUuid = book.uuid
        val generation = catalogueGeneration
        model.enqueuePosition = { locator, timestamp, origin ->
            if (catalogueGeneration != generation) false else writePosition(locator, timestamp, bookUuid, origin)
        }
        model.recordAudioAnchor = { anchor ->
            if (catalogueGeneration == generation) runCatchingCancellable { store?.setAudioAnchor(anchor, bookUuid) }
        }
        model.loadAudioAnchor = {
            if (catalogueGeneration != generation) null else runCatchingCancellable { store?.audioAnchor(bookUuid) }
        }
        model.loadStoredAnnotations = { if (catalogueGeneration != generation) emptyList() else annotations(bookUuid) }
        model.onSaveAnnotation = { if (catalogueGeneration == generation) save(it) }
        model.onDeleteAnnotation = { if (catalogueGeneration == generation) delete(it) }
        model.publishReading = { snapshot ->
            if (catalogueGeneration == generation) snapshot.publish(book, session, currentBookPublisher)
        }
        model.accountGeneration = generation
        installSharedHooks(model, generation)
        readers = readers + (bookUuid to model)
        return model
    }

    /**
     * The model for a book the reader added from their own files: kept in the
     * same [readers], with its writes going to [persistence] — the device's
     * store — and never to the server's queue, store or catalogue.
     */
    fun reader(book: Book, persistence: ReaderPersistence): ReaderModel {
        readers[book.uuid]?.let { return it }
        val model = ReaderModel(book, ReaderModel.Source.Local(persistence.files(book.uuid)), requireReaderServices())
        val bookUuid = book.uuid
        model.enqueuePosition = { locator, timestamp, origin -> persistence.writePosition(locator, timestamp, origin, bookUuid) }
        model.recordAudioAnchor = { persistence.recordAudioAnchor(it, bookUuid) }
        model.loadAudioAnchor = { persistence.audioAnchor(bookUuid) }
        model.loadStoredPosition = { persistence.storedPosition(bookUuid) }
        model.loadStoredAnnotations = { persistence.annotations(bookUuid) }
        model.onSaveAnnotation = { persistence.save(it) }
        model.onDeleteAnnotation = { persistence.delete(it) }
        // No account's fence: the book is the device's.
        installSharedHooks(model, null)
        readers = readers + (bookUuid to model)
        persistence.didOpen(bookUuid)
        return model
    }

    private fun requireReaderServices(): ReaderServices =
        checkNotNull(readerServices) { "AppModel.readerServices was never handed over" }

    /** The models currently held, for the tests and the exit flush. */
    internal val openReaders: Map<String, ReaderModel> get() = readers

    /**
     * Lets go of a book from the reader's own files that is being removed:
     * narration stopped, extraction revoked, pending save dropped.
     */
    fun releaseLocalBook(bookUuid: String) {
        // Forgotten first: `stopNarration` saves a model whose screen closed,
        // and a book being removed must not save.
        closedWhileNarrating.remove(bookUuid)
        if (narratingBookUuid == bookUuid) stopNarration()
        val model = readers[bookUuid] ?: return
        readers = readers - bookUuid
        model.cancelNarrationExtraction()
        model.cancelPendingSave()
        model.readalong?.player?.pause()
        if (visibleReaderUuid == bookUuid) setVisibleReaderUuid(null)
    }

    /**
     * The hooks every open book gets whatever it came from: which reader is on
     * screen, and the narration it may start.
     *
     * @param generation the account fence a server book's reader was opened
     *   under, or null for a book from the reader's own files. A reader the
     *   account has left cannot narrate.
     */
    private fun installSharedHooks(model: ReaderModel, generation: Int?) {
        val bookUuid = model.book.uuid
        model.onVisibilityChanged = { visible -> setReaderVisible(bookUuid, visible) }
        // Every route into playback ends at the player's rate, so watching
        // that catches all of them.
        model.onNarrationReady = { coordinator ->
            coordinator.player.setRateObserver(coordinator) { rate ->
                if (rate > 0 && generation != null && catalogueGeneration != generation) {
                    // From inside `play()`'s own notification.
                    coordinator.player.pause()
                    return@setRateObserver
                }
                if (rate > 0) {
                    // Play pressed after the sleep timer ran out: the reader is back.
                    sleepTimerRanOut = false
                    narrationDidStart(bookUuid)
                }
                // Zero is the release signal, and the only one that reaches
                // every way a read-along stops.
                updateScreenAwake()
            }
            // On a cold open the extraction finishes long after the screen
            // appeared.
            considerListeningHandoff(ListeningHandoff.Trigger.READER_READY)
        }
    }

    /** Whether [model] is a reader an account has left: what a reader's screen closes on. */
    fun hasLeft(model: ReaderModel): Boolean {
        val opened = model.accountGeneration ?: return false
        return opened != catalogueGeneration
    }

    /**
     * Lets one book's reader go once its own screen has left it and it is not
     * the one narrating. Identity is checked, so a later model for the same
     * book is not evicted.
     */
    fun readerDidClose(model: ReaderModel) {
        if (readers[model.book.uuid] !== model) return
        if (narratingBookUuid == model.book.uuid) {
            closedWhileNarrating.add(model.book.uuid)
            return
        }
        readers = readers - model.book.uuid
        model.release()
    }

    /**
     * Writes out every open book's position, then sends whatever is queued:
     * for the app going to the background, where the reader is not dismissed
     * and the debounce's tail would otherwise wait for a relaunch.
     */
    suspend fun flushOpenReaders() {
        // The log first, before anything here can wait on the network.
        logFlush()
        for (model in readers.values.toList()) model.saveProgress()
        // And the audiobook, which has no reader model.
        writeListeningPositionNow()
        drainPendingWrites(waitingForInFlight = true)
        logFlush()
    }

    /** How [flushOpenReaders] flushes the log. A test seam. */
    internal var logFlush: suspend () -> Unit = { withContext(Dispatchers.IO) { IssaLog.flush() } }

    /**
     * Releases every open reader of the account being left, and stops
     * narration if one of them is narrating. Not a book from the reader's own
     * files.
     */
    private fun releaseServerReaders() {
        val departing = readers.filterValues { !it.isLocal }.keys
        // Dropped before narration stops: no last save for the account being left.
        closedWhileNarrating.removeAll(departing)
        narratingBookUuid?.let { if (it in departing) stopNarration() }
        for (uuid in departing) {
            val model = readers[uuid] ?: continue
            readers = readers - uuid
            model.cancelPendingSave()
            model.readalong?.player?.pause()
        }
    }

    /** Silences narration and gives up the lock screen, if it held it. */
    fun stopNarration() {
        val uuid = narratingBookUuid ?: return
        narratingBookUuid = null
        readers[uuid]?.readalong?.player?.pause()
        nowPlayingController?.attach(null, null)
        releaseIfScreenClosed(uuid)
        updateScreenAwake()
    }

    /** Lets go of a model whose screen already closed, now that its narration has ended, with one last save. */
    private fun releaseIfScreenClosed(uuid: String) {
        if (!closedWhileNarrating.remove(uuid)) return
        val model = readers[uuid] ?: return
        readers = readers - uuid
        scope.launch {
            model.saveProgress()
            model.release()
        }
    }

    /**
     * Called when one open book's narration actually begins: playback is
     * exclusive, enforced at the moment a different book starts.
     */
    private fun narrationDidStart(bookUuid: String) {
        // Fires on every play, and most change nothing.
        if (narratingBookUuid == bookUuid) return
        val model = readers[bookUuid] ?: return
        val coordinator = model.readalong ?: return
        narratingBookUuid?.let { previous ->
            if (previous != bookUuid) {
                readers[previous]?.readalong?.player?.pause()
                releaseIfScreenClosed(previous)
            }
        }
        if (listening != null) stopListening(null)
        narratingBookUuid = bookUuid
        // A local book's art is the cover cut at import, read off the disk.
        val source = model.source
        val artworkFile = if (source is ReaderModel.Source.Local && model.book.localCopy?.hasCover == true) source.files.cover else null
        nowPlayingController?.attach(
            coordinator = coordinator,
            book = model.book,
            session = model.readerSession,
            artworkFile = artworkFile,
            chapterTitle = { model.chapterTitle },
        )
        updateScreenAwake()
    }

    /** Re-entrancy guard for [startListening]: a double tap ran it twice — two engines, two voices. */
    private var isStartingListening = false

    /**
     * The book a start has claimed but not yet attached, and which download it
     * expects to be reading by the time it does: what a removal has to see.
     */
    private var startingListening: Pair<String, BookContentService.Format?>? = null

    /** The chunk extraction a start is waiting on, the only handle there is on it. */
    private var listeningExtraction: Job? = null

    /** Which book a start has claimed. A test seam. */
    internal val startingListeningBook: String? get() = startingListening?.first

    /** Stages a claim without the start behind it. A test seam. */
    internal fun claimListeningStart(book: Book, format: BookContentService.Format?) {
        startingListening = book.uuid to format
    }

    /** Whether the start that claimed this book still holds it, under the account it began for. */
    private fun startStillClaimed(book: Book, generation: Int): Boolean {
        if (startingListening?.first != book.uuid || catalogueGeneration != generation) {
            IssaLog.info("listening start stood down", mapOf("book" to book.title))
            return false
        }
        return true
    }

    /** Starts a plain audiobook: fetch the manifest, resume where the server says we were, and hand it to Now Playing. */
    suspend fun startListening(book: Book, nowPlaying: NowPlayingController, settings: PlaybackSettings) {
        // A concurrent duplicate is dropped, not queued.
        if (isStartingListening) return
        isStartingListening = true
        startingListening = book.uuid to null
        try {
            val generation = catalogueGeneration
            // Each attempt speaks only for itself: the car reads this back.
            listeningError = null
            val session = session
            val url = ServerAddress.normalize(serverAddress)
            if (session == null || url == null) {
                listeningError = "Not signed in yet."
                return
            }
            // One player at a time.
            stopNarration()
            val current = listening
            if (listeningBook?.uuid == book.uuid && current != null) {
                current.player.play()
                // Nothing else republishes on a resume.
                publishListeningSnapshot(book, current)
                return
            }
            if (listening != null) stopListening(nowPlaying)
            listeningError = null
            val content = BookContentService(session.client)
            // An aligned read-along already on the device plays from its own
            // narration chunks, through a manifest synthesised over them, so the
            // two engines share a track list by construction. Downloaded only.
            if (book.readaloud?.isAligned == true && isDownloaded(book, BookContentService.Format.READALOUD)) {
                startingListening = book.uuid to BookContentService.Format.READALOUD
                val built = synthesisedListening(book, content)
                if (built != null) {
                    // The likeliest place for a removal to land, and the disk is
                    // asked again for the undo window's sake.
                    if (!startStillClaimed(book, generation) || !isDownloaded(book, BookContentService.Format.READALOUD)) return
                    val attached = attachListening(
                        built.manifest, AudiobookCoordinator.Source.Files(built.files), built.chapters, built.timeline,
                        ListeningResume.ManifestKind.SYNTHESISED, book, nowPlaying, settings,
                    )
                    // `wouldNotPlay` is the only outcome with anywhere left to go.
                    if (attached != ListeningAttachment.WOULD_NOT_PLAY) return
                    IssaLog.warning("chunk playback would not start; trying the server's manifest", mapOf("book" to book.title))
                    stopListening(nowPlaying)
                    listeningError = null
                }
            }
            // An account exit while the extraction ran: what comes next would be
            // a request for the departed account's book.
            if (catalogueGeneration != generation) {
                IssaLog.info("listening start stood down", mapOf("book" to book.title))
                return
            }
            val service = AudiobookService(session.client, url, session.tokenProvider)
            try {
                val manifest = service.manifest(book.uuid)
                if (!startStillClaimed(book, generation)) return
                if (manifest.playableTracks.isEmpty()) {
                    listeningError = "This audiobook has no playable tracks on the server."
                    return
                }
                // The download stands in for the manifest only when the manifest
                // has exactly one playable track; through the model, so an
                // audiobook inside its undo window is streamed instead.
                val playableAsOneFile = manifest.playableTracks.size == 1 && isDownloaded(book, BookContentService.Format.AUDIOBOOK)
                startingListening = book.uuid to if (playableAsOneFile) BookContentService.Format.AUDIOBOOK else null
                val source = if (playableAsOneFile) {
                    AudiobookCoordinator.Source.Local(content.localUrl(book, BookContentService.Format.AUDIOBOOK))
                } else {
                    // The token travels both as a bearer and as the cookie the
                    // server's audio routes accept: the player makes its own
                    // requests.
                    val base = service.trackBase(book.uuid).toString()
                    val token = session.tokenProvider.currentToken()
                    if (token != null) AudiobookCoordinator.Source.streaming(base, token) else AudiobookCoordinator.Source.Streaming(base, emptyMap())
                }
                if (!startStillClaimed(book, generation)) return
                val attached = attachListening(
                    manifest, source, emptyList(), null, ListeningResume.ManifestKind.ORIGINAL, book, nowPlaying, settings,
                )
                // A start that produced no audio must not leave the book in the
                // slot: this is the fall-back.
                if (attached == ListeningAttachment.WOULD_NOT_PLAY) stopListening(nowPlaying)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                IssaLog.failure("start listening", e, mapOf("book" to book.title))
                if (catalogueGeneration != generation) return
                listeningError = message(e)
            }
        } finally {
            isStartingListening = false
            startingListening = null
        }
    }

    /** A manifest over a book's own narration chunks. */
    private class Synthesised(
        val manifest: AudiobookManifest,
        val chapters: List<AudiobookChapter>,
        val files: Map<String, File>,
        val timeline: SmilTimeline,
    )

    /**
     * Builds a manifest over this book's own narration chunks, off the main
     * thread. Null for every way this can honestly fail; the caller falls
     * back to the server's manifest.
     */
    private suspend fun synthesisedListening(book: Book, content: BookContentService): Synthesised? {
        val epubFile = content.localUrl(book, BookContentService.Format.READALOUD)
        val bookId = book.uuid
        val title = book.title
        // The reader's, when a reader is open: the archive is already
        // inflated and the overlay already parsed.
        val openPackage = readers[book.uuid]?.epubPackage
        val openTimeline = readers[book.uuid]?.timeline
        val started = System.nanoTime()
        val measurer = readerServices?.measurer ?: com.benjaminissa.issareader.playback.AudioFileLength
        // Held, not merely awaited: the only handle a removal has on it.
        val extraction = scope.async(Dispatchers.IO) {
            val context = currentCoroutineContext()
            try {
                val source = ReadaloudSource.load(
                    epubFile, bookId, openPackage, openTimeline, isCancelled = { !context.isActive },
                )
                if (source.timeline.isEmpty || source.audioFiles.isEmpty()) {
                    IssaLog.warning("read-along has no narration; playing original", mapOf("book" to title))
                    return@async null
                }
                val cached = ChunkDurations.load(bookId)
                val measured = ChunkDurations.measure(source.audioFiles, cached, measurer)
                // Only when it grew.
                if (measured.size > cached.size) runCatching { ChunkDurations.save(measured, bookId) }
                ChunkManifest.make(source.timeline, source.epubPackage, source.audioFiles, measured, title) to source.timeline
            } catch (e: CancellationException) {
                // Ordinary: a removal revoking an extraction is a thing the
                // reader asked for.
                IssaLog.info("chunk extraction revoked", mapOf("book" to title))
                null
            } catch (e: Exception) {
                IssaLog.failure("chunk manifest", e, mapOf("book" to title))
                null
            }
        }
        listeningExtraction = extraction
        val built = try {
            extraction.await()
        } catch (_: CancellationException) {
            null
        } finally {
            if (listeningExtraction === extraction) listeningExtraction = null
        }
        if (built == null || built.first.manifest.playableTracks.isEmpty()) return null
        IssaLog.info(
            "chunk manifest built",
            mapOf(
                "book" to title,
                "tracks" to built.first.manifest.playableTracks.size.toString(),
                "chapters" to built.first.chapters.size.toString(),
                "ms" to format1((System.nanoTime() - started) / 1e6),
            ),
        )
        return Synthesised(built.first.manifest, built.first.chapters, built.first.files, built.second)
    }

    /** How an attach ended, for the one caller that has somewhere else to go. */
    enum class ListeningAttachment {
        /** Positioned, owned by this call, and playing unless the resume said otherwise. */
        STARTED,

        /** The audio this manifest names would not load; another manifest is worth trying. */
        WOULD_NOT_PLAY,

        /** The slot changed hands while this call was suspended: what is there owns it. */
        SLOT_TAKEN,
    }

    /**
     * Hands a manifest to a coordinator, Now Playing and the position writer,
     * and starts it where the resume ladder says: one tail for both track
     * lists.
     */
    internal suspend fun attachListening(
        manifest: AudiobookManifest,
        source: AudiobookCoordinator.Source,
        chapters: List<AudiobookChapter>,
        timeline: SmilTimeline?,
        manifestKind: ListeningResume.ManifestKind,
        book: Book,
        nowPlaying: NowPlayingController,
        settings: PlaybackSettings,
    ): ListeningAttachment {
        // Again, now that the suspensions are over: a read-along tapped during
        // them would otherwise still be playing.
        stopNarration()
        val coordinator = AudiobookCoordinator(
            manifest, source, chapters, AudioPlayer(requireReaderServices().makeMediaBackend()), scope,
        )
        coordinator.player.rate = settings.playbackRate.toFloat()
        // The level belongs to the book, not to the surface it is played from.
        coordinator.player.gain = VolumeTrim.gain(settings.volumeTrim(book.uuid))
        listening = coordinator
        listeningBook = book
        listeningFormat = formatRead(source)
        // Play and pause both have to reach the widget.
        coordinator.player.setRateObserver(this) { rate -> publishListeningSnapshot(book, coordinator, rate > 0) }
        nowPlaying.attach(coordinator, book, session, chapterTitle = { coordinator.chapterTitle })
        val resume = resolveListeningStart(book, coordinator, timeline, manifestKind)
        // The slot, after every suspension: identity, because starting the same
        // book twice is exactly the case that has to lose.
        if (listening !== coordinator) return slotChangedHands(book, coordinator, "resolvedStart")
        IssaLog.info(
            "listening started",
            mapOf(
                "book" to book.title,
                "from" to resume.reason.rawValue,
                "atBookTime" to format1(resume.bookTime ?: -1.0),
                "storedProgress" to format4(book.progress ?: -1.0),
                "manifestKind" to manifestKind.rawValue,
                "trackCount" to coordinator.tracks.size.toString(),
                "source" to if (manifestKind == ListeningResume.ManifestKind.SYNTHESISED) "chunks" else "original",
            ),
        )
        // Before a note plays: an unresolved start plays from zero, and the
        // writer must not persist that zero over a place this app could not find.
        prepareListeningGuard(book, resume.isTrusted)
        val time = resume.bookTime
        if (time != null) {
            val outcome = coordinator.seekToBookTime(time)
            if (listening !== coordinator) return slotChangedHands(book, coordinator, "seeked")
            when (outcome) {
                AudiobookCoordinator.MoveOutcome.LANDED -> coordinator.player.play()
                AudiobookCoordinator.MoveOutcome.UNPLAYABLE -> return declined(book, "seekDeclined")
                // A newer load inside this same coordinator overtook the
                // resume: nothing to say, and the publish and the writer are
                // still owed.
                AudiobookCoordinator.MoveOutcome.SUPERSEDED ->
                    IssaLog.info("listening resume was overtaken by a newer load", mapOf("book" to book.title))
            }
        } else {
            val outcome = coordinator.start(0.0)
            if (listening !== coordinator) return slotChangedHands(book, coordinator, "started")
            when (outcome) {
                AudiobookCoordinator.MoveOutcome.LANDED -> Unit
                AudiobookCoordinator.MoveOutcome.UNPLAYABLE -> return declined(book, "nothingLoaded")
                AudiobookCoordinator.MoveOutcome.SUPERSEDED ->
                    IssaLog.info("listening start was overtaken by a newer load", mapOf("book" to book.title))
            }
        }
        // After the seek, never before: a coordinator one line old reads 0.
        publishListeningSnapshot(book, coordinator)
        watchListeningProgress(book, coordinator)
        // A start finishing over a reader already open on this book.
        considerListeningHandoff(ListeningHandoff.Trigger.LISTENING_STARTED, duringStart = true)
        return ListeningAttachment.STARTED
    }

    /** Says out loud that a start produced no audio, and stops before it can look like one that did. */
    private fun declined(book: Book, reason: String): ListeningAttachment {
        IssaLog.warning("listening produced no audio", mapOf("book" to book.title, "reason" to reason))
        listeningError = "That book's audio would not play. Try downloading it again."
        return ListeningAttachment.WOULD_NOT_PLAY
    }

    /**
     * Silences a start that woke up to find the book already somewhere else,
     * and its rate observers. Now Playing is left to whatever took the book.
     */
    private fun slotChangedHands(book: Book, coordinator: AudiobookCoordinator, stage: String): ListeningAttachment {
        coordinator.player.removeRateObservers()
        coordinator.player.pause()
        IssaLog.info("listening slot changed hands while starting", mapOf("book" to book.title, "stage" to stage))
        return ListeningAttachment.SLOT_TAKEN
    }

    /**
     * Stops playback and lets go of everything holding onto it. Order
     * matters: `pause()` notifies its rate observers synchronously, so they go
     * first; and Now Playing holds the coordinator, so it is detached.
     */
    fun stopListening(nowPlaying: NowPlayingController?) {
        listeningProgressTask?.cancel()
        listeningProgressTask = null
        listening?.player?.removeRateObservers()
        nowPlaying?.attach(null, null)
        listening?.player?.pause()
        listening?.player?.release()
        listening = null
        listeningBook = null
        listeningFormat = null
    }

    /**
     * Writes the listening position back periodically: an hour of listening is
     * as much progress as an hour of reading.
     *
     * @param intervalMillis how long between writes; a test drives it in milliseconds.
     */
    internal fun watchListeningProgress(book: Book, coordinator: AudiobookCoordinator, intervalMillis: Long = 15_000) {
        listeningProgressTask?.cancel()
        listeningLastWritten = -1.0
        listeningProgressTask = scope.launch {
            while (isActive) {
                delay(intervalMillis)
                // Spends things (`consumeSteering`), so a cancel landing in the
                // sleep must not run the body.
                if (!isActive) return@launch
                val progress = coordinator.bookProgress
                // Only when it actually moved.
                if (abs(progress - listeningLastWritten) <= 0.0005) continue
                listeningLastWritten = progress
                // A scrub is the listener naming a place; the clock arriving
                // somewhere is not.
                val origin = if (coordinator.consumeSteering()) PositionOrigin.CHOSEN else PositionOrigin.DERIVED
                val accepted = writePosition(audioLocator(coordinator), ProgressService.now(), book.uuid, origin)
                // And the anchor — only for an accepted position, and only if
                // still wanted after the write's suspension.
                if (!isActive) return@launch
                val anchor = coordinator.currentAnchor
                if (accepted && anchor != null) runCatchingCancellable { store?.setAudioAnchor(anchor, book.uuid) }
                if (!isActive || listeningBook?.uuid != book.uuid) return@launch
                publishListeningSnapshot(book, coordinator)
            }
        }
    }

    /** The book progress the listening writer last wrote, or -1 when it has written nothing since it was armed. */
    private var listeningLastWritten: Double = -1.0

    /**
     * Writes where the audiobook is, now, as the writer's next tick would —
     * on the writer's terms exactly. For the exit flush.
     */
    private suspend fun writeListeningPositionNow() {
        if (listeningProgressTask == null) return
        val coordinator = listening ?: return
        val book = listeningBook ?: return
        val progress = coordinator.bookProgress
        if (abs(progress - listeningLastWritten) <= 0.0005) return
        listeningLastWritten = progress
        val origin = if (coordinator.consumeSteering()) PositionOrigin.CHOSEN else PositionOrigin.DERIVED
        val accepted = writePosition(audioLocator(coordinator), ProgressService.now(), book.uuid, origin)
        val anchor = coordinator.currentAnchor
        if (accepted && anchor != null) runCatchingCancellable { store?.setAudioAnchor(anchor, book.uuid) }
    }

    /**
     * Keeps the widget honest while an audiobook plays — only for the engine
     * in the listening slot.
     *
     * @param isPlaying what the player just reported, when driven by a rate change.
     */
    internal fun publishListeningSnapshot(book: Book, coordinator: AudiobookCoordinator, isPlaying: Boolean? = null) {
        if (listening !== coordinator || listeningBook?.uuid != book.uuid) return
        val progress = coordinator.bookProgress
        val total = coordinator.totalDuration
        currentBookPublisher.publish(
            book = book,
            session = session,
            progress = progress,
            chapter = coordinator.chapterTitle,
            remaining = if (total.isFinite() && total > 0) total * (1 - progress) else null,
            isPlaying = isPlaying ?: (coordinator.player.effectiveRate > 0),
            candidate = CurrentBookPublisher.Owner.Listening(book.uuid),
        )
    }

    /** Where an audiobook should resume, and why — with a log line good enough to diagnose the next one. */
    private suspend fun resolveListeningStart(
        book: Book,
        coordinator: AudiobookCoordinator,
        timeline: SmilTimeline?,
        manifestKind: ListeningResume.ManifestKind,
    ): ListeningResume.Resolution {
        val anchor = runCatchingCancellable { store?.audioAnchor(book.uuid) }
        val stored = book.position?.locator
        val overlay = timeline ?: readers[book.uuid]?.timeline
        val resolution = ListeningResume.resolve(anchor, book.position, overlay, coordinator.manifest)
        val fields = mutableMapOf(
            "book" to book.title,
            "manifestKind" to manifestKind.rawValue,
            "trackCount" to coordinator.tracks.size.toString(),
            "firstTrack" to (coordinator.manifest.playableTracks.firstOrNull()?.href ?: "none"),
            "storedScale" to (stored?.let { if (it.isAudioScaled) "audio" else "text" } ?: "none"),
            "storedHrefMatchesTrack" to (
                stored?.let { if (it.isAudioScaled) (coordinator.manifest.trackIndex(it.href) != null).toString() else "n/a" }
                    ?: "n/a"
                ),
            "timeline" to if (overlay == null) "absent" else "present",
        )
        when (resolution.reason) {
            ListeningResume.Reason.ANCHOR_NAMES_UNKNOWN_FILE -> {
                anchor?.let {
                    fields["anchorHref"] = it.audioHref
                    fields["anchorOffset"] = format1(it.offset)
                }
                IssaLog.warning("audio anchor names no track in this manifest", fields)
            }
            ListeningResume.Reason.NO_ANCHOR_STORED -> IssaLog.warning("no audio anchor stored for this book", fields)
            ListeningResume.Reason.ANCHOR_OLDER_THAN_POSITION -> {
                anchor?.let {
                    fields["anchorHref"] = it.audioHref
                    fields["anchorOffset"] = format1(it.offset)
                }
                fields["positionWrittenAt"] = book.position?.writtenAt?.toString() ?: "none"
                IssaLog.warning("audio anchor is older than the stored position", fields)
            }
            ListeningResume.Reason.AUDIO_POSITION_FROM_ANOTHER_MANIFEST -> {
                fields["bookTime"] = format1(resolution.bookTime ?: -1.0)
                IssaLog.warning("stored audio position scaled from another track list", fields)
            }
            else -> Unit
        }
        return resolution
    }

    /**
     * Downloads a book and waits for it, reporting progress as it goes,
     * through the same manager as every other download.
     */
    suspend fun downloadAndWait(book: Book, format: BookContentService.Format, onProgress: (Long, Long) -> Unit): File {
        val session = session ?: throw StorytellerError.NotAuthenticated()
        val downloads = downloads ?: throw StorytellerError.NotAuthenticated()
        val destination = BookContentService(session.client).localUrl(book, format)
        // Through the model: the bytes of an edition inside its undo window
        // are about to be deleted.
        if (isDownloaded(book, format)) return destination
        val job = DownloadManager.Job(book.uuid, format)
        // `download` can refuse to start at all — the Wi-Fi rule — and then
        // there is no state to wait on.
        if (!download(book, format)) {
            throw StorytellerError.Download(downloadRefusals[job] ?: "Couldn't start the download.")
        }
        // The removal `download` took back left the file where it was.
        if (isDownloaded(book, format)) return destination
        var lastWritten = 0L
        var lastTotal = 0L
        while (currentCoroutineContext().isActive) {
            when (val state = downloads.state(job)) {
                DownloadManager.State.Finished -> return destination
                is DownloadManager.State.Failed -> throw StorytellerError.Download(state.reason)
                is DownloadManager.State.Downloading -> {
                    lastWritten = state.bytesWritten
                    lastTotal = state.totalBytes
                    onProgress(state.bytesWritten, state.totalBytes)
                }
                // Not a failure: resuming picks straight back up. Reported in
                // the bytes the callback is defined in.
                is DownloadManager.State.Paused -> onProgress(lastWritten, lastTotal)
                DownloadManager.State.Queued -> Unit
                // Only the reader's Cancel clears a claimed job's state.
                null -> throw StorytellerError.Download("Download cancelled.")
            }
            delay(250)
        }
        throw CancellationException("download wait cancelled")
    }

    /**
     * Pending transfers, in a form the Downloads screen can list — and the
     * downloads the Wi-Fi rule held back, as failed rows saying why.
     */
    val downloadsPending: List<Pair<DownloadManager.Job, DownloadManager.State>>
        get() {
            val transfers = (downloads?.pending ?: emptyList()).filter { downloadRefusals[it.first] == null }
            val refused = downloadRefusals.map { it.key to DownloadManager.State.Failed(it.value) }
            return (transfers + refused).sortedWith(compareBy({ it.first.bookUuid }, { it.first.format.rawValue }))
        }

    /**
     * Downloads the reader asked for that the Wi-Fi rule held back, and the
     * sentence saying so, by job: the only record that the tap was heard.
     */
    var downloadRefusals: Map<DownloadManager.Job, String> by mutableStateOf(emptyMap())
        private set

    /** Stands in for `reachability.isExpensive` when set. A test seam. */
    internal var meteredNetworkOverride: Boolean? = null
        set(value) {
            field = value
            meteringMayHaveChanged()
        }

    /** Whether the connection is one the Wi-Fi rule holds large downloads back on: metered, or Data Saver. */
    private val isOnMeteredNetwork: Boolean get() = meteredNetworkOverride ?: reachability.isExpensive.value

    /** Takes [manager] as the download manager: the app's, built at launch. */
    fun useDownloads(manager: DownloadManager) {
        downloads = manager
    }

    var wifiOnlyDownloads: Boolean
        get() = downloads?.wifiOnly ?: false
        set(value) {
            downloads?.wifiOnly = value
            // The reader lifting the rule is the wait every refusal names ending.
            if (!value) retryRefusedDownloads()
        }

    /** Starts the downloads the Wi-Fi rule held back, once it no longer holds them, through [resumeDownload]. */
    private fun retryRefusedDownloads() {
        val refused = downloadRefusals.keys.toList()
        if (refused.isEmpty()) return
        IssaLog.info("retrying held-back downloads", mapOf("count" to refused.size.toString()))
        scope.launch {
            for (job in refused) {
                // Only what is still refused.
                if (downloadRefusals[job] == null) continue
                resumeDownload(job)
            }
        }
    }

    private fun meteringMayHaveChanged() {
        if (!isOnMeteredNetwork) retryRefusedDownloads()
    }

    /** Follows `reachability.isExpensive`, so a move from cellular to Wi-Fi — not a return from offline — is heard. */
    private fun watchMetering() {
        scope.launch { reachability.isExpensive.drop(1).collect { meteringMayHaveChanged() } }
    }

    /** Restarts a paused or failed transfer, looking the book back up so the free-space check has a size. */
    suspend fun resumeDownload(job: DownloadManager.Job) {
        val book = books.firstOrNull { it.uuid == job.bookUuid }
        if (book == null) {
            cancelPendingRemoval(job)
            downloadRefusals = downloadRefusals - job
            downloads?.start(job)
            return
        }
        download(book, job.format)
    }

    /**
     * Starts a download, refusing early if it plainly will not fit.
     *
     * @return whether a transfer was actually started — or the edition is
     *   simply still here. False means no state will ever exist for this job.
     */
    suspend fun download(book: Book, format: BookContentService.Format): Boolean {
        val downloads = downloads ?: return false
        val expected: Long? = when (format) {
            BookContentService.Format.READALOUD -> book.readaloud?.fileSize
            BookContentService.Format.AUDIOBOOK -> book.audiobook?.fileSize
            BookContentService.Format.EBOOK -> book.ebook?.fileSize
        }
        // An unknown size is not a known-small one: assumed large.
        val job = DownloadManager.Job(book.uuid, format)
        if (downloads.wifiOnly && isOnMeteredNetwork && (expected?.let { it > 20_000_000 } ?: true)) {
            downloadRefusals = downloadRefusals + (job to "Waiting for Wi-Fi to download this.")
            return false
        }
        downloadRefusals = downloadRefusals - job
        // After the guard, before the transfer.
        val tookBack = cancelPendingRemoval(job)
        // A removal taken back deleted nothing.
        if (tookBack && isDownloaded(book, format)) return true
        downloads.start(job, expected)
        return true
    }

    /** Search, using the store's full-text index when there is one. */
    suspend fun search(query: String): List<Book> {
        val store = store ?: return LibraryDerivation(books).search(query)
        return runCatchingCancellable { store.search(query) } ?: LibraryDerivation(books).search(query)
    }

    // Per-user state

    /**
     * Moves a book to a shelf the reader chose: takes the book out of the
     * rule's filings first, so the rule never overrides a choice made by hand.
     */
    suspend fun setStatus(status: Status, book: Book) {
        autoFiledBookUuids.remove(book.uuid)
        applyStatus(status, book)
    }

    /**
     * Moves a book to a shelf, whoever chose it: locally first, counted in
     * [localWrites] until its row is queued, queued only while it is still the
     * newest write for the book and the catalogue is still the account's.
     */
    private suspend fun applyStatus(status: Status, book: Book) {
        if (session == null) return
        val index = books.indexOfFirst { it.uuid == book.uuid }
        if (index < 0) return
        val generation = catalogueGeneration
        val mark = localWrites.begin(MutationQueue.Kind.STATUS, book.uuid)
        try {
            val updated = books[index].copy(status = status)
            books = books.toMutableList().also { it[index] = updated }
            rebuildDerived()
            persist(updated, generation)
            beforeQueueingStatus?.invoke(book.uuid)
            if (catalogueGeneration != generation) return
            if (!localWrites.isNewest(mark, MutationQueue.Kind.STATUS, book.uuid)) {
                books.firstOrNull { it.uuid == book.uuid }?.let { persist(it, generation) }
                return
            }
            // Queued, not sent directly: a shelf change made offline must survive.
            enqueue(MutationQueue.Kind.STATUS, book.uuid, MutationDrain.StatusPayload(status.uuid), MutationDrain.StatusPayload.serializer())
        } finally {
            // Not after a switch: the records were cleared with the account.
            if (catalogueGeneration == generation) localWrites.end(MutationQueue.Kind.STATUS, book.uuid)
        }
    }

    /** Runs between a status's local save and the queueing of its row. A test seam. */
    internal var beforeQueueingStatus: (suspend (String) -> Unit)? = null

    /** Rates a book, or clears its rating: counted and queued the way [applyStatus] counts and queues a status. */
    suspend fun setRating(value: Double?, book: Book) {
        if (session == null) return
        val generation = catalogueGeneration
        val mark = localWrites.begin(MutationQueue.Kind.RATING, book.uuid)
        try {
            ratings = if (value != null) ratings + (book.uuid to value) else ratings - book.uuid
            // Persisted, or a rating set offline vanished at the next cold launch.
            runCatchingCancellable { store?.setRating(value, book.uuid) }
            beforeQueueingRating?.invoke(book.uuid)
            if (catalogueGeneration != generation) return
            if (!localWrites.isNewest(mark, MutationQueue.Kind.RATING, book.uuid)) {
                runCatchingCancellable { store?.setRating(ratings[book.uuid], book.uuid) }
                return
            }
            enqueue(MutationQueue.Kind.RATING, book.uuid, MutationDrain.RatingPayload(value), MutationDrain.RatingPayload.serializer())
        } finally {
            if (catalogueGeneration == generation) localWrites.end(MutationQueue.Kind.RATING, book.uuid)
        }
    }

    /** Runs between a rating's local save and the queueing of its row. A test seam. */
    internal var beforeQueueingRating: (suspend (String) -> Unit)? = null

    /**
     * Records a position the app has just written, without asking the server,
     * and persists it, so a chapter read offline and then killed comes back
     * where it was.
     */
    suspend fun recordPosition(locator: ReadiumLocator, timestamp: Double, bookUuid: String) {
        val index = books.indexOfFirst { it.uuid == bookUuid }
        if (index < 0) return
        val generation = catalogueGeneration
        val shelvedOn = LibraryArrangement.stage(books[index])
        val updated = books[index].adopting(locator, timestamp)
        books = books.toMutableList().also { it[index] = updated }
        // A book with no status is shelved by its position, so this write can
        // move it to another shelf: the whole rebuild then, the cheap one
        // otherwise.
        if (LibraryArrangement.stage(updated) != shelvedOn) rebuildDerived() else rebuildAfterPositionChange()
        persist(updated, generation)
    }

    /**
     * Saves a book this account has just changed, unless the catalogue has
     * stopped being this account's: the check sits immediately before the
     * upsert is submitted.
     */
    private suspend fun persist(book: Book, generation: Int) {
        if (catalogueGeneration != generation) return
        runCatchingCancellable { store?.upsert(book) }
    }

    /** One high-water mark per book and clock, for the life of the session. */
    internal var positionGuards: MutableMap<String, PositionGuard> = mutableMapOf()

    /**
     * Puts one candidate position to this book's guard for that clock,
     * seeding the guard first if it has never been used.
     */
    internal fun admitPosition(locator: ReadiumLocator, origin: PositionOrigin, bookUuid: String): PositionGuard.Decision {
        val book = books.firstOrNull { it.uuid == bookUuid }
        // Keyed by book *and* by clock: a fraction of the text and a fraction
        // of the audio are fractions of different timelines.
        val guardKey = positionGuardKey(bookUuid, locator.isAudioScaled)
        val state = positionGuards[guardKey]?.copy() ?: seededGuard(book, locator.isAudioScaled)
        // Read before `decide`, which is what clears it.
        val wasHeld = state.awaitingChoice
        val decision = state.decide(locator.locations?.totalProgression, origin)
        positionGuards[guardKey] = state
        // A steer names a place in the book, which the other clock cannot be
        // told — but it can be told that what it was holding is no longer true.
        if (origin == PositionOrigin.CHOSEN && decision.isAllowed) {
            val other = positionGuardKey(bookUuid, !locator.isAudioScaled)
            positionGuards[other]?.let { positionGuards[other] = it.forgettingItsMark() }
        }
        // The hold letting go is a trigger of its own.
        if (wasHeld && !state.awaitingChoice && listeningBook?.uuid == bookUuid) {
            considerListeningHandoff(ListeningHandoff.Trigger.LISTENER_STEERED)
        }
        return decision
    }

    /**
     * Arms — or releases — the audio clock's guard as an audiobook starts.
     * When nothing could be resolved, the clock is held until the listener
     * names somewhere: the app genuinely does not know where they were.
     *
     * @param trusted whether `ListeningResume` found a place the app may also write down.
     */
    internal fun prepareListeningGuard(book: Book, trusted: Boolean) {
        val key = positionGuardKey(book.uuid, true)
        val stored = book.position?.locator
        val mark = positionGuards[key]?.highWater ?: seededGuard(book, true).highWater
        if (trusted) {
            // Released at the mark it already held, never lowered.
            if (positionGuards[key]?.awaitingChoice == true) positionGuards[key] = seededGuard(book, true, mark)
            return
        }
        // A book with no stored position anywhere has nothing to lose.
        if (book.position == null) return
        positionGuards[key] = seededGuard(book, true, mark, awaitingChoice = true)
        IssaLog.warning(
            "listening resume not exact, derived writes held until the listener steers",
            mapOf(
                "book" to book.uuid,
                "storedScale" to if (stored?.isAudioScaled == true) "audio" else "text",
                "held" to format4(mark),
            ),
        )
    }

    /** Why each clock's last refused write was refused, so a refusal is a line in the log, not a state it repeats. */
    private val refusalsLogged = mutableMapOf<String, String>()

    /** Logs a refusal when it starts, and notes when the clock starts taking writes again. */
    private fun noteRefusal(reason: String?, guardKey: String, fields: () -> Map<String, String>) {
        if (reason == null) {
            if (refusalsLogged.remove(guardKey) != null) IssaLog.info("position writes accepted again", mapOf("guard" to guardKey))
            return
        }
        if (refusalsLogged.put(guardKey, reason) == reason) return
        IssaLog.warning("position write refused", fields())
    }

    /**
     * The single place a reading position is written: the reader's saves and
     * the audiobook's fifteen-second writer both. A refused write is dropped;
     * a write that outlives its account stops, reporting false.
     */
    suspend fun writePosition(locator: ReadiumLocator, timestamp: Double, bookUuid: String, origin: PositionOrigin): Boolean {
        // No queue means no account.
        if (mutations == null) {
            IssaLog.warning("write dropped: no queue", mapOf("book" to bookUuid, "kind" to "position"))
            return false
        }
        val generation = catalogueGeneration
        val guardKey = positionGuardKey(bookUuid, locator.isAudioScaled)
        when (val decision = admitPosition(locator, origin, bookUuid)) {
            PositionGuard.Decision.Allow -> noteRefusal(null, guardKey) { emptyMap() }
            is PositionGuard.Decision.Refuse -> {
                noteRefusal("belowHighWater", guardKey) {
                    mapOf(
                        "book" to bookUuid, "held" to format4(decision.held), "candidate" to format4(decision.candidate),
                        "origin" to origin.rawValue, "reason" to "belowHighWater",
                    )
                }
                return false
            }
            is PositionGuard.Decision.AwaitChoice -> {
                noteRefusal("awaitingChoice", guardKey) {
                    mapOf(
                        "book" to bookUuid, "held" to format4(positionGuards[guardKey]?.highWater ?: 0.0),
                        "candidate" to (decision.candidate?.let(::format4) ?: "none"),
                        "origin" to origin.rawValue, "reason" to "awaitingChoice",
                    )
                }
                return false
            }
        }
        // Only a substantial move earns a line.
        val previous = books.firstOrNull { it.uuid == bookUuid }?.progress
        val candidate = locator.locations?.totalProgression
        if (candidate != null && previous != null && abs(candidate - previous) > 0.02) {
            IssaLog.info(
                "position moved",
                mapOf("book" to bookUuid, "from" to format4(previous), "to" to format4(candidate), "origin" to origin.rawValue),
            )
        }
        // Locally first, then the queue: the queue ends in a drain that can
        // wait on the network, and a page turned offline must be kept.
        recordPosition(locator, timestamp, bookUuid)
        if (catalogueGeneration != generation) return false
        enqueue(
            MutationQueue.Kind.POSITION, bookUuid,
            MutationDrain.PositionPayload(locator, timestamp), MutationDrain.PositionPayload.serializer(),
            supersedes = timestamp,
        )
        if (catalogueGeneration != generation) return false
        advanceStatusIfUnset(locator, bookUuid)
        return catalogueGeneration == generation
    }

    /**
     * Files a book the way the server would have, where the server will not:
     * 3.x cannot advance a book with no status at all (see `StatusAdvance`).
     * Until the server holds it, forward only, and only on a change.
     */
    private suspend fun advanceStatusIfUnset(locator: ReadiumLocator, bookUuid: String) {
        // Restoring the server's rule needs the permission the status route
        // is gated on; only an explicit refusal stops it.
        val user = (session?.state?.value as? Session.State.SignedIn)?.user
        if (user?.permissions?.bookDownload == false) return
        val generation = catalogueGeneration
        var unfiledOnServer = false
        if (bookUuid in autoFiledBookUuids) {
            // A filing still on its way into the queue is as unsent as one in it.
            var queued = bookUuid in localWrites.inFlight(MutationQueue.Kind.STATUS)
            if (!queued) {
                val fence = unsentFence()
                if (catalogueGeneration != generation) return
                queued = keepsLocal(MutationQueue.Kind.STATUS, bookUuid, fence)
            }
            if (queued) {
                // Asked again after the suspension: a status chosen by hand
                // meanwhile takes the book out.
                unfiledOnServer = bookUuid in autoFiledBookUuids
            } else {
                autoFiledBookUuids.remove(bookUuid)
            }
        }
        val book = bookByUuid[bookUuid] ?: return
        if (book.status != null && !unfiledOnServer) return
        val serverGeneration = session?.capabilities?.value?.generation
        val known = if (statuses.isEmpty()) books.mapNotNull { it.status } else statuses
        val next = StatusAdvance.statusToSet(locator, if (unfiledOnServer) null else book.status, serverGeneration, known)
            ?: return
        if (advanceRank(next) <= advanceRank(book.status)) return
        IssaLog.info(
            "status set after a position write",
            mapOf("book" to bookUuid, "status" to next.name, "generation" to (serverGeneration?.rawValue ?: "undetermined")),
        )
        autoFiledBookUuids.add(bookUuid)
        applyStatus(next, book)
    }

    /** Books the rule filed, until their status is seen to have left the queue. Only in memory. */
    private val autoFiledBookUuids = mutableSetOf<String>()

    /**
     * Status and rating changes this device has made, for the two questions
     * asked of a change the server may not hold yet: is it still on its way
     * into the queue, and has a newer one for the same book begun since? The
     * serial is never reset; the records go with the account.
     */
    private class LocalWrites {
        private class Record(var serial: Int, var inFlight: Int)

        private var serial = 0
        private val records = mutableMapOf<MutationQueue.Kind, MutableMap<String, Record>>()

        /** Where the serial stands. */
        val mark: Int get() = serial

        /** Counts a write in, stamped as the newest for its book. */
        fun begin(kind: MutationQueue.Kind, bookUuid: String): Int {
            serial += 1
            val forKind = records.getOrPut(kind) { mutableMapOf() }
            val inFlight = forKind[bookUuid]?.inFlight ?: 0
            forKind[bookUuid] = Record(serial, inFlight + 1)
            return serial
        }

        /** Counts a write out, once its row is in the queue or it has given up. */
        fun end(kind: MutationQueue.Kind, bookUuid: String) {
            val record = records[kind]?.get(bookUuid) ?: return
            record.inFlight = maxOf(0, record.inFlight - 1)
        }

        /** Whether no write of this kind has begun for the book since the one stamped [mark]. */
        fun isNewest(mark: Int, kind: MutationQueue.Kind, bookUuid: String): Boolean =
            (records[kind]?.get(bookUuid)?.serial ?: mark) <= mark

        /** Books with a write of this kind between its begin and its end. */
        fun inFlight(kind: MutationQueue.Kind): Set<String> =
            records[kind]?.filterValues { it.inFlight > 0 }?.keys?.toSet() ?: emptySet()

        /** Books with a write of this kind begun after [mark]. */
        fun books(kind: MutationQueue.Kind, mark: Int): Set<String> =
            records[kind]?.filterValues { it.serial > mark }?.keys?.toSet() ?: emptySet()

        /** Forgets every book, and keeps the serial. */
        fun removeAll() {
            records.clear()
        }
    }

    private val localWrites = LocalWrites()

    /**
     * Re-reads one book after something changed it server-side, keeping an
     * unsent status as [refreshLibrary] keeps one, and re-seeding the guards
     * from the answer.
     */
    suspend fun refresh(book: Book) {
        val session = session ?: return
        if (books.none { it.uuid == book.uuid }) return
        val generation = catalogueGeneration
        val fence = unsentFence()
        val fresh = runCatchingCancellable { LibraryService(session.client).book(book.uuid) } ?: return
        if (catalogueGeneration != generation) return
        // Resolved after the suspension: `books` can be replaced during it.
        val index = books.indexOfFirst { it.uuid == book.uuid }
        if (index < 0) return
        val reconciledFrom = books[index]
        val updated = reconciledFrom.reconciled(fresh, keepingStatus = keepsLocal(MutationQueue.Kind.STATUS, book.uuid, fence))
        books = books.toMutableList().also { it[index] = updated }
        reseedGuards(listOf(updated))
        // Most appearances learn nothing: only a changed book pays for the rebuild.
        if (updated != reconciledFrom) rebuildDerived()
    }

    companion object {
        internal const val LAST_SERVER_KEY = "issa.lastServer"
        private const val LIBRARY_MODE_KEY = "issa.library.mode"

        /** How long the removal toast stands, in milliseconds. */
        const val REMOVAL_UNDO_WINDOW_MILLIS = 6_000L

        /** A sentence a person can act on, with the recovery hint appended. */
        fun message(error: Throwable): String = describe(error)

        /** Every address worth trying for what someone typed. See `ServerAddress`. */
        fun candidateServerUrls(input: String): List<URI> = ServerAddress.candidates(input)

        fun normalizeServerUrl(input: String): URI? = ServerAddress.normalize(input)

        /**
         * Which candidate actually has a Storyteller behind it: a short,
         * unauthenticated probe of `server/public`, with a timeout, because a
         * port with nothing listening hangs rather than failing.
         */
        suspend fun firstReachable(candidates: List<URI>, timeoutSeconds: Long = 6): URI? {
            if (candidates.size <= 1) return candidates.firstOrNull()
            for (candidate in candidates) if (probe(candidate, timeoutSeconds)) return candidate
            // Everything failed: the error the reader gets is the real one from a full attempt.
            return candidates.first()
        }

        private suspend fun probe(url: URI, timeoutSeconds: Long): Boolean = withContext(Dispatchers.IO) {
            val client = OkHttpClient.Builder()
                .callTimeout(timeoutSeconds, TimeUnit.SECONDS)
                .connectTimeout(timeoutSeconds, TimeUnit.SECONDS)
                .build()
            try {
                val target = url.toString().trimEnd('/') + "/api/v2/server/public"
                client.newCall(Request.Builder().url(target).get().build()).execute().use { response ->
                    // Any answer at all means something is listening and speaking HTTP.
                    response.code in 200..499
                }
            } catch (_: Exception) {
                false
            } finally {
                client.dispatcher.executorService.shutdown()
                client.connectionPool.evictAll()
            }
        }

        /** Where the last signed-in account for a server is remembered. */
        internal fun accountKey(url: URI): String = "issa.account.$url"

        /** Whether deleting one edition takes the audiobook engine with it. */
        fun removalSilencesListening(reading: BookContentService.Format?, removing: BookContentService.Format?): Boolean {
            removing ?: return true
            reading ?: return false
            return reading == removing
        }

        /** And whether it takes the read-along with it: narration is only ever built from the `.readaloud` package. */
        fun removalSilencesNarration(removing: BookContentService.Format?): Boolean =
            removing == null || removing == BookContentService.Format.READALOUD

        /** The key a position guard is filed under: the book, and which clock the position is on. */
        fun positionGuardKey(bookUuid: String, isAudioScaled: Boolean): String = "$bookUuid#${if (isAudioScaled) "audio" else "text"}"

        /**
         * A guard for one of a book's two clocks, seeded from what the book
         * says about that clock — and with the duration, without which the
         * guard's absolute bound does not exist.
         */
        fun seededGuard(book: Book?, isAudioScaled: Boolean, highWater: Double? = null, awaitingChoice: Boolean = false): PositionGuard {
            val narration = book?.let(LibraryArrangement::duration) ?: 0.0
            val seed = book?.position?.locator?.takeIf { it.isAudioScaled == isAudioScaled }?.totalProgression ?: 0.0
            return PositionGuard(highWater ?: seed, if (narration > 0) narration else null, awaitingChoice)
        }

        /** Which downloaded edition a source reads, if any. */
        private fun formatRead(source: AudiobookCoordinator.Source): BookContentService.Format? = when (source) {
            is AudiobookCoordinator.Source.Files -> BookContentService.Format.READALOUD
            is AudiobookCoordinator.Source.Local -> BookContentService.Format.AUDIOBOOK
            is AudiobookCoordinator.Source.Streaming -> null
        }

        /** How far along the rule's own statuses a book is: none, then Reading, then Read. */
        private fun advanceRank(status: Status?): Int = when (status?.name) {
            Status.readName -> 2
            Status.readingName -> 1
            else -> 0
        }

        /**
         * A locator for a position inside an audiobook: the track as the href,
         * the chapter the listener is in as the title, and `totalProgression`,
         * which every other client reads to show percent complete.
         */
        fun audioLocator(coordinator: AudiobookCoordinator): ReadiumLocator {
            val tracks = coordinator.tracks
            val index = min(coordinator.trackIndex, maxOf(tracks.size - 1, 0))
            val track = tracks.getOrNull(index)
            val trackStart = coordinator.manifest.startTime(index)
            val trackDuration = track?.duration ?: 0.0
            val within = if (trackDuration > 0) {
                (coordinator.bookProgress * coordinator.totalDuration - trackStart) / trackDuration
            } else {
                0.0
            }
            val chapter = coordinator.chapterTitle
            return ReadiumLocator(
                href = track?.href ?: "",
                type = track?.type ?: "audio/mpeg",
                title = track?.let { if (chapter.isEmpty()) coordinator.manifest.title(it, index) else chapter },
                locations = ReadiumLocator.Locations(
                    progression = within.asProgression ?: 0.0,
                    totalProgression = coordinator.bookProgress,
                ),
            )
        }

        private fun format1(value: Double) = String.format(Locale.ROOT, "%.1f", value)
        private fun format4(value: Double) = String.format(Locale.ROOT, "%.4f", value)
    }
}

/** Swift's spelling of where a position came from, for the log. */
internal val PositionOrigin.rawValue: String get() = name.lowercase()

/** `try?`: the value, or null on any failure but cancellation, which is passed on. */
internal inline fun <T> runCatchingCancellable(block: () -> T): T? = try {
    block()
} catch (e: CancellationException) {
    throw e
} catch (_: Exception) {
    null
}
