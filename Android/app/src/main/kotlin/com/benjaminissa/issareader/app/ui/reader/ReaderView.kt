package com.benjaminissa.issareader.app.ui.reader

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.provider.Settings
import android.view.View
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.systemBarsIgnoringVisibility
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.ScrollAxisRange
import androidx.compose.ui.semantics.horizontalScrollAxisRange
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.pageDown
import androidx.compose.ui.semantics.pageLeft
import androidx.compose.ui.semantics.pageRight
import androidx.compose.ui.semantics.pageUp
import androidx.compose.ui.semantics.scrollBy
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.benjaminissa.issareader.app.ask.AskCoordinator
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.Clipboard
import com.benjaminissa.issareader.app.model.CustomFonts
import com.benjaminissa.issareader.app.model.FontImport
import com.benjaminissa.issareader.app.model.NowPlayingController
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.reader.PageSize
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.app.ui.ask.AskPillState
import com.benjaminissa.issareader.app.ui.ask.AskSheet
import com.benjaminissa.issareader.app.ui.ask.AskSparkle
import com.benjaminissa.issareader.app.ui.ask.AskStatusBadge
import com.benjaminissa.issareader.app.ui.ask.pillState
import com.benjaminissa.issareader.app.ui.ask.showsBadge
import com.benjaminissa.issareader.core.KeyValueStore
import com.benjaminissa.issareader.core.model.Annotation
import com.benjaminissa.issareader.core.model.ByteCountText
import com.benjaminissa.issareader.playback.PlaybackAction
import com.benjaminissa.issareader.render.PageTurn
import com.benjaminissa.issareader.render.PageTurnStyle
import com.benjaminissa.issareader.render.ReaderChrome
import com.benjaminissa.issareader.render.ReaderTapZone
import com.benjaminissa.issareader.render.ReaderTheme
import com.benjaminissa.issareader.render.android.ReaderFonts
import com.benjaminissa.issareader.ui.WrappingText
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.SkipGlyph
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.SystemText
import com.benjaminissa.issareader.ui.Typography
import com.benjaminissa.issareader.ui.color
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.floor

/**
 * What the reader needs from the app beyond its book.
 *
 * @param appScope outlives the screen: the save as it closes, and the release
 *   after, run there.
 * @param app the app's model, for the downloads, the audiobook that may be
 *   playing this book, and the release once the screen has gone. Absent in a
 *   screen built for a test.
 * @param defaults where the first-run guide remembers it has been seen.
 * @param fontImport "Add a font…" in the Aa sheet, and the faces it has
 *   imported: the app's one, which Settings shares. A screen built for a test
 *   gets its own, over [fonts].
 */
class ReaderEnvironment(
    val settings: PlaybackSettings,
    val fonts: ReaderFonts,
    val defaults: KeyValueStore,
    val appScope: CoroutineScope,
    val app: AppModel? = null,
    val nowPlaying: NowPlayingController? = null,
    val ask: AskCoordinator? = null,
    val fontImport: FontImport = FontImport(CustomFonts(fonts), contentResolver = null),
)

/** The sheets the reader presents, one at a time. */
enum class ReaderSheetKind { CONTENTS, SEARCH, MARKS, TYPOGRAPHY, ASK }

/** The first-run guide's flags, the iPhone's keys. */
internal const val SEEN_COACH_KEY = "issa.hasSeenReaderCoach"
internal const val SEEN_NARRATION_TIP_KEY = "issa.hasSeenNarrationTip"

