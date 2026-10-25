package com.benjaminissa.issareader.app.ui.local

import android.net.Uri
import androidx.activity.compose.LocalOnBackPressedDispatcherOwner
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.TopAppBarScrollBehavior
import androidx.compose.material3.rememberTopAppBarState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.local.LocalBookFacts
import com.benjaminissa.issareader.app.local.LocalBooksCopy
import com.benjaminissa.issareader.app.local.LocalBooksKeyboard
import com.benjaminissa.issareader.app.local.LocalDevice
import com.benjaminissa.issareader.app.local.LocalImport
import com.benjaminissa.issareader.app.local.LocalImportError
import com.benjaminissa.issareader.app.local.LocalLibrary
import com.benjaminissa.issareader.app.local.LocalRowNotice
import com.benjaminissa.issareader.app.ui.player.BookCoverImage
import com.benjaminissa.issareader.app.ui.player.PlayerSheet
import com.benjaminissa.issareader.app.ui.settings.ReadingSettings
import com.benjaminissa.issareader.app.ui.shell.AppEnvironment
import com.benjaminissa.issareader.app.ui.shell.LocalAppEnvironment
import com.benjaminissa.issareader.app.ui.settings.observe
import com.benjaminissa.issareader.core.download.DiskSpace
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.ByteCountText
import com.benjaminissa.issareader.core.sync.LibraryService
import com.benjaminissa.issareader.playback.PlaybackAction
import com.benjaminissa.issareader.playback.PlaybackProgress
import com.benjaminissa.issareader.ui.BackButton
import com.benjaminissa.issareader.ui.LargeTitleBar
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.MiniPlayerBar
import com.benjaminissa.issareader.ui.Overline
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.SystemText
import com.benjaminissa.issareader.ui.Typography
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * "On this phone": the books the reader added from their own files.
 * `LocalBooksScreen.swift`.
 *
 * The one new screen of the feature, kept deliberately quiet. Two placements
 * here: the app's root while no server is connected ([standalone]), with a
 * settings button, the way back to sign-in and a mini player of its own; and
 * pushed from Settings › Advanced while one is. Everything on it is the
 * library's ([LocalLibrary]); the screen only lays it out and turns taps into
 * calls. A book opens through the window's `LocalBooksRoute`, whose open book
 * the root presents the reader over.
 *
 * @param onConnectServer the way back to sign-in, from the standalone list.
 */
@Composable
fun LocalBooksScreen(standalone: Boolean, onConnectServer: () -> Unit) {
    val environment = LocalAppEnvironment.current
    val library = environment.local ?: return
    val dispatcher = LocalOnBackPressedDispatcherOwner.current?.onBackPressedDispatcher
    LocalBooksContent(
        environment = environment,
        library = library,
        standalone = standalone,
        onConnectServer = {
            // Books here stay on the device either way.
            environment.localRoute?.showsListSignedOut = false
            onConnectServer()
        },
        onBack = if (standalone) null else ({ dispatcher?.onBackPressed() }),
    )
}

