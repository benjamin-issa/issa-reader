package com.benjaminissa.issareader.render.android

import android.content.Context
import android.graphics.Typeface
import android.graphics.fonts.Font
import android.graphics.fonts.FontFamily
import android.graphics.fonts.FontStyle
import com.benjaminissa.issareader.epub.EpubFontResolver
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.ui.BundledFace
import com.benjaminissa.issareader.ui.IssaFonts
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.roundToInt

/**
 * One face the page is set in: a real member of a family, never a synthesised
 * one.
 *
 * [isItalic] and [isBold] say what the *file* is, not what was asked for: a
 * Lexend book's emphasis asks for italic and gets the upright, because Lexend
 * ships no italic and a faked oblique in a reading face looks visibly wrong.
 */
data class ResolvedFace(
    /** The family it belongs to, or `null` for the system fallback. */
    val family: String?,
    /** Which member — `Literata-BoldItalic`, `Newsreader[wght 700, opsz 18]` — for telling two faces apart. */
    val member: String,
    val isBold: Boolean,
    val isItalic: Boolean,
    val typeface: Typeface,
)

/**
 * The faces a page can be set in: the six the app ships (`:ui`'s
 * [IssaFonts]), the book's own (the publisher's), and any the reader imported.
 * The Swift client's `ReaderStyle.bodyFont` and the `withItalicTrait` /
 * `withBoldTrait` it layers on, over Android fonts.
 *
 * Families are looked up by the names `ReaderStyle` persists — "Literata",
 * "Source Serif 4", "Public Sans" — which are the Swift client's names too, so
 * a typeface chosen on one device is the same face on the other.
 *
 * Built straight from the files with `android.graphics.fonts.Font`, one member
 * per file, so a family's bold *is* its bold file and nothing is synthesised.
 * Variable files are given their axes explicitly: Public Sans's variable file
 * *defaults to Thin*, so a face loaded without a `wght` setting renders
 * hairline-thin; and Newsreader's optical size follows the point size, as
 * CoreText's automatic optical sizing does on the Swift side.
 *
 * Thread-safe; typefaces are cached by member and axes, which is safe for the
 * life of the process because a registered file never changes. The cache that
 * matters for correctness — one parse's faces not reaching the next — is
 * [SpanBuilder]'s, as the Swift parser's `FontCache` is.
 */
class ReaderFonts(private val context: Context) {
    private class Member(
        val name: String,
        val bytes: ByteBuffer,
        val variable: Boolean,
        val italic: Boolean,
        val bold: Boolean,
    )

    private class Family(
        val name: String,
        val regular: Member,
        val bold: Member?,
        val italic: Member?,
        val boldItalic: Member?,
        /** Whether the variable files carry an `opsz` axis that should follow the size. */
        val opticalSize: Boolean,
    )

    private val families = ConcurrentHashMap<String, Family>()
    private val typefaces = ConcurrentHashMap<String, Typeface>()

    /** Whether a family is available under this name, bundled or registered. */
    fun hasFamily(family: String): Boolean = family(family) != null

    /**
     * The upright, regular member of a family, or `null` when nothing is
     * available under that name.
     */
    fun upright(family: String, pointSize: Double): ResolvedFace? {
        val found = family(family) ?: return null
        return resolved(found, found.regular, pointSize)
    }

    /**
     * The italic member of [face]'s family where it has one, otherwise
     * [face] itself. Never synthesises an oblique.
     */
    fun withItalic(face: ResolvedFace, pointSize: Double): ResolvedFace {
        val found = face.family?.let(::family) ?: return systemFace(face.isBold, italic = true, pointSize)
        if (face.isItalic) return face
        val member = (if (face.isBold) found.boldItalic else found.italic) ?: return face
        return resolved(found, member, pointSize) ?: face
    }