/**
 * The reading surface, full screen.
 *
 * A page is drawn straight from the chapter's existing layout, so turning a
 * page translates geometry rather than laying anything out again. The top bar
 * and the footer are drawn over reserved bands rather than beside the page, so
 * showing and hiding them never changes the page's size; the system bars hide
 * with them and come back with a swipe from the edge.
 *
 * @param insets the device's unsafe edges; measured from the window when
 *   null, which is every case but a test's.
 * @param onOpenPlayer the full player — the scrubber, the rate and the sleep
 *   timer — which is another screen's.
 * @param presentSheet a sheet to show, asked for from outside the screen.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ReaderView(
    model: ReaderModel,
    environment: ReaderEnvironment,
    onClose: () -> Unit,
    onOpenPlayer: () -> Unit = {},
    insets: ReaderInsets.Edges? = null,
    presentSheet: ReaderSheetKind? = null,
) {
    val settings = environment.settings
    val view = LocalView.current
    val context = LocalContext.current
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val turner = remember(model) { PageTurner(model, scope) }
    var sheet by remember { mutableStateOf<ReaderSheetKind?>(null) }
    // A sheet asked for from outside: a keyboard shortcut, or a test.
    LaunchedEffect(presentSheet) { presentSheet?.let { sheet = it } }
    val reduceMotion = rememberReduceMotion()
    val theme = model.style.theme
    val uuid = model.book.uuid
    // A tapped answer opens its book's reader with the answer's sheet up.
    environment.ask?.let { ask ->
        LaunchedEffect(ask.reopenRequest, uuid) { if (ask.takeReopenRequest(uuid)) sheet = ReaderSheetKind.ASK }
    }

    // Puts the settings, this book's own departures from them, and the face
    // found inside the book together into the style the page is set in.
    // `publisherFamily` is carried across by hand: it is discovered while
    // opening and belongs to the book. Followed rather than assigned once: a
    // re-resolve, so this book's own settings survive a change of default.
    fun applyStyle() {
        model.style = settings.style(uuid).copy(publisherFamily = model.style.publisherFamily)
    }
    LaunchedEffect(model) {
        snapshotFlow { settings.style(uuid) }.collect { applyStyle() }
    }

    // The back gesture closes the book, as the iPhone's swipe from the edge
    // dismisses its cover. A sheet takes the gesture first.
    BackHandler(enabled = sheet == null) { onClose() }

    // Visibility is the whole screen's: the app learns which book is on screen
    // — which is what holds the display awake — while it is still opening.
    DisposableEffect(model) {
        model.setReaderVisible(true)
        onDispose {
            model.setReaderVisible(false)
            environment.appScope.launch { model.saveProgress() }
            // Released only if nothing is playing it, and a turn later, so the
            // release does not land inside the update that closed this screen.
            environment.app?.let { app -> environment.appScope.launch { app.readerDidClose(model) } }
        }
    }

    ImmersiveBars(view, chromeVisible = model.chromeVisible, theme = theme)

    // The guide's flags, read once and written when it is dismissed.
    var seenCoach by remember { mutableStateOf(environment.defaults.getBoolean(SEEN_COACH_KEY)) }
    var seenTip by remember { mutableStateOf(environment.defaults.getBoolean(SEEN_NARRATION_TIP_KEY)) }
    val showsZones = !seenCoach
    val showsTip = model.hasNarration && !seenTip
    val coachShowing = model.phase == ReaderModel.Phase.Ready && (showsZones || showsTip)

    // The setting *and* the device: the sparkle shows only where Ask can run.
    val showsAsk = environment.ask?.isOffered == true

    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .background(theme.background.color),
    ) {
        // The whole window, not what the bars leave of it: the page is laid
        // out against edges that do not move when the bars hide. Read again
        // on a real change — a rotation, a split screen, or the window's
        // insets arriving after a cold start straight into a book — and
        // never on a chrome toggle, which these do not see.
        val barsTop = WindowInsets.systemBarsIgnoringVisibility.getTop(density)
        val barsBottom = WindowInsets.systemBarsIgnoringVisibility.getBottom(density)
        val cutoutTop = WindowInsets.displayCutout.getTop(density)
        val edges = insets ?: remember(maxWidth, maxHeight, barsTop, barsBottom, cutoutTop) { ReaderInsets.current(view) }
        val chrome = ReaderChrome(edges.top.value.toDouble(), edges.bottom.value.toDouble(), model.style.pageMargin)
        val size = chrome.pageSize(maxWidth.value.toDouble(), maxHeight.value.toDouble())
        val pageWidth = size.width.dp
        val pageHeight = size.height.dp
        // The model lays out in pixels, whole ones, so the page's text never
        // runs a fraction past the canvas it is drawn on.
        val pagePixels = with(density) { PageSize(floor(pageWidth.toPx().toDouble()), floor(pageHeight.toPx().toDouble())) }

        // Keyed on the page size rather than the window's, so the insets and
        // the window arriving in either order lay the chapter out once.
        LaunchedEffect(pagePixels) {
            model.downloadHost = environment.app
            // Fixed into the read-along coordinator by open(), so set first.
            model.preferredRate = settings.playbackRate
            model.preferredVolumeTrim = settings.volumeTrim(uuid)
            applyStyle()
            when (model.phase) {
                // Re-entering while downloading is safe and necessary: the
                // wait for the transfer lived in this effect, which a size
                // change cancels.
                is ReaderModel.Phase.Loading, is ReaderModel.Phase.Downloading -> model.open(pagePixels)
                ReaderModel.Phase.Ready -> model.resize(pagePixels)
                // The retry button is the way out of a failure.
                is ReaderModel.Phase.Failed -> Unit
            }
        }

        Box(
            Modifier
                .fillMaxSize()
                .padding(top = edges.top, bottom = edges.bottom)
                .then(if (coachShowing) Modifier.clearAndSetSemantics {} else Modifier),
            contentAlignment = Alignment.Center,
        ) {
            when (val phase = model.phase) {
                is ReaderModel.Phase.Loading -> Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(Metrics.spacing12),
                ) {
                    CircularProgressIndicator(color = theme.textTertiary.color, strokeWidth = 2.5.dp, modifier = Modifier.size(24.dp))
                    Text(phase.message, style = Typography.footnote, color = theme.textTertiary.color)
                }
                is ReaderModel.Phase.Downloading -> DownloadingView(model, theme, phase.received, phase.total)
                is ReaderModel.Phase.Failed -> FailedView(theme, phase.reason) {
                    scope.launch { model.retryOpen(pagePixels) }
                }
                ReaderModel.Phase.Ready -> PageContent(
                    model, environment, turner, pageWidth, pageHeight,
                    reduceMotion = reduceMotion,
                    onSheet = { sheet = it },
                    onOpenPlayer = onOpenPlayer,
                )
            }
        }

        // The sparkle's state for this book: working, an answer waiting, or nothing.
        val ask = environment.ask
        val askState = if (showsAsk && ask != null) ask.pillState(uuid) else AskPillState.IDLE

        TopBar(
            model, edges.top,
            showsAsk = showsAsk,
            askState = askState,
            onClose = onClose,
            onSheet = { sheet = it },
            modifier = Modifier
                .align(Alignment.TopCenter)
                .then(if (coachShowing) Modifier.clearAndSetSemantics {} else Modifier),
        )

        // The sparkle that stays while the chrome is away. Reading with the
        // bars hidden is the ordinary case, and it is exactly when a reader
        // who closed the sheet is waiting: without this the only sign the app
        // is working goes with the top bar. Inside the notch, like the bar it
        // stands in for.
        AnimatedVisibility(
            visible = !model.chromeVisible && ask != null && ask.showsBadge(uuid),
            enter = fadeIn(tween(200)),
            exit = fadeOut(tween(200)),
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(top = edges.top + Metrics.spacing8, end = Metrics.spacing16),
        ) {
            AskStatusBadge(
                theme,
                askState,
                Modifier
                    .clip(CircleShape)
                    .clickable(role = Role.Button) { sheet = ReaderSheetKind.ASK }
                    .testTag("reader.askBadge"),
            )
        }

        if (coachShowing) {
            ReaderCoachOverlay(
                theme = theme,
                showsZones = showsZones,
                showsNarrationTip = showsTip,
                reduceMotion = reduceMotion,
                onDismiss = {
                    // Only what was actually shown is marked seen, so a plain
                    // book's first open does not spend the narrated tip.
                    if (showsZones) {
                        seenCoach = true
                        environment.defaults.putBoolean(SEEN_COACH_KEY, true)
                    }
                    if (showsTip) {
                        seenTip = true
                        environment.defaults.putBoolean(SEEN_NARRATION_TIP_KEY, true)
                    }
                },
            )
        }
    }

    when (sheet) {
        ReaderSheetKind.CONTENTS -> ReaderSheet(onDismiss = { sheet = null }, halfHeight = true) { dismiss ->
            ChapterListView(model, onSelect = { index, fragment -> scope.launch { model.go(index, fragment) } }, onDismiss = dismiss)
        }
        ReaderSheetKind.SEARCH -> ReaderSheet(onDismiss = { sheet = null }) { dismiss ->
            BookSearchView(
                model,
                // The matched text itself, not the whole excerpt: the jump
                // sizes the selection on what it is handed.
                onOpen = { hit -> scope.launch { model.go(hit, hit.matchedText) } },
                onDismiss = dismiss,
            )
        }
        ReaderSheetKind.MARKS -> ReaderSheet(onDismiss = { sheet = null }, halfHeight = true) { dismiss ->
            AnnotationsView(model, onOpen = { annotation -> scope.launch { model.go(annotation) } }, onDismiss = dismiss)
        }
        ReaderSheetKind.TYPOGRAPHY -> ReaderSheet(onDismiss = { sheet = null }) { dismiss ->
            BookTypographyView(
                book = model.book,
                settings = settings,
                fontImport = environment.fontImport,
                publisherFamily = model.style.publisherFamily,
                publisherNote = model.publisherFontDescription,
                onChange = ::applyStyle,
                onDone = dismiss,
            )
        }
        ReaderSheetKind.ASK -> {
            val ask = environment.ask
            if (ask != null) {
                AskSheet(model = model, coordinator = ask) { sheet = null }
            } else {
                LaunchedEffect(Unit) { sheet = null }
            }
        }
        null -> Unit
    }
}

/** The page, its gestures, the selection's capsule and the footer: everything that exists once the book is open. */
@Composable
private fun PageContent(
    model: ReaderModel,
    environment: ReaderEnvironment,
    turner: PageTurner,
    pageWidth: Dp,
    pageHeight: Dp,
    reduceMotion: Boolean,
    onSheet: (ReaderSheetKind) -> Unit,
    onOpenPlayer: () -> Unit,
) {
    val settings = environment.settings
    val view = LocalView.current
    val context = LocalContext.current
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val margin = model.style.pageMargin.dp
    // Each page carries its margins with it, so a turning page takes the whole
    // width of the reader across rather than being cut by a margin that stays
    // put. No top margin: the top bar's reserve stands in for it.
    val pageInsets = PageInsets(top = 0.dp, leading = margin, bottom = margin, trailing = margin)
    SideEffect { turner.width = (pageWidth + margin * 2).value.toDouble() }

    // Anything but the turner's own turn moving the page — narration, a
    // jump — shows it where it now is, at once.
    LaunchedEffect(model, turner) {
        snapshotFlow { model.pageKey }.drop(1).collect { turner.modelKeyChanged(it) }
    }
    // Turning the page dismisses a selection left behind on the old one, the
    // way scrolling does anywhere else — but only one left behind: a search
    // landing sets the page and its found text's selection together. Also on
    // a chapter change, which can land on the same page number.
    LaunchedEffect(model) {
        snapshotFlow { model.pageIndex to model.chapterIndex }.drop(1).collect { model.clearSelectionIfStale() }
    }
    val effective = PageTurn.effectiveStyle(settings.pageTurn, reduceMotion)
    LaunchedEffect(turner, effective) { turner.adopt(effective) }
    // Land on the page being spoken, if the book carried on while the reader
    // was elsewhere in the app.
    LaunchedEffect(model) { model.syncToNarration() }
    // From whichever store this book's marks are kept in.
    LaunchedEffect(model) { model.loadAnnotations(model.loadStoredAnnotations?.invoke() ?: emptyList()) }

    /** A point in the padded page's coordinates, in the canvas's own pixels. */
    fun canvasPoint(at: Offset): Pair<Double, Double> = with(density) {
        ((at.x.dp - margin).toPx().toDouble()) to (at.y.dp.toPx().toDouble())
    }

    // Whether this touch moved the page: a quick, slightly sloppy tap can
    // travel far enough to be a drag and lift fast enough to be a throw; it
    // has turned the page already and must not turn it again as a tap.
    val touch = remember { TouchState() }
    val handler = object : PageGestures {
        override val doubleTapEnabled: Boolean get() = model.hasNarration && model.style.tapToPlay

        override fun touchBegan() {
            touch.movedPage = false
        }

        override fun moved(startX: Float, translationX: Float): Boolean {
            // Starting to move the page lets go of a selection, as a swipe
            // always has.
            if (turner.dragChanged(startX.toDouble(), translationX.toDouble())) {
                touch.movedPage = true
                if (model.selection != null) model.clearSelection()
                return true
            }
            return false
        }

        override fun longPressed(at: Offset): Boolean {
            // Selecting on a page still sliding would select what is under
            // the finger now, which is not where the words will be.
            turner.finish()
            val (x, y) = canvasPoint(at)
            model.beginSelection(x, y)
            // Claimed only if there was text under it: a long press on an
            // illustration or a margin leaves the finger free to turn the page.
            val selecting = model.selection != null
            if (selecting) turner.dragCancelled()
            return selecting
        }

        override fun selectionMoved(to: Offset) {
            val (x, y) = canvasPoint(to)
            model.extendSelection(x, y)
        }

        override fun lifted(startX: Float, translationX: Float, velocityX: Float, selecting: Boolean) {
            // A press-and-drag that was adjusting a selection is not a turn.
            if (selecting) {
                turner.dragCancelled()
                return
            }
            // Slide and Cover: where the page lands is the turner's.
            if (turner.style != PageTurnStyle.INSTANT) {
                turner.dragEnded(velocityX.toDouble())
                return
            }
            val direction = PageTurn.liftOffSwipe(startX.toDouble(), translationX.toDouble()) ?: return
            // Clear a selection and turn the page in one motion.
            if (model.selection != null) model.clearSelection()
            turner.requestTurn(direction == PageTurn.Direction.FORWARD)
        }

        override fun cancelled() {
            turner.dragCancelled()
        }

        override fun tapped(at: Offset) {
            if (touch.movedPage) return
            // A tap with something selected dismisses it, and does nothing more.
            if (model.selection != null) {
                model.clearSelection()
                return
            }
            when (ReaderTapZone.of(at.x.toDouble(), pageWidth.value.toDouble(), margin.value.toDouble())) {
                ReaderTapZone.BACK -> turner.requestTurn(forward = false)
                ReaderTapZone.FORWARD -> turner.requestTurn(forward = true)
                ReaderTapZone.MIDDLE -> model.toggleChrome()
            }
        }

        override fun doubleTapped(at: Offset) {
            // The sentence under the finger, on a page at rest.
            turner.finish()
            model.clearSelection()
            val (x, y) = canvasPoint(at)
            scope.launch { model.playSentence(x, y) }
        }
    }

    fun turnForAccessibility(forward: Boolean) {
        turner.requestTurn(forward, carriesNarration = true) {
            @Suppress("DEPRECATION")
            view.announceForAccessibility(model.spokenPagePosition)
        }
    }

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            // The top bar's reserve, held whether or not the chrome is showing,
            // exactly as the footer holds its own — so toggling can never
            // re-paginate. It stands in for the page's top margin.
            Spacer(Modifier.height(ReaderChrome.BAR_HEIGHT.dp))
            Box(Modifier.pageGestures(handler)) {
                PageTrackView(
                    model, turner, pageWidth, pageHeight, pageInsets,
                    modifier = Modifier.pageAccessibility(
                        model, ::turnForAccessibility,
                        copyPage = { Clipboard.copy(context, model.spokenPageText) },
                        playPage = { scope.launch { model.playFirstSentenceOnPage() } },
                    ),
                )
                if (model.selection != null) {
                    SelectionMenu(model, Modifier.align(Alignment.BottomCenter).padding(bottom = Metrics.spacing24))
                }
            }
            Footer(model, environment, onSheet = onSheet, onOpenPlayer = onOpenPlayer)
        }
        // A chapter that would not open, said over the page it left in place,
        // below the top bar's reserve.
        ChapterNoticeBanner(
            model,
            Modifier
                .align(Alignment.TopCenter)
                .padding(top = ReaderChrome.BAR_HEIGHT.dp + Metrics.spacing12, start = Metrics.spacing24, end = Metrics.spacing24),
        )
    }
}