/**
 * The list, given what it reads.
 *
 * @param sizes and [freeSpace] given rather than measured: a screenshot's.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class, ExperimentalFoundationApi::class)
@Composable
internal fun LocalBooksContent(
    environment: AppEnvironment,
    library: LocalLibrary,
    standalone: Boolean,
    onConnectServer: () -> Unit,
    onBack: (() -> Unit)?,
    sizes: Map<String, Long>? = null,
    freeSpace: Long? = null,
    initialInfo: String? = null,
) {
    val app = environment.app
    val context = LocalContext.current
    val reduceMotion = remember(context) { ReadingSettings.animationsRemoved(context) }

    var measuredSizes by remember { mutableStateOf(sizes ?: emptyMap()) }
    var measuredFree by remember { mutableStateOf(freeSpace) }
    var reattaching by rememberSaveable { mutableStateOf<String?>(null) }
    var showsSettings by rememberSaveable { mutableStateOf(false) }
    var showsPlayer by rememberSaveable { mutableStateOf(false) }
    var info by rememberSaveable { mutableStateOf(initialInfo) }
    var highlighted by remember { mutableStateOf<String?>(null) }
    var openRow by remember { mutableStateOf<String?>(null) }
    // The row a hardware keyboard is on: arrows and Tab move it, Enter opens
    // it, Ctrl+Delete removes it and Ctrl+I shows its Book info.
    var focusedRow by remember { mutableStateOf<String?>(null) }
    val listState = rememberLazyListState()

    // The picker. EPUBs, and anything a provider only knows as bytes: a cloud
    // drive often hands an .epub over as `application/octet-stream`, and the
    // importer reads the file itself to decide what it is.
    val types = arrayOf("application/epub+zip", "application/octet-stream")
    val chooseMany = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris: List<Uri> ->
        if (uris.isNotEmpty()) library.importBooks(uris)
    }
    val chooseOne = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        val target = reattaching
        reattaching = null
        if (uri != null) library.importBooks(listOf(uri), reattaching = target)
    }
    fun choose() {
        reattaching = null
        runCatching { chooseMany.launch(types) }
    }
    fun addAgain(book: Book) {
        reattaching = book.uuid
        runCatching { chooseOne.launch(types) }
    }
    fun open(book: Book) {
        if (book.uuid in library.missingFiles) return addAgain(book)
        environment.localRoute?.open(book.uuid)
    }
    fun remove(uuids: List<String>) {
        if (uuids.isEmpty()) return
        openRow = null
        library.remove(uuids)
        app.announce(LocalBooksCopy.removedSpoken(library.pendingRemoval?.titles ?: emptyList()))
    }
    fun tap(book: Book) {
        if (openRow != null) {
            openRow = null
            return
        }
        if (book.uuid in library.missingFiles) addAgain(book) else open(book)
    }

    // The set, not the order: opening a book moves it to the top, and that is
    // no reason to walk every book's folder again.
    if (sizes == null) {
        LaunchedEffect(library.books.map { it.uuid }.toSet()) {
            val uuids = library.books.map { it.uuid }
            val (found, free) = withContext(Dispatchers.IO) { LocalLibrary.sizes(uuids, library.root) to DiskSpace.available() }
            measuredSizes = found
            measuredFree = free
        }
    }
    LaunchedEffect(Unit) { library.noteShown() }
    LaunchedEffect(library.addRequested) {
        if (library.addRequested) {
            library.addRequested = false
            choose()
        }
    }
    // The duplicate's row, outlined for two seconds and scrolled to.
    val duplicate = library.duplicate
    LaunchedEffect(duplicate?.uuid) {
        val uuid = duplicate?.uuid ?: return@LaunchedEffect
        highlighted = uuid
        LocalBooksLayout.indexOfBook(library, uuid)?.let { listState.animateScrollToItem(it) }
        delay(2_000)
        if (highlighted == uuid) highlighted = null
    }
    LaunchedEffect(duplicate?.uuid) {
        val uuid = duplicate?.uuid ?: return@LaunchedEffect
        delay(4_000)
        if (library.duplicate?.uuid == uuid) library.clearDuplicate()
    }
    // Narration that has stopped takes its player with it.
    val playing = app.playback
    LaunchedEffect(playing == null) { if (playing == null) showsPlayer = false }
    app.playback?.player.observe()

    val behavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior(rememberTopAppBarState())
    Scaffold(
        modifier = Modifier
            .fillMaxSize()
            .semantics { testTagsAsResourceId = true }
            .testTag("screen.localBooks")
            .nestedScroll(behavior.nestedScrollConnection)
            .onPreviewKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown || !event.isCtrlPressed) return@onPreviewKeyEvent false
                when (event.key) {
                    // Ctrl+O, as File › Add Book… is ⌘O on the Mac.
                    Key.O -> {
                        choose()
                        true
                    }
                    Key.Backspace, Key.Delete -> {
                        LocalBooksKeyboard.removalTarget(focusedRow)?.let { remove(listOf(it)) }
                        true
                    }
                    Key.I -> {
                        LocalBooksKeyboard.infoTarget(focusedRow, library.books)?.let { info = it }
                        true
                    }
                    else -> false
                }
            },
        containerColor = Palette.paper,
        topBar = {
            LocalBooksTitleBar(
                behavior = behavior,
                onBack = onBack,
                onSettings = if (standalone) ({ showsSettings = true }) else null,
                onAdd = ::choose,
            )
        },
        bottomBar = {
            // The tab bar carries its own mini player when the list is pushed;
            // standing alone, the list carries one while narration outlives
            // the reader.
            if (standalone && playing != null) StandaloneMiniPlayer(environment, onExpand = { showsPlayer = true })
        },
    ) { padding ->
        Box(Modifier.fillMaxSize()) {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(
                    start = Metrics.screenMargin,
                    end = Metrics.screenMargin,
                    top = padding.calculateTopPadding() + Metrics.spacing16,
                    bottom = padding.calculateBottomPadding() + Metrics.spacing16 + 72.dp,
                ),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                val empty = library.books.isEmpty() && library.imports.isEmpty()
                if (empty) {
                    item(key = "empty") { EmptyState(onChoose = ::choose) }
                } else {
                    item(key = "header") { Header(library.books.size, measuredSizes.values.sum(), measuredFree) }
                    importGroups(library, reduceMotion, onChooseAgain = ::choose)
                    booksGroup(
                        library = library,
                        environment = environment,
                        sizes = measuredSizes,
                        highlighted = highlighted,
                        openRow = openRow,
                        onOpenRowChange = { openRow = it },
                        onFocusChange = { uuid, focused ->
                            if (focused) focusedRow = uuid else if (focusedRow == uuid) focusedRow = null
                        },
                        onTap = ::tap,
                        onOpen = ::open,
                        onInfo = { info = it.uuid },
                        onAddAgain = ::addAgain,
                        onRemove = { remove(listOf(it.uuid)) },
                    )
                }
                if (standalone) item(key = "wayBack") { WayBack(onConnectServer) }
            }

            // The toasts, over the list's foot.
            val pending = library.pendingRemoval
            AnimatedVisibility(
                visible = pending != null || duplicate != null,
                modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = padding.calculateBottomPadding()),
                enter = slideInVertically { it } + fadeIn(),
                exit = slideOutVertically { it } + fadeOut(),
            ) {
                when {
                    pending != null -> LocalToast(
                        message = pending.message,
                        action = "Undo",
                        spoken = LocalBooksCopy.removedSpoken(pending.titles),
                        onAction = { library.undoRemoval() },
                        modifier = Modifier.testTag("toast.localRemoval"),
                    )
                    duplicate != null -> LocalToast(
                        message = LocalBooksCopy.alreadyHere(duplicate.title),
                        action = "Open",
                        spoken = LocalBooksCopy.alreadyHere(duplicate.title),
                        onAction = {
                            library.clearDuplicate()
                            open(duplicate)
                        },
                    )
                }
            }
        }
    }

    if (showsSettings) {
        LocalSettingsSheet(environment, library, onDismiss = { showsSettings = false }, onConnectServer = onConnectServer)
    }
    if (showsPlayer) {
        PlayerSheet(onDismiss = { showsPlayer = false }, onReadAlong = {
            showsPlayer = false
            app.playbackBook?.let { environment.localRoute?.open(it.uuid) }
        })
    }
    info?.let { uuid ->
        val book = library.book(uuid)
        if (book == null) {
            info = null
        } else {
            LocalBookInfoSheet(
                book = book,
                isMissing = uuid in library.missingFiles,
                coverCache = environment.covers(),
                onDismiss = { info = null },
                onOpen = {
                    info = null
                    open(book)
                },
                onAddAgain = { addAgain(book) },
                onRemove = {
                    info = null
                    remove(listOf(book.uuid))
                },
            )
        }
    }
}

/** Where things sit in the list, for scrolling to a row. */
internal object LocalBooksLayout {
    /** The list item a book's row is, counting the header and the import groups before it. */
    fun indexOfBook(library: LocalLibrary, uuid: String): Int? {
        val index = library.books.indexOfFirst { it.uuid == uuid }
        if (index < 0) return null
        val working = library.imports.count { it.stage !is LocalImport.Stage.Failed }
        val failed = library.imports.size - working
        var before = 1 // the header
        if (working > 0) before += 1 + working
        if (failed > 0) before += 1 + failed
        if (library.imports.isNotEmpty()) before += 1 // "Books"
        return before + index
    }
}

