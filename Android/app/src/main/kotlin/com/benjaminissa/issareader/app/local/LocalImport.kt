package com.benjaminissa.issareader.app.local

import android.net.Uri
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.ByteCountText
import com.benjaminissa.issareader.core.model.LocalNotice
import com.benjaminissa.issareader.core.model.ReadingProgress
import com.benjaminissa.issareader.ui.HtmlText
import com.benjaminissa.issareader.core.model.wholeSeconds
import java.util.UUID
import kotlin.math.roundToLong

/**
 * One file the reader chose, on its way into the local library.
 *
 * A row of its own from the moment the picker closes, in the order chosen;
 * files are added one at a time. Leaving the screen does not stop them.
 */
data class LocalImport(
    /** What the picker handed over: a `content://` Uri from the Storage Access Framework. */
    val source: Uri,
    /** The name the reader knows the file by. */
    val fileName: String,
    /** Whose missing file this is meant to put back, for "Add Again…". */
    val reattaching: String? = null,
    val id: String = UUID.randomUUID().toString(),
    val stage: Stage = Stage.Waiting,
) {
    sealed interface Stage {
        /** Queued behind another file. */
        data object Waiting : Stage

        /** A cloud provider is still fetching it, with no percentage to give. */
        data object Downloading : Stage

        /** Being copied into the app, 0…1. */
        data class Copying(val fraction: Double) : Stage

        /** Being checked: fingerprint, container, lock, chapters, narration. */
        data object Checking : Stage

        /** Added, as this book. Held briefly before the row goes. */
        data class Added(val bookUuid: String) : Stage

        /** Could not be added, and why. Stays until dismissed. */
        data class Failed(val error: LocalImportError) : Stage
    }

    /** Still to finish, and so cancellable. */
    val isUnfinished: Boolean
        get() = when (stage) {
            Stage.Waiting, Stage.Downloading, is Stage.Copying, Stage.Checking -> true
            is Stage.Added, is Stage.Failed -> false
        }

    /** What the row says while it works: the copy deck's status line. */
    val statusText: String?
        get() = when (val stage = stage) {
            Stage.Waiting -> "Waiting"
            Stage.Downloading -> "Downloading from cloud storage…"
            is Stage.Copying -> "Copying · ${(stage.fraction * 100).toInt()}%"
            Stage.Checking -> "Checking the book…"
            is Stage.Added -> "Added"
            is Stage.Failed -> null
        }
}

/**
 * Why a file could not be added, with the copy deck's words for it: what
 * happened ([title]), why and what to do ([reason]), then at most one action
 * beside Dismiss.
 */
sealed class LocalImportError : Exception() {
    /** Not an EPUB. [kind] names what it is instead, when that is known: "a PDF". */
    data class NotAnEpub(val kind: String?) : LocalImportError()

    /** A folder was chosen instead of the .epub. */
    data object Folder : LocalImportError()

    /** Parts of the file are missing or unreadable. */
    data object Damaged : LocalImportError()

    /** Locked by a shop's DRM. */
    data object DrmProtected : LocalImportError()

    /** Larger than the 4 GB limit. */
    data class TooLarge(val bytes: Long) : LocalImportError()

    /** Not enough room for the copy and the narration it will extract. */
    data class NotEnoughSpace(val needed: Long, val free: Long) : LocalImportError()

    /** The provider could not deliver the file: offline, usually. */
    data object NotDownloaded : LocalImportError()

    /** Access to the file was refused. */
    data object AccessDenied : LocalImportError()

    /** The copy itself failed; nothing was added. */
    data object CopyFailed : LocalImportError()

    /** "Add Again…" was given a different book than the one whose file is missing. */
    data class NotTheSameBook(val expectedFileName: String) : LocalImportError()

    enum class Action { TRY_AGAIN, CHOOSE_AGAIN }

    val title: String
        get() = when (this) {
            is NotAnEpub -> "Not an EPUB"
            Folder -> "This is a folder"
            Damaged -> "This book is damaged"
            DrmProtected -> "This book is copy-protected"
            is TooLarge -> "Too large to add"
            is NotEnoughSpace -> "Not enough space on this ${LocalDevice.noun}"
            NotDownloaded -> "Couldn’t download this file"
            AccessDenied -> "Issa Reader wasn’t given access"
            CopyFailed -> "Couldn’t copy this book"
            is NotTheSameBook -> "This isn’t the same book"
        }