private class TouchState {
    var movedPage = false
}

/**
 * What TalkBack makes of a drawn page: the whole accessible surface of the
 * reader, since a canvas is a picture. Activation turns forward rather than
 * starting narration at the page's centre; every other action is named.
 */
private fun Modifier.pageAccessibility(
    model: ReaderModel,
    turn: (Boolean) -> Unit,
    copyPage: () -> Unit,
    playPage: () -> Unit,
): Modifier = clearAndSetSemantics {
    contentDescription = model.spokenPageText
    stateDescription = model.spokenPagePosition
    onClick {
        turn(true)
        true
    }
    // What people try in every other paged app: TalkBack's scroll forward
    // and back, and its page actions. Towards the top or the leading edge is
    // back; anything else is forward. The range says only that both ways are
    // open; where the book ends, the turn itself goes nowhere.
    horizontalScrollAxisRange = ScrollAxisRange(value = { 1f }, maxValue = { 2f })
    scrollBy { x, y ->
        turn(if (x != 0f) x > 0 else y > 0)
        true
    }
    pageLeft {
        turn(false)
        true
    }
    pageUp {
        turn(false)
        true
    }
    pageRight {
        turn(true)
        true
    }
    pageDown {
        turn(true)
        true
    }
    customActions = buildList {
        add(CustomAccessibilityAction("Next page") { turn(true); true })
        add(CustomAccessibilityAction("Previous page") { turn(false); true })
        // Named for what it will actually do, since it is a toggle.
        add(CustomAccessibilityAction(if (model.isPageBookmarked) "Remove bookmark" else "Bookmark this page") { model.toggleBookmark(); true })
        add(CustomAccessibilityAction("Copy page") { copyPage(); true })
        if (model.hasNarration) add(CustomAccessibilityAction("Play from this page") { playPage(); true })
        // Selection is made with a long press and a drag, which TalkBack
        // consumes — so highlighting, and playing a sentence, are otherwise
        // unreachable. These act on the top of the page.
        for (tint in Annotation.Tint.entries) {
            add(CustomAccessibilityAction("Highlight page in ${tint.title}") { model.annotatePage(tint); true })
        }
    }
}

