package com.benjaminissa.issareader.render

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.testing.Fixtures
import com.benjaminissa.issareader.testing.ReleaseRun
import kotlinx.serialization.Serializable
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/**
 * The Android half of the parity contract: every fixture chapter renders to
 * exactly the string the Swift client wrote down for it.
 *
 * A position's `charOffset` is a UTF-16 index into the rendered string, and so
 * is every Ask passage and spoiler boundary. `ParityGoldenTests.swift` writes
 * `Packages/IssaRender/Tests/Fixtures/parity/<package>-<book>.json` on a Mac —
 * each chapter's length, the SHA-256 of its UTF-16LE units, the string itself,
 * its fragment ranges and where each plate's U+FFFC sits — and this reads the
 * same files and parses the same books with [ChapterParser]. A difference of
 * one unit anywhere is a position that lands on the wrong sentence when it
 * crosses from one device to the other.
 *
 * Parsed exactly as the Ask index parses (`AskIndexStore.parseChapter`): a
 * plain `ReaderStyle()` and an [ArchiveImageSource], because each plate
 * contributes an object-replacement character and a newline to the string.
 *
 * Until the goldens have been written there is nothing to check: the suite
 * skips, except on a release run (`ISSA_RELEASE_RUN=1`), which must see the
 * contract checked.
 */
class ParserParityTest {
    @Serializable
    data class Chapter(
        val spineIndex: Int,
        val href: String,
        /** The chapter could not be parsed at all; this client must fail on it too, rather than invent text. */
        val failed: Boolean = false,
        val utf16Length: Int? = null,
        val sha256: String? = null,
        val text: String? = null,
        /** Fragment id → `[location, length]` in UTF-16 units. */
        val fragmentRanges: Map<String, List<Int>>? = null,
        val plates: List<Int>? = null,
    )

    @Serializable
    data class Book(
        val epub: String,
        val failed: Boolean = false,
        val chapters: List<Chapter> = emptyList(),
    )

    companion object {
        /** The directories `ParityGoldenTests` reads books from, in its order. */
        val fixtureDirectories = listOf(
            "Packages/IssaEPUB/Tests/Fixtures",
            "Packages/IssaRender/Tests/Fixtures",
            "Packages/IssaPlayback/Tests/Fixtures",
            "Packages/IssaAsk/Tests/Fixtures",
        )

        val goldenDirectory: File get() = File(Fixtures.repoRoot, "Packages/IssaRender/Tests/Fixtures/parity")

        /** Every fixture book, keyed `<package>-<book>` as the Swift suite keys them. */
        fun books(): List<Pair<String, String>> = fixtureDirectories.flatMap { directory ->
            val folder = File(Fixtures.repoRoot, directory)
            val pkg = folder.parentFile.parentFile.name
            folder.list().orEmpty().filter { it.endsWith(".epub") }.sorted().map { name ->
                "$pkg-${name.removeSuffix(".epub")}" to "$directory/$name"
            }
        }

        /** One book, parsed chapter by chapter as the Ask index parses it. */
        fun render(path: String): Book {
            val pkg = try {
                EpubPackage.open(File(Fixtures.repoRoot, path))
            } catch (_: Exception) {
                return Book(epub = path, failed = true)
            }
            val images = ArchiveImageSource(pkg.archive)
            val chapters = pkg.spine.mapIndexed { index, item ->
                val parsed = try {
                    ChapterParser(style = ReaderStyle(), loadImage = { images.image(it) })
                        .parse(pkg.archive.read(item.href), baseHref = item.href)
                } catch (_: Exception) {
                    null
                }
                if (parsed == null) {
                    Chapter(spineIndex = index, href = item.href, failed = true)
                } else {
                    Chapter(
                        spineIndex = index,
                        href = item.href,
                        utf16Length = parsed.text.length,
                        sha256 = sha256Utf16Le(parsed.text),
                        text = parsed.text,
                        fragmentRanges = parsed.fragmentRanges.mapValues { listOf(it.value.location, it.value.length) },
                        plates = parsed.text.indices.filter { parsed.text[it] == '\uFFFC' },
                    )
                }
            }
            return Book(epub = path, chapters = chapters)
        }

        fun sha256Utf16Le(text: String): String {
            val bytes = ByteArray(text.length * 2)
            for ((index, unit) in text.withIndex()) {
                bytes[index * 2] = (unit.code and 0xFF).toByte()
                bytes[index * 2 + 1] = (unit.code ushr 8).toByte()
            }
            return MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        }

        /** Where two strings first differ, with some of each either side, for a failure a person can read. */
        fun firstDifference(expected: String, actual: String): String {
            var index = 0
            while (index < expected.length && index < actual.length && expected[index] == actual[index]) index += 1
            fun around(text: String): String {
                val from = maxOf(0, index - 30)
                val to = minOf(text.length, index + 30)
                return text.substring(from, to).replace("\n", "⏎")
            }
            return "first differs at UTF-16 offset $index: expected «${around(expected)}», got «${around(actual)}»"
        }
    }

