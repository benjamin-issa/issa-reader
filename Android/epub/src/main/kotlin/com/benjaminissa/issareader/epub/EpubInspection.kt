package com.benjaminissa.issareader.epub

import com.benjaminissa.issareader.core.model.removingPercentEncoding
import java.io.File
import java.io.IOException

/**
 * What a file the reader chose turns out to be, before it is added.
 *
 * The checks a book from the reader's own files has to pass that a server's
 * never did: that it is an EPUB at all, that it is not locked by a shop's DRM,
 * that it has a chapter to read — and what it is, for the list and for Book
 * info: its version, its layout, its narration and its cover.
 *
 * Everything is read from the central directory and the package document;
 * nothing is extracted. The one thing not decided here is whether the
 * narration's audio will *play*, which is the media player's to say and this
 * module does not link it — [audioFiles] carries what the caller needs to ask.
 */
class EpubInspection internal constructor(
    /** The opened package. (`package` in Swift, which Kotlin reserves.) */
    val epubPackage: EpubPackage,
    /**
     * Fixed pages: `rendition:layout`, the older `fixed-layout` meta, or
     * Apple's display options.
     */
    val isFixedLayout: Boolean,
    /** The narration, empty when the book has none. */
    val timeline: SmilTimeline,
    /** Every distinct file the narration plays, in the order they first play. */
    val audioFiles: List<AudioFile>,
) {
    /** Why a file cannot be added. */
    sealed class Problem(message: String) : Exception(message) {
        /**
         * Not a ZIP, or a ZIP with no `META-INF/container.xml` naming a
         * package: not an EPUB at all.
         */
        data object NotAnEpub : Problem("not an EPUB")

        /** An EPUB whose package will not parse, or with no chapter that can be read. */
        data class Damaged(val reason: String) : Problem(reason)

        /** Locked by a shop's DRM. */
        data class Protected(val protection: Protection) : Problem("protected by ${protection.rawValue}")
    }

    /** Whose lock a protected book carries, as far as the archive says. */
    enum class Protection(val rawValue: String) {
        /**
         * `META-INF/rights.xml`: Adobe ADEPT, which Adobe Digital Editions, Kobo
         * and most library loans use.
         */
        ADOBE("adobe"),

        /** A Readium LCP licence. */
        LCP("lcp"),

        /** `META-INF/sinf.xml`: Apple Books' FairPlay. */
        FAIR_PLAY("fairPlay"),

        /**
         * An `encryption.xml` that encrypts something other than a font, or by
         * an algorithm that is not font obfuscation.
         */
        UNKNOWN("unknown"),
    }

    /** One audio file the narration plays. */
    data class AudioFile(
        val href: String,
        /** As the manifest declares it, or null when no manifest item names the file. */
        val mediaType: String?,
        /**
         * What it takes once extracted, from the central directory: up to
         * [EpubArchive.maximumExtractedSize], which is what extraction streams,
         * not `read`'s in-memory cap. Null when the directory claims a size the
         * entry could not have.
         */
        val byteCount: Long?,
        /** Whether the archive holds it at all. */
        val isPresent: Boolean,
    )

    /** The package version: "2.0", "3.0". */
    val version: String? get() = epubPackage.metadata.version
    val isEpub2: Boolean get() = epubPackage.metadata.isEpub2

    /** The archive path of the cover image, if the book names one. */
    val coverHref: String? get() = epubPackage.coverImageHref

    /**
     * Whether the book carries narration with all of its audio in the archive.
     * Whether that audio plays is the caller's question.
     */
    val hasCompleteNarration: Boolean get() = !timeline.isEmpty && audioFiles.all { it.isPresent }

    /**
     * The bytes narration will take once extracted on first open.
     *
     * Saturating: each size is bounded by the archive, but a sum of them is
     * still arithmetic on values a file chose, and an overflow here is a wrong
     * answer during "Checking the book…".
     */
    val audioByteCount: Long
        get() = audioFiles.fold(0L) { total, file ->
            val size = file.byteCount ?: 0L
            if (total > Long.MAX_VALUE - size) Long.MAX_VALUE else total + size
        }

    companion object {
        /**
         * Inspects the EPUB at `file`.
         *
         * @throws Problem
         */
        fun inspect(file: File): EpubInspection {
            val archive = try {
                EpubArchive(file)
            } catch (_: EpubError) {
                throw Problem.NotAnEpub
            } catch (_: IOException) {
                throw Problem.NotAnEpub
            }
            return inspect(archive)
        }

        /**
         * Inspects an archive already open.
         *
         * @throws Problem
         */
        fun inspect(archive: EpubArchive): EpubInspection {
            // A ZIP without the container document is a ZIP, not an EPUB: a
            // renamed .docx or a zipped folder of pictures.
            if ("META-INF/container.xml" !in archive) throw Problem.NotAnEpub

            // Before the package is parsed. A locked book's package usually
            // reads perfectly well, and a damaged-book message for a book that
            // is simply locked sends the reader looking for a fresh copy that
            // will be locked too.
            protection(archive)?.let { throw Problem.Protected(it) }

            val epubPackage = try {
                EpubPackage.open(archive)
            } catch (error: EpubError) {
                // The container is there but names nothing usable.
                throw Problem.Damaged(error.toString())
            }
            if (!hasReadableSpine(epubPackage)) throw Problem.Damaged("no readable chapter")

            val timeline = SmilParser.timeline(epubPackage)
            val mediaTypes = HashMap<String, String>()
            for (item in epubPackage.manifest.values.sortedBy { it.documentOrder }) {
                mediaTypes.putIfAbsent(item.href, item.mediaType)
            }
            val seen = HashSet<String>()
            val audio = ArrayList<AudioFile>()
            for (entry in timeline.entries) {
                if (!seen.add(entry.audioHref)) continue
                audio.add(
                    AudioFile(
                        href = entry.audioHref,
                        mediaType = mediaTypes[entry.audioHref],
                        byteCount = archive.extractedSizeOf(entry.audioHref),
                        isPresent = entry.audioHref in archive,
                    ),
                )
            }

            return EpubInspection(
                epubPackage = epubPackage,
                isFixedLayout = epubPackage.metadata.isFixedLayout || appleFixedLayout(archive),
                timeline = timeline,
                audioFiles = audio,
            )
        }

        // DRM

        /**
         * The two algorithms that only scramble a font so it cannot be lifted
         * out of the book. A book carrying nothing else in `encryption.xml` is
         * not locked: [EpubFontResolver] reports such a font as unusable and the
         * book reads in the reader's own face.
         */
        internal val fontObfuscation = setOf(
            "http://www.idpf.org/2008/embedding",
            "http://ns.adobe.com/pdf/enc#RC",
        )

        /** Extensions a font has, for telling an obfuscated font from anything else. */
        internal val fontExtensions = setOf("otf", "ttf", "woff", "woff2", "ttc", "otc")

        /**
         * Whose lock the archive carries, or null when it is not locked.
         *
         * The licence files first, because they are unambiguous. Then
         * `encryption.xml`, read the way [EpubFontResolver.obfuscatedPaths]
         * reads it: any encrypted resource that is not a font, or any algorithm
         * that is not font obfuscation, is a lock — whatever the file is called.
         */
        internal fun protection(archive: EpubArchive): Protection? {
            if ("META-INF/license.lcpl" in archive || "license.lcpl" in archive) return Protection.LCP
            if ("META-INF/rights.xml" in archive) return Protection.ADOBE
            if ("META-INF/sinf.xml" in archive) return Protection.FAIR_PLAY

            if ("META-INF/encryption.xml" !in archive) return null
            val root = try {
                EpubXml.parse(archive.read("META-INF/encryption.xml"))
            } catch (_: EpubError) {
                // An encryption document that will not parse says something is
                // encrypted and will not say what. Treating that as unlocked
                // would add a book every chapter of which may be ciphertext.
                return Protection.UNKNOWN
            }
            for (encrypted in root.descendants("EncryptedData")) {
                val algorithm = encrypted.descendants("EncryptionMethod").firstOrNull()?.get("Algorithm") ?: ""
                val target = encrypted.descendants("CipherReference").firstOrNull()?.get("URI")
                    ?.let { EpubArchive.normalize(it.removingPercentEncoding() ?: it) } ?: ""
                val isFont = target.pathExtension.lowercase() in fontExtensions
                if (algorithm !in fontObfuscation || !isFont) {
                    // LCP's own encryption document names its licence in a
                    // `RetrievalMethod`; a book that lost the licence file but
                    // kept that still says whose lock it is.
                    val retrieval = encrypted.descendants("RetrievalMethod").firstOrNull()?.get("URI") ?: ""
                    return if ("license.lcpl" in retrieval) Protection.LCP else Protection.UNKNOWN
                }
            }
            return null
        }

        // Layout and spine

        /**
         * Apple's `com.apple.ibooks.display-options.xml`, which is how a book
         * made for iBooks says it is fixed layout without EPUB 3's property.
         */
        internal fun appleFixedLayout(archive: EpubArchive): Boolean {
            val path = "META-INF/com.apple.ibooks.display-options.xml"
            if (path !in archive) return false
            val root = try {
                EpubXml.parse(archive.read(path))
            } catch (_: EpubError) {
                return false
            }
            return root.descendants("option").any {
                it["name"] == "fixed-layout" && it.trimmedText.lowercase() == "true"
            }
        }

        /**
         * Whether at least one spine item is in the archive and inflates.
         *
         * One is enough: a book with a single corrupt chapter still opens, and
         * the reader says which chapter would not. A spine of nothing but
         * missing or broken entries is a book that would open onto nothing.
         */
        internal fun hasReadableSpine(epubPackage: EpubPackage): Boolean = epubPackage.spine.any { item ->
            try {
                epubPackage.archive.read(item.href).isNotEmpty()
            } catch (_: EpubError) {
                false
            }
        }
    }
}
