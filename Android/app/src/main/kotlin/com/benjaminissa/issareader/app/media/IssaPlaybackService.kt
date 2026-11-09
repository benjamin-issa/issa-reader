package com.benjaminissa.issareader.app.media

import android.app.PendingIntent
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.KeyEvent
import androidx.annotation.DrawableRes
import androidx.annotation.OptIn
import androidx.core.content.IntentCompat
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.CommandButton
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaConstants
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionError
import androidx.media3.session.SessionResult
import com.benjaminissa.issareader.R
import com.benjaminissa.issareader.app.IssaApplication
import com.benjaminissa.issareader.app.model.NowPlayingSink
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.sync.CarCatalogue
import com.benjaminissa.issareader.playback.CommandRouter
import com.benjaminissa.issareader.playback.ControlSurface
import com.benjaminissa.issareader.playback.android.ControllerSurfaces
import com.benjaminissa.issareader.playback.android.HeadphoneRouteMonitor
import com.benjaminissa.issareader.playback.android.HeadsetButtons
import com.benjaminissa.issareader.playback.android.IssaSessionPlayer
import com.benjaminissa.issareader.playback.android.SessionMediaIds
import com.benjaminissa.issareader.playback.android.SessionPresentation
import com.benjaminissa.issareader.playback.android.SessionTransport
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * The media session and Android Auto: Swift's CarPlay scene, its
 * `CarPlayBridge` and the system half of `NowPlayingController` in one
 * service, because on Android one media library session is all three — the
 * lock screen and notification, the headset's buttons, and the car's browse
 * tree, Now Playing screen and steering wheel.
 *
 * - **Now Playing** is [IssaSessionPlayer], presenting what
 *   `NowPlayingController` publishes (it is that controller's
 *   [NowPlayingSink] while the service runs): the book, its byline, the
 *   chapter, the square cover, the position on the reader's chosen scope, the
 *   chapters as the queue, and a rate button.
 * - **Commands** go through `CommandRouter` with the surface of the controller
 *   that sent them — Android Auto is the car, the notification and the app
 *   are the phone, a hardware key is inferred from the route as iOS inferred
 *   everything — so the per-surface bindings decide what the wheel, a
 *   headset's double press or the lock screen's skip does.
 * - **The browse tree** is [AutoBrowseTree] over `CarCatalogue`: Recent,
 *   Library and Downloaded, as CarPlay's tabs. Playing a row starts the book
 *   through the app (`AppGraph.startListeningFromCar`), and the session then
 *   shows it.
 * - **Voice search** ranks the audio books with [VoiceSearch] and plays the
 *   best match; an empty query resumes the most recent.
 * - **A failure** is said on the car's screen, as CarPlay's alert said it:
 *   the session's playback error, with the message the start gave.
 */
@OptIn(UnstableApi::class)
open class IssaPlaybackService : MediaLibraryService() {
    internal lateinit var host: MediaHost
        private set
    internal lateinit var player: IssaSessionPlayer
        private set
    internal lateinit var session: MediaLibrarySession
        private set

    /** The session's callback: the browse tree, search, playing and the rate button. */
    internal val callback = Callback()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val headset = HeadsetButtons { key, from -> HeadsetButtons.route(host.router, key, from) }
    private var routeMonitor: AutoCloseable? = null
    private var libraryWatch: AutoCloseable? = null

    /** How many tabs each browser said it draws, from its root hints. */
    private val tabLimits = HashMap<MediaSession.ControllerInfo, Int>()

    /** Android Auto's controllers, so the car's fallback witness hears each go. */
    private val carControllers = HashSet<MediaSession.ControllerInfo>()

    /** The last results per query, between `onSearch` and `onGetSearchResult`. */
    private val searchResults = HashMap<String, List<Book>>()

    /** What the rate button last said, so it is rebuilt only when the speed moves. */
    private var buttonsRate = Double.NaN

    /** The cover address last granted for Now Playing. */
    private var grantedArtwork: Uri? = null

    /** The error the car is showing, if any. */
    internal var shownError: PlaybackException? = null
        private set

    /** The app's media half, or a test's stand-in for it. */
    protected open fun makeHost(): MediaHost = (application as IssaApplication).graph.media.host

