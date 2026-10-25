package com.benjaminissa.issareader.app.ui.book

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.text.font.FontWeight
import com.benjaminissa.issareader.app.model.BookAlert
import com.benjaminissa.issareader.app.model.BookRouter
import com.benjaminissa.issareader.app.ui.shell.LocalShellActions
import com.benjaminissa.issareader.app.ui.shell.LocalTabNavigator
import com.benjaminissa.issareader.core.download.BookMenu
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.SystemText

/** This screen's router, found by a book's menu: Swift's `@Environment(BookRouter.self)`. */
val LocalBookRouter = staticCompositionLocalOf<BookRouter?> { null }

/** Which screen a book's menu is opened on; see [BookMenu.Place]. Swift's `\.bookPlace`. */
val LocalBookPlace = staticCompositionLocalOf<BookMenu.Place> { BookMenu.Place.Shelf }

/**
 * Installs this screen's [BookRouter] and says which screen it is, so a book's
 * menu offers neither the way to here nor a route it cannot take: Swift's
 * `.bookRoutes(place:)`.
 *
 * A route the menu asks for is pushed on this screen's tab, on top of this
 * screen, keeping the back stack. "Now Playing" raises the shell's player, and
 * anything a menu item tried and could not do is said in an alert, because
 * the menu that asked has already closed.
 */
@Composable
fun BookRoutes(place: BookMenu.Place, content: @Composable () -> Unit) {
    val router = remember { BookRouter() }
    val navigator = LocalTabNavigator.current
    val shell = LocalShellActions.current
    LaunchedEffect(router) {
        snapshotFlow { router.route }.collect { route ->
            if (route != null) {
                router.route = null
                navigator.push(route)
            }
        }
    }
    LaunchedEffect(router) {
        snapshotFlow { router.showsPlayer }.collect { shows ->
            if (shows) {
                router.showsPlayer = false
                shell.showPlayer()
            }
        }
    }
    CompositionLocalProvider(LocalBookRouter provides router, LocalBookPlace provides place) {
        content()
    }
    router.alert?.let { alert -> BookAlertDialog(alert) { router.alert = null } }
}

/** A [BookAlert] as Material's dialog, with the one button Swift's has. */
@Composable
fun BookAlertDialog(alert: BookAlert, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text("OK", style = SystemText.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.tangerine)
            }
        },
        title = { Text(alert.title, style = SystemText.headline, color = Palette.ink) },
        text = { Text(alert.message, style = SystemText.subheadline, color = Palette.inkSecondary) },
        containerColor = Palette.surface,
    )
}
