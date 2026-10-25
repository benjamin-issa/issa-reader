package com.benjaminissa.issareader.app.ui

import com.benjaminissa.issareader.app.local.LocalBooksRoute
import com.benjaminissa.issareader.app.local.LocalLibrary
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.CoverCache
import com.benjaminissa.issareader.app.model.NowPlayingController
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.model.SignOutCentre
import com.benjaminissa.issareader.app.ui.settings.ScreenServices
import com.benjaminissa.issareader.app.ui.settings.SettingsAccount
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.core.auth.TokenPersisting
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.Creator
import com.benjaminissa.issareader.core.model.EbookFormat
import com.benjaminissa.issareader.core.model.LocalBookMetadata
import com.benjaminissa.issareader.core.model.LocalContributor
import com.benjaminissa.issareader.core.model.LocalCopy
import com.benjaminissa.issareader.core.model.LocalNotice
import com.benjaminissa.issareader.core.model.ReadaloudFormat
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.model.ServerCapabilities
import com.benjaminissa.issareader.core.model.ServerGeneration
import com.benjaminissa.issareader.core.model.StoredPosition
import com.benjaminissa.issareader.core.model.local
import com.benjaminissa.issareader.core.networking.MonitoredReachability
import com.benjaminissa.issareader.playback.AudioLocation
import com.benjaminissa.issareader.playback.AudioPlayer
import com.benjaminissa.issareader.playback.ChapterSpan
import com.benjaminissa.issareader.playback.CommandMap
import com.benjaminissa.issareader.playback.MediaBackend
import com.benjaminissa.issareader.playback.MediaSupport
import com.benjaminissa.issareader.playback.MediaTime
import com.benjaminissa.issareader.playback.PlaybackAction
import com.benjaminissa.issareader.playback.PlaybackDriving
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import java.io.File
import java.nio.file.Files
import java.time.Instant

/**
 * A small, fixed state for the Settings, player and local-books screens: the
 * signed-in "sweep" account on the fixture server, six books two of which are
 * narrated, two books from the reader's files, and something playing.
 *
 * Named apart from the screens port's `FixtureLibrary`/`FixtureServer`, which
 * build the whole library from a recorded server.
 */
internal class SettingsFixture {
    val root: File = Files.createTempDirectory("settings-fixture").toFile()
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    val defaults = InMemoryKeyValueStore()
    private val centre = SignOutCentre()
    val settings = PlaybackSettings(defaults, centre)
    val app = AppModel(
        keychain = NoTokens,
        defaults = defaults,
        notificationCentre = centre,
        reachability = MonitoredReachability(),
        scope = scope,
    )
    val nowPlaying = NowPlayingController(scope)
    val local = LocalLibrary(
        root = File(root, "Local"),
        storeDirectory = File(root, "Store"),
        scope = scope,
        mediaSupport = NoMedia,
        contentResolver = null,
    )
    val coverCache = CoverCache(directory = File(root, "Covers"))
    val services = ScreenServices(
        app = app,
        settings = settings,
        nowPlaying = nowPlaying,
        local = local,
        localRoute = LocalBooksRoute(defaults),
        coverCache = coverCache,
        versionText = "1.5.1 (52)",
    )

    fun withLibrary(): SettingsFixture = apply { app.books = serverBooks }

    fun withLocalBooks(): SettingsFixture = apply { local.setBooksForTesting(localBooks) }

    fun close() {
        settings.close()
        scope.cancel()
        root.deleteRecursively()
    }

