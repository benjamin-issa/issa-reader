package com.benjaminissa.issareader.app.ui.reader

import android.content.Context
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
import java.util.Collections
import java.util.WeakHashMap

/**
 * Faces the app did not ship that the reader imported: the Swift client's
 * `CustomFonts`, over [ReaderFonts].
 *
 * The page renderer registers a family from its files; this keeps which file
 * is which member of which family, so that importing a family's bold after
 * its regular gives the family a bold rather than replacing it. Faces found
 * inside a book are the renderer's own business (`registerPublisherFace`) and
 * never reach the picker — a book's face chosen as one of the reader's would
 * be a promise the next book could not keep.
 *
 * Main-thread only, as the reader's sheets that call it are.
 */
object CustomFonts {
    /**
     * Formats Android's font loader actually reads. EPUB 3 permits WOFF and
     * WOFF2, and a book or a download that ships only those has no usable
     * font, which the reader should be told rather than left wondering why
     * the setting did nothing.
     */
    val readableExtensions: Set<String> = setOf("otf", "ttf", "ttc", "otc")

    fun isReadable(file: File): Boolean = file.extension.lowercase() in readableExtensions

    private data class Member(val family: String, val bold: Boolean, val italic: Boolean)

    /** File → the family and member it registered as. */
    private val registered = LinkedHashMap<File, Member>()

    /** The subset of [registered] the reader imported themselves, which is what the picker lists. */
    private val imported = LinkedHashSet<File>()

    /** The renderers that have been handed every imported face already. */
    private val loaded: MutableSet<ReaderFonts> = Collections.newSetFromMap(WeakHashMap())

    /**
     * Registers a font file and returns the family name to ask for.
     *
     * Idempotent per file. Returns `null` for a format that cannot be read, or
     * a file the font loader rejects — callers fall back to the chosen face
     * rather than rendering nothing. A copy of a family the app already ships
     * is answered with the bundled family and not registered: registered
     * beside the bundled files, the copy would become what that family name
     * means for every other book.
     */
    fun register(file: File, fonts: ReaderFonts, imported: Boolean = false): String? {
        registered[file]?.let { known ->
            if (imported) this.imported.add(file)
            if (!fonts.hasFamily(known.family)) install(known.family, fonts)
            return known.family
        }
        if (!isReadable(file)) return null
        val bytes = runCatching { file.readBytes() }.getOrNull() ?: return null
        val description = FontNames.describe(bytes) ?: return null
        bundledFamily(description.family)?.let { return it }
        if (!FontNames.loads(bytes)) return null
        registered[file] = Member(description.family, description.bold, description.italic)
        if (imported) this.imported.add(file)
        install(description.family, fonts)
        return description.family
    }

    /** Hands a family's every member to the renderer, the upright regular first in line. */
    private fun install(family: String, fonts: ReaderFonts) {
        val members = registered.filter { it.value.family == family && it.key.exists() }
        fun member(bold: Boolean, italic: Boolean) = members.entries.firstOrNull { it.value.bold == bold && it.value.italic == italic }?.key
        val regular = member(bold = false, italic = false) ?: members.keys.firstOrNull() ?: return
        runCatching {
            fonts.register(
                family, regular,
                bold = member(bold = true, italic = false),
                italic = member(bold = false, italic = true),
                boldItalic = member(bold = true, italic = true),
            )
        }
    }

    /**
     * The family the app ships under this name, if it ships one — spelled the
     * way the app spells it, whatever case [family] arrived in. The picker
     * must not offer one of these under "Your fonts".
     */
    fun bundledFamily(matching: String): String? = IssaFonts.bundledFace(matching)?.family

    /** Every imported face currently registered, for the picker to list. */
    fun families(): List<String> = imported.mapNotNull { registered[it]?.family }.toSortedSet().toList()

    /** Registers everything at the root of the fonts directory, which [FontImport.adopt] put there. */
    fun registerAll(directory: File, fonts: ReaderFonts): List<String> =
        directory.listFiles().orEmpty().filter { it.isFile }.sortedBy { it.name }.mapNotNull { register(it, fonts, imported = true) }

    /**
     * Makes every imported face available to [fonts], once: a face imported
     * in an earlier session has to be registered again before the first page
     * is set, or the book renders in the fallback and the setting looks
     * forgotten.
     */
    fun ensureLoaded(fonts: ReaderFonts) {
        if (!loaded.add(fonts)) return
        importedDirectory?.let { registerAll(it, fonts) }
    }

