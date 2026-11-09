package com.benjaminissa.issareader.app.ui.shell

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.navigation.NavController
import com.benjaminissa.issareader.app.model.BookRouter
import kotlinx.serialization.Serializable

/*
 * The places the app can be, as Navigation's type-safe routes.
 *
 * Two levels, as on the iPhone: the root holds the tabs and, over them, the
 * reader — a full-screen cover the tab bar does not reach — and each tab
 * keeps its own stack of pages, saved and restored as the reader moves
 * between tabs.
 */

/** A book open in the reader, over everything. */
@Serializable
data class ReaderRoute(val bookUuid: String, val local: Boolean = false)

/** The three tabs' graphs, each its own back stack. */
@Serializable
data object LibraryTab

@Serializable
data object ReadingTab

@Serializable
data object SettingsTab

/** The tabs' first screens. */
@Serializable
data object LibraryHome

@Serializable
data object ReadingHomeRoute

@Serializable
data object SettingsHome

/** A book's page, by uuid: the screen looks the live book up, as Swift's does. */
@Serializable
data class BookDetailRoute(val uuid: String)

@Serializable
data class SeriesRoute(val name: String)

/** Every series, from the Series rail's "See all". */
@Serializable
data object SeriesListRoute

@Serializable
data class TagRoute(val name: String)

@Serializable
data class AuthorRoute(val name: String)

/** The Downloads screen, from the Reading tab's "Manage". */
@Serializable
data object DownloadsRoute

/** The books from the reader's own files, pushed from Settings. */
@Serializable
data object LocalBooksRoute

/** The shell's tabs, in the bar's order. */
enum class Tab { LIBRARY, READING, SETTINGS }

/**
 * Pushes pages on the stack of the tab a screen is in. A screen asks this
 * rather than holding the controller, as Swift's cells are not handed a
 * navigation path.
 */
class TabNavigator(private val controller: NavController?) {
    fun push(route: BookRouter.Route) {
        val destination: Any = when (route) {
            is BookRouter.Route.Details -> BookDetailRoute(route.book.uuid)
            is BookRouter.Route.Series -> SeriesRoute(route.name)
            is BookRouter.Route.Author -> AuthorRoute(route.name)
            is BookRouter.Route.Tag -> TagRoute(route.name)
        }
        controller?.navigate(destination)
    }

    fun push(destination: Any) {
        controller?.navigate(destination)
    }

    fun back() {
        controller?.popBackStack()
    }

    /** Whether there is a page under this one to go back to. */
    val canGoBack: Boolean get() = controller?.previousBackStackEntry != null

    companion object {
        val None = TabNavigator(null)
    }
}

val LocalTabNavigator = staticCompositionLocalOf { TabNavigator.None }
