package com.benjaminissa.issareader.app.ui.player

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.ui.shell.AppEnvironment
import com.benjaminissa.issareader.app.ui.shell.LocalAppEnvironment
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.BookFormat
import com.benjaminissa.issareader.core.model.isLocal
import com.benjaminissa.issareader.playback.PlaybackDriving
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.SystemText

/**
 * The full player for whatever is running, expanded from the mini bar:
 * `NowPlayingSheet.swift`, as a full-height Material bottom sheet.
 *
 * There is no idle state: the only way here is the mini bar, which exists only
 * while something is playing — so playback ending takes the sheet with it.
 *
 * @param onReadAlong opens the reader on the book that is playing; offered
 *   only for a book with text, and one this device can open.
 * @param fromReader the reader whose waveform raised the sheet. Its sheet is
 *   about its own book, as the iPhone's reader sheet is: its read-along,
 *   started or not, unless the audiobook engine has the book, which is then
 *   what plays. Before anything has played it shows where Play would begin,
 *   and Play, the skips and the slider go through the reader.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlayerSheet(onDismiss: () -> Unit, onReadAlong: () -> Unit, fromReader: ReaderModel? = null) {
    val environment = LocalAppEnvironment.current
    val app = environment.app
    // The audiobook engine holding the reader's book is the thing playing it.
    val readerOwnsPlayback = fromReader != null && !(app.listening != null && app.listeningBook?.uuid == fromReader.book.uuid)
    val book = if (fromReader != null) fromReader.book else app.playbackBook
    LaunchedEffect(book == null) { if (book == null) onDismiss() }
    if (book == null) return
    val coordinator = if (readerOwnsPlayback) fromReader?.readalong else app.playback
    val fromPage = fromReader?.let { reader ->
        NarrationFromPage(
            pending = { if (readerOwnsPlayback) reader.pendingNarrationStart else null },
            start = { app.togglePlaybackForThisBook(reader) },
            cue = { reader.cueNarration(it) },
        )
    }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Palette.paper,
        dragHandle = { BottomSheetDefaults.DragHandle(color = Palette.borderStrong) },
    ) {
        NowPlayingSheetContent(
            book = book,
            session = app.session,
            coordinator = coordinator,
            chapterTitle = if (readerOwnsPlayback) fromReader?.chapterTitle else app.playbackChapterTitle,
            environment = environment,
            onDone = onDismiss,
            // From the reader, the words are already under the sheet.
            onReadAlong = if (fromReader != null) onDismiss else onReadAlong,
            modifier = Modifier.fillMaxHeight(),
            fromPage = fromPage,
        )
    }
}

/** The sheet's inside: its bar — Done, "Playing", Read along — over the player. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class)
@Composable
internal fun NowPlayingSheetContent(
    book: Book,
    session: Session?,
    coordinator: PlaybackDriving?,
    chapterTitle: String?,
    environment: AppEnvironment,
    onDone: () -> Unit,
    onReadAlong: () -> Unit,
    modifier: Modifier = Modifier,
    fromPage: NarrationFromPage? = null,
) {
    Column(modifier.fillMaxWidth().semantics { testTagsAsResourceId = true }.testTag("screen.player")) {
        CenterAlignedTopAppBar(
            title = { Text("Playing", style = SystemText.navigationTitle, maxLines = 1) },
            navigationIcon = {
                TextButton(onClick = onDone) {
                    Text("Done", style = SystemText.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.tangerine)
                }
            },
            actions = {
                // Getting back to the words should not mean Library, then the
                // book, then Resume. A book from the reader's files needs no
                // session: it is read from the device.
                if (NowPlayingSheet.offersReadAlong(book, hasSession = session != null)) {
                    IconButton(onClick = onReadAlong, modifier = Modifier.testTag("player.readAlong")) {
                        Icon(painterResource(Symbols.book), contentDescription = "Read along", tint = Palette.ink, modifier = Modifier.size(24.dp))
                    }
                }
            },
            // Inside the sheet, which already sits below the status bar.
            windowInsets = WindowInsets(0, 0, 0, 0),
            colors = TopAppBarDefaults.topAppBarColors(
                containerColor = Palette.paper,
                scrolledContainerColor = Palette.paper,
                titleContentColor = Palette.ink,
                actionIconContentColor = Palette.ink,
                navigationIconContentColor = Palette.tangerine,
            ),
        )
        Box(Modifier.fillMaxSize()) {
            PlayerView(
                book = book,
                session = session,
                coordinator = coordinator,
                chapterTitle = chapterTitle,
                settings = environment.settings,
                nowPlaying = environment.nowPlaying,
                coverCache = environment.covers(),
                fromPage = fromPage,
            )
        }
    }
}

/** The sheet's rules, without the sheet. */
internal object NowPlayingSheet {
    /**
     * Whether there is anything to read along with, and a way to open it: a
     * plain audiobook has no text at all, and offering to open it would be a
     * lie; a server's book needs its session.
     */
    fun offersReadAlong(book: Book, hasSession: Boolean): Boolean {
        val hasText = BookFormat.EBOOK in book.servableFormats || BookFormat.READALOUD in book.servableFormats
        return hasText && (hasSession || book.isLocal)
    }
}