    /**
     * The bold member, keeping an italic italic. The Swift client's AppKit
     * path once *replaced* the traits rather than adding to them, so
     * `<strong><em>` came out bold upright on the Mac; here bold layered on
     * italic asks for the bold italic, and settles for the italic it has.
     */
    fun withBold(face: ResolvedFace, pointSize: Double): ResolvedFace {
        val found = face.family?.let(::family) ?: return systemFace(bold = true, italic = face.isItalic, pointSize)
        if (face.isBold) return face
        val member = (if (face.isItalic) found.boldItalic else found.bold) ?: return face
        return resolved(found, member, pointSize) ?: face
    }

    /**
     * The body face: the chosen family, then the app's own, then the
     * system's, so a book that ships no usable font is still set in
     * something deliberate — falling straight through to the system face
     * changes the look of the page for a setting the reader did not touch.
     */
    fun bodyFace(style: ReaderStyle, italic: Boolean, bold: Boolean, scale: Double): ResolvedFace {
        val pointSize = style.fontSize * scale
        for (name in listOfNotNull(style.resolvedFamily, ReaderStyle.DEFAULT_FAMILY)) {
            var face = upright(name, pointSize) ?: continue
            if (italic) face = withItalic(face, pointSize)
            if (bold) face = withBold(face, pointSize)
            return face
        }
        return systemFace(bold, italic, pointSize)
    }

    /**
     * Registers a family from its members' files — a face the reader imported,
     * or anything else that arrives as bytes. The upright regular is required;
     * a family without one is not a family a page can be set in.
     */
    fun register(family: String, regular: ByteArray, bold: ByteArray? = null, italic: ByteArray? = null, boldItalic: ByteArray? = null) {
        fun member(bytes: ByteArray, suffix: String, isItalic: Boolean, isBold: Boolean) =
            Member("$family-$suffix", direct(bytes), variable = false, italic = isItalic, bold = isBold)
        families[family.lowercase()] = Family(
            name = family,
            regular = member(regular, "Regular", isItalic = false, isBold = false),
            bold = bold?.let { member(it, "Bold", isItalic = false, isBold = true) },
            italic = italic?.let { member(it, "Italic", isItalic = true, isBold = false) },
            boldItalic = boldItalic?.let { member(it, "BoldItalic", isItalic = true, isBold = true) },
            opticalSize = false,
        )
    }

    /** [register], from files on disk. */
    fun register(family: String, regular: File, bold: File? = null, italic: File? = null, boldItalic: File? = null) =
        register(family, regular.readBytes(), bold?.readBytes(), italic?.readBytes(), boldItalic?.readBytes())

    /**
     * Registers the face the book asks for its running text, every member of
     * it — which is what makes a word in italic look italic: a family
     * registered with only its upright member is a book with no emphasis in
     * it, and one registered with only its italic member is a book entirely in
     * italic. Returns the family to put in `ReaderStyle.publisherFamily`, or
     * `null` when the book ships nothing usable.
     */
    fun registerPublisherFace(book: EpubPackage): String? {
        val found = EpubFontResolver.resolve(book) as? EpubFontResolver.Resolution.Found ?: return null
        val family = found.face.family
        val members = EpubFontResolver.members(family, book)
        fun read(face: EpubFontResolver.Face?): ByteArray? = face?.let {
            try {
                book.archive.read(it.path)
            } catch (_: Exception) {
                null
            }
        }
        val regular = read(members.firstOrNull { !it.isItalic && !it.isBold } ?: found.face) ?: return null
        register(
            family,
            regular = regular,
            bold = read(members.firstOrNull { it.isBold && !it.isItalic }),
            italic = read(members.firstOrNull { it.isItalic && !it.isBold }),
            boldItalic = read(members.firstOrNull { it.isItalic && it.isBold }),
        )
        return if (upright(family, 18.0) != null) family else null
    }

    private fun family(name: String): Family? {
        families[name.lowercase()]?.let { return it }
        val bundled = IssaFonts.bundledFace(name) ?: return null
        val loaded = bundledFamily(bundled) ?: return null
        return families.putIfAbsent(name.lowercase(), loaded) ?: loaded
    }