/**
 * What to do with the selected text. Copy first, because that is what a
 * selection is usually for. On the page's own surface, not a system one: the
 * reader's theme has nothing to do with the device's.
 */
@Composable
private fun SelectionMenu(model: ReaderModel, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val theme = model.style.theme
    var tints by remember { mutableStateOf(false) }
    Row(
        modifier
            .dropShadow(CircleShape, Shadow(radius = 12.dp, color = Color.Black.copy(alpha = 0.15f), offset = DpOffset(0.dp, 4.dp)))
            .background(theme.background.color, CircleShape)
            .border(1.dp, theme.text.withAlpha(0.15).color, CircleShape)
            .padding(horizontal = Metrics.spacing8, vertical = Metrics.spacing4),
        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing4),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MenuGlyph(Symbols.docOnDoc, "Copy", theme) {
            model.selectedText?.let { Clipboard.copy(context, it) }
            model.clearSelection()
        }
        Box {
            MenuGlyph(Symbols.highlighter, "Highlight", theme) { tints = true }
            DropdownMenu(expanded = tints, onDismissRequest = { tints = false }, containerColor = Palette.surface) {
                for (tint in Annotation.Tint.entries) {
                    DropdownMenuItem(
                        text = { Text(tint.title, style = SystemText.body, color = Palette.ink) },
                        trailingIcon = { Icon(painterResource(Symbols.circleFill), contentDescription = null, tint = ReaderPalette.color(tint), modifier = Modifier.size(18.dp)) },
                        onClick = {
                            tints = false
                            model.annotate(Annotation.Kind.HIGHLIGHT, tint)
                        },
                    )
                }
            }
        }
        if (model.hasNarration) {
            MenuGlyph(Symbols.playCircle, "Play", theme) {
                scope.launch {
                    model.playSelection()
                    model.clearSelection()
                }
            }
        }
        MenuGlyph(Symbols.xmark, "Done", theme) { model.clearSelection() }
    }
}

