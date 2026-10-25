package com.benjaminissa.issareader.app.ui.signin

/**
 * A QR code for a string, generated on the device: byte mode, the smallest
 * version that holds it, and medium error correction.
 *
 * The iPhone draws the approval link's QR with CoreImage's generator for the
 * same reason this exists: the server offers its own as an SVG
 * (`qr_svg_url`), which no image type here can load without a renderer, and
 * fetching it would put the device code on the wire a second time. Generating
 * it here needs no network at all. Medium correction, as Swift's: the payload
 * is a URL with a code in it, and a denser symbol is harder to scan.
 *
 * The algorithm is ISO/IEC 18004's, in the shape of Project Nayuki's public
 * reference implementation: segment, Reed–Solomon blocks interleaved, the
 * function patterns, the zigzag placement, and the mask with the lowest
 * penalty.
 */
class QrCode private constructor(
    /** Modules per side: 21 for version 1, four more per version. */
    val size: Int,
    private val modules: BooleanArray,
) {
    /** Whether the module at column [x], row [y] is dark. */
    operator fun get(x: Int, y: Int): Boolean = x in 0 until size && y in 0 until size && modules[y * size + x]

    /** The symbol as rows of `#` and `.`, for a test to compare. */
    fun rows(): List<String> = (0 until size).map { y -> (0 until size).joinToString("") { x -> if (get(x, y)) "#" else "." } }

    enum class Ecc(internal val index: Int, internal val formatBits: Int) {
        LOW(0, 1),
        MEDIUM(1, 0),
        QUARTILE(2, 3),
        HIGH(3, 2),
    }

    companion object {
        /** The QR for [text], in UTF-8; null when it is too long for any version. */
        fun encode(text: String, ecc: Ecc = Ecc.MEDIUM): QrCode? = encode(text.encodeToByteArray(), ecc)

        fun encode(data: ByteArray, ecc: Ecc = Ecc.MEDIUM): QrCode? {
            // The smallest version whose capacity holds the byte segment.
            var version = 1
            while (true) {
                val capacityBits = dataCodewords(version, ecc) * 8
                val used = 4 + countBits(version) + data.size * 8
                if (data.size < (1 shl countBits(version)) && used <= capacityBits) break
                version += 1
                if (version > 40) return null
            }
            val bits = BitBuffer()
            bits.append(0b0100, 4)
            bits.append(data.size, countBits(version))
            for (byte in data) bits.append(byte.toInt() and 0xFF, 8)
            val capacityBits = dataCodewords(version, ecc) * 8
            // Terminator, byte alignment, then the alternating pad bytes.
            bits.append(0, minOf(4, capacityBits - bits.size))
            bits.append(0, (8 - bits.size % 8) % 8)
            var pad = 0xEC
            while (bits.size < capacityBits) {
                bits.append(pad, 8)
                pad = pad xor 0xEC xor 0x11
            }
            val codewords = ByteArray(bits.size / 8)
            for (i in 0 until bits.size) {
                if (bits[i]) codewords[i ushr 3] = (codewords[i ushr 3].toInt() or (1 shl (7 - (i and 7)))).toByte()
            }
            return Builder(version, ecc).build(codewords)
        }

        private fun countBits(version: Int): Int = if (version <= 9) 8 else 16

        private fun dataCodewords(version: Int, ecc: Ecc): Int =
            rawDataModules(version) / 8 - ECC_CODEWORDS_PER_BLOCK[ecc.index][version] * ERROR_CORRECTION_BLOCKS[ecc.index][version]

        /** Data and error-correction bits a version holds once its function patterns are drawn. */
        internal fun rawDataModules(version: Int): Int {
            var result = (16 * version + 128) * version + 64
            if (version >= 2) {
                val alignments = version / 7 + 2
                result -= (25 * alignments - 10) * alignments - 55
                if (version >= 7) result -= 36
            }
            return result
        }

        private val ECC_CODEWORDS_PER_BLOCK = arrayOf(
            intArrayOf(-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30),
            intArrayOf(-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28),
            intArrayOf(-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30),
            intArrayOf(-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30),
        )

        private val ERROR_CORRECTION_BLOCKS = arrayOf(
            intArrayOf(-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25),
            intArrayOf(-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49),
            intArrayOf(-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68),
            intArrayOf(-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81),
        )

        private const val PENALTY_N1 = 3
        private const val PENALTY_N2 = 3
        private const val PENALTY_N3 = 40
        private const val PENALTY_N4 = 10
    }

    /** A growable run of bits, most significant first. */
    private class BitBuffer {
        private val bits = ArrayList<Boolean>()
        val size: Int get() = bits.size

        operator fun get(index: Int): Boolean = bits[index]

        fun append(value: Int, length: Int) {
            for (i in length - 1 downTo 0) bits.add((value ushr i) and 1 != 0)
        }
    }

    /** One symbol being drawn: the function patterns, the data, and the mask. */
    private class Builder(private val version: Int, private val ecc: Ecc) {
        val size = version * 4 + 17
        val modules = BooleanArray(size * size)
        val isFunction = BooleanArray(size * size)

        fun build(data: ByteArray): QrCode {
            drawFunctionPatterns()
            drawCodewords(addEccAndInterleave(data))
            // The mask with the lowest penalty.
            var best = 0
            var minPenalty = Int.MAX_VALUE
            for (mask in 0 until 8) {
                applyMask(mask)
                drawFormatBits(mask)
                val penalty = penalty()
                if (penalty < minPenalty) {
                    best = mask
                    minPenalty = penalty
                }
                applyMask(mask) // Undoes it: XOR.
            }
            applyMask(best)
            drawFormatBits(best)
            return QrCode(size, modules)
        }

        private fun set(x: Int, y: Int, dark: Boolean) {
            modules[y * size + x] = dark
        }

        private fun get(x: Int, y: Int): Boolean = modules[y * size + x]

        private fun setFunction(x: Int, y: Int, dark: Boolean) {
            set(x, y, dark)
            isFunction[y * size + x] = true
        }

        private fun drawFunctionPatterns() {
            for (i in 0 until size) {
                setFunction(6, i, i % 2 == 0)
                setFunction(i, 6, i % 2 == 0)
            }
            drawFinder(3, 3)
            drawFinder(size - 4, 3)
            drawFinder(3, size - 4)
            val positions = alignmentPositions()
            val count = positions.size
            for (i in 0 until count) {
                for (j in 0 until count) {
                    // Not over the three finders' corners.
                    if (i == 0 && j == 0 || i == 0 && j == count - 1 || i == count - 1 && j == 0) continue
                    drawAlignment(positions[i], positions[j])
                }
            }
            drawFormatBits(0) // Reserved now, overwritten once the mask is chosen.
            drawVersion()
        }

        private fun drawFinder(x: Int, y: Int) {
            for (dy in -4..4) {
                for (dx in -4..4) {
                    val distance = maxOf(kotlin.math.abs(dx), kotlin.math.abs(dy))
                    val xx = x + dx
                    val yy = y + dy
                    if (xx in 0 until size && yy in 0 until size) setFunction(xx, yy, distance != 2 && distance != 4)
                }
            }
        }

        private fun drawAlignment(x: Int, y: Int) {
            for (dy in -2..2) {
                for (dx in -2..2) setFunction(x + dx, y + dy, maxOf(kotlin.math.abs(dx), kotlin.math.abs(dy)) != 1)
            }
        }

        private fun alignmentPositions(): IntArray {
            if (version == 1) return IntArray(0)
            val count = version / 7 + 2
            val step = (version * 8 + count * 3 + 5) / (count * 4 - 4) * 2
            val result = IntArray(count)
            result[0] = 6
            var position = size - 7
            for (i in count - 1 downTo 1) {
                result[i] = position
                position -= step
            }
            return result
        }

        private fun drawFormatBits(mask: Int) {
            val data = ecc.formatBits shl 3 or mask
            var remainder = data
            repeat(10) { remainder = (remainder shl 1) xor ((remainder ushr 9) * 0x537) }
            val bits = (data shl 10 or remainder) xor 0x5412
            fun bit(i: Int) = (bits ushr i) and 1 != 0
            for (i in 0..5) setFunction(8, i, bit(i))
            setFunction(8, 7, bit(6))
            setFunction(8, 8, bit(7))
            setFunction(7, 8, bit(8))
            for (i in 9 until 15) setFunction(14 - i, 8, bit(i))
            for (i in 0 until 8) setFunction(size - 1 - i, 8, bit(i))
            for (i in 8 until 15) setFunction(8, size - 15 + i, bit(i))
            setFunction(8, size - 8, true) // The dark module.
        }

        private fun drawVersion() {
            if (version < 7) return
            var remainder = version
            repeat(12) { remainder = (remainder shl 1) xor ((remainder ushr 11) * 0x1F25) }
            val bits = version shl 12 or remainder
            for (i in 0 until 18) {
                val dark = (bits ushr i) and 1 != 0
                val a = size - 11 + i % 3
                val b = i / 3
                setFunction(a, b, dark)
                setFunction(b, a, dark)
            }
        }

        private fun addEccAndInterleave(data: ByteArray): ByteArray {
            val blocks = ERROR_CORRECTION_BLOCKS[ecc.index][version]
            val eccLength = ECC_CODEWORDS_PER_BLOCK[ecc.index][version]
            val raw = rawDataModules(version) / 8
            val shortBlocks = blocks - raw % blocks
            val shortLength = raw / blocks
            val divisor = reedSolomonDivisor(eccLength)
            val all = ArrayList<ByteArray>()
            var offset = 0
            for (i in 0 until blocks) {
                val dataLength = shortLength - eccLength + if (i < shortBlocks) 0 else 1
                val block = data.copyOfRange(offset, offset + dataLength)
                offset += dataLength
                val remainder = reedSolomonRemainder(block, divisor)
                // Short blocks get a hole where the long blocks' extra data byte sits.
                val full = ByteArray(shortLength + 1)
                block.copyInto(full, 0)
                remainder.copyInto(full, shortLength + 1 - eccLength)
                all.add(full)
            }
            val result = ByteArray(raw)
            var k = 0
            for (i in 0..shortLength) {
                for (j in 0 until blocks) {
                    if (i != shortLength - eccLength || j >= shortBlocks) {
                        result[k] = all[j][i]
                        k += 1
                    }
                }
            }
            return result
        }

        private fun drawCodewords(data: ByteArray) {
            var i = 0
            var right = size - 1
            while (right >= 1) {
                if (right == 6) right = 5
                for (vertical in 0 until size) {
                    for (j in 0..1) {
                        val x = right - j
                        val upward = (right + 1) and 2 == 0
                        val y = if (upward) size - 1 - vertical else vertical
                        if (!isFunction[y * size + x] && i < data.size * 8) {
                            set(x, y, ((data[i ushr 3].toInt() ushr (7 - (i and 7))) and 1) != 0)
                            i += 1
                        }
                    }
                }
                right -= 2
            }
        }

        private fun applyMask(mask: Int) {
            for (y in 0 until size) {
                for (x in 0 until size) {
                    val invert = when (mask) {
                        0 -> (x + y) % 2 == 0
                        1 -> y % 2 == 0
                        2 -> x % 3 == 0
                        3 -> (x + y) % 3 == 0
                        4 -> (x / 3 + y / 2) % 2 == 0
                        5 -> x * y % 2 + x * y % 3 == 0
                        6 -> (x * y % 2 + x * y % 3) % 2 == 0
                        else -> ((x + y) % 2 + x * y % 3) % 2 == 0
                    }
                    if (invert && !isFunction[y * size + x]) modules[y * size + x] = !modules[y * size + x]
                }
            }
        }

        private fun penalty(): Int {
            var result = 0
            // Runs of one colour in rows and columns, and finder-like patterns.
            for (y in 0 until size) {
                var runColor = false
                var runX = 0
                val history = IntArray(7)
                for (x in 0 until size) {
                    if (get(x, y) == runColor) {
                        runX += 1
                        if (runX == 5) result += PENALTY_N1 else if (runX > 5) result += 1
                    } else {
                        finderPenaltyAddHistory(runX, history)
                        if (!runColor) result += finderPenaltyCountPatterns(history) * PENALTY_N3
                        runColor = get(x, y)
                        runX = 1
                    }
                }
                result += finderPenaltyTerminateAndCount(runColor, runX, history) * PENALTY_N3
            }
            for (x in 0 until size) {
                var runColor = false
                var runY = 0
                val history = IntArray(7)
                for (y in 0 until size) {
                    if (get(x, y) == runColor) {
                        runY += 1
                        if (runY == 5) result += PENALTY_N1 else if (runY > 5) result += 1
                    } else {
                        finderPenaltyAddHistory(runY, history)
                        if (!runColor) result += finderPenaltyCountPatterns(history) * PENALTY_N3
                        runColor = get(x, y)
                        runY = 1
                    }
                }
                result += finderPenaltyTerminateAndCount(runColor, runY, history) * PENALTY_N3
            }
            // 2×2 blocks of one colour.
            for (y in 0 until size - 1) {
                for (x in 0 until size - 1) {
                    val color = get(x, y)
                    if (color == get(x + 1, y) && color == get(x, y + 1) && color == get(x + 1, y + 1)) result += PENALTY_N2
                }
            }
            // The balance of dark and light.
            val dark = modules.count { it }
            val total = size * size
            val k = (kotlin.math.abs(dark * 20 - total * 10) + total - 1) / total - 1
            result += k * PENALTY_N4
            return result
        }

        private fun finderPenaltyCountPatterns(history: IntArray): Int {
            val n = history[1]
            val core = n > 0 && history[2] == n && history[3] == n * 3 && history[4] == n && history[5] == n
            return (if (core && history[0] >= n * 4 && history[6] >= n) 1 else 0) +
                (if (core && history[6] >= n * 4 && history[0] >= n) 1 else 0)
        }

        private fun finderPenaltyTerminateAndCount(currentRunColor: Boolean, currentRunLength: Int, history: IntArray): Int {
            var length = currentRunLength
            if (currentRunColor) {
                finderPenaltyAddHistory(length, history)
                length = 0
            }
            length += size
            finderPenaltyAddHistory(length, history)
            return finderPenaltyCountPatterns(history)
        }

        private fun finderPenaltyAddHistory(currentRunLength: Int, history: IntArray) {
            var length = currentRunLength
            if (history[0] == 0) length += size
            System.arraycopy(history, 0, history, 1, history.size - 1)
            history[0] = length
        }

        private fun reedSolomonDivisor(degree: Int): ByteArray {
            val result = ByteArray(degree)
            result[degree - 1] = 1
            var root = 1
            for (i in 0 until degree) {
                for (j in result.indices) {
                    result[j] = multiply(result[j].toInt() and 0xFF, root).toByte()
                    if (j + 1 < result.size) result[j] = (result[j].toInt() xor result[j + 1].toInt()).toByte()
                }
                root = multiply(root, 0x02)
            }
            return result
        }

        private fun reedSolomonRemainder(data: ByteArray, divisor: ByteArray): ByteArray {
            val result = ByteArray(divisor.size)
            for (byte in data) {
                val factor = (byte.toInt() xor result[0].toInt()) and 0xFF
                System.arraycopy(result, 1, result, 0, result.size - 1)
                result[result.size - 1] = 0
                for (i in result.indices) result[i] = (result[i].toInt() xor multiply(divisor[i].toInt() and 0xFF, factor)).toByte()
            }
            return result
        }

        private fun multiply(x: Int, y: Int): Int {
            var z = 0
            for (i in 7 downTo 0) {
                z = (z shl 1) xor ((z ushr 7) * 0x11D)
                z = z xor ((y ushr i) and 1) * x
            }
            return z
        }
    }
}
