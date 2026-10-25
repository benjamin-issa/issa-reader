package com.benjaminissa.issareader.app.ui.reader

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.app.reader.ReaderPersistence
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.app.ui.shell.LocalAppEnvironment
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Typography
import com.benjaminissa.issareader.ui.color
import kotlinx.coroutines.flow.first

/** A book from the reader's own files, and where its writes go. */
data class LocalReaderBook(val book: Book, val persistence: ReaderPersistence)

/**
 * Opens a book, resolving its model at the moment the screen is really shown.
 *
 * Asking `AppModel` for the model has a side effect: a book opened for the
 * first time is registered with the app, which is what keeps its narration
 * alive after the screen closes. So it is asked once the screen has been
 * composed, never while it is being composed — registering from inside
 * composition writes state that the rest of the app is reading in the same
 * pass — and the answer is held, so nothing the app does to its readers
 * afterwards can make this screen build a second one.
 *
 * @param local whether this is a book from the reader's own files, whose
 *   writes go to the local library and nothing about it to any server.
 * @param onClose leaves the reader: the back gesture, the back button, or the
 *   account it was opened under going away.
 * @param onOpenPlayer the full player, which another screen draws.
 */
@Composable
fun ReaderScreen(bookUuid: String, local: Boolean, onClose: () -> Unit, onOpenPlayer: () -> Unit = {}) {
    // Everything from the shell's environment, not the graph: a test's fixture
    // library opens its books in the same reader the app's does.
    val shell = LocalAppEnvironment.current
    val environment = remember(shell) { shell.readerEnvironment() } ?: return
    val app = shell.app
    var model by remember { mutableStateOf<ReaderModel?>(null) }
    var missing by remember { mutableStateOf(false) }

    LaunchedEffect(bookUuid, local) {
        if (model != null) return@LaunchedEffect
        // Every face the reader imported is registered at launch
        // (`AppGraph.start`), before the first page is set in one.
        model = if (local) {
            shell.localBook(bookUuid)?.let { app.reader(it.book, it.persistence) }
        } else {
            val book = app.bookByUuid[bookUuid] ?: app.books.firstOrNull { it.uuid == bookUuid }
            val session = app.session
            if (book != null && session != null) app.reader(book, session) else null
        }
        missing = model == null
    }

    // Closed when the account it was opened under is left: nothing of the
    // departed account's book stays on screen.
    val opened = model
    if (opened != null) {
        LaunchedEffect(opened) {
            snapshotFlow { app.hasLeft(opened) }.first { it }
            onClose()
        }
    }

    // The page's own ground for the moment before the model lands, so a
    // reader that is opening is never briefly the wrong colour.
    val theme = environment.settings.readerStyle.theme
    Box(
        Modifier
            .fillMaxSize()
            .background(theme.background.color)
            .testTag("screen.reader")
            // The live check finds the reader's tags as resource ids, as the
            // iPhone's finds its accessibility identifiers.
            .semantics { testTagsAsResourceId = true },
    ) {
        when {
            opened != null && !app.hasLeft(opened) -> ReaderView(opened, environment, onClose = onClose, onOpenPlayer = onOpenPlayer)
            missing -> {
                BackHandler { onClose() }
                Column(
                    Modifier.align(Alignment.Center).padding(Metrics.spacing32),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(Metrics.spacing12),
                ) {
                    Text("Couldn't open this book", style = Typography.headline, color = theme.text.color)
                    Text(
                        "That book is no longer in your library.",
                        style = Typography.footnote,
                        color = theme.text.withAlpha(0.7).color,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
    }
}