@Composable
private fun MenuGlyph(icon: Int, label: String, theme: ReaderTheme, onClick: () -> Unit) {
    Box(
        Modifier
            .size(40.dp)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = ripple(bounded = false, radius = 20.dp),
                role = Role.Button,
                onClickLabel = null,
                onClick = onClick,
            )
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(painterResource(icon), contentDescription = null, tint = theme.text.color, modifier = Modifier.size(22.dp))
    }
}

/**
 * The reader's own top bar, floating over the page: back, and the book's
 * tools. In the page's own colour, not a system surface, and reaching the top
 * of the window behind the status bar. Faded with the chrome, and untappable
 * while it is gone.
 */
@Composable
private fun TopBar(
    model: ReaderModel,
    top: Dp,
    showsAsk: Boolean,
    askState: AskPillState,
    onClose: () -> Unit,
    onSheet: (ReaderSheetKind) -> Unit,
    modifier: Modifier = Modifier,
) {
    val theme = model.style.theme
    val visible = model.chromeVisible
    val alpha by animateFloatAsState(if (visible) 1f else 0f, tween(200), label = "chrome")
    if (alpha == 0f && !visible) return
    var menu by remember { mutableStateOf(false) }
    Row(
        modifier
            .fillMaxWidth()
            .graphicsLayer { this.alpha = alpha }
            .background(theme.background.withAlpha(0.94).color)
            .padding(top = top)
            .height(ReaderChrome.BAR_HEIGHT.dp)
            .padding(horizontal = 10.dp)
            .then(if (visible) Modifier else Modifier.clearAndSetSemantics {}),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Larger than its neighbours: Material's chevron sits small in its
        // box, where the iPhone's is a full-height stroke.
        BarGlyph(Symbols.chevronLeft, "Back to the book", theme, enabled = visible, iconSize = 32.dp, onClick = onClose)
        Spacer(Modifier.weight(1f))
        if (showsAsk) {
            // The sparkle says its state with the glyph: a pulse while an
            // answer is being worked out, the accent's dot when one waits.
            BarGlyph(
                Symbols.sparkles, askState.label, theme, enabled = visible, modifier = Modifier.testTag("reader.ask"),
                glyph = {
                    Box(Modifier.clearAndSetSemantics {}) {
                        AskSparkle(askState, tint = theme.text.color, dot = theme.accent.color)
                    }
                },
            ) {
                onSheet(ReaderSheetKind.ASK)
            }
        }
        BarGlyph(Symbols.textformatSize, "Text options for this book", theme, enabled = visible) { onSheet(ReaderSheetKind.TYPOGRAPHY) }
        BarGlyph(
            if (model.isPageBookmarked) Symbols.bookmarkFill else Symbols.bookmark,
            if (model.isPageBookmarked) "Remove bookmark" else "Bookmark this page",
            theme, enabled = visible,
        ) { model.toggleBookmark() }
        Box {
            BarGlyph(Symbols.ellipsisCircle, "More", theme, enabled = visible) { menu = true }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, containerColor = Palette.surface) {
                for ((title, icon, kind) in listOf(
                    Triple("Find in book", Symbols.magnifyingglass, ReaderSheetKind.SEARCH),
                    Triple("Marks", Symbols.bookmarkSquare, ReaderSheetKind.MARKS),
                    Triple("Contents", Symbols.listBullet, ReaderSheetKind.CONTENTS),
                )) {
                    DropdownMenuItem(
                        text = { Text(title, style = SystemText.body, color = Palette.ink) },
                        trailingIcon = { Icon(painterResource(icon), contentDescription = null, tint = Palette.ink) },
                        onClick = {
                            menu = false
                            onSheet(kind)
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun BarGlyph(
    icon: Int,
    label: String,
    theme: ReaderTheme,
    enabled: Boolean,
    iconSize: Dp = 24.dp,
    modifier: Modifier = Modifier,
    glyph: (@Composable () -> Unit)? = null,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .size(width = 38.dp, height = ReaderChrome.BAR_HEIGHT.dp)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = ripple(bounded = false, radius = 20.dp),
                enabled = enabled,
                role = Role.Button,
                onClick = onClick,
            )
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        if (glyph != null) {
            glyph()
        } else {
            Icon(painterResource(icon), contentDescription = null, tint = theme.text.color, modifier = Modifier.size(iconSize))
        }
    }
}

/**
 * The strip below the page.
 *
 * Its height is reserved whether or not the controls are showing, so toggling
 * the chrome never changes the page size. What the strip *contains* is
 * conditional; its height never is. A swipe up anywhere on it opens the full
 * player, as well as the waveform.
 */
@Composable
private fun Footer(
    model: ReaderModel,
    environment: ReaderEnvironment,
    onSheet: (ReaderSheetKind) -> Unit,
    onOpenPlayer: () -> Unit,
) {
    val theme = model.style.theme
    val scope = rememberCoroutineScope()
    val settings = environment.settings
    val app = environment.app
    // Whatever is actually playing *this book*: the reader's narration, or
    // the audiobook engine — which Android Auto drives — when it has the book.
    val readalongChanges = remember(model.readalong) { model.readalong?.player?.changes ?: MutableStateFlow(0L) }
    readalongChanges.collectAsState().value
    val listening = app?.listening
    val listeningChanges = remember(listening) { listening?.player?.changes ?: MutableStateFlow(0L) }
    listeningChanges.collectAsState().value
    val ownsListening = listening != null && app.listeningBook?.uuid == model.book.uuid
    val bookIsPlaying = if (ownsListening) listening.player.isPlaying else model.isPlaying

    suspend fun togglePlaybackForThisBook() {
        // Not while a hand-off is taking the book from the audiobook to the
        // page: that coordinator is about to be discarded.
        if (app?.isHandingOffToReader(model.book.uuid) == true) return
        val playing = app?.listening
        if (playing != null && app.listeningBook?.uuid == model.book.uuid) {
            if (playing.player.isPlaying) playing.player.pause() else playing.player.play()
            return
        }
        model.togglePlayback()
    }

    Row(
        Modifier
            .fillMaxWidth()
            .height(ReaderChrome.BAR_HEIGHT.dp)
            .pointerInput(model) {
                // Swipe up on the strip to open the player. The whole bar is
                // the target; past the distance the buttons' taps are let go.
                val distance = 24.dp.toPx()
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    var opened = false
                    while (true) {
                        val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                        val dy = change.position.y - down.position.y
                        if (abs(dy) > distance || abs(change.position.x - down.position.x) > distance) change.consume()
                        if (!change.pressed) {
                            if (!opened && model.hasNarration && dy < -distance) {
                                opened = true
                                onOpenPlayer()
                            }
                            break
                        }
                    }
                }
            }
            .padding(horizontal = model.style.pageMargin.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12),
    ) {
        if (!model.chromeVisible) return@Row
        if (model.hasNarration) {
            // Toggles narration in place, reflecting whatever is actually
            // playing this book.
            Box(
                Modifier
                    .size(32.dp)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = ripple(bounded = false, radius = 20.dp),
                        role = Role.Button,
                    ) { scope.launch { togglePlaybackForThisBook() } }
                    .semantics {
                        contentDescription = if (bookIsPlaying) "Pause narration" else "Play narration"
                        // TalkBack has no swipe up, so it reaches the player
                        // through a named action as well as the waveform.
                        customActions = listOf(CustomAccessibilityAction("Open player") { onOpenPlayer(); true })
                    },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    painterResource(if (bookIsPlaying) Symbols.pauseCircleFill else Symbols.playCircleFill),
                    contentDescription = null,
                    tint = theme.accent.color,
                    modifier = Modifier.size(31.dp),
                )
            }
            FooterGlyph("Open player", onOpenPlayer) {
                Icon(painterResource(Symbols.waveform), contentDescription = null, tint = theme.textTertiary.color, modifier = Modifier.size(22.dp))
            }
        }
        Row(
            Modifier.weight(1f),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12),
        ) {
            Row(
                Modifier
                    .weight(1f, fill = false)
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button) {
                        onSheet(ReaderSheetKind.CONTENTS)
                    }
                    .padding(vertical = Metrics.spacing8),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Metrics.spacing4),
            ) {
                val ink = theme.text.withAlpha(0.55).color
                Icon(painterResource(Symbols.listBullet), contentDescription = null, tint = ink, modifier = Modifier.size(17.dp))
                Text(model.chapterTitle, style = Typography.caption, color = ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (model.hasNarration) {
                // Same seconds, same glyphs as the full player and the mini
                // bar; the only way to move the page *with* the audio.
                val map = settings.commandMap
                for ((forward, seconds) in listOf(false to map.skipBackwardInterval, true to map.skipForwardInterval)) {
                    val label = if (forward) "Skip forward" else "Skip back"
                    FooterGlyph("$label ${seconds.toInt()} seconds", onClick = {
                        scope.launch {
                            model.readalong?.perform(if (forward) PlaybackAction.SKIP_FORWARD else PlaybackAction.SKIP_BACKWARD, map)
                            environment.nowPlaying?.publish()
                        }
                    }) {
                        SkipGlyph(forward = forward, size = 22.dp, seconds = seconds.toInt(), tint = theme.textTertiary.color)
                    }
                }
            }
        }
        // Inside the chrome: hiding everything hides everything.
        val progress = model.progressText
        if (progress.isNotEmpty()) {
            Text(
                progress,
                style = Typography.caption.copy(fontFeatureSettings = "tnum"),
                color = theme.text.withAlpha(0.55).color,
                maxLines = 1,
                // The page already says where the reader is, in words; this
                // would follow it as "3 slash 12".
                modifier = Modifier.clearAndSetSemantics {},
            )
        }
    }
}

