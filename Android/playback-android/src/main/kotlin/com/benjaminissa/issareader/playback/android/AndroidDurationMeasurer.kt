package com.benjaminissa.issareader.playback.android

import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import com.benjaminissa.issareader.playback.AudioFileLength
import com.benjaminissa.issareader.playback.DurationMeasurer
import java.io.File

/**
 * One file's true length, on Android: [DurationMeasurer] for
 * [com.benjaminissa.issareader.playback.ChunkDurations.measure].
 *
 * MPEG audio and WAVE first, through [AudioFileLength], which counts frames.
 * That is the measurement iOS gets from AVFoundation's precise timing, and the
 * one the platform's own extractor does not make: asked for an MP3's length it
 * divides the file's size by its bitrate, and over a hundred and seventy-six
 * chunks those small errors sum into a book clock that disagrees with the
 * audio. Everything else — an M4A, an Ogg — states its length in its container,
 * and the extractor reads that exactly; the metadata retriever is the last
 * resort.
 *
 * Blocking, and called off the main thread.
 */
class AndroidDurationMeasurer : DurationMeasurer {
    override fun duration(file: File): Double? =
        AudioFileLength.duration(file) ?: extracted(file) ?: retrieved(file)

    private fun extracted(file: File): Double? {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(file.path)
            var longest: Long? = null
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("audio/") || !format.containsKey(MediaFormat.KEY_DURATION)) continue
                val micros = format.getLong(MediaFormat.KEY_DURATION)
                if (micros > 0 && (longest == null || micros > longest)) longest = micros
            }
            longest?.let { it / 1_000_000.0 }
        } catch (_: Exception) {
            null
        } finally {
            extractor.release()
        }
    }

    private fun retrieved(file: File): Double? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.path)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                ?.takeIf { it > 0 }
                ?.let { it / 1000.0 }
        } catch (_: Exception) {
            null
        } finally {
            retriever.release()
        }
    }
}