    /**
     * Imported faces live here; the reader chose them. The root only: a
     * subdirectory would be a book's, never the reader's.
     */
    val importedDirectory: File?
        get() {
            val directory = StorageRoot.directory("Fonts")
            if (!directory.isDirectory && !directory.mkdirs()) return null
            return directory
        }

    /** Forgets every registration, for a test that starts from nothing. */
    internal fun resetForTesting() {
        registered.clear()
        imported.clear()
        loaded.clear()
    }
}

/** What a picked font file can do, said under "Add a font…" when it cannot. */
object FontImport {
    /**
     * What the document picker offers. `font/…` where the provider knows the
     * type; the octet stream because many providers do not, and the file is
     * read to decide either way.
     */
    val mimeTypes: Array<String> = arrayOf(
        "font/ttf", "font/otf", "font/collection", "font/sfnt",
        "application/x-font-ttf", "application/x-font-otf", "application/font-sfnt",
        "application/vnd.ms-opentype", "application/octet-stream",
    )

    /** What the last import could not do. One for the app: Settings and a book's sheet share the controls that say it. */
    val notice = Notice()

    class Notice {
        var message: String? by mutableStateOf(null)
            internal set

        fun clear() {
            message = null
        }
    }

    /**
     * Copies a picked document into the app's font directory and registers it.
     *
     * Copied rather than referenced: a document grant is a loan from another
     * app, and it is not there on the next launch — a face that vanished
     * would leave the book set in a font the picker still listed.
     */
    fun adopt(context: Context, uri: Uri, fonts: ReaderFonts): String? {
        notice.clear()
        val name = runCatching {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        }.getOrNull() ?: uri.lastPathSegment?.substringAfterLast('/') ?: "Font"
        val bytes = runCatching { context.contentResolver.openInputStream(uri)?.use { it.readBytes() } }.getOrNull()
            ?: return refuse(name, "That file couldn't be opened.", "copy failed")
        return adopt(name, bytes, fonts)
    }

    /**
     * The import itself, given the file's name and bytes.
     *
     * A failure is said, in [notice], and logged: the picker closing with
     * nothing changed looked exactly like an import that worked and had not
     * refreshed.
     */
    fun adopt(fileName: String, bytes: ByteArray, fonts: ReaderFonts): String? {
        notice.clear()
        val directory = CustomFonts.importedDirectory
            ?: return refuse(fileName, "That font couldn't be saved on this device.", "no font directory")
        val destination = destinationFor(fileName, bytes, directory)
        val existedBefore = destination.exists()
        if (!existedBefore) {
            runCatching { destination.writeBytes(bytes) }.onFailure {
                return refuse(fileName, "That file couldn't be opened.", "copy failed")
            }
        }
        val family = CustomFonts.register(destination, fonts, imported = true)
        if (family == null) {
            // A file the loader rejects must not stay behind: the launch-time
            // registration would retry it — and fail again — every time. Only
            // the copy this import just made is removed.
            if (!existedBefore) destination.delete()
            return refuse(fileName, unreadableSentence(fileName), "not a readable font")
        }
        // A copy of a family the app ships is answered with the app's own and
        // never registered, so the copy would only sit in the fonts folder,
        // never listed and so never removable. It goes now.
        if (CustomFonts.bundledFamily(family) != null) destination.delete()
        return family
    }

    /** The typeface to choose for a family an import answered with: the app's own row when the file was a copy of one it ships. */
    fun typeface(family: String): ReaderStyle.Typeface =
        CustomFonts.bundledFamily(family)?.let { ReaderStyle.Typeface.Bundled(it) } ?: ReaderStyle.Typeface.Custom(family)

    /** What to say about a file the loader would not take. */
    fun unreadableSentence(fileName: String): String = when (fileName.substringAfterLast('.', "").lowercase()) {
        "woff", "woff2" -> "WOFF fonts can't be used on this device. Try the OTF or TTF version of the font."
        else -> "That file isn't a font this device can read."
    }

    private fun refuse(fileName: String, sentence: String, reason: String): String? {
        IssaLog.warning(
            "font import refused",
            mapOf("reason" to reason, "extension" to fileName.substringAfterLast('.', "").lowercase()),
        )
        notice.message = sentence
        return null
    }