@Composable
private fun FooterGlyph(label: String, onClick: () -> Unit, content: @Composable () -> Unit) {
    Box(
        Modifier
            .size(28.dp)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = ripple(bounded = false, radius = 18.dp),
                role = Role.Button,
                onClick = onClick,
            )
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { content() }
}

/**
 * What a book looks like while it is still arriving: real bytes and a way
 * out, rather than a bare spinner indistinguishable from a hang.
 */
@Composable
private fun DownloadingView(model: ReaderModel, theme: ReaderTheme, received: Long, total: Long) {
    Column(
        Modifier.padding(Metrics.spacing32),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Metrics.spacing16),
    ) {
        WrappingText(model.book.title, style = Typography.title, color = theme.text.color, textAlign = TextAlign.Center)
        val numbers = Typography.caption.copy(fontFeatureSettings = "tnum")
        if (total > 0) {
            LinearProgressIndicator(
                progress = { (received.toDouble() / total).toFloat().coerceIn(0f, 1f) },
                color = theme.accent.color,
                trackColor = theme.text.withAlpha(0.12).color,
                drawStopIndicator = {},
                modifier = Modifier.widthIn(max = 280.dp).fillMaxWidth(),
            )
            Text("${ByteCountText.text(received)} of ${ByteCountText.text(total)}", style = numbers, color = theme.textTertiary.color)
        } else {
            // No length: an indeterminate spinner is honest, where a bar
            // pinned at zero looks exactly like a stall.
            CircularProgressIndicator(color = theme.textTertiary.color, strokeWidth = 2.5.dp, modifier = Modifier.size(24.dp))
            Text(if (received > 0) ByteCountText.text(received) else "Starting…", style = numbers, color = theme.textTertiary.color)
        }
        Text(
            "Cancel",
            style = Typography.callout,
            color = theme.textSecondary.color,
            modifier = Modifier
                .clickable(role = Role.Button) { model.cancelDownload() }
                .padding(Metrics.spacing8),
        )
    }
}