    @Test
    fun `every fixture chapter renders to the string written down for it`() {
        val mismatches = ArrayList<String>()
        var checked = 0
        for ((key, path) in books()) {
            val file = File(goldenDirectory, "$key.json")
            if (!file.isFile) continue
            val golden = IssaJson.decodeFromString(Book.serializer(), file.readText())
            val fresh = render(golden.epub.ifEmpty { path })
            checked += 1
            if (golden.failed != fresh.failed) {
                mismatches += "$key: whether the book opens changed (golden ${golden.failed}, here ${fresh.failed})"
                continue
            }
            if (golden.chapters.size != fresh.chapters.size) {
                mismatches += "$key: the spine changed (${golden.chapters.size} chapters, here ${fresh.chapters.size})"
            }
            for ((old, new) in golden.chapters.zip(fresh.chapters)) {
                val where = "$key spine ${old.spineIndex} (${old.href})"
                if (old.href != new.href) mismatches += "$where: href is ${new.href} here"
                if (old.failed != new.failed) {
                    mismatches += "$where: " + if (old.failed) "parses here but failed on the Mac" else "fails to parse here"
                    continue
                }
                if (old.failed) continue
                if (old.utf16Length != new.utf16Length || old.sha256 != new.sha256) {
                    val detail = if (old.text != null && new.text != null) firstDifference(old.text, new.text) else ""
                    mismatches += "$where: length ${new.utf16Length}, golden ${old.utf16Length}; sha256 differs. $detail"
                    continue
                }
                if (old.fragmentRanges != new.fragmentRanges) {
                    val ids = (old.fragmentRanges.orEmpty().keys + new.fragmentRanges.orEmpty().keys)
                        .filter { old.fragmentRanges?.get(it) != new.fragmentRanges?.get(it) }.sorted()
                    mismatches += "$where: fragment ranges differ for ${ids.take(8)}" +
                        ids.take(3).joinToString { " $it golden ${old.fragmentRanges?.get(it)} here ${new.fragmentRanges?.get(it)}" }
                }
                if (old.plates != new.plates) mismatches += "$where: plates at ${new.plates}, golden ${old.plates}"
            }
        }
        if (checked == 0) {
            // Nothing written yet. A release run must see the contract checked.
            ReleaseRun.require(
                available = false,
                what = "Parity goldens in ${goldenDirectory.path} (write them on a Mac with " +
                    "ISSA_WRITE_PARITY_GOLDENS=1 swift test --filter ParityGoldenTests)",
            )
        }
        if (mismatches.isNotEmpty()) {
            fail("${mismatches.size} chapter(s) no longer match the Swift client's string:\n" + mismatches.joinToString("\n"))
        }
        assertTrue(checked > 0)
    }

    /**
     * The reading of the goldens themselves, so a format change on the Swift
     * side shows up as a decode failure here rather than as silent skips.
     */
    @Test
    fun `a golden written by the Swift suite decodes`() {
        val written = """
            {"chapters":[{"failed":false,"fragmentRanges":{"s0":[0,5]},"href":"OEBPS/c.xhtml","plates":[7],
            "sha256":"ab","spineIndex":0,"text":"Hello\n\uFFFC","utf16Length":7},
            {"failed":true,"href":"OEBPS/d.xhtml","spineIndex":1}],"epub":"Packages/x.epub","failed":false}
        """.trimIndent()
        val book = IssaJson.decodeFromString(Book.serializer(), written)
        assertTrue(book.chapters[1].failed)
        assertTrue(book.chapters[0].fragmentRanges == mapOf("s0" to listOf(0, 5)))
        assertTrue(book.chapters[0].plates == listOf(7))
    }

    /**
     * The hash is of UTF-16 little-endian units, as Swift's `Array(text.utf16)`
     * is written out: an astral character is its two surrogates, low byte
     * first. The empty string's digest is the well-known one.
     */
    @Test
    fun `the digest is of UTF-16LE units`() {
        assertTrue(sha256Utf16Le("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        val manual = MessageDigest.getInstance("SHA-256")
            .digest(byteArrayOf(0x41, 0x00, 0x3D, 0xD8.toByte(), 0x00, 0xDE.toByte()))
            .joinToString("") { "%02x".format(it) }
        assertTrue(sha256Utf16Le("A😀") == manual)
    }
}
