package com.benjaminissa.issareader.playback.android

import android.os.Handler
import android.os.Looper
import androidx.media3.common.util.Clock
import androidx.media3.test.utils.robolectric.RobolectricUtil
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.coroutines.CoroutineContext
import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin

/** The main thread, as a dispatcher that posts: the shape the app's `Dispatchers.Main` has. */
internal object MainLooper : CoroutineDispatcher() {
    private val handler by lazy { Handler(Looper.getMainLooper()) }

    override fun dispatch(context: CoroutineContext, block: Runnable) {
        handler.post(block)
    }
}

/** A scope on the main thread, for the coordinators' hops. */
internal fun mainScope(): CoroutineScope = CoroutineScope(SupervisorJob() + MainLooper)

/**
 * Runs [block] on the main thread and turns the main looper until it is done,
 * so the engine's own callbacks — which arrive on that looper — are delivered
 * meanwhile.
 */
internal fun <T> onMain(clock: Clock? = null, timeoutMillis: Long = 20_000, block: suspend CoroutineScope.() -> T): T {
    val deferred = mainScope().async { block() }
    if (clock != null) {
        RobolectricUtil.runMainLooperUntil({ deferred.isCompleted }, timeoutMillis, clock)
    } else {
        RobolectricUtil.runMainLooperUntil(timeoutMillis) { deferred.isCompleted }
    }
    deferred.getCompletionExceptionOrNull()?.let { throw it }
    @Suppress("OPT_IN_USAGE")
    return deferred.getCompleted()
}

/** Turns the main looper until [condition] holds, or fails after [timeoutMillis]. */
internal fun runUntil(clock: Clock? = null, timeoutMillis: Long = 20_000, condition: () -> Boolean) {
    if (clock != null) {
        RobolectricUtil.runMainLooperUntil({ condition() }, timeoutMillis, clock)
    } else {
        RobolectricUtil.runMainLooperUntil(timeoutMillis) { condition() }
    }
}

/**
 * A 16-bit PCM WAVE file: [seconds] of a sine at [amplitude] of full scale, or
 * of silence at zero.
 */
internal fun wav(
    file: File,
    seconds: Double,
    sampleRate: Int = 8_000,
    amplitude: Double = 0.0,
    frequency: Double = 440.0,
): File {
    val samples = (seconds * sampleRate).roundToInt()
    val buffer = ByteBuffer.allocate(44 + samples * 2).order(ByteOrder.LITTLE_ENDIAN)
    buffer.put("RIFF".toByteArray()).putInt(36 + samples * 2).put("WAVE".toByteArray())
    buffer.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1)
        .putInt(sampleRate).putInt(sampleRate * 2).putShort(2).putShort(16)
    buffer.put("data".toByteArray()).putInt(samples * 2)
    for (index in 0 until samples) {
        val value = amplitude * sin(2 * PI * frequency * index / sampleRate)
        buffer.putShort((value * 32767).roundToInt().toShort())
    }
    file.writeBytes(buffer.array())
    return file
}

/**
 * A silent MP3: [frames] MPEG-1 Layer III frames at 128 kbps and 44.1 kHz,
 * each a header and a zeroed body — empty side information, which decodes to
 * silence. 1152 samples a frame.
 */
internal fun silentMp3(file: File, frames: Int): File {
    val frame = ByteArray(417)
    frame[0] = 0xFF.toByte()
    frame[1] = 0xFB.toByte()
    frame[2] = 0x90.toByte()
    frame[3] = 0x00
    file.outputStream().use { out -> repeat(frames) { out.write(frame) } }
    return file
}

/** The length of [frames] MPEG-1 Layer III frames at 44.1 kHz. */
internal fun mp3Seconds(frames: Int): Double = frames * 1152.0 / 44_100.0