/** Coloured from the page's own theme, not the system's: a system-coloured view here is white on cream for anyone reading Paper in dark theme. */
@Composable
private fun FailedView(theme: ReaderTheme, reason: String, onRetry: () -> Unit) {
    Column(
        Modifier.padding(Metrics.spacing32),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Metrics.spacing12),
    ) {
        Icon(painterResource(Symbols.bookClosed), contentDescription = null, tint = theme.text.withAlpha(0.45).color, modifier = Modifier.size(40.dp))
        Text("Couldn't open this book", style = Typography.headline, color = theme.text.color)
        Text(reason, style = Typography.footnote, color = theme.text.withAlpha(0.7).color, textAlign = TextAlign.Center)
        Text(
            "Try Again",
            style = Typography.callout.copy(fontWeight = FontWeight.SemiBold),
            color = theme.accent.color,
            modifier = Modifier
                .clickable(role = Role.Button, onClick = onRetry)
                .padding(Metrics.spacing8),
        )
    }
}

/**
 * The status and navigation bars, hidden with the reader's chrome and shown
 * with it — the iPhone hides its status bar and home indicator together — and
 * their icons drawn for the page's colour, not the system's. Hidden, they come
 * back for a moment with a swipe from the edge. Put back as they were when
 * the reader closes.
 */
