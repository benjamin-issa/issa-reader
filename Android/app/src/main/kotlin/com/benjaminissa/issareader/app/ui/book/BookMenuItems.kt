package com.benjaminissa.issareader.app.ui.book

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.BookRouter
import com.benjaminissa.issareader.app.ui.shell.appModel
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.download.BookMenu
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.SystemText

/**
 * A book's hold menu — long-press on a cover or a row — wherever the book is
 * drawn. [content] is handed the way to open it (null while signed out, when
 * the cell is inert, as Swift's `BookLink` is), and the menu hangs from the
 * box the content is drawn in.
 *
 * @param focusEdition the edition a Downloads row stands for. Its removal is
 *   the row's own, last in the menu.
 * @param onRemoveFocused how the row removes it, so the row can tidy up after
 *   itself as its swipe does.
 */
@Composable
fun BookMenuBox(
    book: Book,
    modifier: Modifier = Modifier,
    focusEdition: BookContentService.Format? = null,
    onRemoveFocused: (() -> Unit)? = null,
    content: @Composable (openMenu: (() -> Unit)?) -> Unit,
) {
    val signedIn = appModel.session != null
    var open by remember { mutableStateOf(false) }
    Box(modifier) {
        content(if (signedIn) ({ open = true }) else null)
        if (signedIn) {
            BookMenuDropdown(book, open, onDismiss = { open = false }, focusEdition = focusEdition, onRemoveFocused = onRemoveFocused)
        }
    }
}

/** Which of the menu's submenus is showing in place of its items. */
private enum class Submenu { MARK_AS, RATE, DOWNLOADS }

/**
 * The menu itself: core's [BookMenu] drawn as Material's menu, in its groups
 * with a divider between them, and its items run.
 *
 * "Mark as", "Rate" and "Downloads" are submenus, as on the iPhone. Material's
 * menu has no cascading submenu, so a submenu takes the menu's place, headed
 * by a row that leads back.
 *
 * Nothing is worked out until the menu opens: a grid of a thousand covers
 * carries a thousand menus, and the one question that touches the disk —
 * which editions are on it — is asked only for a book the downloads set names.
 */
@Composable
fun BookMenuDropdown(
    book: Book,
    expanded: Boolean,
    onDismiss: () -> Unit,
    focusEdition: BookContentService.Format? = null,
    onRemoveFocused: (() -> Unit)? = null,
) {
    val actions = rememberBookActions()
    var submenu by remember { mutableStateOf<Submenu?>(null) }
    val dismiss = {
        submenu = null
        onDismiss()
    }
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = dismiss,
        containerColor = Palette.surface,
        shape = RoundedCornerShape(Metrics.radiusLarge),
    ) {
        if (!expanded) return@DropdownMenu
        // The live book: the cell that built the menu may hold a copy from
        // before a status or a position changed.
        val live = actions.app.bookByUuid[book.uuid] ?: book
        val menu = BookMenu.resolve(live, actions.inputs(live, focusEdition))
        when (submenu) {
            null -> menu.sections.forEachIndexed { index, section ->
                if (index > 0) MenuDivider()
                for (item in section) {
                    when (item) {
                        BookMenu.Item.Details -> MenuRow(actions.detailsTitle, Symbols.infoCircle) {
                            dismiss()
                            actions.viewDetails(live)
                        }
                        is BookMenu.Item.Read -> MenuRow(item.title, Symbols.book) {
                            dismiss()
                            actions.read(live)
                        }
                        BookMenu.Item.Listen -> MenuRow("Listen", Symbols.headphones) {
                            dismiss()
                            actions.listen(live)
                        }
                        BookMenu.Item.NowPlaying -> MenuRow("Now Playing", Symbols.waveform) {
                            dismiss()
                            actions.showPlayer()
                        }
                        is BookMenu.Item.MarkAs -> SubmenuRow("Mark as", Symbols.bookmark) { submenu = Submenu.MARK_AS }
                        is BookMenu.Item.Rate -> SubmenuRow("Rate", Symbols.star) { submenu = Submenu.RATE }
                        is BookMenu.Item.GoToSeries -> MenuRow("Go to Series", Symbols.booksVertical) {
                            dismiss()
                            actions.push(BookRouter.Route.Series(item.name))
                        }
                        is BookMenu.Item.MoreBy -> MenuRow("More by ${item.author}", Symbols.person) {
                            dismiss()
                            actions.push(BookRouter.Route.Author(item.author))
                        }
                        is BookMenu.Item.Edition -> EditionRow(item.action, namingEdition = false) {
                            dismiss()
                            actions.perform(item.action, live)
                        }
                        is BookMenu.Item.Downloads -> SubmenuRow("Downloads", Symbols.arrowDownCircle) { submenu = Submenu.DOWNLOADS }
                        is BookMenu.Item.RemoveFocused -> MenuRow("Remove download", Symbols.trash, destructive = true) {
                            dismiss()
                            if (onRemoveFocused != null) onRemoveFocused() else actions.remove(live, item.format)
                        }
                    }
                }
            }
            Submenu.MARK_AS -> {
                BackRow("Mark as") { submenu = null }
                MenuDivider()
                val choices = menu.items.filterIsInstance<BookMenu.Item.MarkAs>().firstOrNull()?.choices.orEmpty()
                for (choice in choices) {
                    CheckRow(choice.status.displayName, checked = choice.isCurrent) {
                        dismiss()
                        actions.setStatus(choice.status, live)
                    }
                }
            }
            Submenu.RATE -> {
                BackRow("Rate") { submenu = null }
                MenuDivider()
                val current = menu.items.filterIsInstance<BookMenu.Item.Rate>().firstOrNull()?.current
                for (stars in 1..5) {
                    CheckRow(stars(stars), checked = stars == current) {
                        dismiss()
                        actions.setRating(stars, live)
                    }
                }
                if (current != null) {
                    MenuDivider()
                    MenuRow("Clear rating", Symbols.starSlash) {
                        dismiss()
                        actions.setRating(null, live)
                    }
                }
            }
            Submenu.DOWNLOADS -> {
                BackRow("Downloads") { submenu = null }
                MenuDivider()
                val editions = menu.items.filterIsInstance<BookMenu.Item.Downloads>().firstOrNull()?.actions.orEmpty()
                for (action in editions) {
                    EditionRow(action, namingEdition = true) {
                        dismiss()
                        actions.perform(action, live)
                    }
                }
            }
        }
    }
}

