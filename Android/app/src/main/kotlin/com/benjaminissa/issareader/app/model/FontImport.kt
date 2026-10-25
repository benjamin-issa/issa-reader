package com.benjaminissa.issareader.app.model

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.benjaminissa.issareader.core.StorageRoot
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.android.ReaderFonts
import com.benjaminissa.issareader.ui.IssaFonts
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Faces the reader imported: the Android half of IssaUI's `CustomFonts`, for
 * imported faces only.
 *
 * A book's own face never comes through here: [ReaderFonts.registerPublisherFace]
 * registers it from the book's archive, in memory, so there is no
 * `Fonts/<uuid>/` to extract into or sweep. What is left is the fonts folder's
 * root, which holds what the reader imported and nothing else, and is
 * registered again at every launch ([registerAll]).
 *
 * Registration is keyed by file, as the Swift registry is by URL, so two
 * imports of different files are two registrations. The renderer registers a
 * family from its files, so this keeps which file is which member of which
 * family: importing a family's bold after its regular gives the family a bold
 * rather than replacing it, as CoreText's registration does on the iPhone.
 * And a copy of a family the app ships is answered with the app's own and
 * never registered, because registering it beside the bundled files would
 * make which copy a page gets depend on the order things happened in.
 *
 * One for the app ([com.benjaminissa.issareader.app.AppGraph.customFonts]),
 * over the one [ReaderFonts] every page is set from.
 *
 * @param directory where imported faces live: `Fonts/` under [StorageRoot],
 *   which the backup rules leave out — the file came from somewhere else and
 *   can come from there again.
 */
class CustomFonts(
    private val fonts: ReaderFonts,
    private val directory: () -> File = { StorageRoot.directory("Fonts") },
) {
    private data class Member(val family: String, val bold: Boolean, val italic: Boolean)

    /** File path to the family and member it registered as, in the order they arrived. */
    private val registered = LinkedHashMap<String, Member>()

    /** Imported faces live here; the reader chose them. Created on first ask, or null when it cannot be. */
    val importedDirectory: File?
        get() = directory().also { it.mkdirs() }.takeIf { it.isDirectory }

    /**
     * Registers a font file and returns the family name to ask for.
     *
     * Idempotent per file. Returns null for a format Android cannot read, or a
     * file it rejects — callers fall back to the chosen face rather than
     * setting the page in nothing.
     */
    @Synchronized
    fun register(file: File): String? {
        registered[file.path]?.let { return it.family }
        if (!isReadable(file.name)) return null
        val bytes = try {
            file.readBytes()
        } catch (_: Exception) {
            return null
        }
        // Read before registering: a file that cannot be named is never
        // registered at all.
        val description = describe(bytes) ?: return null
        // A copy of a family the app ships is answered with the bundled
        // family, and neither registered nor recorded — so [families] never
        // offers it under "Your fonts".
        bundledFamily(description.family)?.let { return it }
        if (!isUsable(bytes)) return null
        registered[file.path] = Member(description.family, description.bold, description.italic)
        install(description.family)
        return description.family
    }

    /**
     * Hands a family's every member to the renderer, which registers a family
     * whole: the upright regular — or, failing one, the first file of the
     * family — with whichever bold, italic and bold italic have arrived.
     */
    private fun install(family: String) {
        val members = registered.entries
            .filter { it.value.family == family }
            .map { File(it.key) to it.value }
            .filter { it.first.exists() }
        fun member(bold: Boolean, italic: Boolean): File? =
            members.firstOrNull { it.second.bold == bold && it.second.italic == italic }?.first
        val regular = member(bold = false, italic = false) ?: members.firstOrNull()?.first ?: return
        try {
            fonts.register(
                family,
                regular,
                bold = member(bold = true, italic = false),
                italic = member(bold = false, italic = true),
                boldItalic = member(bold = true, italic = true),
            )
        } catch (_: Exception) {
            // A member that read once and will not now: the family keeps what
            // it was last registered with.
        }
    }

    /** Every imported face currently registered, for the picker to list. */
    @Synchronized
    fun families(): List<String> = registered.values.map { it.family }.toSortedSet().toList()

    /**
     * Registers everything in the fonts folder. Called at launch: a face
     * imported in a previous session has to be registered again before the
     * first page is set, or the book renders in the fallback and the setting
     * looks forgotten.
     */
    fun registerAll(): List<String> =
        importedDirectory?.listFiles()?.filter { it.isFile }?.sortedBy { it.name }?.mapNotNull { register(it) }.orEmpty()

    /** What a font file says about itself: its family, and which member of it the file is. */
    data class Description(val family: String, val bold: Boolean, val italic: Boolean)

    companion object {
        /**
         * Formats Android reads. EPUB permits WOFF and WOFF2, and the
         * platform's font builder reads neither: importing one would appear
         * to work and then render nothing.
         */
        val readableExtensions: Set<String> = setOf("otf", "ttf", "ttc", "otc")

        fun isReadable(name: String): Boolean = name.substringAfterLast('.', "").lowercase() in readableExtensions

        /**
         * The family the app ships under this name, if it ships one — spelled
         * the way the app spells it, whatever case [family] arrived in.
         */
        fun bundledFamily(family: String): String? = IssaFonts.bundledFace(family)?.family

        /**
         * Reads the family name out of the file, rather than trusting its
         * file name: a file called `body.otf` is set under whatever family it
         * declares. The typographic family (name 16) where the file has one,
         * which is what CoreText answers with, then the family (name 1).
         */
        fun familyName(data: ByteArray): String? = describe(data)?.family

        /** The family a file declares and which member of it the file is, or null for a file that is not a font. */
        fun describe(data: ByteArray): Description? = try {
            SfntTables(data).describe()
        } catch (_: IndexOutOfBoundsException) {
            null
        } catch (_: IllegalArgumentException) {
            null
        }

        /** Whether the platform's font builder takes the file. */
        fun isUsable(data: ByteArray): Boolean = try {
            val buffer = ByteBuffer.allocateDirect(data.size).order(ByteOrder.nativeOrder())
            buffer.put(data).flip()
            android.graphics.fonts.Font.Builder(buffer).build()
            true
        } catch (_: Exception) {
            false
        }
    }
}

