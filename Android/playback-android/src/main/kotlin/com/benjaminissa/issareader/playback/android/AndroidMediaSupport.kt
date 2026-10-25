package com.benjaminissa.issareader.playback.android

import android.media.MediaCodecList
import android.webkit.MimeTypeMap
import com.benjaminissa.issareader.playback.MediaSupport

/**
 * What this device plays, as its codec list says: [MediaSupport] for
 * [com.benjaminissa.issareader.playback.AudioPlayability].
 *
 * iOS asks AVFoundation whether it plays a MIME type outright. Android has no
 * single question to ask, so this asks the two that decide it: whether
 * ExoPlayer can read the container the type names, and whether the device has
 * a decoder for the audio inside it. Uncompressed PCM needs no decoder at all —
 * the sink plays it directly.
 *
 * Not the same answer as iOS, and deliberately so: Android decodes Opus, so a
 * book from the reader's own files narrated in Opus is narrated here, where
 * the iPhone adds it as text.
 */
class AndroidMediaSupport(
    /** The decoders to ask about; the device's own by default. */
    private val decoders: () -> Set<String> = ::deviceDecoders,
) : MediaSupport {
    private val available: Set<String> by lazy { decoders() }

    override fun isPlayable(mimeType: String): Boolean {
        val type = mimeType.substringBefore(';').trim().lowercase()
        if (type in uncompressed) return true
        val codecs = containers[type] ?: listOf(type)
        return codecs.any { it in available }
    }

    override fun mimeType(extension: String): String? {
        val lowered = extension.lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(lowered) ?: extensions[lowered]
    }

    companion object {
        /** PCM, which the sink plays without a decoder. */
        private val uncompressed = setOf("audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave", "audio/raw")

        /**
         * The containers ExoPlayer's extractors read, by the decoders that can
         * play what is inside them. A type not listed is asked about as itself.
         */
        private val containers: Map<String, List<String>> = mapOf(
            "audio/mpeg" to listOf("audio/mpeg"),
            "audio/mp3" to listOf("audio/mpeg"),
            "audio/mp4" to listOf("audio/mp4a-latm"),
            "audio/x-m4a" to listOf("audio/mp4a-latm"),
            "audio/m4a" to listOf("audio/mp4a-latm"),
            "audio/x-m4b" to listOf("audio/mp4a-latm"),
            "audio/m4b" to listOf("audio/mp4a-latm"),
            "audio/aac" to listOf("audio/mp4a-latm"),
            "audio/aacp" to listOf("audio/mp4a-latm"),
            "audio/ogg" to listOf("audio/opus", "audio/vorbis", "audio/flac"),
            "audio/opus" to listOf("audio/opus"),
            "audio/webm" to listOf("audio/opus", "audio/vorbis"),
            "audio/flac" to listOf("audio/flac"),
            "audio/x-flac" to listOf("audio/flac"),
            "audio/amr" to listOf("audio/3gpp"),
            "audio/3gpp" to listOf("audio/3gpp"),
        )

        /** What the MIME map may not know, for the extensions narration comes in. */
        private val extensions: Map<String, String> = mapOf(
            "mp3" to "audio/mpeg",
            "m4a" to "audio/mp4",
            "m4b" to "audio/mp4",
            "mp4" to "audio/mp4",
            "aac" to "audio/aac",
            "ogg" to "audio/ogg",
            "oga" to "audio/ogg",
            "opus" to "audio/opus",
            "flac" to "audio/flac",
            "wav" to "audio/wav",
            "webm" to "audio/webm",
        )

        /** Every MIME type a decoder on this device accepts, lowercased. */
        fun deviceDecoders(): Set<String> = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
            .filter { !it.isEncoder }
            .flatMap { it.supportedTypes.map(String::lowercase) }
            .toSet()
    }
}