/** "1 star", "3 stars". */
fun stars(count: Int): String = if (count == 1) "1 star" else "$count stars"

@Composable
private fun MenuDivider() {
    HorizontalDivider(thickness = 0.5.dp, color = Palette.border)
}

@Composable
private fun MenuText(title: String, color: Color) {
    Text(title, style = SystemText.body, color = color, maxLines = 1, overflow = TextOverflow.Ellipsis)
}

@Composable
private fun MenuIcon(symbol: Int, tint: Color) {
    Icon(painterResource(symbol), contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
}

@Composable
private fun MenuRow(title: String, symbol: Int, destructive: Boolean = false, onClick: () -> Unit) {
    val color = if (destructive) Palette.alert else Palette.ink
    DropdownMenuItem(
        text = { MenuText(title, color) },
        leadingIcon = { MenuIcon(symbol, color) },
        onClick = onClick,
    )
}

@Composable
private fun EditionRow(action: BookMenu.EditionAction, namingEdition: Boolean, onClick: () -> Unit) {
    MenuRow(action.title(namingEdition), BookActions.symbol(action), destructive = action.isDestructive, onClick = onClick)
}

/** A row that opens a submenu: its icon, its title, and the chevron that says there is more. */
@Composable
private fun SubmenuRow(title: String, symbol: Int, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { MenuText(title, Palette.ink) },
        leadingIcon = { MenuIcon(symbol, Palette.ink) },
        trailingIcon = { MenuIcon(Symbols.chevronRight, Palette.inkTertiary) },
        onClick = onClick,
    )
}

/** A submenu's head, which leads back to the menu. */
@Composable
private fun BackRow(title: String, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(title, style = SystemText.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.ink) },
        leadingIcon = { MenuIcon(Symbols.chevronLeft, Palette.ink) },
        onClick = onClick,
    )
}

/** One choice of several, checked when it is the current one. */
@Composable
private fun CheckRow(title: String, checked: Boolean, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { MenuText(title, Palette.ink) },
        trailingIcon = if (checked) {
            { Icon(painterResource(Symbols.checkmark), contentDescription = "Selected", tint = Palette.tangerine) }
        } else {
            null
        },
        onClick = onClick,
    )
}

/** The live book: a value handed over at navigation time does not change when the library does. */
internal fun Book.liveIn(app: AppModel): Book = app.bookByUuid[uuid] ?: this