/**
 * The tables of an OpenType or TrueType file, or of the first face of a
 * collection, as the loader takes it: just enough to say what family a file
 * declares and which member of that family it is.
 */
private class SfntTables(private val data: ByteArray) {
    private val buffer: ByteBuffer = ByteBuffer.wrap(data).order(ByteOrder.BIG_ENDIAN)

    private fun u16(at: Int): Int = buffer.getShort(at).toInt() and 0xFFFF
    private fun u32(at: Int): Long = buffer.getInt(at).toLong() and 0xFFFFFFFFL

    /**
     * The family, and whether this file is its bold or its italic: from
     * `OS/2`'s selection flags and weight where the file has that table, from
     * `head`'s style bits where it does not.
     */
    fun describe(): CustomFonts.Description? {
        var face = 0
        if (u32(0) == TTCF) face = u32(12).toInt()
        val version = u32(face)
        if (version != TRUE_TYPE && version != OPEN_TYPE && version != APPLE_TRUE) return null
        val tables = HashMap<Long, Pair<Int, Int>>()
        for (index in 0 until u16(face + 4)) {
            val record = face + 12 + 16 * index
            tables[u32(record)] = u32(record + 8).toInt() to u32(record + 12).toInt()
        }
        val family = family(tables[NAME]?.first ?: return null) ?: return null
        var bold = false
        var italic = false
        val os2 = tables[OS2]
        val head = tables[HEAD]
        if (os2 != null && os2.second >= 64) {
            val selection = u16(os2.first + 62)
            italic = selection and 0x1 != 0
            bold = selection and 0x20 != 0 || u16(os2.first + 4) >= 600
        } else if (head != null) {
            val style = u16(head.first + 44)
            bold = style and 0x1 != 0
            italic = style and 0x2 != 0
        }
        return CustomFonts.Description(family, bold, italic)
    }

