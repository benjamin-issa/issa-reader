package com.benjaminissa.issareader.app.ui.book

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import com.benjaminissa.issareader.app.model.BookActions
import com.benjaminissa.issareader.app.ui.shell.LocalAppEnvironment
import com.benjaminissa.issareader.core.download.BookMenu
import com.benjaminissa.issareader.ui.Symbols

/**
 * This screen's [BookActions]: the model's, with what the screen it was
 * opened on supplies — where it pushes ([LocalBookRouter]) and what kind of
 * screen it is ([LocalBookPlace]).
 */
@Composable
fun rememberBookActions(): BookActions {
    val environment = LocalAppEnvironment.current
    val router = LocalBookRouter.current
    val place = LocalBookPlace.current
    val scope = environment.app.scope
    return remember(environment, router, place) {
        BookActions(environment.app, router, environment.nowPlaying, environment.settings, place, scope)
    }
}

/** The icon for an edition action's SF Symbol. */
val BookMenu.EditionAction.symbol: Int
    get() = when (kind) {
        BookMenu.EditionAction.Kind.SAVE -> Symbols.arrowDownCircle
        BookMenu.EditionAction.Kind.PAUSE -> Symbols.pauseCircle
        BookMenu.EditionAction.Kind.RESUME -> Symbols.playCircle
        BookMenu.EditionAction.Kind.RETRY -> Symbols.arrowClockwise
        BookMenu.EditionAction.Kind.REMOVE -> Symbols.trash
    }