@Composable
private fun ImmersiveBars(view: View, chromeVisible: Boolean, theme: ReaderTheme) {
    val window = remember(view) { view.context.findActivity()?.window } ?: return
    val controller = remember(window) { WindowCompat.getInsetsController(window, view) }
    DisposableEffect(controller) {
        val lightStatus = controller.isAppearanceLightStatusBars
        val lightNavigation = controller.isAppearanceLightNavigationBars
        val behavior = controller.systemBarsBehavior
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        onDispose {
            controller.show(WindowInsetsCompat.Type.systemBars())
            controller.isAppearanceLightStatusBars = lightStatus
            controller.isAppearanceLightNavigationBars = lightNavigation
            controller.systemBarsBehavior = behavior
        }
    }
    LaunchedEffect(controller, chromeVisible) {
        if (chromeVisible) {
            controller.show(WindowInsetsCompat.Type.systemBars())
        } else {
            controller.hide(WindowInsetsCompat.Type.systemBars())
        }
    }
    SideEffect {
        controller.isAppearanceLightStatusBars = !theme.isDark
        controller.isAppearanceLightNavigationBars = !theme.isDark
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

/**
 * Whether the system has removed animations — Android's Reduce Motion. Read
 * again whenever the reader comes back to the front, since that is where the
 * setting is changed.
 */
@Composable
internal fun rememberReduceMotion(): Boolean {
    val context = LocalContext.current
    fun read(): Boolean = Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    var reduced by remember { mutableStateOf(read()) }
    LifecycleResumeEffect(Unit) {
        reduced = read()
        onPauseOrDispose {}
    }
    return reduced
}