/**
 * The list's title bar: "On this phone", large, collapsing as it scrolls —
 * the design system's large title bar, with the standalone list's settings
 * button where the back button would be, and Add on the trailing side.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LocalBooksTitleBar(behavior: TopAppBarScrollBehavior, onBack: (() -> Unit)?, onSettings: (() -> Unit)?, onAdd: () -> Unit) {
    LargeTitleBar(
        LocalBooksCopy.listTitle,
        behavior,
        navigationIcon = {
            when {
                onBack != null -> BackButton(onBack, Modifier.padding(start = Metrics.spacing8))
                onSettings != null -> RoundToolbarButton(Symbols.gearshape, "Settings", onSettings, Modifier.padding(start = Metrics.spacing8).testTag("button.localSettings"))
            }
        },
        actions = {
            // "Add a book from Files" on the iPhone.
            RoundToolbarButton(Symbols.plus, "Add a book from your files", onAdd, Modifier.padding(end = Metrics.spacing8).testTag("button.addLocalBook"))
        },
    )
}

/** A toolbar button in the back button's round tonal style. */
@Composable
private fun RoundToolbarButton(icon: Int, description: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    FilledTonalIconButton(
        onClick = onClick,
        modifier = modifier.size(44.dp),
        colors = IconButtonDefaults.filledTonalIconButtonColors(containerColor = Palette.surface, contentColor = Palette.ink),
    ) {
        Icon(painterResource(icon), contentDescription = description, modifier = Modifier.size(24.dp))
    }
}

