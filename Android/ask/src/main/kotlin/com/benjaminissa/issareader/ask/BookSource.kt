package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.epub.EpubPackage
import kotlinx.serialization.Serializable
import java.io.File

/**
 * The book an index is built from, and the fingerprint that says whether the
 * index on disk still describes it.
 *
 * Holds the opened [EpubPackage] rather than re-opening: the package is an
 * immutable value over an archive that is nothing but a central directory in
 * memory, so passing it between threads costs nothing, and every chapter body
 * is still inflated lazily when it is read. The EPUB is never unzipped to
 * disk; the index is the only derived file.
 */
data class BookSource(
    /** The catalogue uuid, which names the index file. */
    val bookUuid: String,
    /** Where the EPUB itself lives, for the fingerprint. */
    val file: File,
    val epubPackage: EpubPackage,
) {
    /** Opens the EPUB and takes its fingerprint in one step. */
    constructor(bookUuid: String, file: File) : this(bookUuid, file, EpubPackage.open(file))

    /**
     * BCP-47 tag from the package metadata, used to pre-flight the model's
     * supported languages before a question is ever sent.
     */
    val language: String? get() = epubPackage.metadata.language

    /** The fingerprint of the file as it is right now. */
    val indexKey: IndexKey get() = IndexKey.of(file, epubPackage.spine.size)
}

/**
 * What an index on disk was built from, so a stale one is rebuilt rather than
 * silently answering from the wrong book.
 *
 * Size and modification date rather than a content hash: an EPUB is hundreds
 * of megabytes in the read-aloud edition, and hashing it would cost more than
 * rebuilding the index. The two versions are the part that actually matters —
 * a change to the chunker or to the parser moves every offset in the file, and
 * an offset that has moved puts the spoiler boundary in the wrong place.
 */
@Serializable
data class IndexKey(
    val fileSize: Long,
    /**
     * Seconds since the epoch, rounded down to the second — filesystems do not
     * all agree below that, and a false mismatch costs a full rebuild.
     */
    val modified: Long,
    val spineCount: Int,
    /** Bumped whenever chunking or parsing changes what the offsets mean. */
    val parserVersion: Int = currentParserVersion,
    /** Bumped whenever the SQLite schema changes. */
    val schemaVersion: Int = currentSchemaVersion,
) {
    /** One row in `meta`, so the whole key is one read and one comparison. */
    val storedValue: String get() = "$fileSize|$modified|$spineCount|$parserVersion|$schemaVersion"

    companion object {
        /**
         * Chunking, parsing and the image rule together. Anything that moves a
         * character in the rendered string belongs here.
         *
         * The Swift client's history, kept because the number is shared: 2
         * since the index stopped storing navigation; 3 since it stopped
         * storing the front matter the book names in its own landmarks; 4
         * since a document longer than the book's average chapter stops being
         * treated as apparatus however it is tagged; 5 since the renderer
         * stopped treating the whitespace *between* two block elements as
         * content (one character per paragraph, which is every offset); 6
         * since the chapter parse substitutes every HTML 4.01 entity name, and
         * parses navigation documents through the same table. Each is rebuilt
         * the same lazy way — per book, on the first question after the
         * update, behind "Reading what you've read…".
         *
         * An Android index is never read by the iPhone, or the reverse; the
         * number is the same so that a change made on one side and bumped
         * there is bumped on the other in the same commit.
         */
        const val currentParserVersion = 6

        /** 2 since the `name` table grew `nameKey`: an index built before it pools two spellings of one character as two people. */
        const val currentSchemaVersion = 2

        /**
         * Reads the file's size and date fresh, every time — the case this type
         * exists to catch is the book re-downloaded under the same name, and a
         * cached answer would say nothing has changed.
         */
        fun of(file: File, spineCount: Int): IndexKey = IndexKey(
            fileSize = if (file.isFile) file.length() else 0,
            modified = Math.floorDiv(file.lastModified(), 1000L),
            spineCount = spineCount,
        )

        /** The stored form read back, or null for anything that is not one. */
        fun fromStoredValue(storedValue: String): IndexKey? {
            val parts = storedValue.split("|")
            if (parts.size != 5) return null
            return IndexKey(
                fileSize = parts[0].toLongOrNull() ?: return null,
                modified = parts[1].toLongOrNull() ?: return null,
                spineCount = parts[2].toIntOrNull() ?: return null,
                parserVersion = parts[3].toIntOrNull() ?: return null,
                schemaVersion = parts[4].toIntOrNull() ?: return null,
            )
        }
    }
}
