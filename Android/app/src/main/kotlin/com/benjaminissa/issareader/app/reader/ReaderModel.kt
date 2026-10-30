package com.benjaminissa.issareader.app.reader

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.CurrentBookPublisher
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.download.DownloadManager
import com.benjaminissa.issareader.core.model.Annotation
import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.LocalBookFiles
import com.benjaminissa.issareader.core.model.ReadingProgress
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.model.StoredPosition
import com.benjaminissa.issareader.core.model.asProgression
import com.benjaminissa.issareader.core.sync.PositionOrigin
import com.benjaminissa.issareader.core.sync.ProgressService
import com.benjaminissa.issareader.epub.EpubFontResolver
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.EpubStyleSheet
import com.benjaminissa.issareader.epub.SmilEntry
import com.benjaminissa.issareader.epub.SmilParser
import com.benjaminissa.issareader.epub.SmilTimeline
import com.benjaminissa.issareader.playback.AudioExtraction
import com.benjaminissa.issareader.playback.AudioFileLength
import com.benjaminissa.issareader.playback.AudioPlayer
import com.benjaminissa.issareader.playback.ChunkDurations
import com.benjaminissa.issareader.playback.DurationMeasurer
import com.benjaminissa.issareader.playback.ListeningHandoff
import com.benjaminissa.issareader.playback.MediaBackend
import com.benjaminissa.issareader.playback.ReadalongCoordinator
import com.benjaminissa.issareader.playback.VolumeTrim
import com.benjaminissa.issareader.render.ArchiveImageSource
import com.benjaminissa.issareader.render.BookSearch
import com.benjaminissa.issareader.render.ChapterParser
import com.benjaminissa.issareader.render.LocatorAnchoring
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.RenderedPage
import com.benjaminissa.issareader.render.StyledChapter
import com.benjaminissa.issareader.render.TextRange
import com.benjaminissa.issareader.render.android.ChapterLayout
import com.benjaminissa.issareader.render.android.ReaderFonts
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale
import java.util.UUID
import kotlin.math.abs

/** A page's size in pixels, inside its margins: what a chapter is laid out for. */
data class PageSize(val width: Double, val height: Double) {
    val isEmpty: Boolean get() = !(width > 0) || !(height > 0)

    companion object {
        val ZERO = PageSize(0.0, 0.0)
    }
}

/**
 * What a reader needs from the app that is not about the book: where its work
 * runs, how its pages are set, and how its narration is played.
 *
 * @param scope a main-thread scope whose dispatcher posts — the coordinators'
 *   end-of-file hop is part of their contract.
 * @param fonts the faces pages are set in; needs an Android `Context`.
 * @param makeMediaBackend a fresh engine for each narration: on Android the
 *   ExoPlayer backend (`:playback-android`).
 * @param scale pixels per point: the parser measures in points, the layout in
 *   pixels.
 * @param measurer reads the length of an audio file whose clips state no end.
 */
class ReaderServices(
    val scope: CoroutineScope,
    val fonts: ReaderFonts,
    val makeMediaBackend: () -> MediaBackend,
    val scale: Double = 1.0,
    val io: CoroutineDispatcher = Dispatchers.IO,
    val measurer: DurationMeasurer = AudioFileLength,
)

/**
 * Drives one open book: downloads it, lays out chapters, tracks position.
 *
 * App-owned and outliving its screen, as the Swift model is: `AppModel` keeps
 * one per open book (`AppModel.reader(book, session)`), installs its hooks,
 * and lets it go when its screen has closed and it is not narrating.
 *
 * Observable: the state a reader screen draws is Compose snapshot state.
 * Main-thread only, as the Swift class is `@MainActor`.
 */
