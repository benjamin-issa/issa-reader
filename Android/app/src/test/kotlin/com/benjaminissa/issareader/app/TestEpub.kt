package com.benjaminissa.issareader.app

import com.benjaminissa.issareader.epub.EpubArchive
import com.benjaminissa.issareader.epub.EpubPackage
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * A small EPUB built in the test, byte by byte, for the shapes no fixture has:
 * a chapter whose markup will not parse, or one long enough that a stale
 * offset crosses a page.
 *
 * Stored, not deflated, and with no checksums: `EpubArchive` reads neither.
 */
object TestEpub {
    data class Chapter(
        /** The manifest id, and the file's name without its extension. */
        val id: String,
        /** What the contents list calls it. */
        val title: String,
        /** Everything inside `<body>`, as markup. */
        val body: String,
        /** The element ids its media overlay narrates, in order, a second each of the book's one audio file. */
        val narrated: List<String> = emptyList(),
    )

    /** The spine href `open` gives a chapter, for asserting against. */
    fun href(chapter: Chapter): String = "OEBPS/${chapter.id}.xhtml"

    /** The archive path of the audio every narrated chapter plays. */
    const val audioHref = "OEBPS/narration.wav"

    /**
     * The whole book, as the bytes of a `.epub`.
     *
     * @param audio the bytes of the one audio file the overlays point at.
     * @param audioMediaType what the manifest declares that file to be.
     * @param metadata further `<metadata>` children, as markup.
     * @param extras further archive members — a DRM licence, say.
     */
    fun data(
        title: String = "A Test Book",
        chapters: List<Chapter>,
        audio: ByteArray? = null,
        audioMediaType: String = "audio/wav",
        metadata: String = "",
        extras: List<Pair<String, ByteArray>> = emptyList(),
    ): ByteArray {
        val container = """
            <?xml version="1.0" encoding="utf-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
        """.trimIndent()
        var manifest = chapters.joinToString("\n") { chapter ->
            val overlay = if (chapter.narrated.isEmpty()) "" else " media-overlay=\"${chapter.id}_overlay\""
            "<item id=\"${chapter.id}\" href=\"${chapter.id}.xhtml\" media-type=\"application/xhtml+xml\"$overlay/>"
        }
        for (chapter in chapters) {
            if (chapter.narrated.isEmpty()) continue
            manifest += "\n<item id=\"${chapter.id}_overlay\" href=\"${chapter.id}.smil\" media-type=\"application/smil+xml\"/>"
        }
        if (audio != null) manifest += "\n<item id=\"narration\" href=\"narration.wav\" media-type=\"$audioMediaType\"/>"
        val spine = chapters.joinToString("") { "<itemref idref=\"${it.id}\"/>" }
        val opf = """
            |<?xml version="1.0" encoding="utf-8"?>
            |<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
            |<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            |<dc:identifier id="uid">urn:uuid:issa-test-epub</dc:identifier>
            |<dc:title>$title</dc:title><dc:language>en</dc:language>
            |$metadata
            |</metadata>
            |<manifest>
            |<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            |$manifest
            |</manifest>
            |<spine>$spine</spine>
            |</package>
        """.trimMargin()
        val entries = chapters.joinToString("") { "<li><a href=\"${it.id}.xhtml\">${it.title}</a></li>" }
        val nav = """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>Contents</title></head>
            <body><nav epub:type="toc"><ol>$entries</ol></nav></body>
            </html>
        """.trimIndent()
        val files = mutableListOf(
            "mimetype" to "application/epub+zip",
            "META-INF/container.xml" to container,
            "OEBPS/content.opf" to opf,
            "OEBPS/nav.xhtml" to nav,
        )
        // Clips run on through the one file from chapter to chapter, a second
        // each, so no two sentences claim the same moment of it.
        var second = 0
        for (chapter in chapters) {
            files.add(
                href(chapter) to "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
                    "<html xmlns=\"http://www.w3.org/1999/xhtml\">\n" +
                    "<head><title>${chapter.title}</title></head>\n" +
                    "<body>${chapter.body}</body>\n</html>",
            )
            if (chapter.narrated.isEmpty()) continue
            val first = second
            second += chapter.narrated.size
            val pars = chapter.narrated.mapIndexed { index, id ->
                "<par id=\"${chapter.id}-par$index\"><text src=\"${chapter.id}.xhtml#$id\"/>" +
                    "<audio src=\"narration.wav\" clipBegin=\"${first + index}.000s\" clipEnd=\"${first + index + 1}.000s\"/></par>"
            }.joinToString("\n")
            files.add(
                "OEBPS/${chapter.id}.smil" to "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
                    "<smil xmlns=\"http://www.w3.org/ns/SMIL\" xmlns:epub=\"http://www.idpf.org/2007/ops\" version=\"3.0\">\n" +
                    "<body><seq epub:textref=\"${chapter.id}.xhtml\">\n$pars\n</seq></body>\n</smil>",
            )
        }
        val members = files.map { it.first to it.second.toByteArray(Charsets.UTF_8) }.toMutableList()
        if (audio != null) members.add(audioHref to audio)
        members.addAll(extras)
        return StoredZip.zip(members)
    }