    companion object {
        val account = SettingsAccount(
            username = "sweep",
            server = "http://issa-fixture.test",
            capabilities = ServerCapabilities(
                serverDiscovery = true,
                homeSections = true,
                shelves = true,
                sidebar = true,
                libraryFacets = false,
                generation = ServerGeneration.V3,
                reportedVersion = "3.0.0-beta.49",
            ),
        )

        private fun creator(name: String, kind: String, uuid: String) = Creator(uuid = "$uuid-$kind", name = name)

        private fun position(progress: Double) = StoredPosition(
            locator = ReadiumLocator(
                href = "OEBPS/chapter01.xhtml",
                type = "application/xhtml+xml",
                locations = ReadiumLocator.Locations(totalProgression = progress),
            ),
            timestamp = 1_790_000_000_000.0,
        )

        /** A server book; narrated ones carry an aligned read-along of [narration] seconds. */
        fun book(
            uuid: String,
            title: String,
            author: String,
            narrator: String? = null,
            narration: Double? = null,
            progress: Double? = null,
        ): Book = Book(
            uuid = uuid,
            title = title,
            authors = listOf(creator(author, "a", uuid)),
            narrators = listOfNotNull(narrator?.let { creator(it, "n", uuid) }),
            creators = emptyList(),
            series = emptyList(),
            tags = emptyList(),
            collections = emptyList(),
            identifiers = emptyList(),
            ebook = EbookFormat(uuid = "$uuid-e", filepath = "book.epub", identifiers = emptyList()),
            readaloud = narration?.let {
                ReadaloudFormat(uuid = "$uuid-r", filepath = "book-readaloud.epub", status = "ALIGNED", duration = it, identifiers = emptyList())
            },
            position = progress?.let(::position),
        )

        val peterAndWendy = book(
            "4f1c8a52-1b11-4f61-9a0e-5a7b2f6c0001", "Peter and Wendy", "J. M. Barrie",
            narrator = "Lucy Simmons", narration = 4 * 3600.0 + 12 * 60, progress = 0.42,
        )

        val serverBooks: List<Book> = listOf(
            peterAndWendy,
            book("4f1c8a52-1b11-4f61-9a0e-5a7b2f6c0002", "Pride and Prejudice", "Jane Austen", narrator = "Karen Savage", narration = 11 * 3600.0),
            book("4f1c8a52-1b11-4f61-9a0e-5a7b2f6c0003", "Dracula", "Bram Stoker", progress = 0.18),
            book("4f1c8a52-1b11-4f61-9a0e-5a7b2f6c0004", "Carmilla", "J. Sheridan Le Fanu"),
            book("4f1c8a52-1b11-4f61-9a0e-5a7b2f6c0005", "The Wind in the Willows", "Kenneth Grahame"),
            book("4f1c8a52-1b11-4f61-9a0e-5a7b2f6c0006", "Middlemarch", "George Eliot"),
        )

        private val imported: Instant = Instant.parse("2026-10-12T09:30:00Z")

        val localBooks: List<Book> = listOf(
            Book.local(
                uuid = "9a0e5a7b-2f6c-4f61-8c11-000000000101",
                metadata = LocalBookMetadata(
                    title = "Alice's Adventures in Wonderland",
                    description = "<div><p>Alice follows a White Rabbit down a rabbit hole &amp; into a world of nonsense.</p></div>",
                    authors = listOf(LocalContributor("Lewis Carroll")),
                    narrators = listOf(LocalContributor("Kristin Hughes")),
                ),
                narrationDuration = 25_440.0,
                copy = LocalCopy(
                    fileName = "alice-in-wonderland.epub", fingerprint = "f1", byteCount = 148_200_000,
                    importedAt = imported, epubVersion = "3.0", notices = emptyList(),
                ),
            ).copy(position = position(0.27)),
            Book.local(
                uuid = "9a0e5a7b-2f6c-4f61-8c11-000000000102",
                metadata = LocalBookMetadata(title = "The Secret Garden", authors = listOf(LocalContributor("Frances Hodgson Burnett"))),
                narrationDuration = null,
                copy = LocalCopy(
                    fileName = "the-secret-garden.epub", fingerprint = "f2", byteCount = 1_240_000,
                    importedAt = imported, epubVersion = "3.0", isFixedLayout = true, notices = listOf(LocalNotice.FIXED_LAYOUT),
                ),
            ),
        )

        val localSizes: Map<String, Long> = mapOf(
            localBooks[0].uuid to 151_300_000L,
            localBooks[1].uuid to 1_310_000L,
        )
    }
}

/** No stored tokens, and nowhere to store one. */
private object NoTokens : TokenPersisting {
    override fun read(account: String): String? = null
    override fun write(token: String, account: String): Boolean = true
    override fun delete(account: String): Boolean = true
}

private object NoMedia : MediaSupport {
    override fun isPlayable(mimeType: String): Boolean = true
    override fun mimeType(extension: String): String? = null
}

/** An engine that plays nothing, so a player can be drawn playing or paused. */
private class SilentBackend : MediaBackend {
    override var sessionListener: MediaBackend.SessionListener? = null
    override fun configureSession() = Unit
    override fun activateSession() = Unit
    override fun deactivateSession() = Unit
    override val currentItem: MediaBackend.Item? = null
    override fun replaceItem(location: AudioLocation, listener: MediaBackend.ItemListener): MediaBackend.Item = error("not used")
    override fun cancelPendingSeeks() = Unit
    override suspend fun seek(to: MediaTime): Boolean = true
    override var rate: Float = 0f
    override var volume: Float = 1f
    override var gain: Float = 1f
    override val currentTime: Double = 0.0
    override val isPlaying: Boolean = false
    override fun setTimeObserver(intervalSeconds: Double, observer: ((Double) -> Unit)?) = Unit
    override fun release() = Unit
}

/**
 * A coordinator part-way through a chapter: 42 % of a 4 h 12 m book, in a
 * chapter that began 1 h 40 m in and runs 38 minutes.
 */
internal class FixturePlayback(playing: Boolean) : PlaybackDriving {
    override val player: AudioPlayer = AudioPlayer(SilentBackend()).also { if (playing) it.play() }
    override val bookProgress: Double = 0.42
    override val totalDuration: Double = 4 * 3600.0 + 12 * 60
    override val currentChapterTitle: String = "Chapter VII · The Home Under the Ground"
    override val chapterSpan: ChapterSpan = ChapterSpan(start = 100 * 60.0, duration = 38 * 60.0)
    override suspend fun seekToBookProgress(progress: Double) = Unit
    override suspend fun perform(action: PlaybackAction, map: CommandMap) = Unit
}