    /** The typographic family (name 16), else the family (name 1): Windows English first, then any Windows or Unicode entry, then a Macintosh Roman one. */
    private fun family(nameTable: Int): String? {
        val count = u16(nameTable + 2)
        val strings = nameTable + u16(nameTable + 4)
        class Found(val name: String, val rank: Int)
        var best: Found? = null
        for (nameId in listOf(16, 1)) {
            for (index in 0 until count) {
                val record = nameTable + 6 + 12 * index
                if (u16(record + 6) != nameId) continue
                val platform = u16(record)
                val language = u16(record + 4)
                val length = u16(record + 8)
                val offset = strings + u16(record + 10)
                val rank = when {
                    platform == 3 && language == 0x409 -> 0
                    platform == 3 -> 1
                    platform == 0 -> 2
                    platform == 1 && language == 0 -> 3
                    else -> continue
                }
                val bytes = data.copyOfRange(offset, offset + length)
                val name = when (platform) {
                    1 -> String(bytes, Charsets.ISO_8859_1)
                    else -> String(bytes, Charsets.UTF_16BE)
                }.trim()
                if (name.isEmpty()) continue
                if (best == null || rank < best.rank) best = Found(name, rank)
            }
            best?.let { return it.name }
        }
        return null
    }

    private companion object {
        const val TTCF = 0x74746366L
        const val TRUE_TYPE = 0x00010000L
        const val OPEN_TYPE = 0x4F54544FL
        const val APPLE_TRUE = 0x74727565L
        const val NAME = 0x6E616D65L
        const val OS2 = 0x4F532F32L
        const val HEAD = 0x68656164L
    }
}

/**
 * Copying a picked font into the fonts folder and registering it. The Swift
 * client's `FontImport`, with the two view helpers its tests reach —
 * `TypographyControls.listedCustomFamilies` and
 * `BookTypographyView.importedTypeface` — kept beside it.
 *
 * One for the app ([com.benjaminissa.issareader.app.AppGraph.fontImport]),
 * because the two screens that import — Settings and a book's own sheet —
 * share the controls that say what the last import could not do. The screens
 * reach it through their environment: Settings through `AppEnvironment`, the
 * reader through `ReaderEnvironment`.
 */