    val reason: String
        get() = when (this) {
            is NotAnEpub -> (kind?.let { "This is $it." } ?: "This file isn’t an EPUB.") +
                " Issa Reader can open EPUB books only."
            Folder -> "Choose the .epub file itself rather than the folder it’s in."
            Damaged -> "Parts of the file are missing or unreadable. A fresh copy from where you got it should open."
            DrmProtected ->
                "It has DRM, a lock some shops add so a book opens only in their own app. Books from Kindle, Kobo, " +
                    "Apple Books or Adobe Digital Editions usually have it, and won’t open here."
            is TooLarge -> "This book is ${ByteCountText.text(bytes)}. Books up to 4 GB can be added."
            is NotEnoughSpace ->
                "This book needs ${ByteCountText.text(needed)} and ${ByteCountText.text(free)} is free. " +
                    "Free up some space, then try again."
            NotDownloaded -> "This ${LocalDevice.noun} seems to be offline. Connect to the internet, then try again."
            AccessDenied -> "The file couldn’t be opened where it’s stored. Choose it again to give access."
            CopyFailed -> "Something went wrong while copying, so nothing was added."
            is NotTheSameBook -> "This file is a different book. Choose $expectedFileName again to keep reading."
        }

    override val message: String get() = "$title. $reason"

    /** The one action beside Dismiss, or null when nothing the reader does here will help. */
    val action: Action?
        get() = when (this) {
            is NotAnEpub, Folder, AccessDenied, is NotTheSameBook -> Action.CHOOSE_AGAIN
            is NotEnoughSpace, NotDownloaded, CopyFailed -> Action.TRY_AGAIN
            Damaged, DrmProtected, is TooLarge -> null
        }

    companion object {
        /** What an action button says. */
        fun label(action: Action): String = when (action) {
            Action.TRY_AGAIN -> "Try Again"
            Action.CHOOSE_AGAIN -> "Choose Again"
        }

        /** What a file's extension says it is, for "This is a PDF." */
        fun kind(ofExtension: String): String? = when (ofExtension.lowercase()) {
            "pdf" -> "a PDF"
            "mobi", "azw", "azw3", "kfx" -> "a Kindle book"
            "doc", "docx" -> "a Word document"
            "txt" -> "a text file"
            "rtf" -> "a rich-text document"
            "zip" -> "a ZIP archive"
            "cbz", "cbr" -> "a comic archive"
            "m4b", "mp3", "m4a" -> "an audiobook file"
            else -> null
        }
    }
}

/**
 * The phone or tablet whose list this is, named as the copy deck names it:
 * "On this phone". Set from the configuration at launch.
 */
object LocalDevice {
    @Volatile var noun: String = "phone"
}

/** The copy deck's words for the list's notices and toasts, in one place. */
object LocalBooksCopy {
    /**
     * Where the original stays. "Files" on the iPhone, the app of that name;
     * Android has no one app the reader's files live in, so the copy deck
     * names them by what they are.
     */
    const val ORIGINALS_PLACE = "your files"

    /** The list's title: "On this phone". */
    val listTitle: String get() = "On this ${LocalDevice.noun}"

    val privacyLine: String get() = "Kept only on this ${LocalDevice.noun}. Nothing is sent to a server."

    fun notice(notice: LocalNotice): String = when (notice) {
        LocalNotice.NARRATION_UNPLAYABLE ->
            "Added without narration. Its audio is in a format this ${LocalDevice.noun} can’t play, so the book reads as text only."
        LocalNotice.FIXED_LAYOUT ->
            "This book was designed as fixed pages. It’s shown as flowing text, so pictures and layout may look different."
    }

    val restoredNotice: String get() = "Add it again from $ORIGINALS_PLACE to keep reading — your place and highlights are kept."

    val notOnDevice: String get() = "Not on ${LocalDevice.noun}"

    fun alreadyHere(title: String): String = "$title is already on this ${LocalDevice.noun}."

    /** The undo toast: "Removed Dracula. Original kept in your files." */
    fun removed(titles: List<String>): String =
        if (titles.size == 1) {
            "Removed ${titles[0]}. Original kept in $ORIGINALS_PLACE."
        } else {
            "Removed ${titles.size} books. Originals kept in $ORIGINALS_PLACE."
        }