/** "Kept only on this phone…", and "3 books · 1.4 GB · 23 GB free". */
@Composable
private fun Header(count: Int, bytes: Long, free: Long?) {
    Column(Modifier.fillMaxWidth().widthIn(max = 640.dp).padding(bottom = Metrics.spacing24), verticalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
        Text(LocalBooksCopy.privacyLine, style = Typography.subhead, color = Palette.inkSecondary)
        Text(
            LocalBooksText.storageLine(count, bytes, free),
            style = Typography.footnote.copy(fontFeatureSettings = "tnum"),
            color = Palette.inkTertiary,
            modifier = Modifier.testTag("localBooks.storage"),
        )
    }
}

/** The list's words, without the list. */
internal object LocalBooksText {
    fun storageLine(count: Int, bytes: Long, free: Long?): String {
        val parts = mutableListOf("$count book${if (count == 1) "" else "s"}", ByteCountText.text(bytes))
        if (free != null) parts += "${ByteCountText.text(free)} free"
        return parts.joinToString(" · ")
    }

    /** "Files or iCloud Drive" on the iPhone. */
    val emptyFootnote: String get() = "Choose an EPUB from ${LocalBooksCopy.ORIGINALS_PLACE}. It’s copied here and read on this ${LocalDevice.noun} only."
}

@Composable
private fun EmptyState(onChoose: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(Metrics.spacing32)
            .testTag("localBooks.empty"),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Metrics.spacing12),
    ) {
        Icon(painterResource(Symbols.doc), contentDescription = null, tint = Palette.inkQuaternary, modifier = Modifier.size(38.dp))
        Text("No books on this ${LocalDevice.noun} yet", style = Typography.headline, color = Palette.ink, textAlign = TextAlign.Center)
        Text(LocalBooksText.emptyFootnote, style = Typography.footnote, color = Palette.inkTertiary, textAlign = TextAlign.Center)
        Text(
            "Choose a Book…",
            style = Typography.callout.copy(fontWeight = FontWeight.SemiBold),
            color = Palette.tangerinePressed,
            modifier = Modifier
                .heightIn(min = 44.dp)
                .clickable(role = Role.Button, onClick = onChoose)
                .testTag("localBooks.choose")
                .padding(horizontal = Metrics.spacing8, vertical = 12.dp),
        )
    }
}

