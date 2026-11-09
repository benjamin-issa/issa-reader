package com.benjaminissa.issareader.app.ui.signin

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The device-code screen's QR, read back the way a scanner reads it: the
 * format and version information decoded and checked, the mask taken off,
 * the codewords collected in the zigzag, every Reed–Solomon block's
 * syndromes zero, and the byte segment giving back the text. The Galois
 * arithmetic here is the test's own, so an encoder error in it cannot cancel
 * itself out.
 */
class QrCodeTest {
    private val approval = "http://192.168.1.10:8001/device?device_code=3g9tSBBTa0buV5EfRTCq_qBzTjXKnSzm"

    @Test
    fun `the approval link reads back exactly`() {
        val code = QrCode.encode(approval)!!
        assertEquals(approval, read(code))
    }

    @Test
    fun `texts across versions and block layouts read back`() {
        val texts = listOf(
            "",
            "A",
            "HELLO WORLD",
            "http://issa-fixture.test/device",
            // Past version 6, so the version information is drawn.
            "x".repeat(110),
            // Short and long blocks interleaved, and two alignment rows.
            "https://example.com/" + "abcdefghij".repeat(30),
            "Ünïcödé — ✓",
        )
        for (text in texts) {
            val code = QrCode.encode(text)!!
            assertEquals(text, read(code))
        }
    }

    @Test
    fun `the smallest version that holds the payload, at medium correction`() {
        // Byte capacities at M: version 1 holds 14, version 5 holds 84.
        assertEquals(21, QrCode.encode("x".repeat(14))!!.size)
        assertEquals(25, QrCode.encode("x".repeat(15))!!.size)
        assertEquals(37, QrCode.encode("x".repeat(84))!!.size)
        assertEquals(41, QrCode.encode("x".repeat(85))!!.size)
    }

    @Test
    fun `data capacities match the standard's table`() {
        assertEquals(16, QrCode.dataCodewords(1, QrCode.Ecc.MEDIUM))
        assertEquals(86, QrCode.dataCodewords(5, QrCode.Ecc.MEDIUM))
        assertEquals(216, QrCode.dataCodewords(10, QrCode.Ecc.MEDIUM))
        assertEquals(2334, QrCode.dataCodewords(40, QrCode.Ecc.MEDIUM))
        assertEquals(19, QrCode.dataCodewords(1, QrCode.Ecc.LOW))
        assertEquals(9, QrCode.dataCodewords(1, QrCode.Ecc.HIGH))
    }

    @Test
    fun `alignment patterns sit where the standard puts them`() {
        assertArrayEquals(intArrayOf(), QrCode.alignmentPositions(1))
        assertArrayEquals(intArrayOf(6, 18), QrCode.alignmentPositions(2))
        assertArrayEquals(intArrayOf(6, 22, 38), QrCode.alignmentPositions(7))
        assertArrayEquals(intArrayOf(6, 34, 60, 86, 112, 138), QrCode.alignmentPositions(32))
        assertArrayEquals(intArrayOf(6, 30, 58, 86, 114, 142, 170), QrCode.alignmentPositions(40))
    }

    @Test
    fun `version information carries the standard's codeword`() {
        val code = QrCode.encode("x".repeat(110))!!
        val version = (code.size - 17) / 4
        assertEquals(7, version)
        // ISO/IEC 18004 Annex D: version 7 is 00 0111 1100 1001 0100.
        assertEquals(0x07C94, versionBits(code))
    }

    @Test
    fun `nothing past the largest version`() {
        // Version 40 at M holds 2,331 bytes.
        assertEquals(177, QrCode.encode("x".repeat(2331))!!.size)
        assertNull(QrCode.encode("x".repeat(2332)))
    }

    // Reading a symbol back