class FontImport(
    val customFonts: CustomFonts,
    private val contentResolver: ContentResolver?,
) {
    /** What the last import could not do, for the controls to say under "Add a font…". */
    class Notice {
        var message: String? by mutableStateOf(null)
            internal set

        fun clear() {
            message = null
        }
    }

    val notice = Notice()

    /**
     * Copies a picked file into the fonts folder and registers it, returning
     * the family to choose, or null with [notice] saying why.
     *
     * Copied rather than referenced: the picked Uri is a grant from another
     * app's provider, and it is not there on the next launch — a face that
     * vanished would leave the book set in a font the picker still listed.
     */
    fun adopt(picked: Uri): String? {
        notice.clear()
        val name = displayName(picked)
        val bytes = read(picked) ?: return refuse(safeName(name), "That file couldn't be opened.", "copy failed")
        return adopt(name, bytes)
    }

    /**
     * The import itself, once the picked file has been read: its name, as the
     * provider gave it, and its bytes.
     *
     * A failure is said, in [notice], and logged: the picker closing with
     * nothing changed looked exactly like an import that worked and had not
     * refreshed.
     */
    fun adopt(fileName: String, bytes: ByteArray): String? {
        notice.clear()
        val name = safeName(fileName)
        val directory = customFonts.importedDirectory
            ?: return refuse(name, "That font couldn't be saved on this device.", "no font directory")
        val destination = destination(name, bytes, directory)
        val existedBefore = destination.exists()
        if (!existedBefore) {
            try {
                destination.writeBytes(bytes)
            } catch (_: Exception) {
                destination.delete()
                return refuse(name, "That file couldn't be opened.", "copy failed")
            }
        }
        val family = customFonts.register(destination)
        if (family == null) {
            // A file the platform rejects must not stay behind: `registerAll`
            // would retry it — and fail again — at every launch. Only the copy
            // this import just made is removed.
            if (!existedBefore) destination.delete()
            return refuse(name, unreadableSentence(name), "not a readable font")
        }
        // A copy of a family the app ships did nothing but sit in the folder,
        // never listed under "Your fonts" and so with no way to remove it. It
        // goes now; the bundled row is chosen.
        if (CustomFonts.bundledFamily(family) != null) destination.delete()
        return family
    }

    /**
     * The typeface a book's own sheet sets for a picked file: the app's own
     * row when the file was a copy of a family it ships, or null when it was
     * refused. `BookTypographyView.importedTypeface`.
     *
     * Resolved the way the reading settings resolve it: a file of a family the
     * app ships was once set here as a custom face — the book set in the app's
     * own face under no row of the picker, listed as a face of the reader's
     * that is not theirs.
     */
    fun importedTypeface(picked: Uri): ReaderStyle.Typeface? = adopt(picked)?.let(::typeface)

    /** [importedTypeface], once the picked file has been read. */
    fun importedTypeface(fileName: String, bytes: ByteArray): ReaderStyle.Typeface? = adopt(fileName, bytes)?.let(::typeface)

    private fun refuse(name: String, sentence: String, reason: String): String? {
        IssaLog.warning(
            "font import refused",
            mapOf("reason" to reason, "extension" to name.substringAfterLast('.', "").lowercase()),
        )
        notice.message = sentence
        return null
    }

    private fun displayName(picked: Uri): String {
        if (picked.scheme == ContentResolver.SCHEME_FILE) return picked.lastPathSegment ?: "font"
        val resolver = contentResolver ?: return picked.lastPathSegment ?: "font"
        return try {
            resolver.query(picked, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (cursor.moveToFirst() && column >= 0 && !cursor.isNull(column)) cursor.getString(column) else null
            }
        } catch (_: Exception) {
            null
        } ?: picked.lastPathSegment ?: "font"
    }

    private fun read(picked: Uri): ByteArray? = try {
        if (picked.scheme == ContentResolver.SCHEME_FILE) {
            File(checkNotNull(picked.path)).readBytes()
        } else {
            contentResolver?.openInputStream(picked)?.use { it.readBytes() }
        }
    } catch (_: Exception) {
        null
    }

    /**
     * Where the picked file should land, without trusting its name: a second,
     * different file that happens to share a name gets a numbered name of its
     * own, and identical bytes reuse the existing copy.
     */
    private fun destination(name: String, bytes: ByteArray, directory: File): File {
        val extension = name.substringAfterLast('.', "")
        val base = if (extension.isEmpty()) name else name.dropLast(extension.length + 1)
        var candidate = File(directory, name)
        var counter = 2
        while (candidate.exists() && !sameBytes(candidate, bytes)) {
            candidate = File(directory, if (extension.isEmpty()) "$base-$counter" else "$base-$counter.$extension")
            counter += 1
        }
        return candidate
    }

    private fun sameBytes(file: File, bytes: ByteArray): Boolean =
        file.length() == bytes.size.toLong() && runCatching { file.readBytes().contentEquals(bytes) }.getOrDefault(false)

    companion object {
        /**
         * What the system picker is asked for. Font files arrive under several
         * types depending on the provider, and many as plain bytes; WOFF is not
         * offered, and one picked anyway is told which format to look for.
         */
        val contentTypes: Array<String> = arrayOf(
            "font/ttf", "font/otf", "font/sfnt", "font/collection",
            "application/x-font-ttf", "application/x-font-otf", "application/font-sfnt",
            "application/vnd.ms-opentype", "application/octet-stream",
        )

        /** The typeface to choose for a family an import answered with. */
        fun typeface(family: String): ReaderStyle.Typeface =
            CustomFonts.bundledFamily(family)?.let { ReaderStyle.Typeface.Bundled(it) } ?: ReaderStyle.Typeface.Custom(family)

        /** What to say about a file the platform would not take. */
        fun unreadableSentence(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
            "woff", "woff2" -> "WOFF fonts can't be used on this device. Try the OTF or TTF version of the font."
            else -> "That file isn't a font this device can read."
        }

        /**
         * Imported faces less any family the app ships: a copy of Literata
         * registers as Literata, and listing it again under "Your fonts"
         * offered one face twice. `TypographyControls.listedCustomFamilies`.
         */
        fun listedCustomFamilies(families: List<String>): List<String> = families.filter { CustomFonts.bundledFamily(it) == null }

        /** A picked file's name as a single path component, never a way out of the fonts folder. */
        private fun safeName(name: String): String {
            val last = name.substringAfterLast('/').substringAfterLast('\\').trim()
            return if (last.isEmpty() || last == "." || last == "..") "font" else last
        }
    }
}