/** Files on their way in, and the ones that could not be added. */
private fun LazyListScope.importGroups(library: LocalLibrary, reduceMotion: Boolean, onChooseAgain: () -> Unit) {
    val working = library.imports.filter { it.stage !is LocalImport.Stage.Failed }
    val failed = library.imports.filter { it.stage is LocalImport.Stage.Failed }
    if (working.isNotEmpty()) {
        item(key = "adding") {
            Row(Modifier.fillMaxWidth().widthIn(max = 640.dp), verticalAlignment = Alignment.CenterVertically) {
                Overline("Adding ${working.size} book${if (working.size == 1) "" else "s"}", Modifier.weight(1f))
                if (working.any { it.isUnfinished }) {
                    Text(
                        "Cancel All",
                        style = Typography.callout.copy(fontWeight = FontWeight.SemiBold),
                        color = Palette.tangerinePressed,
                        modifier = Modifier
                            .heightIn(min = 44.dp)
                            .clickable(role = Role.Button) { library.cancelAllImports() }
                            .testTag("localBooks.cancelAll")
                            .padding(vertical = 12.dp),
                    )
                }
            }
        }
        for (item in working) {
            item(key = "import-${item.id}") {
                Box(Modifier.widthIn(max = 640.dp).padding(bottom = Metrics.spacing8)) {
                    LocalImportRow(item, reduceMotion) { library.cancelImport(item.id) }
                }
            }
        }
    }
    if (failed.isNotEmpty()) {
        item(key = "failed") {
            Overline(
                "Couldn’t add ${failed.size} book${if (failed.size == 1) "" else "s"}",
                Modifier.fillMaxWidth().widthIn(max = 640.dp).padding(top = Metrics.spacing16, bottom = Metrics.spacing8),
            )
        }
        for (item in failed) {
            val error = (item.stage as LocalImport.Stage.Failed).error
            item(key = "problem-${item.id}") {
                Box(Modifier.widthIn(max = 640.dp).padding(bottom = Metrics.spacing8)) {
                    LocalProblemRow(
                        item,
                        error,
                        onAction = { action ->
                            when (action) {
                                LocalImportError.Action.TRY_AGAIN -> library.retry(item.id)
                                LocalImportError.Action.CHOOSE_AGAIN -> {
                                    library.dismissImport(item.id)
                                    onChooseAgain()
                                }
                            }
                        },
                        onDismiss = { library.dismissImport(item.id) },
                    )
                }
            }
        }
    }
}

/**
 * The books, lazily: a reader with hundreds of books had every row and every
 * cover built at once on the iPhone before its list was made lazy.
 */
@OptIn(ExperimentalFoundationApi::class)
private fun LazyListScope.booksGroup(
    library: LocalLibrary,
    environment: AppEnvironment,
    sizes: Map<String, Long>,
    highlighted: String?,
    openRow: String?,
    onOpenRowChange: (String?) -> Unit,
    onFocusChange: (String, Boolean) -> Unit,
    onTap: (Book) -> Unit,
    onOpen: (Book) -> Unit,
    onInfo: (Book) -> Unit,
    onAddAgain: (Book) -> Unit,
    onRemove: (Book) -> Unit,
) {
    if (library.imports.isNotEmpty()) {
        item(key = "booksTitle") {
            Overline("Books", Modifier.fillMaxWidth().widthIn(max = 640.dp).padding(top = Metrics.spacing16, bottom = Metrics.spacing8))
        }
    }
    for (book in library.books) {
        item(key = book.uuid) {
            val app = environment.app
            val isMissing = book.uuid in library.missingFiles
            val isPlaying = app.playbackBook?.uuid == book.uuid && app.playback?.player?.isPlaying == true
            val facts = LocalBookFacts(book, sizes[book.uuid], isMissing, isPlaying)
            var menu by remember { mutableStateOf(false) }
            val removeTitle = "Remove from this ${LocalDevice.noun}"
            Box(Modifier.widthIn(max = 640.dp).padding(bottom = Metrics.spacing8)) {
                LocalSwipeToRemove(
                    id = book.uuid,
                    openRow = openRow,
                    onOpenRowChange = onOpenRowChange,
                    label = "Remove",
                    onRemove = { onRemove(book) },
                ) {
                    LocalBookRow(
                        book = book,
                        size = sizes[book.uuid],
                        isMissing = isMissing,
                        isPlaying = isPlaying,
                        isHighlighted = highlighted == book.uuid,
                        onNoticeAction = { notice ->
                            when (notice) {
                                is LocalRowNotice.Imported -> library.dismissNotice(notice.notice, book.uuid)
                                LocalRowNotice.Missing -> onAddAgain(book)
                            }
                        },
                        coverCache = environment.covers(),
                        modifier = Modifier
                            .onFocusChanged { onFocusChange(book.uuid, it.isFocused) }
                            .combinedClickable(onClick = { onTap(book) }, onLongClick = { menu = true }),
                        rowModifier = Modifier.localRowActions(
                                spoken = facts.spoken,
                                onOpen = { onTap(book) },
                                onInfo = { onInfo(book) },
                                onRemove = { onRemove(book) },
                                removeTitle = removeTitle,
                            ),
                    )
                }
                // The row's menu, on a long press: Open and Book Info, or Add
                // Again for a book whose file is missing; then Remove.
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, containerColor = Palette.surface) {
                    if (isMissing) {
                        MenuItem("Add Again…", Symbols.plus) { menu = false; onAddAgain(book) }
                    } else {
                        MenuItem("Open", Symbols.book) { menu = false; onOpen(book) }
                        MenuItem("Book Info", Symbols.infoCircle) { menu = false; onInfo(book) }
                    }
                    HorizontalDivider(color = Palette.border)
                    DropdownMenuItem(
                        text = {
                            Column {
                                Text(removeTitle, style = SystemText.body, color = Palette.alert)
                                Text("The original in ${LocalBooksCopy.ORIGINALS_PLACE} stays", style = SystemText.footnote, color = Palette.inkTertiary)
                            }
                        },
                        trailingIcon = { Icon(painterResource(Symbols.trash), contentDescription = null, tint = Palette.alert) },
                        onClick = { menu = false; onRemove(book) },
                    )
                }
            }
        }
    }
}

