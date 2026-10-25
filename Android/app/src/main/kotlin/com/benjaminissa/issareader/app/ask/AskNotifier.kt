package com.benjaminissa.issareader.app.ask

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import com.benjaminissa.issareader.app.local.LocalLibrary
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.ui.Symbols
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * What [AskCoordinator] asks of the notification shade.
 *
 * An interface so a test can count what was asked. The coordinator's
 * once-only permission prompt was otherwise unobservable, and deleting the
 * guard that makes it once-only left every test green.
 */
interface AskNotifying {
    /**
     * Asks for permission to notify, if nobody has decided yet. On Android 13
     * and later that is a runtime permission, which only a screen can put to
     * the reader: this raises [wantsPermission] for the sheet to ask.
     */
    fun requestAuthorizationIfNeeded()

    /** "Your answer is ready", if the reader is not already looking at the app. */
    fun postAnswerReady(job: AskJob)

    /**
     * The book has been read and the question is waiting for the app to come
     * back: Gemini Nano answers only for the app on screen. Android's own.
     */
    fun postReadyToAnswer(job: AskJob)

    fun removeDelivered(bookUuid: String)

    /**
     * Every book's but `kept`'s: sign-out on a device that also holds books
     * the reader added from their own files, whose answers are the device's.
     *
     * The one way to remove them all, with no default — a short form that
     * kept nothing was how a sign-out once swept the device's own banners.
     */
    fun removeAllDelivered(keeping: Set<String>)

    /** Whether the system's permission question should be put now, by the screen the reader is on. */
    val wantsPermission: Boolean get() = false

    /** The screen has put it, whatever the answer. */
    fun permissionAsked() {}
}

/**
 * Telling a reader their answer is ready, when they are not looking at it.
 *
 * The text is the **book**, and neither the question nor the answer. A
 * notification lands on a lock screen that gets handed round, glanced at
 * across a table, or mirrored onto a watch, so the answer was never a
 * candidate: this feature's whole promise is that nothing from further into
 * the book reaches the reader before they do. And on a secure lock screen not
 * even the book: the public version is the title alone.
 *
 * The question used to be the body, on the argument that it is theirs
 * already. PRIVACY.md promises "your questions and the answers are never
 * written down: they exist while the sheet is open and are gone when you close
 * it" — and a delivered notification outlives the sheet. So the question is
 * out, and [removeDelivered] takes back what has been delivered when the
 * reader reopens the answer and when the account's data is purged.
 *
 * One notification per book, under a tag naming the book: a later one for the
 * same book replaces the earlier, and two books answered while the app was
 * away read as two conversations rather than one pile.
 *
 * @param isActive whether the app is in front, read at the moment of posting.
 */
class AskNotifier(
    context: Context,
    private val isActive: () -> Boolean = {
        ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
    },
) : AskNotifying {
    private val context: Context = context.applicationContext ?: context
    private val manager: NotificationManager? get() = context.getSystemService(NotificationManager::class.java)

    override var wantsPermission: Boolean by mutableStateOf(false)
        private set

    /**
     * Raises the request, if the system has one to make and it has not been
     * granted. Below Android 13 notifications need no runtime permission.
     */
    override fun requestAuthorizationIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        wantsPermission = true
    }

    override fun permissionAsked() {
        wantsPermission = false
    }

    /**
     * Checked at the moment of posting rather than when the job started: an
     * answer that arrives two seconds after the reader comes back should not
     * buzz in their hand while they watch it appear.
     */
    override fun postAnswerReady(job: AskJob) = post(job, TITLE)

    override fun postReadyToAnswer(job: AskJob) = post(job, READY_TO_ANSWER_TITLE)

    private fun post(job: AskJob, title: String) {
        if (isActive()) {
            // Logged rather than passed over in silence: "I closed the sheet
            // and never heard anything" is the one complaint this feature will
            // attract, and the answer is usually that the app was in front.
            IssaLog.info("ask notification skipped", mapOf("reason" to "app active"))
            return
        }
        val manager = manager ?: return
        if (!manager.areNotificationsEnabled()) {
            IssaLog.info("ask notification skipped", mapOf("reason" to "not permitted"))
            return
        }
        ensureChannel(manager)
        val tapped = PendingIntent.getActivity(
            context,
            job.bookUuid.hashCode(),
            Intent(Intent.ACTION_VIEW, Uri.parse(link(job.bookUuid))).setPackage(context.packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        // What a secure lock screen shows: the title and nothing else.
        val public = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(Symbols.sparkles)
            .setContentTitle(title)
            .build()
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(Symbols.sparkles)
            .setContentTitle(title)
            .setContentText(body(job.bookTitle))
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(public)
            .setContentIntent(tapped)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_STATUS)
            .build()
        try {
            manager.notify(thread(job.bookUuid), NOTIFICATION_ID, notification)
            IssaLog.info("ask notification posted")
        } catch (refused: SecurityException) {
            // Never the question, never the answer.
            IssaLog.error("ask notification failed", mapOf("kind" to refused.javaClass.simpleName))
        }
    }

    /**
     * Takes back what has already been delivered for one book: a banner about
     * an answer would otherwise outlive the answer, the sheet and the app.
     */
    override fun removeDelivered(bookUuid: String) {
        manager?.cancel(thread(bookUuid), NOTIFICATION_ID)
    }

    /**
     * Every book's but `kept`'s, by tag rather than `cancelAll()`: a later
     * notification that has nothing to do with asking — a download's — must
     * not be swept away by a purge of the Ask indexes.
     */
    override fun removeAllDelivered(keeping: Set<String>) {
        val manager = manager ?: return
        val keptThreads = keeping.map(::thread).toSet()
        val delivered = runCatching { manager.activeNotifications }.getOrNull() ?: return
        for (notification in delivered) {
            val tag = notification.tag ?: continue
            if (tag.startsWith(THREAD_PREFIX) && tag !in keptThreads) manager.cancel(tag, notification.id)
        }
    }

    private fun ensureChannel(manager: NotificationManager) {
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_HIGH)
        channel.description = CHANNEL_DESCRIPTION
        manager.createNotificationChannel(channel)
    }

    companion object {
        const val TITLE = "Your answer is ready"

        /** The book has been read and the answer waits for the app: Gemini Nano answers only on screen. */
        const val READY_TO_ANSWER_TITLE = "Ready to answer your question"

        const val CHANNEL_ID = "issa.ask"
        const val CHANNEL_NAME = "Answers"
        const val CHANNEL_DESCRIPTION = "When the answer to a question about a book is ready."
        private const val NOTIFICATION_ID = 1
        private const val THREAD_PREFIX = "issa.ask."

        /**
         * Which book the answer is about, and nothing else.
         *
         * The book on its own rather than a sentence around it: the title
         * above has already said what happened. The fallback is for an EPUB
         * whose metadata carries no title at all.
         */
        fun body(bookTitle: String?): String {
            val trimmed = bookTitle?.trim().orEmpty()
            return trimmed.ifEmpty { "Open the book to read it." }
        }

        /** Everything this feature posts is under this, so what it takes back is its own and never somebody else's. */
        fun thread(bookUuid: String): String = "$THREAD_PREFIX$bookUuid"

        /** What a tap opens: `issareader://ask/<uuid>`, handled by `AppModel.open`. */
        fun link(bookUuid: String): String = "issareader://ask/$bookUuid"
    }
}

