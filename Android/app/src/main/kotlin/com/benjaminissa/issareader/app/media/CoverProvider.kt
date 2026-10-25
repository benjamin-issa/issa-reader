package com.benjaminissa.issareader.app.media

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.io.FileNotFoundException

/**
 * Serves the car its covers: `content://<package>.covers/<key>`, read-only,
 * from [com.benjaminissa.issareader.app.model.CoverCache]'s files.
 *
 * Not exported. Each address is granted to the car it was handed to
 * ([CarCovers.grant]), so the library's art is not readable by every app on
 * the phone.
 *
 * A cover not yet on disk is fetched while the car waits, briefly: a row
 * whose art arrives late is fine, and one that never does falls back to the
 * car's placeholder, as CarPlay's did.
 */
class CoverProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun getType(uri: Uri): String = "image/jpeg"

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("covers are read-only")
        val file = resolve(uri) ?: throw FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? {
        val key = uri.lastPathSegment?.takeIf(CarCovers::isKey) ?: return null
        val file = CarCovers.cached(key) ?: return null
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns, 1).apply {
            addRow(columns.map { if (it == OpenableColumns.SIZE) file.length() else "$key.jpg" })
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    private fun resolve(uri: Uri): File? {
        val key = uri.lastPathSegment?.takeIf(CarCovers::isKey) ?: return null
        CarCovers.cached(key)?.let { return it }
        // The fetch runs on the main thread, where the cache lives. A request
        // that arrived on it cannot wait for it.
        if (Looper.myLooper() == Looper.getMainLooper()) return null
        return runBlocking {
            withTimeoutOrNull(FETCH_TIMEOUT_MILLIS) { withContext(Dispatchers.Main) { CarCovers.fetch(key) } }
        }
    }

    companion object {
        /** How long a car's row waits for art the phone does not have yet. */
        const val FETCH_TIMEOUT_MILLIS = 8_000L
    }
}
