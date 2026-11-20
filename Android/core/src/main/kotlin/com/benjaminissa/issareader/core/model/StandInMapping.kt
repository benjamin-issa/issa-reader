package com.benjaminissa.issareader.core.model

import kotlin.math.max

/**
 * Where a second in a downloaded audiobook's own file falls in the server's
 * track list, for the offline stand-in that plays the whole file as one track.
 *
 * The one pure function every caller shares: the listening writer, the
 * conversion of a device-only place once the manifest is known, and the resume.
 */
object StandInMapping {
    /** A place in the server's manifest: the track as it names it, and the offset into it. */
    data class Place(
        val trackIndex: Int,
        val track: AudiobookManifest.Track,
        val offset: Double,
        /** The fraction of the whole book, as a streamed session would write it. */
        val totalProgression: Double,
    )

    /** How far the kept manifest's total may be from the file's measured length: max(2 s, 0.5%). */
    fun tolerance(seconds: Double): Double = max(2.0, seconds * 0.005)

    /** Whether the kept manifest's total matches the file's measured length within [tolerance]. */
    fun describes(kept: AudiobookManifest, fileLength: Double): Boolean {
        val total = kept.playableTracks.sumOf { it.duration ?: 0.0 }
        return fileLength.isFinite() && fileLength > 0 && total > 0 && kotlin.math.abs(total - fileLength) <= tolerance(fileLength)
    }

    /**
     * Maps [fileSeconds] into the file onto the kept manifest's playable tracks,
     * in order, by cumulative duration. Null when there is no kept manifest, when
     * its total does not match the file's measured length [fileLength] — the
     * file is then not the audio the tracks describe — or when a number is not
     * finite. A one-track manifest maps to itself.
     */
    fun locate(kept: AudiobookManifest?, fileSeconds: Double, fileLength: Double): Place? {
        if (kept == null || !fileSeconds.isFinite() || !fileLength.isFinite() || fileLength <= 0) return null
        if (!describes(kept, fileLength)) return null
        val total = kept.playableTracks.sumOf { it.duration ?: 0.0 }
        val located = kept.locate(fileSeconds) ?: return null
        val track = kept.playableTracks[located.index]
        val progression = (fileSeconds / total).coerceIn(0.0, 1.0)
        return Place(located.index, track, located.offset, progression)
    }
}
