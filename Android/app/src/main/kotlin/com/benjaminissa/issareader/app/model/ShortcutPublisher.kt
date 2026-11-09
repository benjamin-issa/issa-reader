package com.benjaminissa.issareader.app.model

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.benjaminissa.issareader.R
import com.benjaminissa.issareader.app.MainActivity
import com.benjaminissa.issareader.core.BoundedWait
import com.benjaminissa.issareader.core.CurrentBookSnapshotStore
import com.benjaminissa.issareader.core.KeyValueStore
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.isLocal
import com.benjaminissa.issareader.core.sync.LibraryRails
import com.benjaminissa.issareader.ui.HtmlText
import kotlinx.coroutines.CancellationException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** One launcher shortcut: a book, and the link that opens it. */
data class BookShortcut(
    val id: String,
    val shortLabel: String,
    val longLabel: String,
    /** `issareader://book/<uuid>`: the widget's link, so a shortcut opens the book rather than the app. */
    val link: String,
)

/**
 * What publishing asks of the launcher: replace the dynamic shortcuts, or
 * remove them. A seam, so a test can hold a removal the way a slow launcher
 * does, which is the condition the generation below exists for.
 */
interface ShortcutBackend {
    /** How many dynamic shortcuts the launcher shows for the app. */
    val capacity: Int
    suspend fun replace(shortcuts: List<BookShortcut>)
    suspend fun removeAll()
}

/** The launcher's own, through `ShortcutManagerCompat`. */
class LauncherShortcutBackend(private val context: Context) : ShortcutBackend {
    /** The static "Continue reading" shortcut takes one place. */
    override val capacity: Int
        get() = maxOf(ShortcutManagerCompat.getMaxShortcutCountPerActivity(context) - 1, 0)

    override suspend fun replace(shortcuts: List<BookShortcut>) {
        val infos = shortcuts.map { shortcut ->
            ShortcutInfoCompat.Builder(context, shortcut.id)
                .setShortLabel(shortcut.shortLabel)
                .setLongLabel(shortcut.longLabel)
                .setIcon(IconCompat.createWithResource(context, R.drawable.ic_shortcut_continue))
                .setIntent(
                    Intent(Intent.ACTION_VIEW, Uri.parse(shortcut.link)).setClass(context, MainActivity::class.java),
                )
                .build()
        }
        ShortcutManagerCompat.setDynamicShortcuts(context, infos)
    }

    override suspend fun removeAll() {
        ShortcutManagerCompat.removeAllDynamicShortcuts(context)
    }
}

/**
 * Puts the books the reader opened most recently into the launcher: Android's
 * stand-in for the iPhone's Spotlight index, chosen by the reader.
 *
 * Long-pressing the app's icon offers them beside "Continue reading", each
 * opening `issareader://book/<uuid>` — the widget's link, so a shortcut opens
 * the book rather than the app. Server books only, never a book from the
 * reader's own files: PRIVACY-ANDROID.md promises those are sent nowhere outside the
 * app, and the launcher is outside it.
 *
 * Replaced when what they would show changes, not on every launch. Cleared
 * when the account leaves ([AppModel]'s exit), which otherwise left its titles
 * on the home screen of a signed-out device. Main-thread only.
 *
 * @param clearWait how long an account's departure waits for the launcher.
 */
class ShortcutPublisher(
    private val backend: ShortcutBackend,
    private val defaults: KeyValueStore,
    private val clearWait: Duration = 3.seconds,
) : LibraryShortcuts {
    /**
     * Bumped by every pass and by [clear], so a pass that has been overtaken —
     * by a newer one, or by the account leaving — neither adds its shortcuts
     * nor records them as published.
     */
    private var generation = 0

    /** The [generation] the last [clear] took: what tells an account leaving from a newer pass. */
    private var clearedAt = -1

    /**
     * Publishes the recently opened books, unless what is published already
     * answers for them.
     */
    suspend fun update(books: List<Book>, force: Boolean = false) {
        val chosen = chosen(books, backend.capacity)
        val stamp = stamp(chosen)
        if (!force && defaults.getString(VERSION_KEY) == stamp) return
        generation += 1
        val pass = generation
        // Forgotten before the shortcuts are replaced: a pass that stops part
        // way must not leave a stored version claiming otherwise.
        defaults.remove(VERSION_KEY)
        try {
            val shortcuts = chosen.map(::shortcut)
            if (pass != generation) return
            backend.replace(shortcuts)
            if (pass != generation) {
                // Overtaken while the launcher was applying it. By the account
                // leaving, the clear's removal may have landed first, and what
                // this pass put there is the departed account's: it goes too.
                if (clearedAt == generation) runCatching { backend.removeAll() }
                return
            }
            defaults.putString(VERSION_KEY, stamp)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // A convenience; failing it must never surface as an error.
            IssaLog.failure("launcher shortcuts", e, mapOf("items" to chosen.size.toString()))
            defaults.remove(VERSION_KEY)
        }
    }

    /**
     * Takes this library out of the launcher, waiting for that at most
     * [clearWait]: an account's departure must not be held by a launcher that
     * does not answer. The removal still runs to the end.
     */
    override suspend fun clear() {
        generation += 1
        clearedAt = generation
        defaults.remove(VERSION_KEY)
        val backend = backend
        val finished = BoundedWait.run(clearWait) { runCatching { backend.removeAll() } }
        if (!finished) {
            IssaLog.warning(
                "launcher shortcuts clear still running; not waiting for it",
                mapOf("seconds" to clearWait.inWholeSeconds.toString()),
            )
        }
    }

    companion object {
        const val VERSION_KEY = "issa.shortcuts.libraryVersion"

        /** What the shortcuts carry, bumped whenever that changes. */
        const val SCHEMA = 1

        /** The books to publish: the most recently opened server books, newest first. */
        fun chosen(books: List<Book>, capacity: Int): List<Book> =
            LibraryRails.byRecency(books.filter { !it.isLocal && it.position != null }).take(capacity)

        /** What is stored for a set of shortcuts: the books, in order, under this schema. */
        fun stamp(books: List<Book>): String = "$SCHEMA|" + books.joinToString(",") { it.uuid }

        fun shortcut(book: Book): BookShortcut = BookShortcut(
            id = book.uuid,
            shortLabel = book.title,
            longLabel = listOf(book.title, book.byline).filter { it.isNotEmpty() }.joinToString(" — "),
            link = CurrentBookSnapshotStore.deepLink(book.uuid)?.toString() ?: "issareader://book/${book.uuid}",
        )

        /**
         * The line under a book: the byline, then the blurb as plain text — a
         * 3.x description arrives as HTML, tags, entities and all.
         */
        fun contentDescription(book: Book): String {
            val blurb = book.description?.let { HtmlText.plain(it).trim() }
            return listOf(book.byline, blurb).filter { !it.isNullOrEmpty() }.joinToString("\n")
        }
    }
}