    /** The book, opened. */
    fun epubPackage(title: String = "A Test Book", chapters: List<Chapter>, audio: ByteArray? = null): EpubPackage =
        EpubPackage.open(EpubArchive(data(title = title, chapters = chapters, audio = audio)))
}

/**
 * A read-along whose overlay gives clips a `clipBegin` and no `clipEnd`: the
 * shape another toolchain's EPUB has, which no Storyteller book does. One
 * audio file per chapter, each a real WAV of silence of the length the test
 * names, so its true length is something a player can measure.
 */
object OpenClipBook {
    data class Chapter(
        val id: String,
        val title: String,
        /** Seconds of audio in this chapter's file. */
        val seconds: Int,
        /** Where each sentence's clip begins in that file. None states an end. */
        val clipBegins: List<Double>,
    )

    fun audioHref(chapter: Chapter): String = "OEBPS/Audio/${chapter.id}.wav"
    fun href(chapter: Chapter): String = "OEBPS/${chapter.id}.xhtml"

    fun data(chapters: List<Chapter>): ByteArray {
        val members = mutableListOf(
            "mimetype" to "application/epub+zip".toByteArray(),
            "META-INF/container.xml" to (
                "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
                    "<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">\n" +
                    "<rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles>\n" +
                    "</container>"
                ).toByteArray(),
        )
        var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        for (chapter in chapters) {
            manifest += "<item id=\"${chapter.id}\" href=\"${chapter.id}.xhtml\" media-type=\"application/xhtml+xml\" " +
                "media-overlay=\"${chapter.id}_overlay\"/>\n" +
                "<item id=\"${chapter.id}_overlay\" href=\"${chapter.id}.smil\" media-type=\"application/smil+xml\"/>\n" +
                "<item id=\"${chapter.id}_audio\" href=\"Audio/${chapter.id}.wav\" media-type=\"audio/wav\"/>"
        }
        val spine = chapters.joinToString("") { "<itemref idref=\"${it.id}\"/>" }
        members.add(
            "OEBPS/content.opf" to (
                "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
                    "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"uid\">\n" +
                    "<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n" +
                    "<dc:identifier id=\"uid\">urn:uuid:issa-open-clip-book</dc:identifier>\n" +
                    "<dc:title>The Open Clips</dc:title><dc:language>en</dc:language>\n" +
                    "</metadata>\n<manifest>$manifest</manifest>\n<spine>$spine</spine>\n</package>"
                ).toByteArray(),
        )
        val entries = chapters.joinToString("") { "<li><a href=\"${it.id}.xhtml\">${it.title}</a></li>" }
        members.add(
            "OEBPS/nav.xhtml" to (
                "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
                    "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">\n" +
                    "<head><title>Contents</title></head>\n" +
                    "<body><nav epub:type=\"toc\"><ol>$entries</ol></nav></body>\n</html>"
                ).toByteArray(),
        )
        for (chapter in chapters) {
            val sentences = chapter.clipBegins.indices.joinToString("") { index ->
                "<p><span id=\"${chapter.id}-s$index\">Sentence $index of ${chapter.title}, " +
                    "spoken for as long as its clip runs on.</span></p>"
            }
            members.add(
                href(chapter) to (
                    "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
                        "<html xmlns=\"http://www.w3.org/1999/xhtml\">\n" +
                        "<head><title>${chapter.title}</title></head>\n" +
                        "<body><h1>${chapter.title}</h1>$sentences</body>\n</html>"
                    ).toByteArray(),
            )
            val pars = chapter.clipBegins.mapIndexed { index, begin ->
                "<par id=\"${chapter.id}-par$index\"><text src=\"${chapter.id}.xhtml#${chapter.id}-s$index\"/>" +
                    "<audio src=\"Audio/${chapter.id}.wav\" clipBegin=\"${begin}s\"/></par>"
            }.joinToString("\n")
            members.add(
                "OEBPS/${chapter.id}.smil" to (
                    "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
                        "<smil xmlns=\"http://www.w3.org/ns/SMIL\" xmlns:epub=\"http://www.idpf.org/2007/ops\" version=\"3.0\">\n" +
                        "<body><seq epub:textref=\"${chapter.id}.xhtml\">\n$pars\n</seq></body>\n</smil>"
                    ).toByteArray(),
            )
            members.add(audioHref(chapter) to SilentAudio.wav(chapter.seconds))
        }
        return StoredZip.zip(members)
    }
}