    override fun onCreate() {
        super.onCreate()
        host = makeHost()
        player = IssaSessionPlayer(host.router, PlayerDelegate())
        val builder = MediaLibrarySession.Builder(this, player, callback)
            // A library error — signed out — is the car's whole screen, with
            // the way to fix it, rather than a toast over an empty list.
            .setLibraryErrorReplicationMode(MediaLibrarySession.LIBRARY_ERROR_REPLICATION_MODE_FATAL)
            .setMediaButtonPreferences(buttons())
        appActivity()?.let(builder::setSessionActivity)
        session = builder.build()
        setMediaNotificationProvider(
            DefaultMediaNotificationProvider.Builder(this)
                .setChannelName(R.string.playback_channel_name)
                .build()
                .apply { setSmallIcon(R.drawable.ic_notification_listening) },
        )
        host.router.onTransportChange = { transportChanged() }
        transportChanged()
        routeMonitor = runCatching { HeadphoneRouteMonitor(this) { host.router.headphonesRouted = it } }.getOrNull()
        libraryWatch = host.observeLibrary { libraryChanged() }
        host.attachSink(sink)
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession = session

    override fun onDestroy() {
        host.attachSink(null)
        host.router.onTransportChange = null
        routeMonitor?.close()
        libraryWatch?.close()
        for (controller in carControllers) host.carPresence.carControllerDisconnected(controller)
        carControllers.clear()
        scope.cancel()
        session.release()
        player.release()
        super.onDestroy()
    }

    // Now Playing

    private val sink = object : NowPlayingSink {
        override fun publish(entry: CommandRouter.NowPlaying?, artwork: ByteArray?) = present(entry, artwork)
    }

    private fun present(entry: CommandRouter.NowPlaying?, artwork: ByteArray?) {
        val playing = host.playing
        if (entry == null || playing == null) {
            player.present(null)
            return
        }
        val cover = CarCovers.uri(this, playing.book)
        if (cover != null && cover != grantedArtwork) {
            CarCovers.grant(this, cover, CarCovers.carPackages + carControllers.map { it.packageName })
            grantedArtwork = cover
        }
        player.present(
            SessionPresentation(
                bookId = playing.book.uuid,
                title = entry.title,
                artist = entry.artist,
                chapter = entry.album,
                artworkData = artwork,
                artworkUri = cover,
                elapsed = entry.elapsed,
                duration = entry.duration,
                isPlaying = playing.isPlaying,
                effectiveRate = entry.rate,
                rate = playing.rate,
                chapters = host.chapters(),
                chapterIndex = host.currentChapter(),
            ),
        )
        // Something playing is the answer to whatever failed before it.
        if (playing.isPlaying) clearError()
        if (host.playbackRate != buttonsRate) session.setMediaButtonPreferences(buttons())
    }

    /** The buttons beside play, for the transport and speed now. */
    private fun buttons(): List<CommandButton> {
        buttonsRate = host.playbackRate
        return SessionTransport.buttons(host.router.transport, buttonsRate)
    }

    /**
     * The bindings changed which transport the system draws — the car came or
     * went, headphones were plugged in, a binding or an interval changed in
     * Settings — so the buttons and the commands on offer follow.
     */
    private fun transportChanged() {
        val transport = host.router.transport
        if (transport != null) player.setSkipIntervals(transport.skipBackwardInterval, transport.skipForwardInterval)
        session.setMediaButtonPreferences(buttons())
        for (controller in session.connectedControllers) {
            if (ControllerSurfaces.isCar(session, controller)) continue
            session.setAvailableCommands(controller, SessionTransport.sessionCommands(), playerCommands(controller))
        }
    }

    /** The car's controller is offered the track pair always; its own binding decides what it does. */
    private fun playerCommands(controller: MediaSession.ControllerInfo) =
        SessionTransport.playerCommands(
            ControllerSurfaces.isCar(session, controller) || host.router.transport?.usesTrackCommands == true,
        )

    // Errors

    /** Says [error] where the car shows it: the session's playback error. */
    private fun showError(error: PlaybackException) {
        shownError = error
        session.setPlaybackException(error)
    }

    private fun clearError() {
        if (shownError == null) return
        shownError = null
        session.setPlaybackException(null)
    }

    /** Signed out: the car cannot sign in, so it says where to. */
    private fun signInError(): SessionError = SessionError(SessionError.ERROR_SESSION_AUTHENTICATION_EXPIRED, SIGN_IN_MESSAGE, resolutionExtras())

    private fun resolutionExtras(): Bundle {
        val extras = Bundle()
        val open = appActivity() ?: return extras
        extras.putString(MediaConstants.EXTRAS_KEY_ERROR_RESOLUTION_ACTION_LABEL_COMPAT, "Open Issa Reader")
        extras.putParcelable(MediaConstants.EXTRAS_KEY_ERROR_RESOLUTION_ACTION_INTENT_COMPAT, open)
        return extras
    }

    private fun failure(message: String, code: Int = SessionError.ERROR_UNKNOWN): PlaybackException =
        PlaybackException(message, null, code, resolutionExtras().takeIf { code == SessionError.ERROR_SESSION_AUTHENTICATION_EXPIRED } ?: Bundle.EMPTY)

    // The library

    /** The books changed: every browser subscribed to a shelf asks again. */
    private fun libraryChanged() {
        searchResults.clear()
        val catalogue = host.catalogue
        session.notifyChildrenChanged(AutoBrowseTree.ROOT, CarCatalogue.Shelf.entries.size, null)
        for (shelf in CarCatalogue.Shelf.entries) {
            session.notifyChildrenChanged(AutoBrowseTree.shelfId(shelf), AutoBrowseTree.items(catalogue, shelf).size, null)
        }
    }

    private fun tabs(): List<MediaItem> = CarCatalogue.Shelf.entries.map { AutoBrowseTree.tab(it, resourceUri(tabIcon(it))) }

    @DrawableRes
    private fun tabIcon(shelf: CarCatalogue.Shelf): Int = when (shelf) {
        CarCatalogue.Shelf.RECENT -> R.drawable.ic_auto_recent
        CarCatalogue.Shelf.LIBRARY -> R.drawable.ic_auto_library
        CarCatalogue.Shelf.DOWNLOADED -> R.drawable.ic_auto_downloaded
    }

    private fun resourceUri(@DrawableRes id: Int): Uri = Uri.Builder()
        .scheme(ContentResolver.SCHEME_ANDROID_RESOURCE)
        .authority(packageName)
        .appendPath(resources.getResourceTypeName(id))
        .appendPath(resources.getResourceEntryName(id))
        .build()

    /** One shelf's rows for [browser], whose car is granted their covers. */
    private fun shelfResult(browser: MediaSession.ControllerInfo, shelf: CarCatalogue.Shelf): LibraryResult<ImmutableList<MediaItem>> {
        if (host.access == MediaHost.Access.SIGNED_OUT) return LibraryResult.ofError(signInError())
        val catalogue = host.catalogue
        val byUuid = catalogue.books.associateBy { it.uuid }
        val items = AutoBrowseTree.items(catalogue, shelf) { uuid -> byUuid[uuid]?.let { CarCovers.uri(this, it) } }
        grantCovers(browser, items)
        return LibraryResult.ofItemList(items, null)
    }

    private fun grantCovers(browser: MediaSession.ControllerInfo, items: List<MediaItem>) {
        for (item in items) {
            val uri = item.mediaMetadata.artworkUri ?: continue
            if (uri.scheme == ContentResolver.SCHEME_CONTENT) CarCovers.grant(this, uri, listOf(browser.packageName))
        }
    }

    /** A playable row for any book the car may play, as the shelves draw it. */
    private fun playableItem(book: Book, catalogue: CarCatalogue = host.catalogue): MediaItem? {
        val entry = catalogue.entries(CarCatalogue.Shelf.LIBRARY, Int.MAX_VALUE).firstOrNull { it.bookUuid == book.uuid } ?: return null
        return AutoBrowseTree.bookItem(entry, book, CarCovers.uri(this, book))
    }

    /** The audio books, ranked against a spoken or typed query: best first. */
    internal suspend fun search(query: String): List<Book> {
        host.awaitLibrary()
        val catalogue = host.catalogue
        val playable = catalogue.entries(CarCatalogue.Shelf.LIBRARY, Int.MAX_VALUE).map { it.bookUuid }.toSet()
        val books = catalogue.books.filter { it.uuid in playable }
        val ranked = VoiceSearch.rank(books, query)
        if (ranked.isNotEmpty() || VoiceSearch.namesNothing(query)) return ranked
        // The store's own index matches tags and subtitles too, and wants
        // every word: the place to look when the ranking found nothing.
        val byUuid = books.associateBy { it.uuid }
        return host.searchLibrary(query).mapNotNull { byUuid[it.uuid] }.distinctBy { it.uuid }
    }

    /** The book to resume: what is loaded now, else the top of Recent. */
    private fun mostRecent(catalogue: CarCatalogue = host.catalogue): Book? {
        val playable = catalogue.entries(CarCatalogue.Shelf.LIBRARY, Int.MAX_VALUE).map { it.bookUuid }.toSet()
        host.playing?.book?.takeIf { it.uuid in playable }?.let { return it }
        val recent = catalogue.entries(CarCatalogue.Shelf.RECENT, 1).firstOrNull() ?: return null
        return catalogue.books.firstOrNull { it.uuid == recent.bookUuid }
    }

    /**
     * What a controller asked to play, as items this session can start: a
     * book from the list, a voice search's best match, the most recent book
     * for an empty query, or a chapter of the book playing.
     *
     * @throws Unplayable with the sentence to show when nothing resolves.
     */
    internal suspend fun resolve(items: List<MediaItem>): List<MediaItem> {
        host.awaitLibrary()
        if (host.access == MediaHost.Access.SIGNED_OUT) throw Unplayable(failure(SIGN_IN_MESSAGE, SessionError.ERROR_SESSION_AUTHENTICATION_EXPIRED))
        val catalogue = host.catalogue
        var refusal: String? = null
        val resolved = items.mapNotNull { item ->
            val query = item.requestMetadata.searchQuery
            if (query != null) {
                val spoken = VoiceSearch.query(query, item.requestMetadata.extras)
                val book = if (VoiceSearch.namesNothing(spoken)) mostRecent(catalogue) else search(spoken).firstOrNull()
                if (book == null) {
                    refusal = if (VoiceSearch.namesNothing(spoken)) CarCatalogue.Shelf.RECENT.emptyMessage else "Nothing in your library matches “${spoken.trim()}”."
                    IssaLog.info("android auto search found nothing", mapOf("query" to spoken))
                } else {
                    IssaLog.info("android auto search", mapOf("query" to spoken, "book" to book.title))
                }
                return@mapNotNull book?.let { playableItem(it, catalogue) }
            }
            SessionMediaIds.chapter(item.mediaId)?.let { return@mapNotNull item }
            val uuid = SessionMediaIds.bookUuid(item.mediaId)
            val book = uuid?.let { id -> catalogue.books.firstOrNull { it.uuid == id } }
            if (book == null) refusal = BOOK_GONE
            book?.let { playableItem(it, catalogue) }
        }
        if (resolved.isEmpty()) throw Unplayable(failure(refusal ?: BOOK_GONE))
        return resolved
    }

    /** Nothing a controller asked for can play; [error] says why, on the car's screen. */
    internal class Unplayable(val error: PlaybackException) : Exception(error.message)

    /** Starts what [item] names, saying on the car's screen if it could not. */
    private suspend fun start(item: MediaItem?) {
        val id = item?.mediaId ?: return
        val chapter = SessionMediaIds.chapter(id)
        val uuid = SessionMediaIds.bookUuid(id) ?: chapter?.first ?: return
        if (chapter != null && host.playing?.book?.uuid == uuid) {
            host.playChapter(chapter.second)
            return
        }
        if (host.access == MediaHost.Access.SIGNED_OUT) {
            showError(failure(SIGN_IN_MESSAGE, SessionError.ERROR_SESSION_AUTHENTICATION_EXPIRED))
            return
        }
        clearError()
        IssaLog.info("android auto play", mapOf("book" to uuid))
        val message = host.startListening(uuid)
        if (message != null) {
            // Reported rather than logged alone: streaming needs a signal, a
            // car often has none, and a row that silently does nothing at
            // 70mph is indistinguishable from a crash.
            IssaLog.error("android auto could not play", mapOf("book" to uuid, "reason" to message))
            showError(failure(message))
        }
    }

    /** Runs [block] on the main thread as a future, for a callback that has to wait. */
    private fun <T> future(block: suspend () -> T): ListenableFuture<T> {
        val result = SettableFuture.create<T>()
        scope.launch {
            try {
                result.set(block())
            } catch (e: CancellationException) {
                result.cancel(false)
                throw e
            } catch (e: Exception) {
                result.setException(e)
            }
        }
        return result
    }

    /** The app's own screen, which the notification and a car's "open" action lead to. */
    private fun appActivity(): PendingIntent? {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        return PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    /**
     * Who may read the library through the browse tree: Android Auto and the
     * car, the system's media controls, the app itself, the assistant and the
     * phone's own Bluetooth and watch bridges, and any controller the system
     * trusts with media control. The library is the reader's; an app that
     * merely binds the service is not shown it.
     */
    private fun mayBrowse(controller: MediaSession.ControllerInfo): Boolean =
        controller.isTrusted || ControllerSurfaces.isCar(session, controller) ||
            session.isMediaNotificationController(controller) || controller.packageName == packageName ||
            controller.packageName in BROWSERS

    private inner class PlayerDelegate : IssaSessionPlayer.Delegate {
        override fun requestSurface(): ControlSurface? =
            ControllerSurfaces.surface(session, session.controllerForCurrentRequest, packageName)

        override fun setMediaItems(items: List<MediaItem>, startIndex: Int, startPositionMs: Long): ListenableFuture<*> {
            val target = items.getOrNull(startIndex) ?: items.firstOrNull()
            return future { start(target) }
        }

        override fun playChapter(index: Int): ListenableFuture<*> = future {
            IssaLog.info("android auto chapter picked", mapOf("index" to index.toString()))
            host.playChapter(index)
        }
    }

    internal inner class Callback : MediaLibrarySession.Callback {
        override fun onConnect(session: MediaSession, controller: MediaSession.ControllerInfo): MediaSession.ConnectionResult {
            if (ControllerSurfaces.isCar(session, controller) && carControllers.add(controller)) {
                host.carPresence.carControllerConnected(controller)
            }
            return MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                .setAvailablePlayerCommands(playerCommands(controller))
                .setAvailableSessionCommands(SessionTransport.sessionCommands())
                .setMediaButtonPreferences(buttons())
                .build()
        }

        override fun onDisconnected(session: MediaSession, controller: MediaSession.ControllerInfo) {
            tabLimits.remove(controller)
            if (carControllers.remove(controller)) host.carPresence.carControllerDisconnected(controller)
        }

        override fun onGetLibraryRoot(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<MediaItem>> {
            val limit = params?.extras?.getInt(AutoBrowseTree.ROOT_CHILDREN_LIMIT, 0) ?: 0
            if (limit > 0) tabLimits[browser] = limit
            return Futures.immediateFuture(LibraryResult.ofItem(AutoBrowseTree.root(), AutoBrowseTree.rootParams()))
        }

        override fun onGetChildren(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            parentId: String,
            page: Int,
            pageSize: Int,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> {
            if (!mayBrowse(browser)) return Futures.immediateFuture(LibraryResult.ofError(SessionError.ERROR_PERMISSION_DENIED))
            if (parentId == AutoBrowseTree.ROOT) {
                // Filtered and clamped to what the car draws: a tab bar is the
                // car's, and it is the one that says how many.
                val chosen = AutoBrowseTree.tabs(tabs(), tabLimits[browser] ?: Int.MAX_VALUE).ifEmpty { tabs().take(1) }
                return Futures.immediateFuture(LibraryResult.ofItemList(AutoBrowseTree.page(chosen, page, pageSize), null))
            }
            val shelf = AutoBrowseTree.shelf(parentId)
                ?: return Futures.immediateFuture(LibraryResult.ofError(SessionError.ERROR_BAD_VALUE))
            val answer: () -> LibraryResult<ImmutableList<MediaItem>> = {
                val all = shelfResult(browser, shelf)
                if (all.resultCode == LibraryResult.RESULT_SUCCESS) {
                    LibraryResult.ofItemList(AutoBrowseTree.page(all.value.orEmpty(), page, pageSize), null)
                } else {
                    all
                }
            }
            // A car connecting to a cold process: the library is on its way,
            // and an empty list now would read as an app with nothing in it.
            if (host.access == MediaHost.Access.LOADING) {
                return future {
                    host.awaitLibrary()
                    answer()
                }
            }
            return Futures.immediateFuture(answer())
        }

        override fun onGetItem(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            mediaId: String,
        ): ListenableFuture<LibraryResult<MediaItem>> {
            if (!mayBrowse(browser)) return Futures.immediateFuture(LibraryResult.ofError(SessionError.ERROR_PERMISSION_DENIED))
            val item = when {
                mediaId == AutoBrowseTree.ROOT -> AutoBrowseTree.root()
                AutoBrowseTree.shelf(mediaId) != null -> tabs().firstOrNull { it.mediaId == mediaId }
                else -> SessionMediaIds.bookUuid(mediaId)?.let { uuid ->
                    val catalogue = host.catalogue
                    catalogue.books.firstOrNull { it.uuid == uuid }?.let { playableItem(it, catalogue) }
                }
            }
            return Futures.immediateFuture(
                if (item != null) LibraryResult.ofItem(item, null) else LibraryResult.ofError(SessionError.ERROR_BAD_VALUE),
            )
        }

        override fun onSearch(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            query: String,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<Void>> {
            if (!mayBrowse(browser)) return Futures.immediateFuture(LibraryResult.ofError(SessionError.ERROR_PERMISSION_DENIED))
            return future {
                val results = search(query)
                searchResults[query] = results
                session.notifySearchResultChanged(browser, query, results.size, params)
                LibraryResult.ofVoid()
            }
        }

        override fun onGetSearchResult(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            query: String,
            page: Int,
            pageSize: Int,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> {
            if (!mayBrowse(browser)) return Futures.immediateFuture(LibraryResult.ofError(SessionError.ERROR_PERMISSION_DENIED))
            return future {
                if (host.access == MediaHost.Access.SIGNED_OUT) return@future LibraryResult.ofError(signInError())
                val catalogue = host.catalogue
                val items = (searchResults[query] ?: search(query)).mapNotNull { playableItem(it, catalogue) }
                grantCovers(browser, items)
                LibraryResult.ofItemList(AutoBrowseTree.page(items, page, pageSize), null)
            }
        }

        override fun onSetMediaItems(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
            mediaItems: MutableList<MediaItem>,
            startIndex: Int,
            startPositionMs: Long,
        ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> = future {
            // Each request speaks only for itself, as each start does.
            clearError()
            val resolved = try {
                resolve(mediaItems)
            } catch (refused: Unplayable) {
                showError(refused.error)
                throw refused
            }
            // The book resumes where the server says it was, not at a position
            // a controller guessed.
            MediaSession.MediaItemsWithStartPosition(resolved.take(1), 0, C.TIME_UNSET)
        }

        override fun onAddMediaItems(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
            mediaItems: MutableList<MediaItem>,
        ): ListenableFuture<MutableList<MediaItem>> = future {
            try {
                resolve(mediaItems).toMutableList()
            } catch (refused: Unplayable) {
                showError(refused.error)
                throw refused
            }
        }

        /** The book a play button resumes with nothing loaded: the last listened. */
        override fun onPlaybackResumption(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
            isForPlayback: Boolean,
        ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> = future {
            host.awaitLibrary()
            val catalogue = host.catalogue
            val book = mostRecent(catalogue) ?: throw UnsupportedOperationException("nothing to resume")
            val item = playableItem(book, catalogue) ?: throw UnsupportedOperationException("nothing to resume")
            item.mediaMetadata.artworkUri?.let { CarCovers.grant(this@IssaPlaybackService, it, CarCovers.carPackages) }
            MediaSession.MediaItemsWithStartPosition(listOf(item), 0, C.TIME_UNSET)
        }

        override fun onCustomCommand(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
            customCommand: SessionCommand,
            args: Bundle,
        ): ListenableFuture<SessionResult> {
            if (customCommand.customAction != SessionTransport.CYCLE_RATE) {
                return Futures.immediateFuture(SessionResult(SessionError.ERROR_NOT_SUPPORTED))
            }
            host.cycleRate()
            session.setMediaButtonPreferences(buttons())
            return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
        }

        /**
         * A hardware key: decoded here, so a headset's double press is the
         * wheel's `»` under the bindings rather than Media3's next chapter.
         * The notification's own buttons arrive this way on older Android and
         * are the phone's, discrete, so Media3 handles those; so does a key
         * with nothing loaded, whose play resumes the last book.
         */
        override fun onMediaButtonEvent(
            session: MediaSession,
            controllerInfo: MediaSession.ControllerInfo,
            intent: Intent,
        ): Boolean {
            if (session.isMediaNotificationController(controllerInfo)) return false
            if (player.presentation == null) return false
            val event = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_KEY_EVENT, KeyEvent::class.java) ?: return false
            val from = if (ControllerSurfaces.isCar(session, controllerInfo)) ControlSurface.CAR else null
            return headset.handle(event, from)
        }
    }

    companion object {
        /** What the car says when there is no account to play from. */
        const val SIGN_IN_MESSAGE = "Sign in on your phone"

        /** CarPlay's message for a row whose book has gone. */
        const val BOOK_GONE = "That book is no longer in your library."

        /** The packages that may browse the library besides the car and the trusted. */
        private val BROWSERS = setOf(
            ControllerSurfaces.SYSTEM_UI_PACKAGE,
            "com.google.android.googlequicksearchbox",
            "com.google.android.carassistant",
            "com.google.android.wearable.app",
            "com.google.android.apps.wear.companion",
            "com.android.bluetooth",
        )
    }
}
