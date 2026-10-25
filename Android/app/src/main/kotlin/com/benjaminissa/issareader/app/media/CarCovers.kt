package com.benjaminissa.issareader.app.media

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.benjaminissa.issareader.app.model.CoverCache
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.sync.LibraryService
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Covers for the car, by address: `content://<package>.covers/<key>`.
 *
 * CarPlay's rows were handed images. Android Auto's are handed URIs, which it
 * reads in its own process — a bitmap per row across a binder is what its
 * guidelines ask an app not to send — so the art is served by [CoverProvider]
 * from the files [CoverCache] already keeps, under the same keys, and each
 * address is granted to the car that was given it rather than exported to
 * every app on the phone.
 *
 * Square and small, as the Swift car's were: this is a list row in a car, not
 * the lock-screen tile.
 */
object CarCovers {
    /** The pixel width a car's row asks for. */
    const val PIXELS = 240

    private const val AUTHORITY_SUFFIX = ".covers"
    private val KEY = Regex("[A-Za-z0-9._-]{1,200}")

    /**
     * The packages that draw what the session publishes beyond the app's own
     * process: Android Auto, the system's media controls, Android Automotive's
     * media centre and its assistant.
     */
    val carPackages: List<String> = listOf(
        "com.google.android.projection.gearhead",
        "com.android.systemui",
        "com.android.car.media",
        "com.google.android.carassistant",
    )

    /** Where a cover comes from when it is not on disk yet. */
    interface Source {
        /** The cover cache's directory, where every key's JPEG is filed. */
        val directory: File

        /** Fetches [book]'s square cover into [directory], returning the file. */
        suspend fun fetch(book: Book): File?
    }

    @Volatile
    private var source: Source? = null

    /** Which book each address handed out was for, so a cover not yet on disk can be fetched. */
    private val books = ConcurrentHashMap<String, Book>()

    /** Installed by the app as it starts; null in a process with no graph. */
    fun install(source: Source?) {
        this.source = source
    }

    fun authority(context: Context): String = context.packageName + AUTHORITY_SUFFIX

    /** The key a book's square cover is filed under: [CoverCache]'s own. */
    fun key(book: Book): String = CoverCache.imageKey(book, LibraryService.CoverShape.SQUARE, PIXELS)

    /** A server book's cover address, remembered so the provider can fetch it. Never for a local book. */
    fun uri(context: Context, book: Book): Uri? {
        if (book.localCopy != null) return null
        val key = key(book)
        if (!isKey(key)) return null
        books[key] = book
        return Uri.Builder().scheme(ContentResolver.SCHEME_CONTENT).authority(authority(context)).appendPath(key).build()
    }

    /** Whether [key] is a name this provider could have handed out — never a path. */
    fun isKey(key: String): Boolean = KEY.matches(key) && key != "." && key != ".."

    /** The cover filed under [key], when it is already on disk. */
    fun cached(key: String): File? {
        if (!isKey(key)) return null
        val directory = source?.directory ?: return null
        return File(directory, "$key.jpg").takeIf { it.isFile }
    }

    /** Fetches the cover filed under [key]. Main thread: the cache is main-thread only. */
    suspend fun fetch(key: String): File? {
        val book = books[key] ?: return null
        return source?.fetch(book)
    }

    /**
     * Lets [packages] read [uri]. A package that is not installed is skipped:
     * the grant is for whoever draws the car, and only one of them is there.
     */
    fun grant(context: Context, uri: Uri, packages: Collection<String>) {
        for (pkg in packages) {
            if (pkg == context.packageName) continue
            runCatching { context.grantUriPermission(pkg, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        }
    }
}