    /** What a screen reader says for the toast. */
    fun removedSpoken(titles: List<String>): String =
        if (titles.size == 1) {
            "Removed ${titles[0]}. The original in $ORIGINALS_PLACE is kept. Undo available."
        } else {
            "Removed ${titles.size} books. The originals in $ORIGINALS_PLACE are kept. Undo available."
        }

    /**
     * "Narrated · 7 h 4 min", or "Narrated" alone for a length no clock can
     * show: the length is the book's own claim, and 1e21 seconds is finite.
     */
    fun narrated(seconds: Double): String {
        if (!(seconds > 0)) return "Narrated"
        val total = seconds.wholeSeconds ?: return "Narrated"
        val minutes = (total.toDouble() / 60).roundToLong()
        val length = if (minutes >= 60) "${minutes / 60} h ${minutes % 60} min" else "${maxOf(minutes, 1)} min"
        return "Narrated · $length"
    }
}

/**
 * Which row a keyboard's shortcuts act on — a tablet's or a Chromebook's
 * Delete and Ctrl+I. The Swift client's `LocalBooksKeyboard`.
 */
object LocalBooksKeyboard {
    /**
     * Delete: the row the keyboard is on, and nothing when it is on none.
     * Falling back to the first book removed the one opened last — the list's
     * first row — when the rows had been reached by touch (R-30).
     */
    fun removalTarget(focused: String?): String? = focused

    /** Ctrl+I: the row the keyboard is on, else the first book. Showing a book's info destroys nothing, so it may guess. */
    fun infoTarget(focused: String?, books: List<Book>): String? = focused ?: books.firstOrNull()?.uuid
}

/** What a row's notice strip is about, and so what its one action does. */
sealed interface LocalRowNotice {
    /** Told once after import: OK clears it for good. */
    data class Imported(val notice: LocalNotice) : LocalRowNotice

    /** The file did not come back from a backup: Add Again… opens the picker. */
    data object Missing : LocalRowNotice
}

/**
 * One book as its row card says it: what TalkBack reads and what the trailing
 * column shows. The Swift client's `LocalBookFacts`.
 */
data class LocalBookFacts(
    val book: Book,
    val size: Long?,
    val isMissing: Boolean,
    val isPlaying: Boolean,
) {
    val author: String get() = book.byline

    val narration: String?
        get() {
            val seconds = book.narrationDuration
            if (!book.hasReadalong || seconds == null || isMissing) return null
            return LocalBooksCopy.narrated(seconds)
        }

    val progress: Double? get() = book.progress?.takeIf { it > 0 }
    val percent: String? get() = progress?.let { ReadingProgress.percentText(it) }
    val sizeText: String? get() = size?.let { ByteCountText.text(it) }
    val trailing: String? get() = if (isMissing) LocalBooksCopy.notOnDevice else sizeText

    val notices: List<LocalRowNotice>
        get() = if (isMissing) listOf(LocalRowNotice.Missing) else (book.localCopy?.notices ?: emptyList()).map { LocalRowNotice.Imported(it) }

    /** The whole row, as one sentence: title, author, narration and length, percent, size, and "playing" while it narrates. */
    val spoken: String
        get() {
            val parts = mutableListOf(book.title)
            if (author.isNotEmpty()) parts.add(author)
            narration?.let { parts.add(it.replace(" · ", ", ")) }
            percent?.let { parts.add("$it read") }
            trailing?.let { parts.add(it) }
            if (isPlaying) parts.add("playing")
            return parts.joinToString(", ")
        }

    companion object {
        fun noticeText(notice: LocalRowNotice): String = when (notice) {
            is LocalRowNotice.Imported -> LocalBooksCopy.notice(notice.notice)
            LocalRowNotice.Missing -> LocalBooksCopy.restoredNotice
        }

        fun noticeAction(notice: LocalRowNotice): String = when (notice) {
            is LocalRowNotice.Imported -> "OK"
            LocalRowNotice.Missing -> "Add Again…"
        }
    }
}

/** What Book info shows of a book from the reader's own files. */
object LocalBookInfo {
    /**
     * The description as text. Calibre and most tools write it as escaped
     * HTML, which the XML parser hands back as literal tags and entities, so
     * it showed `<div><p>…` on screen (R-19).
     */
    fun aboutText(description: String?): String? {
        if (description.isNullOrEmpty()) return null
        val text = HtmlText.plain(description).trim()
        return text.ifEmpty { null }
    }
}
