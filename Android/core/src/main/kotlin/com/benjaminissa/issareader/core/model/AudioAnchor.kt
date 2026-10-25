package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.instantOfEpochSeconds
import java.time.Instant

/**
 * Where playback is, said in the one language both engines speak: an audio
 * file, and how far into it.
 *
 * One book has two playback engines here. `ReadalongCoordinator` drives
 * narration against the EPUB's media overlay; `AudiobookCoordinator` drives
 * the server's track list. They keep **different clocks** — the read-along's
 * is a running sum of *clip* durations, the audiobook's a running sum of
 * *file* durations — and `totalProgression` had been carrying whichever of
 * them wrote last, on the assumption that a fraction is a fraction.
 *
 * It is not. *The Hero of Ages* has 109 spine items and 85 narrated ones: the
 * title page, the copyright notice, the maps and every "Part One" divider
 * carry text and no audio. So a text fraction always understates the audio
 * fraction, and resuming a 27-hour audiobook from a reading position landed
 * tens of minutes early — "wildly off, too early", from the car.
 *
 * A fraction cannot bridge that. A file name and a number of seconds can: the
 * read-along reads them off the media-overlay entry it is speaking
 * (`SmilEntry.audioHref` and `start`), the audiobook off the track it is
 * playing, and either can seek to the other's. That is the whole of this type,
 * and it is why switching format mid-book can be exact rather than
 * approximate.
 *
 * A plain class rather than a `data class`, so that the clamp on [offset]
 * cannot be stepped round by a `copy`. Not serialisable: the Swift type is
 * `Codable`, but nothing encodes one — the store keeps its three columns — so
 * there is no wire shape to keep.
 */
class AudioAnchor(
    /**
     * The audio file, as whichever side wrote it names it.
     *
     * Kept verbatim rather than normalised on the way in, because the two
     * sides genuinely have different names for the same file and normalising
     * would throw away the evidence of which wrote it. Matching normalises
     * instead — see [AudiobookManifest.trackIndex].
     */
    val audioHref: String,
    offset: Double,
    /**
     * Seconds since the epoch. A stale anchor must lose to a fresh one: both
     * engines write these, and the last one to play is the one that knows
     * where the listener is.
     */
    val writtenAt: Double,
) {
    /**
     * Seconds into that file.
     *
     * Non-finite offsets have reached seeks in this app before and been
     * persisted as a chosen position; refuse them at the door.
     */
    val offset: Double = if (offset.isFinite()) maxOf(0.0, offset) else 0.0

    /**
     * Whether this anchor was written after some other moment — the instant a
     * reading position was stored, in practice.
     *
     * Against an instant rather than against another anchor. The anchor-versus-
     * anchor rule already ships, in SQL, in `LibraryStore.setAudioAnchor`'s
     * `WHERE excluded.writtenAt > audioAnchor.writtenAt`; a Kotlin twin of it
     * would be a second definition of one rule, free to drift from the one
     * that actually decides what is on disk. The question that had no answer
     * anywhere was the other one: an anchor is a *place*, a stored position is
     * a *place*, and until now the resume ladder trusted the anchor however
     * long ago it was written. Narrate to 0.20, relaunch, read on in silence
     * to 0.70, press Listen — and the car resumed at 0.20 and then wrote that
     * over the 0.70.
     *
     * An [Instant] rather than a bare `Double`, because the two numbers being
     * compared are in different units: this one is epoch seconds and
     * `StoredPosition.timestamp` is epoch milliseconds. See
     * `StoredPosition.writtenAt`.
     *
     * Strictly newer, and nothing rides on the tie: both writers stamp the
     * anchor *after* the position it belongs to, so an anchor that is merely
     * equal has already lost a race it was never in.
     */
    fun isNewerThan(instant: Instant?): Boolean {
        if (instant == null) return true
        return instantOfEpochSeconds(writtenAt).isAfter(instant)
    }

    override fun equals(other: Any?): Boolean =
        other is AudioAnchor && other.audioHref == audioHref && other.offset == offset && other.writtenAt == writtenAt

    override fun hashCode(): Int = (audioHref.hashCode() * 31 + offset.hashCode()) * 31 + writtenAt.hashCode()

    override fun toString(): String = "AudioAnchor(audioHref=$audioHref, offset=$offset, writtenAt=$writtenAt)"
}
