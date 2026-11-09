package com.benjaminissa.issareader.playback

import java.io.ByteArrayOutputStream
import java.util.zip.Deflater

/**
 * A minimal read-along EPUB built in the test, byte by byte. Ported from
 * `InTestEPUB.swift`.
 *
 * For the shapes no fixture book has: an audio member far larger than any file
 * worth checking in. Text members are stored; the audio member is deflated by
 * streaming, so a member that inflates to hundreds of megabytes costs a few
 * hundred kilobytes here.
 */
internal object InTestEpub {
    class Member(val name: String, val payload: ByteArray, val method: Int, val uncompressedSize: Long)

    fun stored(name: String, text: String): Member {
        val data = text.toByteArray(Charsets.UTF_8)
        return Member(name, data, 0, data.size.toLong())
    }

    /** [count] zero bytes, raw-deflated a megabyte at a time. */
    fun deflatedZeros(name: String, count: Long): Member {
        val deflater = Deflater(Deflater.DEFAULT_COMPRESSION, true)
        val chunk = 1 shl 20
        val zeros = ByteArray(chunk)
        val output = ByteArray(chunk)
        val compressed = ByteArrayOutputStream()
        var remaining = count
        try {
            while (remaining > 0) {
                val take = minOf(remaining, chunk.toLong()).toInt()
                deflater.setInput(zeros, 0, take)
                remaining -= take
                while (!deflater.needsInput()) {
                    val written = deflater.deflate(output)
                    compressed.write(output, 0, written)
                }
            }
            deflater.finish()
            while (!deflater.finished()) {
                val written = deflater.deflate(output)
                compressed.write(output, 0, written)
            }
        } finally {
            deflater.end()
        }
        return Member(name, compressed.toByteArray(), 8, count)
    }

    /** A package with one chapter whose overlay names `audio`, and `audio` itself, in a valid archive. */
    fun readalong(audio: Member): ByteArray = archive(
        listOf(
            stored("mimetype", "application/epub+zip"),
            stored(
                "META-INF/container.xml",
                """
                <?xml version="1.0"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
                </container>
                """.trimIndent(),
            ),
            stored(
                "OEBPS/content.opf",
                """
                <?xml version="1.0"?>
                <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:identifier id="id">in-test</dc:identifier><dc:title>In Test</dc:title>
                  </metadata>
                  <manifest>
                    <item id="ch01" href="ch01.xhtml" media-type="application/xhtml+xml"/>
                    <item id="audio" href="Audio/big.mp3" media-type="audio/mpeg"/>
                  </manifest>
                  <spine><itemref idref="ch01"/></spine>
                </package>
                """.trimIndent(),
            ),
            stored("OEBPS/ch01.xhtml", "<html><body><p id=\"s0\">One.</p></body></html>"),
            audio,
        ),
    )

    fun archive(members: List<Member>): ByteArray {
        val out = ByteArrayOutputStream()
        val central = ByteArrayOutputStream()
        fun ByteArrayOutputStream.le16(value: Int) {
            write(value and 0xFF)
            write((value ushr 8) and 0xFF)
        }
        fun ByteArrayOutputStream.le32(value: Long) {
            for (shift in 0 until 4) write(((value ushr (shift * 8)) and 0xFF).toInt())
        }
        for (member in members) {
            val name = member.name.toByteArray(Charsets.UTF_8)
            val offset = out.size().toLong()
            out.write(byteArrayOf(0x50, 0x4B, 0x03, 0x04))
            out.le16(20); out.le16(0); out.le16(member.method)
            out.le16(0); out.le16(0); out.le32(0)
            out.le32(member.payload.size.toLong()); out.le32(member.uncompressedSize)
            out.le16(name.size); out.le16(0)
            out.write(name); out.write(member.payload)

            central.write(byteArrayOf(0x50, 0x4B, 0x01, 0x02))
            central.le16(20); central.le16(20); central.le16(0)
            central.le16(member.method); central.le16(0); central.le16(0)
            central.le32(0)
            central.le32(member.payload.size.toLong()); central.le32(member.uncompressedSize)
            central.le16(name.size); central.le16(0); central.le16(0)
            central.le16(0); central.le16(0); central.le32(0)
            central.le32(offset); central.write(name)
        }
        val directoryOffset = out.size().toLong()
        val directory = central.toByteArray()
        out.write(directory)
        out.write(byteArrayOf(0x50, 0x4B, 0x05, 0x06))
        out.le16(0); out.le16(0)
        out.le16(members.size); out.le16(members.size)
        out.le32(directory.size.toLong()); out.le32(directoryOffset); out.le16(0)
        return out.toByteArray()
    }
}
