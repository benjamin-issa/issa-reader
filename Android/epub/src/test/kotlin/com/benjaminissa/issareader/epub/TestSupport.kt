package com.benjaminissa.issareader.epub

import com.benjaminissa.issareader.testing.Fixtures
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files

/** A book in `Packages/IssaEPUB/Tests/Fixtures`, read in place: `fixture("alice")`. */
internal fun fixture(name: String): File = Fixtures.epub("$name.epub")

internal fun openFixture(name: String): EpubPackage = EpubPackage.open(fixture(name))

/** Bytes appended in order, for the suites that build archives by hand. */
internal class ByteSink {
    private val out = ByteArrayOutputStream()
    val size: Int get() = out.size()

    operator fun plusAssign(bytes: ByteArray) {
        out.write(bytes)
    }

    fun toByteArray(): ByteArray = out.toByteArray()
}

internal fun bytesOf(vararg values: Int): ByteArray = ByteArray(values.size) { values[it].toByte() }

internal fun le16(value: Int): ByteArray = bytesOf(value and 0xFF, (value ushr 8) and 0xFF)

internal fun le32(value: Long): ByteArray = ByteArray(4) { ((value ushr (it * 8)) and 0xFF).toByte() }

internal fun le64(value: ULong): ByteArray = ByteArray(8) { ((value shr (it * 8)) and 0xFFu).toByte() }

internal fun utf8(text: String): ByteArray = text.toByteArray(Charsets.UTF_8)

internal fun ByteArray.utf8String(): String = String(this, Charsets.UTF_8)

/** A fresh directory under the system's temporary one, deleted by the caller. */
internal fun temporaryDirectory(prefix: String): File = Files.createTempDirectory(prefix).toFile()

/** One clip of a narration stated row by row. */
internal class Clip(
    val fragment: String,
    val text: String,
    val audio: String,
    val start: Double,
    val end: Double,
    val audioOnly: Boolean,
)

/**
 * A narration stated row by row, `cumulativeEnd` accumulated exactly as
 * `SmilParser.timeline` accumulates it.
 */
internal fun narration(vararg rows: Clip): SmilTimeline {
    var cumulative = 0.0
    return SmilTimeline(
        rows.map { row ->
            cumulative += row.end - row.start
            SmilEntry(
                fragmentId = row.fragment, textHref = row.text, audioHref = row.audio,
                start = row.start, end = row.end, cumulativeEnd = cumulative, isAudioOnly = row.audioOnly,
            )
        },
    )
}