@Composable
private fun MenuItem(title: String, icon: Int, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(title, style = SystemText.body, color = Palette.ink) },
        trailingIcon = { Icon(painterResource(icon), contentDescription = null, tint = Palette.ink) },
        onClick = onClick,
    )
}

/** The quiet link after the last row, back to the server sign-in. */
@Composable
private fun WayBack(onConnectServer: () -> Unit) {
    Text(
        "Connect to a Storyteller server",
        style = Typography.subhead.copy(fontWeight = FontWeight.Medium, textDecoration = TextDecoration.Underline),
        color = Palette.inkTertiary,
        textAlign = TextAlign.Center,
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = Metrics.spacing24)
            .heightIn(min = 44.dp)
            .clickable(role = Role.Button, onClick = onConnectServer)
            .testTag("link.connectToServer")
            .padding(vertical = 12.dp),
    )
}

/** The standalone list's own mini player, in a card above the foot of the screen. */
@Composable
private fun StandaloneMiniPlayer(environment: AppEnvironment, onExpand: () -> Unit) {
    val app = environment.app
    val book = app.playbackBook ?: return
    val coordinator = app.playback
    val scope = rememberCoroutineScope()
    coordinator?.player.observe()
    val progress = coordinator?.let {
        PlaybackProgress(environment.settings.progressScope, it.bookProgress, it.totalDuration, it.chapterSpan).fraction
    } ?: 0.0
    Box(Modifier.fillMaxWidth().padding(horizontal = Metrics.screenMargin, vertical = Metrics.spacing8), contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .widthIn(max = 480.dp)
                .fillMaxWidth()
                .border(1.dp, Palette.border, RoundedCornerShape(Metrics.radiusLarge))
                .clip(RoundedCornerShape(Metrics.radiusLarge)),
        ) {
            MiniPlayerBar(
                cover = { BookCoverImage(book, session = app.session, aspect = 1f, shape = LibraryService.CoverShape.SQUARE, cache = environment.covers()) },
                title = book.title,
                chapter = app.playbackChapterTitle,
                isPlaying = coordinator?.player?.isPlaying == true,
                progress = progress,
                onPlayPause = { scope.launch { coordinator?.perform(PlaybackAction.PLAY_PAUSE, environment.settings.commandMap); environment.nowPlaying.publish() } },
                onSkipBack = { scope.launch { coordinator?.perform(PlaybackAction.SKIP_BACKWARD, environment.settings.commandMap) } },
                onSkipForward = { scope.launch { coordinator?.perform(PlaybackAction.SKIP_FORWARD, environment.settings.commandMap) } },
                onExpand = onExpand,
            )
        }
    }
}