// MARK: -

/**
 * What a tapped notification asks for: the answer's sheet, and the book under
 * it. Swift's `AskNotificationDelegate.open`, reached here through the
 * `issareader://ask/<uuid>` link the notification carries (`AppModel.open`).
 *
 * @param local the books from the reader's files, waited for before a tap is
 *   routed — until it has loaded, `app.localBookUuids()` is empty and a tap for
 *   one of them would be asked of the server's library, which never answers
 *   it. Null when there is none to wait for.
 * @param localRequests where a tap for one of those books is left for the root
 *   to take.
 */
class AskNotificationRouter(
    private val coordinator: AskCoordinator,
    private val app: AppModel,
    private val local: LocalLibrary? = null,
    private val localRequests: LocalBookRequests = LocalBookRequests.shared,
    private val scope: CoroutineScope = app.scope,
) {
    fun open(bookUuid: String) {
        // The sheet first, then the book: the reader screen is built after
        // both have run, so the request is already in place when it looks.
        coordinator.reopenRequest = bookUuid
        if (!needsBookRequest(bookUuid, app.visibleReaderUuid)) return
        if (local != null && !local.isLoaded) {
            // A cold launch from the notification: which library the book is
            // in is not known until the local one has loaded.
            scope.launch {
                snapshotFlow { local.isLoaded }.first { it }
                route(bookUuid)
            }
        } else {
            route(bookUuid)
        }
    }

    /**
     * A book from the reader's files is left in [localRequests], where the
     * root takes it and opens its reader; any other book is asked of the
     * server's library.
     */
    private fun route(uuid: String) {
        if (uuid in app.localBookUuids()) {
            localRequests.request(uuid)
        } else {
            app.requestBook(uuid, AppModel.PendingBook.Destination.READ)
        }
    }

    companion object {
        /**
         * Whether a tap has to ask for the book as well as for its answer.
         *
         * Not when that book's reader is already up: it takes the tap through
         * `reopenRequest` and opens the answer itself, so a request for the
         * book has nothing left to do — and one left waiting would open the
         * book again the next time something consumed it.
         */
        fun needsBookRequest(uuid: String, visibleReader: String?): Boolean = visibleReader != uuid
    }
}

/**
 * A book from the reader's files that a tapped answer asked to open, waiting
 * for the root to take it.
 *
 * The local books' counterpart of `AppModel.pendingBook`: a local book is not
 * in the server's catalogue, so that inbox would wait for it for ever, and its
 * reader is presented by the local route instead (`LocalBooksRoute.open`).
 * Taken, not observed: [take] empties it, so only the first taker opens the
 * book.
 */
class LocalBookRequests {
    var pending: String? by mutableStateOf(null)
        private set

    fun request(uuid: String) {
        pending = uuid
    }

    /** The waiting book, once; null for every later caller. */
    fun take(): String? {
        val waiting = pending
        pending = null
        return waiting
    }

    companion object {
        val shared: LocalBookRequests by lazy { LocalBookRequests() }
    }
}