    /** One of the app's own faces, read from `:ui`'s font resources. */
    private fun bundledFamily(face: BundledFace): Family? {
        fun bytes(resource: Int): ByteBuffer? = try {
            context.resources.openRawResource(resource).use { direct(it.readBytes()) }
        } catch (_: Exception) {
            null
        }
        val stem = face.family.replace(" ", "")
        return if (face.variable) {
            val upright = bytes(face.regular) ?: return null
            val italic = face.italic?.let(::bytes)
            Family(
                name = face.family,
                regular = Member("$stem-Regular", upright, variable = true, italic = false, bold = false),
                bold = Member("$stem-Bold", upright, variable = true, italic = false, bold = true),
                italic = italic?.let { Member("$stem-Italic", it, variable = true, italic = true, bold = false) },
                boldItalic = italic?.let { Member("$stem-BoldItalic", it, variable = true, italic = true, bold = true) },
                opticalSize = face.family in opticalSizeFamilies,
            )
        } else {
            Family(
                name = face.family,
                regular = Member("$stem-Regular", bytes(face.regular) ?: return null, variable = false, italic = false, bold = false),
                bold = bytes(face.bold)?.let { Member("$stem-Bold", it, variable = false, italic = false, bold = true) },
                italic = face.italic?.let(::bytes)?.let { Member("$stem-Italic", it, variable = false, italic = true, bold = false) },
                boldItalic = face.boldItalic?.let(::bytes)?.let { Member("$stem-BoldItalic", it, variable = false, italic = true, bold = true) },
                opticalSize = false,
            )
        }
    }

    private fun resolved(family: Family, member: Member, pointSize: Double): ResolvedFace? {
        val weight = if (member.bold) 700 else 400
        val opsz = if (member.variable && family.opticalSize) pointSize.coerceIn(6.0, 72.0).roundToInt() else null
        val axes = if (member.variable) {
            listOfNotNull("'wght' $weight", opsz?.let { "'opsz' $it" }).joinToString(", ")
        } else {
            null
        }
        val key = member.name + (axes?.let { "[$it]" } ?: "")
        val typeface = typefaces[key] ?: build(member, weight, axes)?.also { typefaces.putIfAbsent(key, it) } ?: return null
        return ResolvedFace(family.name, key, isBold = member.bold, isItalic = member.italic, typeface = typeface)
    }

    private fun build(member: Member, weight: Int, axes: String?): Typeface? = try {
        val slant = if (member.italic) FontStyle.FONT_SLANT_ITALIC else FontStyle.FONT_SLANT_UPRIGHT
        val builder = Font.Builder(member.bytes.duplicate()).setWeight(weight).setSlant(slant)
        if (axes != null) builder.setFontVariationSettings(axes)
        val font = builder.build()
        Typeface.CustomFallbackBuilder(FontFamily.Builder(font).build())
            .setStyle(FontStyle(weight, slant))
            // Glyphs the face lacks — a Hebrew word in an English novel —
            // come from the system's serif rather than from nowhere.
            .setSystemFallback("serif")
            .build()
    } catch (_: Exception) {
        null
    }

    /** The system's own face, the last resort, at the weight and slant asked for. */
    private fun systemFace(bold: Boolean, italic: Boolean, pointSize: Double): ResolvedFace {
        val typeface = Typeface.create(Typeface.DEFAULT, if (bold) 700 else 400, italic)
        return ResolvedFace(null, "system[${if (bold) 700 else 400}${if (italic) " italic" else ""}]", bold, italic, typeface)
    }

    private companion object {
        /** The bundled variable faces with an optical-size axis. */
        val opticalSizeFamilies = setOf("Newsreader")

        fun direct(bytes: ByteArray): ByteBuffer = ByteBuffer.allocateDirect(bytes.size).apply {
            put(bytes)
            flip()
        }
    }
}