class ReaderModel(
    val book: Book,
    val source: Source,
    private val services: ReaderServices,
    style: ReaderStyle = ReaderStyle(),
) {
    constructor(book: Book, session: Session, services: ReaderServices, style: ReaderStyle = ReaderStyle()) :
        this(book, Source.Server(session), services, style)

    sealed interface Phase {
        data class Loading(val message: String) : Phase

        /** Fetching the book itself, with real bytes to show. Can take minutes, and must be cancellable. */
        data class Downloading(val received: Long, val total: Long) : Phase
        data object Ready : Phase
        data class Failed(val reason: String) : Phase
    }

    /**
     * Where the book comes from, and so where what the reader writes goes. Not
     * "Origin": `PositionOrigin` is the other kind of where-from.
     */
    sealed interface Source {
        /** A book from the signed-in server, its place written through the app's queue. */
        data class Server(val session: Session) : Source

        /** A book the reader added from their own files, its place kept on this device. */
        data class Local(val files: LocalBookFiles) : Source
    }

    /**
     * A chapter that would not open, once the book already had. Said over the
     * page rather than instead of it; identified, so the same words a second
     * time are a second notice.
     */
    data class ChapterNotice(val message: String, val id: String = UUID.randomUUID().toString())

    var phase: Phase by mutableStateOf(Phase.Loading("Opening…"))
        private set
    var epubPackage: EpubPackage? by mutableStateOf(null)
        internal set

    var chapterNotice: ChapterNotice? by mutableStateOf(null)
        private set

    /** Takes a notice down — that one only, so a later notice that replaced it is not cleared by the earlier one's timer. */
    fun dismissChapterNotice(notice: ChapterNotice) {
        if (chapterNotice?.id != notice.id) return
        chapterNotice = null
    }

    /** The book's stylesheets, parsed once each; the book's, not the reader's preferences. */
    private var styleSheets: Map<String, EpubStyleSheet> = emptyMap()
    var timeline: SmilTimeline? by mutableStateOf(null)
        private set
    var layout: ChapterLayout? by mutableStateOf(null)
        private set
    var chapterIndex: Int by mutableIntStateOf(0)
        private set
    var pageIndex: Int by mutableIntStateOf(0)

    /**
     * Bumped whenever the chapter on screen is replaced or re-paginated: a
     * chapter and page number alone cannot say whether the page changed.
     */
    var layoutRevision: Int by mutableIntStateOf(0)
        private set

    /** Exactly which page is on screen. */
    data class PageKey(val chapter: Int, val page: Int, val revision: Int)

    val pageKey: PageKey get() = PageKey(chapterIndex, pageIndex, layoutRevision)

    /** The chapters either side of this one, laid out before anyone turns to them — `true` is the one after. */
    internal var neighbours: Map<Boolean, Neighbour> = emptyMap()
        private set

    /**
     * Whether the chapters either side are wanted at all: only while pages
     * slide or cover. Set by the page turner.
     */
    var keepsNeighbours: Boolean = false
        set(value) {
            field = value
            if (!value) dropNeighbours()
        }
    private val neighbourTasks = mutableMapOf<Boolean, Job>()

    /** The key the chapter on screen was laid out under. */
    private var layoutKey: NeighbourKey? = null

    /** Called between a neighbour's parse and its layout. A test seam, spent when it fires. */
    internal var whilePreparingNeighbour: (suspend () -> Unit)? = null

    /**
     * The narrated sentence to light on the page: the one the voice is on,
     * when it is in the chapter on screen. Scoped by document because ids are
     * unique per chapter, not per book.
     */
    val activeFragmentId: String? get() = activeFragment(currentSpineHref)

    /** The narrated sentence to light in one document — this chapter's, or a neighbour's sliding in. */
    fun activeFragment(inDocument: String?): String? {
        val fragment = narratedFragment ?: return null
        return if (narratedDocument == inDocument) fragment else null
    }

    private var narratedFragment: String? by mutableStateOf(null)
    private var narratedDocument: String? by mutableStateOf(null)

    /** Present only when the book has usable media overlays. */
    var readalong: ReadalongCoordinator? by mutableStateOf(null)
        private set

    /**
     * How the current position came about. Stored on the model rather than
     * passed per save, so the flush on closing inherits the classification of
     * the move that produced the position.
     */
    internal var positionOrigin: PositionOrigin = PositionOrigin.CHOSEN
        private set

    /** The narrated sentence the server said we were on: the one anchor the audio clock can use directly. */
    private var restoredSentenceId: String? = null

    /**
     * Where the voice was when this book was last put down. Consulted by
     * [narrationStart] only while that sentence is on the page on screen.
     */
    private var quitAnchor: AudioAnchor? = null

    /** Which `open` is the current one, read after every suspension in it. */
    private var openGeneration = 0

    /**
     * How many times narration has been put back to the just-opened state by
     * [clearNarration].
     *
     * Read by [startNarration] before it suspends and again when it comes
     * back, to tell a stop that overtook it from a file that would not play.
     * The coordinator already declines to finish a move a stop overtook, so
     * the start comes back refused either way, and only this says which: a
     * stop is the reader's own request and has nothing to report, where a
     * refusal is a notice. Counted rather than flagged, so a start made after
     * the stop is not taken for the one it overtook.
     */
    private var narrationGeneration = 0

    /**
     * The answer [pendingNarrationStart] gave for one page, so that asking
     * again — and the player sheet asks on every redraw, a drag on its
     * scrubber included — is a comparison and not a walk of the chapter.
     * Valid for the page it was worked out on and the generation it was
     * worked out under: a stop empties [quitAnchor], and so counts as one.
     */
    private var pendingNarrationMemo: Triple<PageKey, Int, PendingNarrationStart?>? = null

    /** Called at the start of narration's preparation. A test seam, spent when it fires. */
    internal var whilePreparingNarration: (suspend () -> Unit)? = null

    /** The extraction narration's preparation runs, off the main thread. A test seam, for one it can hold. */
    internal var extractNarration: (EpubPackage, SmilTimeline, String, File?, () -> Boolean) -> Map<String, File> =
        AudioExtraction::extractAudio

    /** What this book offers by way of its own face, once opened. */
    var publisherFont: EpubFontResolver.Resolution? by mutableStateOf(null)
        internal set

    val hasNarration: Boolean get() = readalong != null
    val isPlaying: Boolean get() = readalong?.player?.isPlaying ?: false

    /**
     * Whether narration has left a place on the book: a sentence the voice is
     * on, or one lit on the page — playing or paused. What there is to put
     * back with [clearNarration], and so whether the reader is offered it.
     */
    val hasNarrationMarker: Boolean get() = readalong?.activeEntry != null || activeFragmentId != null

    /** The one in-flight response to a style change. Superseded, not stacked. */
    private var styleTask: Job? = null

    /** The narration extraction, held so a removal can revoke it. */
    private val narrationExtraction = ExtractionSlot()

    /**
     * Whether any change in the current burst needs a reparse. Accumulated,
     * not recomputed per change: a margin change landing within the coalesce
     * window of a size change used to lose the size change.
     */
    private var pendingReparse = false

    private var styleState by mutableStateOf(style)

    var style: ReaderStyle
        get() = styleState
        set(value) {
            val oldValue = styleState
            if (value == oldValue) return
            styleState = value
            // A neighbour laid out in the old type, or the old ink, is of no
            // use — everything but the highlighter is in its text.
            if (value.copy(highlighters = emptyMap()) != oldValue.copy(highlighters = emptyMap())) dropNeighbours()
            // Synchronously, inside the mutation: the page redraws because the
            // style changed, and it has to find the repainted text when it does.
            if (value.theme != oldValue.theme) layout?.recolour(value.theme.text)
            // A change of colour on its own is now finished.
            if (value.copy(theme = oldValue.theme, highlighters = oldValue.highlighters) == oldValue) return
            // Typography lives in the parsed text, so a font or spacing change
            // needs the chapter parsed again; page size alone re-flows.
            val needsReparse = value.typeface != oldValue.typeface ||
                value.publisherFamily != oldValue.publisherFamily ||
                value.fontSize != oldValue.fontSize ||
                value.lineSpacing != oldValue.lineSpacing ||
                value.justification != oldValue.justification
            pendingReparse = pendingReparse || needsReparse
            styleTask?.cancel()
            styleTask = services.scope.launch {
                delay(STYLE_COALESCE_MILLIS)
                val reparse = pendingReparse
                pendingReparse = false
                if (reparse) reloadCurrentChapter() else relayoutCurrentChapter()
            }
        }

    /** The server's session for a server book; null for a book from the reader's own files. */
    val readerSession: Session? get() = (source as? Source.Server)?.session

    /** Whether this is a book the reader added from their own files. */
    val isLocal: Boolean get() = source is Source.Local

    /**
     * Whether this book may appear outside the app: the widget's snapshot. A
     * book from the reader's files never does — PRIVACY-ANDROID.md promises they are
     * never sent anywhere.
     */
    val publishesToSystem: Boolean get() = !isLocal

    /** The EPUB this model opened, once `open` has found it. What Ask indexes. */
    var fileUrl: File? by mutableStateOf(null)
        private set

    /** Where a book from the reader's files keeps its place; null for a server book. */
    var loadStoredPosition: (suspend () -> StoredPosition?)? = null

    /** The highlights and bookmarks made in earlier sessions. Installed by `AppModel`. */
    var loadStoredAnnotations: (suspend () -> List<Annotation>)? = null

    private var pageSize: PageSize = PageSize.ZERO

    /** The debounce timer. Cancelled freely on every change: it is only a wait. */
    private var saveTask: Job? = null

    /** The write itself, once it has begun. Never cancelled by the debounce. */
    private var saveInFlight: Job? = null

    /** Playback rate to start narration at, supplied by the app's preferences. */
    var preferredRate: Double = 1.0

    /**
     * This book's level, in decibels, supplied by the app's preferences.
     * Applied live: the slider writes it while the voice is running.
     */
    var preferredVolumeTrim: Int = 0
        set(value) {
            field = value
            readalong?.player?.gain = VolumeTrim.gain(value)
        }

    /** Whether the reader's own chrome is showing: the top bar, and everything in the footer. */
    var chromeVisible: Boolean by mutableStateOf(true)
        private set

    fun toggleChrome() {
        chromeVisible = !chromeVisible
    }

    /** Where the reader gets its downloads from, so it uses the one download engine. */
    var downloadHost: AppModel? = null

    /** Where `open` looks for the book's file, when not the app's own download directory. A test seam. */
    internal var booksDirectory: File? = null

    var onSaveAnnotation: ((Annotation) -> Unit)? = null
    var onDeleteAnnotation: ((Annotation) -> Unit)? = null

    /**
     * Told once the book turns out to have usable narration. The app takes
     * ownership from here: exclusivity with an audiobook, the lock screen, and
     * keeping this model alive after its screen has gone.
     */
    var onNarrationReady: ((ReadalongCoordinator) -> Unit)? = null

    /** Returns whether the write was accepted: a refused position must not reach the widget either. */
    var enqueuePosition: (suspend (ReadiumLocator, Double, PositionOrigin) -> Boolean)? = null

    /** Records where the narration is, in terms the audiobook engine can act on. */
    var recordAudioAnchor: (suspend (AudioAnchor) -> Unit)? = null

    /** Reads back the anchor written by whichever engine last played. */
    var loadAudioAnchor: (suspend () -> AudioAnchor?)? = null

    /**
     * What the widget is told about this book, handed to the app's one
     * publisher, fenced to the account the reader was opened under.
     */
    internal var publishReading: ((ReadingSnapshot) -> Unit)? = null

    /** Where to publish when no hook is installed. */
    internal var publisher: CurrentBookPublisher? = null

    /**
     * The account fence this reader was opened under; null for a book from
     * the reader's own files, which no account owns.
     */
    internal var accountGeneration: Int? = null

    /** When the oldest unwritten change happened, for the debounce ceiling, in seconds. */
    private var firstUnsavedChangeAt: Double? = null

    /** The href of the spine item currently loaded, when there is one. */
    private val currentSpineHref: String?
        get() {
            val epubPackage = epubPackage ?: return null
            return epubPackage.spine.getOrNull(chapterIndex)?.href
        }

    val chapterTitle: String
        get() {
            val epubPackage = epubPackage ?: return book.title
            if (chapterIndex >= epubPackage.spine.size) return book.title
            return title(chapterIndex, currentPage?.characterRange?.location ?: 0) ?: book.title
        }

    /**
     * The chapter name for a place inside a spine document: the last
     * navigation entry whose anchor appears at or before the offset, so a book
     * packed into a handful of files is not labelled by its file alone.
     */
    fun title(inSpineItem: Int, atOffset: Int): String? {
        val epubPackage = epubPackage ?: return null
        val href = epubPackage.spine.getOrNull(inSpineItem)?.href ?: return null
        val entries = epubPackage.navigation.filter { it.href == href }
        if (entries.isEmpty()) return null
        val layout = layout
        if (inSpineItem != chapterIndex || layout == null) return entries.first().title
        var best: Pair<String, Int>? = null
        for (entry in entries) {
            val fragment = entry.fragment ?: continue
            val range = layout.fragmentRange(fragment) ?: continue
            if (range.location <= atOffset && range.location >= (best?.second ?: -1)) best = entry.title to range.location
        }
        return best?.first ?: entries.first().title
    }

    /** How far through the whole book the reader is, weighted by each spine item's size. */
    val bookProgress: Double
        get() {
            val epubPackage = epubPackage
            val layout = layout
            val page = currentPage
            if (epubPackage == null || epubPackage.spine.isEmpty() || layout == null || page == null) return book.progress ?: 0.0
            return epubPackage.bookProgress(chapterIndex, layout.progression(page))
        }

    /** The words actually on the current page: the painted range, not `characterRange`. */
    val currentPageText: String
        get() {
            val layout = layout ?: return ""
            val page = currentPage ?: return ""
            return layout.spokenText(page)
        }

    /** The label a screen reader reads for the page, never empty. */
    val spokenPageText: String
        get() {
            val text = currentPageText
            if (text.isNotEmpty()) return text
            return when (val phase = phase) {
                is Phase.Failed -> phase.reason
                is Phase.Loading -> "Opening the book"
                is Phase.Downloading -> if (phase.total > 0) {
                    "Downloading, ${(phase.received.toDouble() / phase.total * 100).toInt()} percent"
                } else {
                    "Downloading"
                }
                Phase.Ready -> "This page has no text on it."
            }
        }

    /** The footer's progress readout, in whichever form the reader chose. */
    val progressText: String
        get() = when (style.progressDisplay) {
            ReaderStyle.ProgressDisplay.BOOK -> ReadingProgress.percentText(bookProgress)
            ReaderStyle.ProgressDisplay.CHAPTER_PAGE -> if (pageCount > 0) "${pageIndex + 1} / $pageCount" else ""
        }

    /** Where the reader is, said the way the footer shows it. */
    val spokenPagePosition: String
        get() {
            if (pageCount <= 0) return chapterTitle
            val place = "Page ${pageIndex + 1} of $pageCount"
            val title = chapterTitle
            return if (title.isEmpty()) place else "$place in $title"
        }

    val pageCount: Int get() = layout?.pages?.size ?: 0
    val currentPage: RenderedPage? get() = layout?.pages?.getOrNull(pageIndex)

    /** What `open` reads the book from: the server's edition, or the reader's own copy. */
    private sealed interface Opening {
        data class Server(val session: Session, val format: BookContentService.Format) : Opening
        data class Local(val files: LocalBookFiles) : Opening
    }

    suspend fun open(pageSize: PageSize) {
        this.pageSize = pageSize
        openGeneration += 1
        dropNeighbours()
        val generation = openGeneration
        val opening: Opening = when (val source = source) {
            is Source.Server -> {
                val content = BookContentService(source.session.client, booksDirectory)
                val preferred = content.preferredReadingFormat(book) ?: run {
                    phase = Phase.Failed("This book has no readable edition on the server.")
                    return
                }
                Opening.Server(source.session, preferred)
            }
            is Source.Local -> {
                if (!source.files.epub.exists()) {
                    IssaLog.warning("local book file missing", mapOf("book" to book.uuid))
                    phase = Phase.Failed(LOCAL_FILE_MISSING)
                    return
                }
                Opening.Local(source.files)
            }
        }
        try {
            val file = resolveFile(opening)
            checkStillOpening(generation)
            val epubPackage = withContext(services.io) { EpubPackage.open(file) }
            checkStillOpening(generation)
            this.epubPackage = epubPackage
            fileUrl = file
            // A book the server calls ALIGNED can still carry no overlays, and
            // a book from the reader's files narrates only when its import
            // found every file of its audio playable here (`hasReadalong`).
            val timeline = SmilParser.timeline(epubPackage, ChunkDurations.loadFromDirectory(narrationDirectory))
            val narrates = !isLocal || book.hasReadalong
            this.timeline = if (timeline.isEmpty || !narrates) null else timeline

            // Before the first parse, so a book set in its own face is set in
            // it from the first page.
            styleSheets = styleSheets(epubPackage)
            resolvePublisherFont(epubPackage)
            // And the reparse that resolving it asked for, revoked: the parse
            // below is made under the style as it now stands. Left alone it
            // laid out the front of the book under the spinner, and backing out
            // in that window saved the cover as a place the reader had chosen.
            styleTask?.cancel()
            styleTask = null
            pendingReparse = false

            // Resume where the server says we were, before the first render,
            // with a local fallback, reconciled by timestamp.
            val stored = resolveStoredPosition()
            checkStillOpening(generation)
            restoredSentenceId = stored?.locator?.sentenceId
            val storedAnchor = if (timeline.isEmpty) null else loadAudioAnchor?.invoke()
            checkStillOpening(generation)
            quitAnchor = storedAnchor
            val anchor = if (stored?.locator?.isAudioScaled == true) storedAnchor else null
            val landing = resolveLanding(stored?.locator, anchor, epubPackage, timeline)
            val resumed = landing.index
            var restoring = landing.restoring
            if (stored != null) {
                if (stored.locator.isAudioScaled && anchor != null && landing.how != Landing.How.AUDIO_ANCHOR) {
                    IssaLog.warning(
                        "audio anchor names no file in the overlay",
                        mapOf(
                            "book" to book.title, "anchorHref" to anchor.audioHref,
                            "narratedFiles" to timeline.entries.map { it.audioHref }.toSet().size.toString(),
                        ),
                    )
                }
                when (landing.how) {
                    Landing.How.STORED_HREF -> Unit
                    Landing.How.AUDIO_ANCHOR -> IssaLog.info(
                        "stored position resolved by audio anchor",
                        mapOf(
                            "book" to book.title, "fragment" to (landing.restoring?.sentenceId ?: "none"),
                            "chapter" to (landing.index ?: -1).toString(),
                        ),
                    )
                    Landing.How.PROGRESSION -> IssaLog.info(
                        "stored position resolved by progression",
                        mapOf(
                            "book" to book.title, "href" to stored.locator.href,
                            "progress" to format4(stored.locator.totalProgression ?: -1.0),
                            "chapter" to (landing.index ?: -1).toString(),
                        ),
                    )
                    // Nothing left to resolve from: the reader is about to land
                    // at the front of the book.
                    Landing.How.NONE -> IssaLog.warning(
                        "stored position matched no chapter",
                        mapOf(
                            "book" to book.title, "href" to stored.locator.href,
                            "spineItems" to epubPackage.spine.size.toString(),
                        ),
                    )
                }
            }
            chapterIndex = resumed ?: firstReadableChapter(epubPackage, style)

            // A chapter that failed to parse already set `Failed`.
            var loaded = loadChapter(chapterIndex, restoring)

            // A resolved landing chapter can still be unreadable; opening the
            // book at the front beats refusing to open it at all.
            if (!loaded && resumed != null) {
                val fallback = firstReadableChapter(epubPackage, style)
                if (fallback != chapterIndex) {
                    IssaLog.warning(
                        "resume landing chapter unreadable, opening at start",
                        mapOf("book" to book.title, "landing" to chapterIndex.toString()),
                    )
                    chapterIndex = fallback
                    restoring = null
                    loaded = loadChapter(chapterIndex, restoring)
                    // The landing chapter's failure set `Failed`, and the book
                    // has now opened after all: still opening, not failed.
                    if (loaded) phase = Phase.Loading("Opening…")
                }
            }

            if (!loaded) {
                // The other way out of `loadChapter` is its bounds guard, which
                // sets nothing, and left the spinner up for ever.
                if (phase is Phase.Failed) return
                IssaLog.warning(
                    "book has no loadable chapter",
                    mapOf(
                        "book" to book.title, "chapter" to chapterIndex.toString(),
                        "spineItems" to epubPackage.spine.size.toString(),
                    ),
                )
                phase = Phase.Failed("This book's file doesn't contain any readable chapters.")
                return
            }
            checkStillOpening(generation)
            if (this.timeline == null && !timeline.isEmpty) {
                // A local book whose import found narration this device cannot
                // play, and added it as text.
                IssaLog.info("narration unavailable", mapOf("book" to book.title, "reason" to "notPlayableHere"))
            } else {
                prepareNarration(epubPackage, generation)
            }
            phase = Phase.Ready
            IssaLog.info(
                "book opened",
                mapOf(
                    "book" to book.title,
                    "chapter" to chapterIndex.toString(),
                    "narration" to (!timeline.isEmpty).toString(),
                    "resumed" to (stored != null).toString(),
                    "storedFragment" to (restoredSentenceId ?: "none"),
                    "storedProgress" to format4(stored?.locator?.totalProgression ?: -1.0),
                    "entries" to timeline.entries.size.toString(),
                    "narratedDocuments" to timeline.entries.map { it.textHref }.toSet().size.toString(),
                    "spineItems" to epubPackage.spine.size.toString(),
                ),
            )
            // Seed the anchor from wherever this open landed, if nothing has
            // written one yet — an anchor written by playback knows more — and
            // only for a book that narrates here.
            val fragment = restoredSentenceId
            if (fragment != null && this.timeline != null && storedAnchor == null) {
                val entry = timeline.entryForFragment(fragment, epubPackage.spine[chapterIndex].href)
                if (entry != null) {
                    recordAudioAnchor?.invoke(
                        AudioAnchor(audioHref = entry.audioHref, offset = entry.start, writtenAt = System.currentTimeMillis() / 1000.0),
                    )
                }
            }
            // Nothing saves on open, so a reader who opened a book and put the
            // phone down left the widget showing the previous session.
            publishSnapshot(bookProgress)
        } catch (e: CancellationException) {
            // The opener was replaced, not the reader's intent: the transfer is
            // still running and the next pass picks the wait back up.
            return
        } catch (e: Exception) {
            val edition = (opening as? Opening.Server)?.format?.rawValue ?: "local"
            IssaLog.failure("open book", e, mapOf("book" to book.title, "format" to edition))
            phase = when (opening) {
                is Opening.Server -> {
                    // "The file never arrived" is not "the server is down".
                    val onDisk = BookContentService(opening.session.client, booksDirectory).isDownloaded(book, opening.format)
                    Phase.Failed(
                        if (onDisk) {
                            "Couldn't open this book. " + AppModel.message(e)
                        } else {
                            "This book hasn't finished downloading. " + AppModel.message(e)
                        },
                    )
                }
                // No server and no download in the story: the copy is here and
                // would not open.
                is Opening.Local -> Phase.Failed("Couldn't open this book. Its file may be damaged.")
            }
        }
    }

    /** Throws when this open is no longer the one that counts. */
    private suspend fun checkStillOpening(generation: Int) {
        currentCoroutineContext().ensureActive()
        if (generation != openGeneration) throw CancellationException("superseded open")
    }

    /** Where this book's narration is extracted to: its own folder for a local book, `Audio/` for a server one. */
    private val narrationDirectory: File
        get() = (source as? Source.Local)?.files?.narration ?: AudioExtraction.defaultDirectory(book.uuid)

    /** The EPUB to open: for a server book the download — fetched first when it is not here — and for a local book its copy. */
    private suspend fun resolveFile(opening: Opening): File = when (opening) {
        is Opening.Local -> opening.files.epub
        is Opening.Server -> {
            val content = BookContentService(opening.session.client, booksDirectory)
            // Through the model where there is one, so opening a book whose
            // edition is inside its undo window takes the removal back.
            val alreadyOnDisk = downloadHost?.isDownloaded(book, opening.format) ?: content.isDownloaded(book, opening.format)
            phase = if (alreadyOnDisk) Phase.Loading("Opening…") else Phase.Downloading(0, 0)
            val host = downloadHost
            when {
                alreadyOnDisk -> content.localUrl(book, opening.format)
                host != null -> host.downloadAndWait(book, opening.format) { written, total ->
                    phase = Phase.Downloading(written, total)
                }
                else -> content.ensureDownloaded(book, opening.format)
            }
        }
    }

    /**
     * Where the reader was, for the open to land on. A server book asks the
     * server, reconciled by timestamp against the copy held here — a newer
     * position can still be undrained in the queue — and falls back to it when
     * the fetch fails; a local book asks the device store.
     */
    private suspend fun resolveStoredPosition(): StoredPosition? = when (val source = source) {
        is Source.Local -> loadStoredPosition?.invoke() ?: book.position
        is Source.Server -> try {
            val server = ProgressService(source.session.client).current(book.uuid)
            val mine = book.position
            if (mine != null && (server?.let { mine.timestamp > it.timestamp } ?: true)) mine else server
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            IssaLog.failure(
                "stored position fetch", e,
                mapOf("book" to book.title, "fallback" to if (book.position == null) "none" else "local"),
            )
            book.position
        }
    }

    /** Starts the whole open again after a failure; an open still running stands down at its next step. */
    suspend fun retryOpen(pageSize: PageSize) {
        phase = Phase.Loading("Opening…")
        open(pageSize)
    }

    /** Stops an in-progress download and closes the book. */
    fun cancelDownload() {
        if (isLocal) return
        val format = BookContentService.preferredReadingFormat(book) ?: return
        downloadHost?.downloads?.cancel(DownloadManager.Job(book.uuid, format))
        phase = Phase.Failed("Download cancelled.")
    }

    /**
     * Extracts the embedded narration and hooks the audio clock to the page.
     * Only for a non-empty timeline, so a book the server reports as aligned
     * but which carries no overlays reads as a plain ebook.
     */
    private suspend fun prepareNarration(epubPackage: EpubPackage, generation: Int) {
        val timeline = timeline
        if (timeline == null || timeline.isEmpty) {
            IssaLog.info("narration unavailable", mapOf("book" to book.title, "reason" to "emptyTimeline"))
            return
        }
        whilePreparingNarration?.let { hook ->
            whilePreparingNarration = null
            hook()
        }
        checkStillOpening(generation)
        // Off the main thread: this inflates every audio track in the book.
        // Held rather than awaited anonymously, so cancelling the handle is
        // what stops it; it reads its own cancellation between chunks.
        val bookId = book.uuid
        val directory = (source as? Source.Local)?.files?.narration
        val extraction: Deferred<Map<String, File>?> = services.scope.async(services.io) {
            val context = currentCoroutineContext()
            try {
                extractNarration(epubPackage, timeline, bookId, directory) { !context.isActive }
            } catch (_: Exception) {
                null
            }
        }
        narrationExtraction.hold(extraction)
        val files = try {
            extraction.await()
        } catch (_: CancellationException) {
            // This open's own cancellation goes on up, and leaves the slot
            // held: the extraction runs on regardless, and the slot is how a
            // removal revokes it before deleting what it writes. Only the
            // extraction's own cancellation, a revoke, reads as no narration.
            currentCoroutineContext().ensureActive()
            null
        }
        narrationExtraction.release(extraction)
        checkStillOpening(generation)
        if (files.isNullOrEmpty()) {
            // A book whose play button never appears, with no reason given, is
            // indistinguishable from one that was never aligned.
            IssaLog.warning(
                "narration unavailable",
                mapOf("book" to book.title, "reason" to "audioExtractionFailed", "entries" to timeline.entries.size.toString()),
            )
            return
        }
        val resolved = if (timeline.filesNeedingLength.isEmpty()) {
            timeline
        } else {
            measuredTimeline(timeline, epubPackage, files, generation)
        }
        attachNarration(resolved, files)
    }

    /**
     * The timeline again, with the real length of every file whose last clip
     * states no end. Each file is measured once, off the main thread, and the
     * answers kept beside the narration.
     */
    private suspend fun measuredTimeline(
        timeline: SmilTimeline,
        epubPackage: EpubPackage,
        files: Map<String, File>,
        generation: Int,
    ): SmilTimeline {
        val directory = narrationDirectory
        val cached = ChunkDurations.loadFromDirectory(directory)
        val wanted = files.filterKeys { it in timeline.filesNeedingLength }
        val measured = ChunkDurations.measure(wanted, cached, services.measurer, services.io)
        checkStillOpening(generation)
        if (measured.size > cached.size) {
            try {
                ChunkDurations.saveToDirectory(measured, directory)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                IssaLog.failure("save narration lengths", e, mapOf("book" to book.title))
            }
        }
        val resolved = withContext(services.io) { SmilParser.timeline(epubPackage, measured) }
        checkStillOpening(generation)
        IssaLog.info(
            "narration lengths measured",
            mapOf(
                "book" to book.title, "files" to wanted.size.toString(),
                "before" to format3(timeline.totalDuration), "after" to format3(resolved.totalDuration),
            ),
        )
        return resolved
    }

    /**
     * Revokes an extraction that is still writing this book's narration.
     * Called by whatever is about to delete those files; safe when nothing is
     * extracting, which is almost always.
     */
    fun cancelNarrationExtraction() {
        narrationExtraction.cancel()
    }

    /**
     * Builds the narration engine over an already-extracted set of audio files
     * and wires it to the page: the seam a test hands the fixture's files to,
     * getting exactly the coordinator production builds.
     */
    fun attachNarration(timeline: SmilTimeline, audioFiles: Map<String, File>) {
        this.timeline = timeline
        // Whatever this replaces is silenced and cut loose first: two opens
        // racing left two coordinators alive for one book. Released too, which
        // the Swift client leaves to ARC: an ExoPlayer holds threads.
        readalong?.let { previous ->
            previous.player.pause()
            previous.player.removeRateObservers()
            previous.onFragmentChange = null
            previous.onChapterChange = null
            previous.onSeek = null
            previous.player.release()
        }
        val coordinator = ReadalongCoordinator(timeline, audioFiles, AudioPlayer(services.makeMediaBackend()), services.scope)
        pendingNarrationMemo = null
        // The saved rate, otherwise written to preferences and never applied.
        coordinator.player.rate = preferredRate.toFloat()
        // And this book's level, for the same reason.
        coordinator.player.gain = VolumeTrim.gain(preferredVolumeTrim)
        coordinator.onFragmentChange = { fragment ->
            // The document the id belongs to: the coordinator has already
            // moved `activeEntry` onto it.
            val document = coordinator.activeEntry?.textHref
            narratedFragment = fragment
            narratedDocument = document
            // Keep the narrated sentence on screen, in its own chapter only,
            // without fighting a reader who can already see it.
            var moved = false
            val layout = layout
            if (style.followNarration && layout != null && document == currentSpineHref) {
                val page = layout.pageContainingFragment(fragment)
                if (page != null && page.index != pageIndex) {
                    pageIndex = page.index
                    moved = true
                }
            }
            // Narration arriving somewhere is not the reader choosing to be
            // there — but only when it actually arrived somewhere; a seek is
            // relabelled by `onSeek`, fired after the move.
            if (moved) positionOrigin = PositionOrigin.DERIVED
            // Listening moves the position as surely as turning pages does.
            scheduleSave()
        }
        coordinator.onChapterChange = { href ->
            // `onFragmentChange` fires first, so this is the sentence that
            // crossed the boundary.
            val fragment = narratedFragment
            services.scope.launch { followNarration(href, fragment) }
        }
        coordinator.onSeek = { positionOrigin = PositionOrigin.CHOSEN }
        readalong = coordinator
        // The screen reported visibility before this coordinator existed.
        coordinator.player.setHighFrequencyUpdates(isReaderVisible)
        onNarrationReady?.invoke(coordinator)
    }

    /**
     * Starts narration at the sentence under a point on the page, in pixels.
     * Returns whether it found one, so a tap in the margin keeps turning the
     * page.
     */
    suspend fun playSentence(x: Double, y: Double): Boolean {
        positionOrigin = PositionOrigin.CHOSEN
        val readalong = readalong
        val layout = layout
        val page = currentPage
        if (readalong == null || layout == null || page == null) {
            IssaLog.warning("tap to play refused", mapOf("why" to "noReadalongOrPage"))
            return false
        }
        // Ask only for ids the narration actually knows.
        val fragment = layout.fragmentId(x, y, page) { narratedEntry(it) != null }
        if (fragment == null) {
            IssaLog.warning(
                "tap to play found nothing",
                mapOf(
                    "book" to book.title, "chapter" to chapterIndex.toString(), "page" to pageIndex.toString(),
                    "x" to format1(x), "y" to format1(y),
                ),
            )
            return false
        }
        seekNarration(readalong, fragment)
        return true
    }

    /**
     * The narration of an element id in the chapter on screen — that
     * chapter's own, never another chapter's that happens to use the id.
     */
    private fun narratedEntry(fragmentId: String): SmilEntry? {
        val timeline = timeline ?: return null
        val href = currentSpineHref ?: return null
        return timeline.exactEntryForFragment(fragmentId, href)
    }

    /** Plays from an element id in the chapter on screen. */
    private suspend fun seekNarration(readalong: ReadalongCoordinator, fragmentId: String) {
        val href = currentSpineHref ?: return
        readalong.seekToFragment(fragmentId, href)
    }

    /** Highlights the whole of the current page: the unit a screen-reader user can refer to. */
    fun annotatePage(tint: Annotation.Tint): Annotation? {
        val page = currentPage ?: return null
        selection = page.characterRange
        return try {
            annotate(Annotation.Kind.HIGHLIGHT, tint)
        } finally {
            clearSelection()
        }
    }

    /** Starts narration at the first narrated sentence on this page. */
    suspend fun playFirstSentenceOnPage() {
        val readalong = readalong ?: return
        val fragment = firstFragmentOnCurrentPage() ?: return
        seekNarration(readalong, fragment)
    }

    /** Plays the narration for whatever is selected. */
    suspend fun playSelection() {
        positionOrigin = PositionOrigin.CHOSEN
        val selection = selection ?: return
        val layout = layout ?: return
        val readalong = readalong ?: return
        if (selection.location < 0 || selection.location >= layout.text.length) return
        val fragment = layout.chapter.fragmentIdAt(selection.location) ?: return
        if (narratedEntry(fragment) == null) return
        seekNarration(readalong, fragment)
    }

    /**
     * Where narration should begin for a reader who is here. Every rung is
     * anchored to the chapter the reader is in, and the last only looks
     * forward: there is no rung that can reach the start of the book from the
     * middle of it.
     */
    internal fun narrationStart(): Pair<SmilEntry, String>? {
        val timeline = timeline ?: return null
        val epubPackage = epubPackage ?: return null
        val href = epubPackage.spine.getOrNull(chapterIndex)?.href ?: return null

        // 0. Where the voice was when the book was last put down, while that
        //    sentence is on the page on screen.
        quitSentenceOnVisiblePage?.let { return it to "quitPoint" }
        // 1. What the reader can see, or the next narrated sentence after it
        //    in this chapter.
        val layout = layout
        val page = currentPage
        if (layout != null && page != null) {
            val rest = NarrationReach.restOfChapter(page.characterRange.location, layout.text.length)
            val fragment = rest?.let { firstNarratedFragment(it, carriedOver = true) }
            val entry = fragment?.let { timeline.exactEntryForFragment(it, href) }
            if (entry != null) return entry to "page"
        }
        // 2. The sentence the stored position named, held to this chapter.
        restoredSentenceId?.let { sentence ->
            timeline.exactEntryForFragment(sentence, href)?.let { return it to "restored" }
        }
        // 3. The nearest narration at or after this chapter. Never behind.
        val entry = timeline.firstEntryInAnyOf(epubPackage.spine.drop(chapterIndex).map { it.href }) ?: return null
        return entry to if (entry.textHref == href) "chapter" else "ahead"
    }

    /**
     * What [narrationStart] found and how far it is from the reader, before
     * anyone has decided whether that is near enough.
     *
     * The decision and the logging used to be one function, which is how the
     * player sheet — asking where Play would begin, with nobody having pressed
     * it — would write Play's refusals into the diagnostics log. This is the
     * decision alone: pure, and the same one for both askers.
     *
     * @property via the rung of [narrationStart] that found it.
     * @property distance how far it is from the reader, in [bookProgress]'s
     *   coordinates; null when the sentence's chapter is not in the spine, so
     *   there is nothing to measure against.
     * @property at where the entry sits in those coordinates, for the log.
     * @property isNear whether Play may begin here. A sentence with no
     *   distance is allowed, as it always was: there is nothing to refuse it by.
     */
    data class NarrationStartCandidate(
        val entry: SmilEntry,
        val via: String,
        val distance: Double?,
        val at: Double?,
        val isNear: Boolean,
    )

    /**
     * Where narration would begin and how far that is from the reader, whether
     * or not it is near enough: [narrationStart] measured against
     * [NARRATION_PROXIMITY_LIMIT], and nothing logged. Null when there is no
     * start at all.
     */
    internal fun narrationStartCandidate(): NarrationStartCandidate? {
        val timeline = timeline ?: return null
        val epubPackage = epubPackage ?: return null
        val (entry, via) = narrationStart() ?: return null
        // The proximity check, measured in the same coordinates as
        // `bookProgress`. Refusing is right: the alternative is a position,
        // written to the server within two seconds.
        val at = spineProgress(entry, epubPackage, timeline)
        val distance = at?.let { abs(it - bookProgress) }
        return NarrationStartCandidate(entry, via, distance, at, isNear = distance?.let { it <= NARRATION_PROXIMITY_LIMIT } ?: true)
    }

    /**
     * Where narration would begin, if it is near enough to the reader to be
     * allowed to: [narrationStartCandidate] held to [NARRATION_PROXIMITY_LIMIT].
     *
     * One decision, because it is asked two ways. Pressing play asks it to
     * begin there, and the player sheet asks it before anything has played, to
     * draw the place Play would begin rather than the start of the book. They
     * must not disagree.
     *
     * Logs its refusals, so a play that does nothing says why. The sheet does
     * not ask this: it asks [narrationStartCandidate], the same decision
     * without the log, because nobody pressed Play and a refusal that never
     * happened does not belong in the diagnostics a reader exports.
     */
    internal fun narrationStartIfNear(): NarrationStartCandidate? {
        val timeline = timeline ?: return null
        if (epubPackage == null) return null
        val candidate = narrationStartCandidate()
        if (candidate == null) {
            IssaLog.warning(
                "narration has nowhere to start",
                mapOf(
                    "book" to book.title, "chapter" to chapterIndex.toString(),
                    "page" to pageIndex.toString(), "entries" to timeline.entries.size.toString(),
                ),
            )
            return null
        }
        if (!candidate.isNear) {
            IssaLog.warning(
                "narration would start too far away",
                mapOf(
                    "book" to book.title, "via" to candidate.via, "chapter" to chapterIndex.toString(),
                    "distance" to format4(candidate.distance ?: -1.0), "reader" to format4(bookProgress),
                    "candidate" to format4(candidate.at ?: -1.0),
                ),
            )
            return null
        }
        return candidate
    }

    /**
     * Where the player sheet should draw a read-along nobody has started, so
     * that it shows the place Play would begin and not the start of the book.
     *
     * Null once the narration has a sentence of its own — the coordinator's
     * numbers are the truth from then on — for a book with no narration, and
     * when there is no narration at or ahead of the reader at all. Until then
     * it is the sentence [narrationStartCandidate] picks, read through
     * [ReadalongCoordinator.readout], so that it is the position and chapter
     * span the coordinator publishes the moment Play puts the voice there.
     *
     * When that sentence is too far away for Play to begin from, it is still
     * what is drawn — on the narrated audio's clock, the only clock the sheet's
     * bar has — but `playable` is false, so the sheet can say Play will not go
     * there.
     *
     * Display only: nothing is loaded, cued, highlighted, saved or logged.
     * Computed, so it cannot go stale behind a page turn or a stop, and
     * memoised per page, because working out where narration starts walks the
     * chapter's fragments and the sheet reads this on every redraw.
     */
    val pendingNarrationStart: PendingNarrationStart?
        get() {
            val readalong = readalong ?: return null
            if (readalong.activeEntry != null) return null
            val page = pageKey
            pendingNarrationMemo?.let { (memoPage, generation, start) ->
                if (memoPage == page && generation == narrationGeneration) return start
            }
            val start = narrationStartCandidate()?.let { candidate ->
                val readout = readalong.readout(candidate.entry)
                PendingNarrationStart(readout.bookProgress, readout.chapterSpan, candidate.entry, candidate.isNear)
            }
            pendingNarrationMemo = Triple(page, narrationGeneration, start)
            return start
        }

    suspend fun startNarration() {
        val readalong = readalong ?: return
        val generation = narrationGeneration
        val (entry, via, distance) = narrationStartIfNear() ?: return
        IssaLog.info(
            "narration start",
            mapOf(
                "book" to book.title, "via" to via, "chapter" to chapterIndex.toString(),
                "page" to pageIndex.toString(), "fragment" to entry.fragmentId,
                "distance" to format4(distance ?: -1.0),
            ),
        )
        // `play(from)`, not a seek: pressing play is not naming a place, which
        // keeps the position guard armed.
        if (!readalong.play(entry)) {
            // Not a file that would not play when a stop landed while it was
            // opening: the coordinator declined to finish the move the stop
            // overtook, and the reader has just asked for that. Nothing to say,
            // and — by returning — nowhere to turn the page to.
            if (generation == narrationGeneration) narrationWouldNotPlay(entry.audioHref)
            return
        }
        followNarration(entry.textHref, entry.fragmentId)
    }

    /**
     * Puts the voice on the sentence at a chosen book position, without
     * playing, and turns the page to it.
     *
     * For the player sheet before narration has started, whose slider and
     * skip buttons name a place while the coordinator holds none. The
     * coordinator announces a chapter change only when it is moving *from* a
     * sentence in another document, and from nothing it announces none — so a
     * cue into another chapter would move the voice and leave the page where
     * it was. This follows explicitly, after a seek of the kind the scrubber
     * makes: the reader naming a place, which `onSeek` records.
     *
     * The chapter it loads is the reader's choice, as the seek was. `onSeek`
     * marks the position CHOSEN when the seek lands, and the follow must not
     * relabel it DERIVED straight after, as for a chapter the voice crossed
     * into: a move back past the position guard's tolerance was then refused
     * on save, and the place the reader had scrubbed away from stayed stored.
     *
     * @param progress a fraction of the whole narrated book, as
     *   [ReadalongCoordinator.seekToBookProgress] takes it.
     */
    suspend fun cueNarration(progress: Double) {
        val readalong = readalong ?: return
        readalong.seekToBookProgress(progress)
        val entry = readalong.activeEntry ?: return
        followNarration(entry.textHref, entry.fragmentId, origin = PositionOrigin.CHOSEN)
    }

    /**
     * Puts narration back to the state of a book just opened: no sentence lit,
     * none the voice is on, nothing playing.
     *
     * After listening, the last sentence stays lit and the coordinator stays on
     * it while the reader reads on, so Play resumes pages back there — and,
     * following the narration, turns the page back to it. This forgets that
     * place, so the next Play begins from the page, as it does on a book
     * nobody has played, and the sheet draws that.
     *
     * The reader's place is not part of what is forgotten, and nothing here
     * writes: not [positionOrigin], not the saved position, not the stored
     * audio anchor. [restoredSentenceId] stays too — it is the stored
     * position's sentence and only a rung [narrationStart] falls to after the
     * page has none.
     *
     * [quitAnchor] goes. It is where the voice was when the book was last put
     * down, and it outranks the page: left in place, the first Play after a
     * stop would start there again.
     *
     * Bumps the generation first, so a start still opening its audio is
     * already overtaken by the time the coordinator is emptied beneath it.
     */
    fun clearNarration() {
        narrationGeneration += 1
        readalong?.clearPosition()
        narratedFragment = null
        narratedDocument = null
        quitAnchor = null
    }

    /**
     * Turns the book to the page a narrated fragment is on, loading its chapter.
     *
     * @param origin DERIVED for a chapter the voice crossed into; CHOSEN when
     *   the reader named the place, as a cue does.
     */
    private suspend fun followNarration(href: String, fragment: String?, origin: PositionOrigin = PositionOrigin.DERIVED) {
        val epubPackage = epubPackage ?: return
        val index = epubPackage.spine.indexOfFirst { it.href == href }
        if (index < 0 || index == chapterIndex) return
        val anchor = fragment?.let {
            ReadiumLocator(href = href, type = XHTML, locations = ReadiumLocator.Locations(fragments = listOf(it)))
        }
        if (!loadChapter(index, anchor)) return
        // By default a chapter the voice crossed into, not one the reader
        // picked.
        positionOrigin = origin
        IssaLog.info(
            "narration crossed chapter",
            mapOf("book" to book.title, "to" to index.toString(), "fragment" to (fragment ?: "none"), "page" to pageIndex.toString()),
        )
    }

    /**
     * Turns the book to the page being spoken, wherever that has got to — but
     * only when the voice did carry on while the reader was away: a paused
     * book whose reader read on silently must not be turned back.
     */
    suspend fun syncToNarration() {
        val readalong = readalong ?: return
        val entry = readalong.activeEntry ?: return
        if (!readalong.player.isPlaying && entry == entryWhenHidden) return
        turnToNarration()
    }

    /** The sentence the voice was on when the reader screen last went away. */
    private var entryWhenHidden: SmilEntry? = null

    /** Puts the page on the sentence the voice is on. */
    private suspend fun turnToNarration() {
        val entry = readalong?.activeEntry ?: return
        followNarration(entry.textHref, entry.fragmentId)
        // In the voice's own chapter only.
        if (entry.textHref != currentSpineHref) return
        val page = layout?.pageContainingFragment(entry.fragmentId) ?: return
        if (page.index == pageIndex) return
        pageIndex = page.index
        // Catching up with the voice is the textbook derived move, and it has
        // to be saved.
        positionOrigin = PositionOrigin.DERIVED
        scheduleSave()
        IssaLog.info(
            "returned to narration",
            mapOf(
                "book" to book.title, "chapter" to chapterIndex.toString(),
                "page" to pageIndex.toString(), "fragment" to entry.fragmentId,
            ),
        )
    }

    /**
     * Picks the book up at a sentence the other engine was on: the reader's
     * half of the hand-off back from the car. Derived at every step, and never
     * a seek — this place was named by an audio clock, not by a person.
     *
     * @return whether the narration reached the sentence. False when its audio
     *   file is not on disk, in which case nothing moved.
     */
    suspend fun resumeNarration(entry: SmilEntry, playing: Boolean): Boolean {
        val readalong = readalong ?: return false
        val reached = if (playing) readalong.play(entry) else readalong.prepare(entry)
        if (!reached) return false
        positionOrigin = PositionOrigin.DERIVED
        turnToNarration()
        return true
    }

    /** The sentence [quitAnchor] names, when it is on the page on screen. */
    private val quitSentenceOnVisiblePage: SmilEntry?
        get() {
            val anchor = quitAnchor ?: return null
            val timeline = timeline ?: return null
            val epubPackage = epubPackage ?: return null
            val href = currentSpineHref ?: return null
            val layout = layout ?: return null
            val page = currentPage ?: return null
            val placed = ListeningHandoff.place(anchor, epubPackage, timeline) ?: return null
            if (placed.entry.textHref != href) return null
            if (layout.pageContainingFragment(placed.entry.fragmentId)?.index != page.index) return null
            return placed.entry
        }

    /** The fragment ids carried by the chapter's text across [range], in order. */
    private fun fragmentIds(chapter: StyledChapter, range: TextRange): Sequence<String> =
        chapter.runs.asSequence()
            .filter { it.end > range.location && it.start < range.end }
            .mapNotNull { it.fragmentId }

    /**
     * The first narrated fragment inside a stretch of the chapter's text: one
     * scanner, its range named at each call site. The range is checked against
     * the text it is walked over.
     *
     * @param carriedOver whether a fragment that began before [range] counts —
     *   `false` is what a page turn wants.
     */
    private fun firstNarratedFragment(range: TextRange, carriedOver: Boolean): String? {
        val layout = layout ?: return null
        if (timeline == null) return null
        if (range.location < 0 || range.length <= 0 || range.end > layout.text.length) return null
        for (id in fragmentIds(layout.chapter, range)) {
            if (narratedEntry(id) == null) continue
            if (!carriedOver) {
                val whole = layout.fragmentRange(id) ?: continue
                if (whole.location < range.location) continue
            }
            return id
        }
        return null
    }

    /** The first media-overlay fragment appearing on the current page. */
    fun firstFragmentOnCurrentPage(): String? {
        val page = currentPage ?: return null
        return firstNarratedFragment(page.characterRange, carriedOver = true)
    }

    /**
     * The first narrated sentence that *begins* on a page — not the one
     * carried over from the page before, which would turn the page straight
     * back — falling back to the next one after the page's top within
     * [NarrationReach].
     */
    fun firstNarratedFragment(beginningOn: RenderedPage): String? {
        val layout = layout ?: return null
        if (timeline == null) return null
        layout.firstFragment(beginningOn) { narratedEntry(it) != null }?.let { return it }
        val reach = NarrationReach.range(beginningOn.characterRange.location, beginningOn.characterRange.length, layout.text.length)
            ?: return null
        return firstNarratedFragment(reach, carriedOver = false)
    }

    /** Whether the voice is speaking a sentence on the page being shown. */
    private val narrationIsOnVisiblePage: Boolean
        get() {
            val layout = layout ?: return false
            val page = currentPage ?: return false
            val href = currentSpineHref ?: return false
            return narrationIsOn(page, layout, href)
        }

    /** Whether the sentence the voice is on — playing or paused — is on a given page of a given chapter. */
    private fun narrationIsOn(page: RenderedPage, layout: ChapterLayout, href: String): Boolean {
        val entry = readalong?.activeEntry ?: return false
        if (entry.textHref != href) return false
        return layout.pageContainingFragment(entry.fragmentId)?.index == page.index
    }

    /**
     * The sentence a playing voice moves to after a turn, for the turns that
     * take the voice with them (a screen reader's). A paused book turns
     * silently.
     */
    fun narrationTargetOnVisiblePage(): String? {
        if (!isPlaying) return null
        val page = currentPage ?: return null
        return firstNarratedFragment(page)
    }

    /** Moves the voice to a sentence chosen by [narrationTargetOnVisiblePage]. */
    suspend fun carryNarration(fragment: String) {
        val readalong = readalong ?: return
        seekNarration(readalong, fragment)
    }

    /**
     * Play/pause for a page the reader may have turned away from the voice: a
     * paused book whose voice is off-page begins at the first sentence on the
     * visible page instead.
     */
    suspend fun playFromVisiblePage() {
        val readalong = readalong ?: return
        // A first press on a book reopened where its voice stopped starts there.
        if (readalong.activeEntry == null && quitSentenceOnVisiblePage != null) {
            startNarration()
            return
        }
        val page = currentPage
        val fragment = page?.let { firstNarratedFragment(it) }
        if (readalong.player.isPlaying || narrationIsOnVisiblePage || fragment == null) {
            togglePlayback()
            return
        }
        seekNarration(readalong, fragment)
    }

    suspend fun togglePlayback() {
        val readalong = readalong ?: return
        if (readalong.player.isPlaying) {
            IssaLog.info(
                "narration paused",
                mapOf("book" to book.title, "chapter" to chapterIndex.toString(), "fragment" to (narratedFragment ?: "none")),
            )
            readalong.player.pause()
        } else if (readalong.activeEntry == null) {
            startNarration()
        } else if (!readalong.resume()) {
            // `resume` reopens a file that would not play rather than pressing
            // play over it, and says when it still will not.
            narrationWouldNotPlay(readalong.activeEntry?.audioHref)
        }
    }

    /** Says so, over the page, rather than leaving a play button that does nothing. */
    private fun narrationWouldNotPlay(audioHref: String?) {
        IssaLog.warning("narration would not play", mapOf("book" to book.title, "audio" to (audioHref ?: "none")))
        chapterNotice = ChapterNotice(NARRATION_UNPLAYABLE)
    }

    /** Notified as the reader screen appears (true) and goes away (false). Installed by `AppModel`. */
    var onVisibilityChanged: ((Boolean) -> Unit)? = null

    private var isReaderVisible = false

    /**
     * The fine-grained clock is only worth running while the page is visible.
     * Leaving also notes the sentence the voice is on, for [syncToNarration].
     */
    fun setReaderVisible(visible: Boolean) {
        isReaderVisible = visible
        if (!visible) dropNeighbours()
        if (!visible) entryWhenHidden = readalong?.activeEntry
        readalong?.player?.setHighFrequencyUpdates(visible)
        onVisibilityChanged?.invoke(visible)
    }

    suspend fun resize(size: PageSize) {
        if (size == pageSize || size.isEmpty) return
        pageSize = size
        dropNeighbours()
        relayoutCurrentChapter()
    }

    /**
     * Re-parses the current chapter under the current style, holding
     * position: the narrated fragment when there is one, the character offset
     * otherwise.
     */
    private suspend fun reloadCurrentChapter() {
        // A chapter on screen is the only thing there is to reload: `open`
        // sets the package long before it knows which chapter to land on.
        if (epubPackage == null || layout == null) return
        // The first fragment that begins on the page, not the one straddling
        // the break, which walked a narrated book one page back per tap.
        val fragment = currentPage?.let { layout?.firstFragment(it) } ?: firstFragmentOnCurrentPage()
        val anchor = currentPage?.characterRange?.location ?: 0
        if (!loadChapter(chapterIndex)) return
        val layout = layout ?: return
        val page = fragment?.let { layout.pageContainingFragment(it) }
        pageIndex = page?.index ?: (
            layout.pages.indexOfFirst { anchor in it.characterRange }.takeIf { it >= 0 }
                ?: if (anchor >= (layout.pages.lastOrNull()?.characterRange?.location ?: 0)) maxOf(layout.pages.size - 1, 0) else 0
            )
    }

    private fun relayoutCurrentChapter() {
        val layout = layout ?: return
        if (pageSize.isEmpty) return
        // The same words across a reflow rather than the same page number.
        val anchor = layout.pages.getOrNull(pageIndex)?.characterRange?.location ?: 0
        layout.layout(pageSize.width, pageSize.height)
        layoutRevision += 1
        // Re-flowed, not re-parsed: not what a fresh layout at the new size
        // would be, so not to be kept as a neighbour.
        layoutKey = null
        pageIndex = layout.pages.indexOfFirst { anchor in it.characterRange }.takeIf { it >= 0 } ?: 0
    }

    /**
     * Loads a chapter, leaving the model untouched if it cannot be read.
     * Nothing is assigned until the whole chapter has parsed and laid out.
     */
    private suspend fun loadChapter(index: Int, restoring: ReadiumLocator? = null): Boolean {
        val epubPackage = epubPackage ?: return false
        if (index !in epubPackage.spine.indices) return false
        val key = neighbourKey
        val layout = prepareOrReport(index) ?: return false
        commit(layout, index, key, restoring)
        return true
    }

    /** Parses and lays out one chapter, assigning nothing. */
    private fun prepareChapter(index: Int): ChapterLayout {
        val epubPackage = epubPackage ?: throw IllegalStateException("no book")
        val item = epubPackage.spine.getOrNull(index) ?: throw java.io.FileNotFoundException("no spine item $index")
        val parsed = parse(item, epubPackage, style, pageSize, styleSheets, services.scale)
        return layOut(parsed, style)
    }

    private fun layOut(chapter: StyledChapter, style: ReaderStyle): ChapterLayout {
        val layout = ChapterLayout(chapter, style, services.fonts, services.scale, bookLocale)
        layout.layout(pageSize.width, pageSize.height)
        return layout
    }

    /** The book's language, for hyphenation. */
    private val bookLocale: Locale?
        get() = (book.language ?: epubPackage?.metadata?.language)?.takeIf { it.isNotBlank() }?.let(Locale::forLanguageTag)

    /** [prepareChapter], saying so when the chapter will not open. */
    private fun prepareOrReport(index: Int): ChapterLayout? = try {
        prepareChapter(index)
    } catch (e: Exception) {
        reportUnloadable(index, e)
        null
    }

    /** Makes a laid-out chapter the one on screen. Everything committed together, once nothing can still throw. */
    private fun commit(layout: ChapterLayout, index: Int, key: NeighbourKey?, restoring: ReadiumLocator? = null) {
        val left = this.layout?.let { LeftChapter(it, chapterIndex, layoutKey, anchoredRanges) }
        this.layout = layout
        chapterIndex = index
        layoutRevision += 1
        layoutKey = key
        anchorAnnotations()
        val offset = restoring?.let { LocatorAnchoring.characterOffset(it, layout.text, layout.fragmentRanges) }
        val page = offset?.let { layout.pageContainingOffset(it) }
        pageIndex = page?.index ?: 0
        keepNeighbours(left)
    }

    /** Says that a chapter would not open. */
    private fun reportUnloadable(index: Int, error: Exception) {
        IssaLog.failure("load chapter", error, mapOf("book" to book.title, "chapter" to index.toString()))
        val reason = AppModel.message(error)
        if (phase == Phase.Ready) {
            // The book is open and its chapter is still on screen, intact:
            // say so over it rather than closing the book.
            chapterNotice = ChapterNotice(unreadable(title(index, 0)) + " " + reason)
        } else {
            // Still opening: `open` decides what to do about it.
            phase = Phase.Failed("Couldn't open this chapter. $reason")
        }
    }

    // Navigation

    // Every deliberate move labels the position only once it has happened.
    suspend fun nextPage() {
        val layout = layout ?: return
        positionOrigin = PositionOrigin.CHOSEN
        val epubPackage = epubPackage
        if (pageIndex + 1 < layout.pages.size) {
            pageIndex += 1
        } else if (epubPackage != null && chapterIndex + 1 < epubPackage.spine.size) {
            move(chapterIndex + 1, landingOnLastPage = false)
        }
        scheduleSave()
    }

    suspend fun previousPage() {
        if (layout == null) return
        positionOrigin = PositionOrigin.CHOSEN
        if (pageIndex > 0) {
            pageIndex -= 1
        } else if (chapterIndex > 0) {
            move(chapterIndex - 1, landingOnLastPage = true)
        }
        scheduleSave()
    }

    /**
     * Moves to a chapter, stepping over ones with nothing on them and ones that
     * will not load, by [ChapterWalk]'s rule; a prepared neighbour is where the
     * turn lands without opening anything again.
     */
    private suspend fun move(index: Int, landingOnLastPage: Boolean) {
        val epubPackage = epubPackage ?: return
        check(index == chapterIndex + if (landingOnLastPage) -1 else 1)
        val neighbour = usableNeighbour(forward = !landingOnLastPage)
        if (neighbour != null) {
            when (val state = neighbour.state) {
                is NeighbourState.Ready -> {
                    commit(state.prepared.layout, state.prepared.index, neighbour.key)
                    land(landingOnLastPage, state.skipped)
                    return
                }
                is NeighbourState.Nowhere -> {
                    cannotLand(state.skipped)
                    return
                }
                NeighbourState.Pending -> Unit
            }
        }
        val key = neighbourKey
        var landing: Pair<Int, ChapterLayout>? = null
        val walk = ChapterWalk.walk(index, if (landingOnLastPage) -1 else 1, epubPackage.spine.size) { target ->
            val layout = prepareOrReport(target) ?: return@walk ChapterWalk.Attempt.UNREADABLE
            landing = target to layout
            if (ChapterWalk.isEmpty(layout.text)) ChapterWalk.Attempt.EMPTY else ChapterWalk.Attempt.CONTENT
        }
        val landed = landing
        if (landed == null || walk.chapter != landed.first) {
            cannotLand(walk.skipped)
            return
        }
        commit(landed.second, landed.first, key)
        land(landingOnLastPage, walk.skipped)
    }

    /** The page a turn across a chapter boundary arrives on, and what it says about chapters stepped over. */
    private fun land(onLastPage: Boolean, skipped: List<Int>) {
        pageIndex = if (onLastPage) maxOf((layout?.pages?.size ?: 1) - 1, 0) else 0
        val first = skipped.firstOrNull() ?: return
        val title = title(first, 0)
        chapterNotice = ChapterNotice(
            title?.let { "“$it” couldn't be opened, so it was skipped." }
                ?: "A chapter of this book couldn't be opened, so it was skipped.",
        )
    }

    /** Nowhere to land: said for the chapter that stopped the turn. */
    private fun cannotLand(skipped: List<Int>) {
        val first = skipped.firstOrNull() ?: return
        chapterNotice = ChapterNotice(unreadable(title(first, 0)))
    }

    // The chapters either side

    /** A chapter laid out ahead of a turn: where the turn would land. */
    internal data class PreparedChapter(val index: Int, val layout: ChapterLayout)

    /** What the far side of a chapter boundary holds. */
    internal sealed interface NeighbourState {
        data object Pending : NeighbourState

        /** Where a turn across the boundary lands, and the chapters it steps over. */
        data class Ready(val prepared: PreparedChapter, val skipped: List<Int>) : NeighbourState

        /** Every chapter the walk tried would not open. */
        data class Nowhere(val skipped: List<Int>) : NeighbourState
    }

    /** Everything a laid-out chapter depends on, without the highlighters. */
    internal data class NeighbourKey(val pageSize: PageSize, val style: ReaderStyle, val open: Int)

    internal data class Neighbour(
        /** The chapter it neighbours. Turned away from that, it is stale. */
        val origin: Int,
        val key: NeighbourKey,
        val state: NeighbourState,
        /** Its marks, resolved as [anchorAnnotations] resolves the chapter on screen. */
        val anchoredRanges: Map<String, TextRange> = emptyMap(),
    )

    /** The chapter a commit replaced, and what it was laid out under. */
    private class LeftChapter(val layout: ChapterLayout, val chapter: Int, val key: NeighbourKey?, val ranges: Map<String, TextRange>)

    internal val neighbourKey: NeighbourKey get() = NeighbourKey(pageSize, style.copy(highlighters = emptyMap()), openGeneration)

    /** The neighbour on one side, when it still belongs to the chapter on screen and to the way it is set. */
    private fun usableNeighbour(forward: Boolean): Neighbour? {
        val neighbour = neighbours[forward] ?: return null
        if (neighbour.origin != chapterIndex || neighbour.key != neighbourKey) return null
        return neighbour
    }

    /**
     * Gets the chapter on the far side of a boundary ready, when the reader is
     * within a page of one, so a turn past the end of a chapter slides the
     * next one in like any other page. Commits nothing: not the chapter, the
     * page, a notice or a save. Parsed off the main thread; laid out on it.
     */
    fun prefetchNeighbours() {
        if (!keepsNeighbours || !isReaderVisible || phase != Phase.Ready) return
        val epubPackage = epubPackage ?: return
        val layout = layout ?: return
        if (pageSize.isEmpty) return
        val key = neighbourKey
        val origin = chapterIndex
        for (forward in listOf(true, false)) {
            val nearEdge = if (forward) pageIndex >= layout.pages.size - 2 else pageIndex <= 1
            if (!nearEdge) {
                neighbourTasks.remove(forward)?.cancel()
                neighbours = neighbours - forward
                continue
            }
            if ((origin + if (forward) 1 else -1) !in epubPackage.spine.indices) continue
            val existing = neighbours[forward]
            if (existing != null && existing.origin == origin && existing.key == key) continue
            neighbourTasks.remove(forward)?.cancel()
            neighbours = neighbours + (forward to Neighbour(origin, key, NeighbourState.Pending))
            neighbourTasks[forward] = services.scope.launch { prepareNeighbour(forward, origin, key) }
        }
    }

    /** Waits for the neighbour on one side to finish being prepared, if it is being prepared. */
    suspend fun neighbourSettled(forward: Boolean) {
        neighbourTasks[forward]?.join()
    }

    /** Forgets every neighbour, and stops any being prepared. */
    fun dropNeighbours() {
        for (task in neighbourTasks.values) task.cancel()
        neighbourTasks.clear()
        if (neighbours.isNotEmpty()) neighbours = emptyMap()
    }

    private suspend fun neighbourIsWanted(forward: Boolean, origin: Int, key: NeighbourKey): Boolean =
        currentCoroutineContext().isActive && chapterIndex == origin && neighbourKey == key &&
            neighbours[forward]?.origin == origin && neighbours[forward]?.key == key

    private suspend fun prepareNeighbour(forward: Boolean, origin: Int, key: NeighbourKey) {
        val epubPackage = epubPackage ?: return
        val spine = epubPackage.spine
        val sheets = styleSheets
        val size = pageSize
        val style = style
        val scale = services.scale
        var landing: PreparedChapter? = null
        val walk = ChapterWalk.walk(origin + if (forward) 1 else -1, if (forward) 1 else -1, spine.size) { index ->
            val parsed = withContext(services.io) {
                runCatching { parse(spine[index], epubPackage, style, size, sheets, scale) }
            }
            whilePreparingNeighbour?.let { seam ->
                whilePreparingNeighbour = null
                seam()
            }
            if (!neighbourIsWanted(forward, origin, key)) return@walk ChapterWalk.Attempt.ABANDONED
            val chapter = parsed.getOrElse { error ->
                IssaLog.failure("prepare chapter", error, mapOf("book" to book.title, "chapter" to index.toString()))
                return@walk ChapterWalk.Attempt.UNREADABLE
            }
            val layout = layOut(chapter, style)
            landing = PreparedChapter(index, layout)
            if (ChapterWalk.isEmpty(layout.text)) ChapterWalk.Attempt.EMPTY else ChapterWalk.Attempt.CONTENT
        }
        if (walk.abandoned || !neighbourIsWanted(forward, origin, key)) return
        val prepared = landing
        val neighbour = if (prepared != null && walk.chapter == prepared.index) {
            Neighbour(
                origin, key, NeighbourState.Ready(prepared, walk.skipped),
                anchoredRanges(prepared.layout, spine[prepared.index].href),
            )
        } else {
            Neighbour(origin, key, NeighbourState.Nowhere(walk.skipped))
        }
        neighbours = neighbours + (forward to neighbour)
        neighbourTasks.remove(forward)
    }

    /**
     * Keeps what is still worth keeping after a commit: the chapter left
     * behind is itself the neighbour of the one arrived at, when the two are
     * next to each other and it has something on it.
     */
    private fun keepNeighbours(left: LeftChapter?) {
        if (!keepsNeighbours || !isReaderVisible) {
            dropNeighbours()
            return
        }
        val kept = mutableMapOf<Boolean, Neighbour>()
        val leftKey = left?.key
        if (left != null && leftKey != null && leftKey == neighbourKey && abs(left.chapter - chapterIndex) == 1 &&
            !ChapterWalk.isEmpty(left.layout.text)
        ) {
            val forward = left.chapter > chapterIndex
            kept[forward] = Neighbour(
                chapterIndex, leftKey,
                NeighbourState.Ready(PreparedChapter(left.chapter, left.layout), emptyList()),
                left.ranges,
            )
        }
        for ((forward, task) in neighbourTasks.toMap()) {
            if (kept[forward] != null || neighbours[forward]?.origin != chapterIndex) {
                task.cancel()
                neighbourTasks.remove(forward)
            }
        }
        for ((forward, neighbour) in neighbours) {
            if (neighbour.origin == chapterIndex && kept[forward] == null) kept[forward] = neighbour
        }
        neighbours = kept
    }

    /** Re-resolves the neighbours' marks after the book's marks changed. */
    private fun reanchorNeighbours() {
        val epubPackage = epubPackage ?: return
        neighbours = neighbours.mapValues { (_, neighbour) ->
            val state = neighbour.state as? NeighbourState.Ready ?: return@mapValues neighbour
            val href = epubPackage.spine.getOrNull(state.prepared.index)?.href ?: return@mapValues neighbour
            neighbour.copy(anchoredRanges = anchoredRanges(state.prepared.layout, href))
        }
    }

    // Pages, as the page turner draws them

    /** The page on screen, as plain values. */
    fun currentSnapshot(): PageSnapshot? {
        val layout = layout ?: return null
        val page = currentPage ?: return null
        return snapshot(layout, page)
    }

    /**
     * What a turn one page that way would show: the next page of the same
     * layout, or across a boundary the prepared neighbour's first page — its
     * last, turning back — or `Pending` while it is still being got ready.
     */
    fun neighbourPreview(forward: Boolean): NeighbourPreview {
        val layout = layout ?: return NeighbourPreview.None
        val epubPackage = epubPackage ?: return NeighbourPreview.None
        val next = pageIndex + if (forward) 1 else -1
        layout.pages.getOrNull(next)?.let { return NeighbourPreview.Page(snapshot(layout, it)) }
        if ((chapterIndex + if (forward) 1 else -1) !in epubPackage.spine.indices) return NeighbourPreview.None
        val neighbour = usableNeighbour(forward) ?: return NeighbourPreview.Pending
        return when (val state = neighbour.state) {
            NeighbourState.Pending -> NeighbourPreview.Pending
            // Not the end of the book: chapters that will not open.
            is NeighbourState.Nowhere -> NeighbourPreview.Pending
            is NeighbourState.Ready -> {
                val pages = state.prepared.layout.pages
                val page = (if (forward) pages.firstOrNull() else pages.lastOrNull()) ?: return NeighbourPreview.Pending
                val href = epubPackage.spine.getOrNull(state.prepared.index)?.href ?: return NeighbourPreview.Pending
                NeighbourPreview.Page(
                    snapshot(
                        state.prepared.layout, page, activeFragment(href),
                        highlightBlocks(page, state.prepared.layout, href, neighbour.anchoredRanges), null,
                    ),
                )
            }
        }
    }

    /** Whether a turn that way would have to wait for a chapter still being laid out. */
    fun neighbourIsPending(forward: Boolean): Boolean {
        val layout = layout ?: return false
        val epubPackage = epubPackage ?: return false
        if (layout.pages.getOrNull(pageIndex + if (forward) 1 else -1) != null) return false
        if ((chapterIndex + if (forward) 1 else -1) !in epubPackage.spine.indices) return false
        val neighbour = usableNeighbour(forward) ?: return true
        return neighbour.state == NeighbourState.Pending
    }

    private fun snapshot(layout: ChapterLayout, page: RenderedPage): PageSnapshot =
        snapshot(layout, page, activeFragmentId, highlightBlocks(page), selection)

    private fun snapshot(
        layout: ChapterLayout,
        page: RenderedPage,
        activeFragment: String?,
        annotations: List<AnnotationBlock>,
        selection: TextRange?,
    ): PageSnapshot = PageSnapshot(
        layout = layout,
        page = page,
        activeFragment = activeFragment,
        annotations = annotations,
        selection = selection,
        theme = style.theme,
        highlight = style.highlightColor,
        highlightStyle = layout.highlightStyle,
    )

    suspend fun go(toChapter: Int, fragment: String? = null) {
        // On failure `layout` still holds the previous chapter, and every
        // offset below would resolve against it — and be saved as chosen.
        if (!loadChapter(toChapter)) return
        positionOrigin = PositionOrigin.CHOSEN
        if (fragment != null) layout?.pageContainingFragment(fragment)?.let { pageIndex = it.index }
        scheduleSave()
    }

    /** Element ids appearing on the current page, for marking the contents list. */
    fun visibleFragments(): Set<String> {
        val layout = layout ?: return emptySet()
        val page = currentPage ?: return emptySet()
        return fragmentIds(layout.chapter, page.characterRange).toSet()
    }

    // Searching inside the book

    var searchHits: List<BookSearch.Hit> by mutableStateOf(emptyList())
        private set
    var isSearching: Boolean by mutableStateOf(false)
        private set
    private var searchTask: Job? = null

    /**
     * Searches the whole book, chapter by chapter, publishing as it goes.
     * Debounced, so a superseded search that has not begun reading does no
     * work; each chapter is read and parsed off the main thread.
     */
    fun search(query: String) {
        searchTask?.cancel()
        val needle = query.trim()
        val epubPackage = epubPackage
        if (needle.length < 2 || epubPackage == null) {
            searchHits = emptyList()
            isSearching = false
            return
        }
        searchHits = emptyList()
        isSearching = true
        val style = style
        searchTask = services.scope.launch {
            delay(SEARCH_DEBOUNCE_MILLIS)
            for ((index, item) in epubPackage.spine.withIndex()) {
                if (!isActive) break
                val hits = withContext(services.io) { hits(needle, epubPackage, item, index, style) }
                if (!isActive) break
                searchHits = searchHits + hits
            }
            // Only when this task is still the live one.
            if (isActive) isSearching = false
        }
    }

    fun cancelSearch() {
        searchTask?.cancel()
        searchHits = emptyList()
        isSearching = false
    }

    /** Jumps to a hit and leaves the matched text selected. */
    suspend fun go(hit: BookSearch.Hit, matching: String) {
        if (!loadChapter(hit.chapterIndex)) return
        val page = layout?.pageContainingOffset(hit.charOffset) ?: return
        positionOrigin = PositionOrigin.CHOSEN
        pageIndex = page.index
        selection = TextRange(hit.charOffset, matching.length)
        selectionChapter = chapterIndex
        scheduleSave()
    }

    /**
     * The same jump for somewhere that is not a search hit: a chapter, an
     * offset into its rendered text, and how much of it to leave marked. The
     * one caller is Ask, citing a passage.
     */
    suspend fun go(toChapter: Int, charOffset: Int, marking: Int) {
        if (!loadChapter(toChapter)) return
        val page = layout?.pageContainingOffset(charOffset) ?: return
        positionOrigin = PositionOrigin.CHOSEN
        pageIndex = page.index
        selection = TextRange(charOffset, marking)
        selectionChapter = chapterIndex
        scheduleSave()
    }

    // Selection and annotations

    /** The characters the reader has selected on this page, if any. */
    var selection: TextRange? by mutableStateOf(null)
        private set

    /** The chapter the current selection was made in: offsets are rebased per chapter. */
    private var selectionChapter: Int? = null

    private var annotationsState by mutableStateOf(emptyList<Annotation>())

    /** Annotations for this book, drawn under the text and listed on demand. */
    var annotations: List<Annotation>
        get() = annotationsState
        private set(value) {
            annotationsState = value
            anchorAnnotations()
            reanchorNeighbours()
        }

    /**
     * Where each of this chapter's annotations actually is, resolved once:
     * highlights by their own words, bookmarks by the place they mark. Ranges
     * and never rectangles, so a re-flow in place cannot leave them stale.
     */
    private var anchoredRanges: Map<String, TextRange> = emptyMap()
    private var selectionAnchor: Int? = null

    val selectedText: String?
        get() {
            val selection = selection ?: return null
            val layout = layout ?: return null
            if (selection.location < 0 || selection.end > layout.text.length) return null
            return layout.text.substring(selection.location, selection.end).trim()
        }

    /**
     * Starts a selection at a point, selecting the sentence there: the
     * aligner has already split this text into sentences.
     */
    fun beginSelection(x: Double, y: Double) {
        val layout = layout ?: return
        val page = currentPage ?: return
        val index = layout.characterIndex(x, y, page) ?: return
        val range = layout.sentenceRange(index) ?: layout.wordRange(index)
        selectionAnchor = index
        selection = range
        selectionChapter = chapterIndex
    }

    fun extendSelection(x: Double, y: Double) {
        val layout = layout ?: return
        val page = currentPage ?: return
        val anchor = selectionAnchor ?: return
        val index = layout.characterIndex(x, y, page) ?: return
        val lower = minOf(anchor, index)
        val upper = maxOf(anchor, index)
        // Snap the ends outward to whole words.
        val start = layout.wordRange(lower)?.location ?: lower
        val end = layout.wordRange(upper)?.end ?: upper
        selection = TextRange(start, maxOf(end - start, 1))
    }

    fun clearSelection() {
        selection = null
        selectionAnchor = null
        selectionChapter = null
    }

    /**
     * Drops a selection the reader has navigated away from: kept only while it
     * is still on the visible page of the chapter it was made in.
     */
    fun clearSelectionIfStale() {
        val selection = selection ?: return
        val page = currentPage
        if (selectionChapter == chapterIndex && page != null && selection.intersection(page.characterRange).length > 0) return
        clearSelection()
    }

    /** Turns the current selection into a highlight, or drops a bookmark at the top of the page. */
    fun annotate(kind: Annotation.Kind, tint: Annotation.Tint = Annotation.Tint.TANGERINE): Annotation? {
        val layout = layout ?: return null
        val page = currentPage ?: return null
        val range = if (kind == Annotation.Kind.BOOKMARK) {
            TextRange(page.characterRange.location, minOf(80, page.characterRange.length))
        } else {
            selection ?: TextRange(page.characterRange.location, 0)
        }
        // A bookmark is a place, legal on a page with no text; a highlight is
        // a piece of text, and there is none.
        if (kind != Annotation.Kind.BOOKMARK && range.length <= 0) return null
        val text = layout.text
        if (range.end > text.length) return null
        val excerpt = if (range.length > 0) {
            text.substring(range.location, range.end).replace("\n", " ").trim()
        } else {
            chapterTitle
        }
        // The stored offset names the excerpt's own first character, so the
        // rebuilt range does not clip its own tail.
        val storedRange = if (range.length > 0) {
            val raw = text.substring(range.location, range.end)
            val leading = raw.length - raw.trimStart().length
            TextRange(range.location + leading, excerpt.length)
        } else {
            range
        }
        val annotation = Annotation(
            bookUuid = book.uuid,
            kind = kind,
            tint = tint,
            locator = locator(storedRange),
            excerpt = excerpt,
            chapterTitle = chapterTitle,
        )
        annotations = (annotations + annotation).sortedWith(Annotation.readingOrder)
        onSaveAnnotation?.invoke(annotation)
        clearSelection()
        return annotation
    }

    /** Resolves this chapter's annotations to where they are in its text, once. */
    private fun anchorAnnotations() {
        val layout = layout
        val href = currentSpineHref
        anchoredRanges = if (layout == null || href == null) emptyMap() else anchoredRanges(layout, href)
    }

    private fun anchoredRanges(layout: ChapterLayout, href: String): Map<String, TextRange> {
        val resolved = mutableMapOf<String, TextRange>()
        for (annotation in annotations) {
            if (!annotation.locator.matchesHref(href)) continue
            anchoredRange(annotation, layout.text, layout.fragmentRanges)?.let { resolved[annotation.id] = it }
        }
        return resolved
    }

    /** Opens the page an annotation is on. */
    suspend fun go(annotation: Annotation) {
        val epubPackage = epubPackage ?: return
        // The annotation has to belong to a chapter this book still has.
        val index = annotation.locator.bestMatch(epubPackage.spine.map { it.href })
        if (index == null) {
            IssaLog.warning(
                "annotation names no chapter in this book",
                mapOf("book" to book.uuid, "href" to annotation.locator.href),
            )
            return
        }
        if (index != chapterIndex && !loadChapter(index, annotation.locator)) return
        // The page the mark is anchored on, not the one its stored offset names.
        val layout = layout
        val anchored = anchoredRanges[annotation.id]
        if (layout != null && anchored != null) layout.pageContainingOffset(anchored.location)?.let { pageIndex = it.index }
        positionOrigin = PositionOrigin.CHOSEN
        scheduleSave()
    }

    /** Seeds the marks made in earlier sessions. */
    fun loadAnnotations(stored: List<Annotation>) {
        annotations = stored.sortedWith(Annotation.readingOrder)
    }

    fun remove(annotation: Annotation) {
        annotations = annotations.filter { it.id != annotation.id }
        onDeleteAnnotation?.invoke(annotation)
    }

    /** True when this page already carries a bookmark, so the control can be a toggle. */
    val isPageBookmarked: Boolean get() = bookmarkOnCurrentPage != null

    /** The bookmark on the page being shown, by where it is anchored, and by its stored offset only when it has not been. */
    val bookmarkOnCurrentPage: Annotation?
        get() {
            val page = currentPage ?: return null
            val href = currentSpineHref ?: return null
            return annotations.firstOrNull { annotation ->
                if (annotation.kind != Annotation.Kind.BOOKMARK || !annotation.locator.matchesHref(href)) return@firstOrNull false
                val place = anchoredRanges[annotation.id]?.location ?: annotation.locator.locations?.charOffset
                    ?: return@firstOrNull false
                place in page.characterRange
            }
        }

    fun toggleBookmark() {
        val existing = bookmarkOnCurrentPage
        if (existing != null) remove(existing) else annotate(Annotation.Kind.BOOKMARK)
    }

    /** Where an annotation on this chapter lives, in the same terms as a reading position. */
    private fun locator(range: TextRange): ReadiumLocator {
        val href = currentSpineHref ?: ""
        val text = layout?.text ?: ""
        val length = text.length
        val total = maxOf(length, 1)
        val chapterProgress = range.location.toDouble() / total
        val spineCount = epubPackage?.spine?.size ?: 0
        val overall = if (spineCount > 0) (chapterIndex + chapterProgress) / spineCount else chapterProgress
        // Guarded on the length: a bookmark is legal on a page with no text.
        val fragment = if (length > 0) layout?.chapter?.fragmentIdAt(minOf(range.location, length - 1)) else null
        return ReadiumLocator(
            href = href,
            type = XHTML,
            title = chapterTitle,
            locations = ReadiumLocator.Locations(
                fragments = fragment?.let { listOf(it) },
                progression = chapterProgress,
                totalProgression = overall,
                charOffset = range.location,
            ),
            text = layout?.let { LocatorAnchoring.quote(it.text, range.location, minOf(range.length, 200)) },
        )
    }

    /** Stored highlights that fall on a page, one block per mark. */
    fun highlightBlocks(page: RenderedPage): List<AnnotationBlock> {
        val layout = layout ?: return emptyList()
        val href = currentSpineHref ?: return emptyList()
        return highlightBlocks(page, layout, href, anchoredRanges)
    }

    private fun highlightBlocks(page: RenderedPage, layout: ChapterLayout, href: String, ranges: Map<String, TextRange>): List<AnnotationBlock> {
        val result = ArrayList<AnnotationBlock>()
        for (annotation in annotations) {
            if (annotation.kind == Annotation.Kind.BOOKMARK || !annotation.locator.matchesHref(href)) continue
            val range = ranges[annotation.id] ?: continue
            val lines = layout.lines(range, page)
            if (lines.isEmpty()) continue
            result.add(AnnotationBlock(lines, annotation.tint))
        }
        return result
    }

    // Progress

    private fun scheduleSave() {
        val now = System.nanoTime() / 1e9
        val first = firstUnsavedChangeAt
        if (first != null && now - first >= SAVE_MAXIMUM_WAIT) {
            saveTask?.cancel()
            firstUnsavedChangeAt = null
            beginSave()
            return
        }
        if (firstUnsavedChangeAt == null) firstUnsavedChangeAt = now
        saveTask?.cancel()
        saveTask = services.scope.launch {
            delay(SAVE_DEBOUNCE_MILLIS)
            firstUnsavedChangeAt = null
            beginSave()
        }
    }

    /**
     * Starts the write, in a task the debounce does not own: the debounce
     * cancels only the wait, and once a write has begun it runs to completion.
     * Chained on the previous write rather than run beside it, because two
     * position writes for one book race.
     */
    private fun beginSave() {
        val previous = saveInFlight
        saveInFlight = services.scope.launch {
            previous?.join()
            saveProgress()
        }
    }

    /**
     * Drops a save that has not run yet — and the one in flight. Sign-out is
     * the caller: a write already on the wire is being sent with a token that
     * has just been revoked.
     */
    fun cancelPendingSave() {
        saveTask?.cancel()
        saveTask = null
        saveInFlight?.cancel()
        saveInFlight = null
        firstUnsavedChangeAt = null
    }

    suspend fun saveProgress() {
        val epubPackage = epubPackage
        val layout = layout
        val page = currentPage
        if (epubPackage == null || layout == null || page == null || chapterIndex !in epubPackage.spine.indices) {
            IssaLog.info("position not saved", mapOf("book" to book.title, "reason" to "noPage"))
            return
        }
        val href = epubPackage.spine[chapterIndex].href
        // Anchor on the first fragment that begins on this page: it survives a
        // font or margin change, which a page number does not.
        val fragment = layout.firstFragment(page)
        val chapterProgress = layout.progression(page)
        val overall = epubPackage.bookProgress(chapterIndex, chapterProgress)
        // Two anchors beyond the fragment: the character offset, and the words
        // that were on screen.
        val offset = page.characterRange.location
        val locator = ReadiumLocator(
            href = href,
            type = XHTML,
            title = chapterTitle,
            locations = ReadiumLocator.Locations(
                fragments = fragment?.let { listOf(it) },
                progression = chapterProgress,
                totalProgression = overall,
                charOffset = offset,
            ),
            text = LocatorAnchoring.quote(layout.text, offset),
        )
        // Decided now, against the page being saved: the reader can turn the
        // page while the write is in flight.
        val narrationBelongsToSave = isPlaying || narrationIsOn(page, layout, href)
        val timestamp = ProgressService.now()
        val enqueue = enqueuePosition
        val session = readerSession
        val accepted = when {
            enqueue != null -> enqueue(locator, timestamp, positionOrigin)
            session != null -> try {
                ProgressService(session.client).save(locator, book.uuid, timestamp) != null
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                false
            }
            // A local book with nowhere to keep its place: refused.
            else -> false
        }
        // Only a position that was actually taken reaches the widget.
        if (accepted) publishSnapshot(overall)
        // The anchor, while the narration is part of where the reader is, and
        // only for an accepted position — the anchor is the more durable half.
        val anchor = readalong?.currentAnchor
        if (accepted && narrationBelongsToSave && anchor != null) recordAudioAnchor?.invoke(anchor)
    }

    /** Publishes the small record the widget reads. Never a book from the reader's own files. */
    internal fun publishSnapshot(progress: Double) {
        if (!publishesToSystem) return
        val snapshot = ReadingSnapshot(
            progress = progress,
            chapter = chapterTitle,
            remaining = book.narrationDuration?.let { it * (1 - progress) },
            isPlaying = isPlaying,
        )
        publishReading?.let {
            it(snapshot)
            return
        }
        publisher?.let { snapshot.publish(book, readerSession, it) }
    }

    /**
     * Lets go of the engine: pauses narration and frees its player. For the
     * app, once nothing will show or play this model again.
     */
    fun release() {
        readalong?.player?.pause()
        readalong?.player?.release()
        dropNeighbours()
    }

    // The publisher's font

    /** Finds the face this book asks to be set in, and makes it usable. */
    internal fun resolvePublisherFont(epubPackage: EpubPackage) {
        val resolution = EpubFontResolver.resolve(epubPackage)
        publisherFont = resolution
        if (resolution !is EpubFontResolver.Resolution.Found) {
            style = style.copy(publisherFamily = null)
            val reason = (resolution as? EpubFontResolver.Resolution.Unavailable)?.reason
            if (reason != null && reason != EpubFontResolver.Unavailable.NoEmbeddedFont) {
                IssaLog.info("publisher font unusable", mapOf("book" to book.title, "reason" to reason.toString()))
            }
            return
        }
        // Every member of the family, registered from the archive in memory:
        // a family registered with only its upright member is a book with no
        // emphasis in it.
        val family = try {
            services.fonts.registerPublisherFace(epubPackage)
        } catch (_: Exception) {
            null
        }
        style = style.copy(publisherFamily = family)
        if (family != null) {
            IssaLog.info(
                "publisher font",
                mapOf("book" to book.title, "declared" to resolution.face.family, "family" to family),
            )
        }
    }

    /** What to tell the reader about this book's own face. */
    val publisherFontDescription: String
        get() = when (val font = publisherFont) {
            is EpubFontResolver.Resolution.Found ->
                if (style.publisherFamily != null) font.face.family else "This book's font couldn't be read."
            null -> "This book doesn't include a font."
            is EpubFontResolver.Resolution.Unavailable -> when (val reason = font.reason) {
                EpubFontResolver.Unavailable.NoEmbeddedFont -> "This book doesn't include a font."
                is EpubFontResolver.Unavailable.UnreadableFormat ->
                    "This book's font is ${reason.format.uppercase()}, which Android can't display."
                EpubFontResolver.Unavailable.Obfuscated -> "This book's font is locked by its publisher."
            }
        }

    /** Whether choosing the publisher's font would actually change anything. */
    val hasPublisherFont: Boolean get() = style.publisherFamily != null

    // The Ask hooks (Swift's ReaderModel+Ask)

    /**
     * The line past which the Ask model is never shown anything, computed at
     * the moment of asking: the narrated sentence's end when the voice is
     * running in the chapter on screen, otherwise the end of what the page
     * *paints* — a paragraph taller than the page runs on past the last word
     * the reader can see.
     */
    fun readingBoundary(): ReadingBoundary? {
        val layout = layout ?: return null
        val page = currentPage ?: return null
        val entry = readalong?.activeEntry
        val href = currentSpineHref
        if (isPlaying && entry != null && href != null &&
            ReadiumLocator(href = entry.textHref, type = XHTML).matchesHref(href)
        ) {
            val range = layout.fragmentRange(entry.fragmentId)
            if (range != null) {
                return ReadingBoundary(chapterIndex, range.end, chapterTitle, pageIndex + 1, ReadingBoundary.Kind.NARRATED_SENTENCE)
            }
        }
        // An empty painted range means nothing laid out on this page: the
        // page's own range is the only answer left.
        val painted = layout.paintedCharacterRange(page)
        val bounded = if (painted.length > 0) painted else page.characterRange
        return ReadingBoundary(chapterIndex, bounded.end, chapterTitle, pageIndex + 1, ReadingBoundary.Kind.PAGE_END)
    }

    /** The file the index is built from: the very edition the reader opened. */
    fun askSource(): ReaderBookSource? {
        val epubPackage = epubPackage ?: return null
        val file = fileUrl ?: return null
        return ReaderBookSource(book.uuid, file, epubPackage)
    }

    /** Where opening a book lands, and how that was decided. */
    data class Landing(val index: Int?, val restoring: ReadiumLocator?, val how: How) {
        enum class How(val rawValue: String) {
            /** The stored locator named a spine item outright. */
            STORED_HREF("storedHref"),

            /** An audio position, placed through the media overlay. */
            AUDIO_ANCHOR("audioAnchor"),

            /** The whole-book fraction, which is a guess but a bounded one. */
            PROGRESSION("progression"),

            /** Nothing this package can resolve. */
            NONE("none"),
        }
    }

    companion object {
        private const val XHTML = "application/xhtml+xml"

        /** How long a burst of style changes is allowed to run together. */
        private const val STYLE_COALESCE_MILLIS = 60L

        /** How long the typist gets between keystrokes before a search starts. */
        private const val SEARCH_DEBOUNCE_MILLIS = 250L

        /** Position writes are debounced, with a ceiling: narration resets the debounce faster than it elapses. */
        internal const val SAVE_DEBOUNCE_MILLIS = 2_000L
        private const val SAVE_MAXIMUM_WAIT = 20.0

        /** How far narration may begin from where the reader actually is, as book progress. */
        const val NARRATION_PROXIMITY_LIMIT = 0.10

        /** What a book from the reader's files says when its copy has gone. */
        const val LOCAL_FILE_MISSING =
            "This book's file is no longer on this device. Add it again to keep reading — your place and highlights are kept."

        /** What the reader is told when narration would not play. */
        const val NARRATION_UNPLAYABLE = "The narration here couldn't be played. Its audio file may be damaged."

        private fun unreadable(title: String?): String =
            title?.let { "Couldn't open “$it”." } ?: "Couldn't open a chapter of this book."

        private fun format1(value: Double) = String.format(Locale.ROOT, "%.1f", value)
        private fun format3(value: Double) = String.format(Locale.ROOT, "%.3f", value)
        private fun format4(value: Double) = String.format(Locale.ROOT, "%.4f", value)

        /** One chapter's text, parsed — the same parse in every caller, with the same limits on its plates. */
        internal fun parse(
            item: EpubPackage.SpineItem,
            epubPackage: EpubPackage,
            style: ReaderStyle,
            pageSize: PageSize,
            styleSheets: Map<String, EpubStyleSheet>,
            scale: Double,
        ): StyledChapter {
            val data = epubPackage.archive.read(item.href)
            val images = ArchiveImageSource(epubPackage.archive)
            val width = maxOf(pageSize.width / scale, 1.0)
            val height = maxOf(pageSize.height / scale, 1.0)
            return ChapterParser(
                style = style,
                maxImageWidth = width,
                maxImageHeight = height,
                columnWidth = width,
                loadImage = { images.image(it) },
                loadStyleSheet = { styleSheets[it] },
            ).parse(data, item.href)
        }

        /**
         * The first spine item with actual prose: real books routinely open
         * on a cover wrapper holding a single image.
         */
        fun firstReadableChapter(epubPackage: EpubPackage, style: ReaderStyle = ReaderStyle()): Int {
            for ((index, item) in epubPackage.spine.withIndex()) {
                val text = try {
                    ChapterParser(style).parse(epubPackage.archive.read(item.href), item.href).text
                } catch (_: Exception) {
                    continue
                }
                if (text.trim().length > 40) return index
            }
            return 0
        }

        /**
         * Turns a stored position into a chapter to open at: a pure function
         * of what is known. An audio position is placed through the media
         * overlay by its anchor — reading its fraction as a fraction of the
         * text is the mirror image of the car resuming tens of minutes early —
         * and an href no spine entry matches falls back to the whole-book
         * progression rather than the front of the book.
         */
        fun resolveLanding(stored: ReadiumLocator?, anchor: AudioAnchor?, epubPackage: EpubPackage, timeline: SmilTimeline): Landing {
            stored ?: return Landing(null, null, Landing.How.NONE)
            stored.bestMatch(epubPackage.spine.map { it.href })?.let { return Landing(it, stored, Landing.How.STORED_HREF) }
            if (stored.isAudioScaled && anchor != null) {
                val placed = ListeningHandoff.place(anchor, epubPackage, timeline)
                if (placed != null) {
                    return Landing(
                        placed.spineIndex,
                        ReadiumLocator(
                            href = epubPackage.spine[placed.spineIndex].href,
                            type = XHTML,
                            locations = ReadiumLocator.Locations(fragments = listOf(placed.entry.fragmentId)),
                        ),
                        Landing.How.AUDIO_ANCHOR,
                    )
                }
            }
            val progress = stored.totalProgression
            if (progress != null && progress.isFinite()) {
                val landing = spinePosition(progress, epubPackage)
                if (landing != null) {
                    // A synthetic anchor rather than the stored locator, whose
                    // progression is within the original resource.
                    return Landing(
                        landing.first,
                        ReadiumLocator(
                            href = epubPackage.spine[landing.first].href,
                            type = XHTML,
                            locations = ReadiumLocator.Locations(progression = landing.second),
                        ),
                        Landing.How.PROGRESSION,
                    )
                }
            }
            return Landing(null, stored, Landing.How.NONE)
        }

        /**
         * The spine location a whole-book progression names — the inverse of
         * `EpubPackage.bookProgress`, sharing its weighting and its
         * equal-count fallback so the two round-trip.
         */
        fun spinePosition(atTotalProgression: Double, epubPackage: EpubPackage): Pair<Int, Double>? {
            if (epubPackage.spine.isEmpty()) return null
            val clamped = atTotalProgression.asProgression ?: 0.0
            val weights = epubPackage.spineWeights
            val total = weights.sum()
            if (!(total > 0)) {
                val scaled = clamped * epubPackage.spine.size
                val index = minOf(scaled.toInt(), epubPackage.spine.size - 1)
                return index to minOf(maxOf(scaled - index, 0.0), 1.0)
            }
            val target = clamped * total
            var before = 0.0
            for ((index, weight) in weights.withIndex()) {
                if (weight > 0 && target < before + weight) return index to (target - before) / weight
                before += weight
            }
            // A progression of exactly 1 walks past every item.
            val last = weights.indexOfLast { it > 0 }.takeIf { it >= 0 } ?: (epubPackage.spine.size - 1)
            return last to 1.0
        }

        /**
         * Where a narration entry sits, in the same byte-weighted spine
         * coordinates as `bookProgress`, so the proximity check compares like
         * with like.
         */
        private fun spineProgress(entry: SmilEntry, epubPackage: EpubPackage, timeline: SmilTimeline): Double? {
            val index = epubPackage.spine.indexOfFirst { it.href == entry.textHref }
            if (index < 0) return null
            var within = 0.0
            val span = timeline.spanOfDocumentContaining(entry)
            val time = timeline.bookTimeForFragment(entry.fragmentId, entry.textHref)
            if (span != null && time != null && span.duration > 0) {
                within = ((time - span.start) / span.duration).asProgression ?: 0.0
            }
            return epubPackage.bookProgress(index, within)
        }

        /**
         * Where a stored mark is in the chapter as it reads now: a highlight by
         * its own words — the copy nearest the recorded offset, matched by
         * whitespace runs and whole words — and by the offset only when they
         * cannot be found; a bookmark the way a reading position is.
         */
        fun anchoredRange(annotation: Annotation, text: String, fragmentRanges: Map<String, TextRange> = emptyMap()): TextRange? {
            if (annotation.kind == Annotation.Kind.BOOKMARK) {
                return LocatorAnchoring.characterOffset(annotation.locator, text, fragmentRanges)?.let { TextRange(it, 0) }
            }
            val recorded = annotation.locator.locations?.charOffset
            LocatorAnchoring.nearestOccurrence(annotation.excerpt, text, recorded, annotation.locator.text?.before)
                ?.let { return it }
            // The words are not in the chapter any more: the recorded offset is
            // a better guess than painting the mark somewhere arbitrary.
            if (recorded == null || recorded < 0) return null
            return TextRange(recorded, annotation.excerpt.length)
        }

        /** Every stylesheet the book declares, parsed, keyed by archive path. */
        fun styleSheets(epubPackage: EpubPackage): Map<String, EpubStyleSheet> {
            val sheets = mutableMapOf<String, EpubStyleSheet>()
            for (href in EpubFontResolver.stylesheets(epubPackage)) {
                val data = try {
                    epubPackage.archive.read(href)
                } catch (_: Exception) {
                    continue
                }
                val css = decodeCss(data)
                val sheet = EpubStyleSheet().adding(css)
                if (!sheet.isEmpty) sheets[href] = sheet
            }
            return sheets
        }

        private fun decodeCss(data: ByteArray): String {
            val decoder = Charsets.UTF_8.newDecoder()
            return try {
                decoder.decode(java.nio.ByteBuffer.wrap(data)).toString()
            } catch (_: java.nio.charset.CharacterCodingException) {
                String(data, Charsets.ISO_8859_1)
            }
        }

        /** Search hits in one spine item, read and parsed with its images so offsets match the laid-out chapter. */
        private fun hits(needle: String, epubPackage: EpubPackage, item: EpubPackage.SpineItem, index: Int, style: ReaderStyle): List<BookSearch.Hit> {
            val images = ArchiveImageSource(epubPackage.archive)
            val parsed = try {
                ChapterParser(style, loadImage = { images.image(it) }).parse(epubPackage.archive.read(item.href), item.href)
            } catch (_: Exception) {
                return emptyList()
            }
            val navigation = epubPackage.navigation.filter { it.href == item.href }
            return BookSearch.hits(
                needle = needle,
                haystack = parsed.text,
                chapterIndex = index,
                chapterTitle = navigation.firstOrNull()?.title ?: "Chapter ${index + 1}",
                navigation = navigation,
                fragmentRanges = parsed.fragmentRanges,
            )
        }
    }
}

/** Hands a reader's snapshot to the one publisher. */
internal fun ReadingSnapshot.publish(book: Book, session: Session?, publisher: CurrentBookPublisher) {
    publisher.publish(
        book = book,
        session = session,
        progress = progress,
        chapter = chapter,
        remaining = remaining,
        isPlaying = isPlaying,
        candidate = CurrentBookPublisher.Owner.Reading(book.uuid),
    )
}