    private fun read(code: QrCode): String {
        val size = code.size
        val version = (size - 17) / 4
        val (ecc, mask) = format(code)
        val function = QrCode.functionModules(version)

        // The data modules in placement order, the mask taken off.
        val bits = ArrayList<Boolean>()
        var right = size - 1
        while (right >= 1) {
            if (right == 6) right = 5
            for (vertical in 0 until size) {
                for (j in 0..1) {
                    val x = right - j
                    val upward = (right + 1) and 2 == 0
                    val y = if (upward) size - 1 - vertical else vertical
                    if (!function[y * size + x]) bits.add(code[x, y] xor masked(mask, x, y))
                }
            }
            right -= 2
        }
        val raw = QrCode.rawDataModules(version) / 8
        val codewords = IntArray(raw) { i -> (0 until 8).fold(0) { acc, b -> (acc shl 1) or if (bits[i * 8 + b]) 1 else 0 } }

        // Undo the interleaving, then check each block is a codeword.
        val blocks = QrCode.blocks(version, ecc)
        val eccLength = QrCode.eccCodewordsPerBlock(version, ecc)
        val shortBlocks = blocks - raw % blocks
        val shortLength = raw / blocks
        val dataLengths = IntArray(blocks) { shortLength - eccLength + if (it < shortBlocks) 0 else 1 }
        val split = Array(blocks) { IntArray(dataLengths[it] + eccLength) }
        var k = 0
        for (i in 0 until shortLength - eccLength + 1) {
            for (j in 0 until blocks) if (i < dataLengths[j]) split[j][i] = codewords[k++]
        }
        for (i in 0 until eccLength) for (j in 0 until blocks) split[j][dataLengths[j] + i] = codewords[k++]
        assertEquals(raw, k)
        for (block in split) {
            for (root in 0 until eccLength) assertEquals("syndrome $root", 0, evaluate(block, power(root)))
        }

        // The byte segment.
        val data = split.flatMapIndexed { j, block -> block.take(dataLengths[j]) }
        val stream = data.flatMap { byte -> (7 downTo 0).map { (byte ushr it) and 1 } }
        var position = 0
        fun take(n: Int): Int {
            var value = 0
            repeat(n) { value = (value shl 1) or stream[position++] }
            return value
        }
        assertEquals("byte mode", 0b0100, take(4))
        val count = take(if (version <= 9) 8 else 16)
        val bytes = ByteArray(count) { take(8).toByte() }
        assertEquals("terminator", 0, take(minOf(4, stream.size - position)))
        return bytes.decodeToString()
    }

    /** The 15 format bits around the top-left finder: correction level and mask, BCH-checked. */
    private fun format(code: QrCode): Pair<QrCode.Ecc, Int> {
        var bits = 0
        fun put(i: Int, dark: Boolean) {
            if (dark) bits = bits or (1 shl i)
        }
        for (i in 0..5) put(i, code[8, i])
        put(6, code[8, 7])
        put(7, code[8, 8])
        put(8, code[7, 8])
        for (i in 9 until 15) put(i, code[14 - i, 8])
        // The second copy says the same.
        var second = 0
        for (i in 0 until 8) if (code[code.size - 1 - i, 8]) second = second or (1 shl i)
        for (i in 8 until 15) if (code[8, code.size - 15 + i]) second = second or (1 shl i)
        assertEquals(bits, second)
        assertTrue("dark module", code[8, code.size - 8])

        val unmasked = bits xor 0x5412
        val data = unmasked ushr 10
        assertEquals("BCH", bch(data, 10, 0x537), unmasked and 0x3FF)
        val ecc = QrCode.Ecc.entries.first { it.formatBits == data ushr 3 }
        return ecc to (data and 7)
    }

    private fun versionBits(code: QrCode): Int {
        var bits = 0
        for (i in 0 until 18) if (code[code.size - 11 + i % 3, i / 3]) bits = bits or (1 shl i)
        var mirrored = 0
        for (i in 0 until 18) if (code[i / 3, code.size - 11 + i % 3]) mirrored = mirrored or (1 shl i)
        assertEquals(bits, mirrored)
        assertEquals("BCH", bch(bits ushr 12, 12, 0x1F25), bits and 0xFFF)
        return bits
    }

    /** The remainder of `data · x^degree` divided by [generator]. */
    private fun bch(data: Int, degree: Int, generator: Int): Int {
        var value = data shl degree
        val top = Integer.numberOfLeadingZeros(generator)
        while (value != 0 && Integer.numberOfLeadingZeros(value) <= top) {
            value = value xor (generator shl (top - Integer.numberOfLeadingZeros(value)))
        }
        return value
    }

    private fun masked(mask: Int, x: Int, y: Int): Boolean = when (mask) {
        0 -> (x + y) % 2 == 0
        1 -> y % 2 == 0
        2 -> x % 3 == 0
        3 -> (x + y) % 3 == 0
        4 -> (x / 3 + y / 2) % 2 == 0
        5 -> x * y % 2 + x * y % 3 == 0
        6 -> (x * y % 2 + x * y % 3) % 2 == 0
        else -> ((x + y) % 2 + x * y % 3) % 2 == 0
    }

    // GF(256) over x^8 + x^4 + x^3 + x^2 + 1, by tables.

    private val exp = IntArray(512).also { table ->
        var value = 1
        for (i in 0 until 255) {
            table[i] = value
            value = value shl 1
            if (value and 0x100 != 0) value = value xor 0x11D
        }
        for (i in 255 until 512) table[i] = table[i - 255]
    }
    private val log = IntArray(256).also { table -> for (i in 0 until 255) table[exp[i]] = i }

    private fun power(n: Int): Int = exp[n % 255]

    private fun times(a: Int, b: Int): Int = if (a == 0 || b == 0) 0 else exp[log[a] + log[b]]

    /** The block as a polynomial, highest degree first, at [point]. */
    private fun evaluate(block: IntArray, point: Int): Int = block.fold(0) { acc, c -> times(acc, point) xor c }
}