/**
 * A real audio file with nothing in it, for suites that need a file whose
 * length can be measured, but are about the clock, not the sound.
 */
object SilentAudio {
    const val sampleRate = 2_000

    /** Thirty minutes of silence on disk, written once per process. */
    val file: File by lazy {
        File.createTempFile("issa-app-tests-silence", ".wav").apply {
            deleteOnExit()
            writeBytes(wav(1_800))
        }
    }

    /** A canonical 44-byte RIFF header and unsigned eight-bit mono silence. */
    fun wav(seconds: Int): ByteArray {
        val samples = seconds * sampleRate
        val out = ByteArrayOutputStream()
        fun le32(value: Int) = repeat(4) { out.write((value ushr (it * 8)) and 0xFF) }
        fun le16(value: Int) = repeat(2) { out.write((value ushr (it * 8)) and 0xFF) }
        out.write("RIFF".toByteArray())
        le32(36 + samples)
        out.write("WAVE".toByteArray())
        out.write("fmt ".toByteArray())
        le32(16)
        le16(1)
        le16(1)
        le32(sampleRate)
        le32(sampleRate)
        le16(1)
        le16(8)
        out.write("data".toByteArray())
        le32(samples)
        out.write(ByteArray(samples) { 0x80.toByte() })
        return out.toByteArray()
    }
}

/** A structurally valid archive of stored entries, with no checksums. */
object StoredZip {
    fun zip(entries: List<Pair<String, ByteArray>>): ByteArray {
        val out = ByteArrayOutputStream()
        val central = ByteArrayOutputStream()
        fun ByteArrayOutputStream.le16(value: Int) = repeat(2) { write((value ushr (it * 8)) and 0xFF) }
        fun ByteArrayOutputStream.le32(value: Int) = repeat(4) { write((value ushr (it * 8)) and 0xFF) }
        for ((path, payload) in entries) {
            val name = path.toByteArray(Charsets.UTF_8)
            val offset = out.size()
            out.write(byteArrayOf(0x50, 0x4B, 0x03, 0x04))
            out.le16(20); out.le16(0); out.le16(0); out.le16(0); out.le16(0)
            out.le32(0); out.le32(payload.size); out.le32(payload.size)
            out.le16(name.size); out.le16(0)
            out.write(name)
            out.write(payload)

            central.write(byteArrayOf(0x50, 0x4B, 0x01, 0x02))
            central.le16(20); central.le16(20); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(0); central.le32(payload.size); central.le32(payload.size)
            central.le16(name.size); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(0); central.le32(offset)
            central.write(name)
        }
        val directoryOffset = out.size()
        val directory = central.toByteArray()
        out.write(directory)
        out.write(byteArrayOf(0x50, 0x4B, 0x05, 0x06))
        out.le16(0); out.le16(0); out.le16(entries.size); out.le16(entries.size)
        out.le32(directory.size); out.le32(directoryOffset); out.le16(0)
        return out.toByteArray()
    }
}