    /**
     * Where the picked file should land, without trusting its name: identical
     * bytes reuse the existing copy, so importing the same font again stays
     * idempotent, and different bytes under the same name get a numbered name
     * of their own rather than silently becoming the face already on disk.
     */
    private fun destinationFor(fileName: String, bytes: ByteArray, directory: File): File {
        val safe = fileName.replace('/', '_').replace('\\', '_').ifEmpty { "Font" }
        val base = safe.substringBeforeLast('.', safe)
        val ext = safe.substringAfterLast('.', "")
        var candidate = File(directory, safe)
        var counter = 2
        while (candidate.exists() && !candidate.readBytes().contentEquals(bytes)) {
            candidate = File(directory, if (ext.isEmpty()) "$base-$counter" else "$base-$counter.$ext")
            counter += 1
        }
        return candidate
    }
}

/**
 * What a font file says about itself: its family, and which member it is.
 *
 * Read from the file's own tables rather than its name — a file called
 * `body.otf` registers under whatever family it declares. The typographic
 * family (name 16) where the file has one, so a family shipped as several
 * weights is one family; the legacy family (name 1) otherwise.
 */
internal object FontNames {
    data class Description(val family: String, val bold: Boolean, val italic: Boolean)

    fun describe(bytes: ByteArray): Description? = runCatching { parse(bytes) }.getOrNull()

    /** Whether Android's font loader builds a face from the bytes at all. */
    fun loads(bytes: ByteArray): Boolean = runCatching {
        val buffer = ByteBuffer.allocateDirect(bytes.size).apply {
            put(bytes)
            flip()
        }
        android.graphics.fonts.Font.Builder(buffer).build()
        true
    }.getOrDefault(false)

    private fun parse(bytes: ByteArray): Description? {
        val data = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
        var font = 0
        if (tag(data, 0) == "ttcf") {
            // A collection: the first face in it, as the loader takes it.
            if (data.getInt(8) < 1) return null
            font = data.getInt(12)
        }
        val version = data.getInt(font)
        if (version != 0x00010000 && tag(data, font) != "OTTO" && tag(data, font) != "true") return null
        val tables = HashMap<String, Pair<Int, Int>>()
        val count = data.getShort(font + 4).toInt() and 0xFFFF
        for (i in 0 until count) {
            val record = font + 12 + i * 16
            tables[tag(data, record)] = data.getInt(record + 8) to data.getInt(record + 12)
        }
        val (nameOffset, _) = tables["name"] ?: return null
        val family = name(data, nameOffset, 16) ?: name(data, nameOffset, 1) ?: return null
        var bold = false
        var italic = false
        tables["OS/2"]?.let { (offset, length) ->
            if (length >= 64) {
                val selection = data.getShort(offset + 62).toInt() and 0xFFFF
                italic = selection and 0x1 != 0
                bold = selection and 0x20 != 0
                val weight = data.getShort(offset + 4).toInt() and 0xFFFF
                if (weight >= 600) bold = true
            }
        } ?: tables["head"]?.let { (offset, _) ->
            val style = data.getShort(offset + 44).toInt() and 0xFFFF
            bold = style and 0x1 != 0
            italic = style and 0x2 != 0
        }
        return Description(family.trim().ifEmpty { return null }, bold, italic)
    }

    private fun tag(data: ByteBuffer, at: Int): String =
        String(ByteArray(4) { data.get(at + it) }, Charsets.ISO_8859_1)

    /**
     * One name, by id: Windows English first, then any Windows or Unicode
     * entry (UTF-16), then a Macintosh Roman one.
     */
    private fun name(data: ByteBuffer, table: Int, id: Int): String? {
        val count = data.getShort(table + 2).toInt() and 0xFFFF
        val strings = table + (data.getShort(table + 4).toInt() and 0xFFFF)
        data class Entry(val platform: Int, val language: Int, val text: String)
        val found = ArrayList<Entry>()
        for (i in 0 until count) {
            val record = table + 6 + i * 12
            val platform = data.getShort(record).toInt() and 0xFFFF
            val language = data.getShort(record + 4).toInt() and 0xFFFF
            val nameId = data.getShort(record + 6).toInt() and 0xFFFF
            if (nameId != id) continue
            val length = data.getShort(record + 8).toInt() and 0xFFFF
            val offset = data.getShort(record + 10).toInt() and 0xFFFF
            val raw = ByteArray(length) { data.get(strings + offset + it) }
            val text = when (platform) {
                0, 3 -> String(raw, Charsets.UTF_16BE)
                1 -> String(raw, Charsets.ISO_8859_1)
                else -> continue
            }
            if (text.isNotBlank()) found.add(Entry(platform, language, text))
        }
        return (
            found.firstOrNull { it.platform == 3 && it.language == 0x0409 }
                ?: found.firstOrNull { it.platform == 3 || it.platform == 0 }
                ?: found.firstOrNull()
            )?.text
    }
}
