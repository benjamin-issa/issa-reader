package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.SmilEntry
import com.benjaminissa.issareader.epub.SmilTimeline

/**
 * Whether the car's engine should hand the book back to the reader on screen,
 * and — just as important — why it should not.
 *
 * Two engines play one book. [AudiobookCoordinator] is what Android Auto, the
 * lock screen and the Listen button start; for a downloaded read-along it plays
 * the EPUB's own narration chunks, so it knows exactly where it is but has no
 * highlight and no page. [ReadalongCoordinator] is what the reader's text
 * follows. They are exclusive — two players would put two voices in the room —
 * so coming back to the phone after a drive used to leave the page sitting
 * where it was an hour ago while the car engine narrated on through the
 * speaker.
 *
 * Lifted out of the app model for the reason [ListeningResume] was: the
 * decision is a ladder over facts, every rung of it is a case someone hit, and
 * a ladder buried in a method that needs a car, a car session and a downloaded
 * novel to reach is a ladder nothing tests. The rungs are ordered so the first
 * failure is the most useful thing to say — "the car is still connected" is a
 * different situation from "this reader has no narration yet", and a log line
 * naming the wrong one sends the next person looking in the wrong place.
 *
 * [place] is the same mapping the reader does when a book is opened cold after
 * a drive: the anchor names an audio file and an offset, and only the media
 * overlay can say which sentence of which chapter that is. One copy, so the two
 * directions of the same bridge cannot drift apart.
 */
object ListeningHandoff {
    /**
     * What woke the decision up. Carried only so the log can say which — they
     * arrive in different circumstances and a hand-off that only ever fires
     * from one of them is a hand-off that is half wired up.
     */
    enum class Trigger(val rawValue: String) {
        /** A reader appeared, or came back to the front of the stack. */
        READER_VISIBLE("readerVisible"),

        /** The phone was picked up and the app came back to the foreground. */
        FOREGROUND("foreground"),

        /**
         * A reader finished extracting its narration, which on a cold open
         * happens well after the screen appeared.
         */
        READER_READY("readerReady"),

        /** The car went away. Until it does the driver is still listening. */
        CAR_DISCONNECTED("carDisconnected"),

        /**
         * The listener named a place, and the held audio clock let go.
         *
         * [Skip.RESUME_UNRESOLVED] holds the book with the car playing on and
         * the reader left where it was, and its own note promises that the
         * listener's first scrub releases the hold and the next trigger hands
         * the book over normally. There was no next trigger. By the time a scrub
         * happens the reader is already visible and the app already frontmost,
         * so [READER_VISIBLE], [FOREGROUND] and [READER_READY] have all fired and
         * gone, and [CAR_DISCONNECTED] is what ended the drive in the first
         * place. The book sat on the wrong page for the rest of the session.
         */
        LISTENER_STEERED("listenerSteered"),

        /**
         * A start finished while a reader was already open on that book.
         *
         * The other end of the same race the re-entrancy guards exist for: a
         * listener pressing Listen from the book they have open, or a start
         * that began before the reader appeared and landed after it. Every
         * other trigger fires *before* the engine exists, so the decision they
         * woke found nothing playing and skipped [Skip.NOT_LISTENING].
         */
        LISTENING_STARTED("listeningStarted"),
    }

    /**
     * Why nothing was handed over. Every one of these is an ordinary state, not
     * an error — the decision runs on several triggers and most of the time
     * there is simply nothing to move.
     */
    enum class Skip(val rawValue: String) {
        /** No audiobook engine is playing anything. */
        NOT_LISTENING("notListening"),

        /** No reader on screen to hand it to. */
        NO_VISIBLE_READER("noVisibleReader"),

        /**
         * The reader on screen is a different book from the one playing, which
         * is a listener browsing while the audiobook runs — not a hand-off.
         */
        DIFFERENT_BOOK("differentBook"),

        /**
         * The car is still connected. This is the one rung that exists for a
         * person rather than for the code: the phone in a pocket at 70mph must
         * not silently take the book off the dashboard.
         */
        CAR_CONNECTED("carConnected"),

        /**
         * The app is not frontmost. Being backgrounded does not dismiss the
         * reader, so a visible reader alone would fire this while the phone was
         * in a pocket.
         */
        BACKGROUND("background"),

        /**
         * The audiobook is playing from a place nobody could resolve, so its
         * clock is held and the anchor it offers is not a fact about the book.
         *
         * [ListeningResume] matched nothing — a stored position on the *text*
         * clock naming the server's own upload, against a manifest synthesised
         * over the EPUB's chunks — so playback began at zero and the listening
         * guard armed the audio clock. Chunk one at offset zero is an honest
         * answer about the audio and no answer at all about the novel: [place]
         * resolves it to the overlay's first sentence, and the reader would then
         * save that page on the *text* clock, which the hold never covered. That
         * is the loss this exists to prevent, reached through the other clock.
         *
         * Skipping leaves the reader on the page it has and the car playing on
         * from where it started, with the stored position intact. The listener's
         * first scrub releases the hold, and the next trigger hands the book
         * over normally.
         */
        RESUME_UNRESOLVED("resumeUnresolved"),

        /**
         * The reader has not finished opening the book, or the book has no
         * narration to hand to. Nothing to aim at yet; [Trigger.READER_READY]
         * brings the decision back when there is.
         */
        READER_NOT_READY("readerNotReady"),

        /** The engine has not played anything, so it has no place to hand over. */
        NO_ANCHOR("noAnchor"),

        /**
         * The anchor names an audio file this book's overlay has never heard of
         * — the server's single upload against the EPUB's own chunks. The same
         * mismatch [ListeningResume.Reason.ANCHOR_NAMES_UNKNOWN_FILE] describes
         * from the other side.
         */
        ANCHOR_NAMES_NO_FILE("anchorNamesNoFile"),

        /**
         * A hand-off is already running. The triggers overlap — waking the
         * phone onto an open reader fires three of them — and a second pass
         * while the first is awaiting its audio load would stop the engine out
         * from under it.
         */
        ALREADY_HANDING_OFF("alreadyHandingOff"),

        /**
         * The read-along refused to move: the sentence's audio file is not on
         * disk. Decided by the caller after the fact rather than by [decide],
         * which cannot know what is extracted.
         */
        AUDIO_FILE_MISSING("audioFileMissing"),

        /**
         * The book left the listening slot while the read-along was loading.
         * Decided by the caller after the fact, like [AUDIO_FILE_MISSING], and
         * for the same reason: [decide] runs before the suspension that makes
         * this possible.
         *
         * Loading a chapter's audio takes long enough for a removal, a sign-out
         * or a second book's start to land in the middle of it. What the
         * hand-off must not then do is finish: it would give the book back to an
         * engine that no longer holds it and re-arm the fifteen-second writer
         * for the evicted pair, and the progress watcher opens by cancelling
         * that task — so the writer the *new* book had just armed would go with
         * it, and an hour of listening after that would be written nowhere.
         */
        SLOT_CHANGED_HANDS("slotChangedHands"),
    }

    /**
     * Where the reader has to pick the book up.
     *
     * [wasPlaying] is the whole difference between the two shapes of this: a
     * driver who parked mid-sentence expects the phone to carry on, and one who
     * pressed pause at the door expects a quiet room with the right page in it.
     */
    data class Target(
        /** Which spine item the sentence lives in, so the reader can load it. */
        val spineIndex: Int,
        /** The sentence itself, in the terms the read-along engine acts on. */
        val entry: SmilEntry,
        /**
         * The anchor it was placed from, kept for the log: it is the only thing
         * that says how far into the file the car actually was.
         */
        val anchor: AudioAnchor,
        /** Whether the car engine was audible at the moment of the hand-off. */
        val wasPlaying: Boolean,
    )

    sealed interface Decision {
        data class HandOff(val target: Target) : Decision
        data class Skipped(val skip: Skip) : Decision
    }

    /** A sentence and the spine item it lives in. */
    data class Placement(val spineIndex: Int, val entry: SmilEntry)

    /**
     * Runs the ladder. First failing rung names the reason.
     *
     * Every input is passed in rather than read from a model, so the whole
     * decision is a function of ten facts and the cases that matter — the car
     * still connected, the phone still in a pocket, a reader open on a
     * different book — can be stated in a test instead of staged in a car.
     *
     * @param resumeWasUnresolved whether this listening session started from a
     *   place [ListeningResume] could not find, which is the same thing as "the
     *   audio clock is held". A fact about the book rather than about the
     *   reader, so it is asked before [Skip.READER_NOT_READY]: a reader that
     *   finishes opening a moment later changes nothing about it.
     */
    fun decide(
        listeningBookUuid: String?,
        visibleBookUuid: String?,
        surface: ControlSurface,
        isForeground: Boolean,
        resumeWasUnresolved: Boolean,
        anchor: AudioAnchor?,
        isPlaying: Boolean,
        epubPackage: EpubPackage?,
        timeline: SmilTimeline?,
        hasReadalong: Boolean,
    ): Decision {
        if (listeningBookUuid == null) return Decision.Skipped(Skip.NOT_LISTENING)
        if (visibleBookUuid == null) return Decision.Skipped(Skip.NO_VISIBLE_READER)
        if (visibleBookUuid != listeningBookUuid) return Decision.Skipped(Skip.DIFFERENT_BOOK)
        if (surface == ControlSurface.CAR) return Decision.Skipped(Skip.CAR_CONNECTED)
        if (!isForeground) return Decision.Skipped(Skip.BACKGROUND)
        if (resumeWasUnresolved) return Decision.Skipped(Skip.RESUME_UNRESOLVED)
        if (epubPackage == null || timeline == null || !hasReadalong) return Decision.Skipped(Skip.READER_NOT_READY)
        if (anchor == null) return Decision.Skipped(Skip.NO_ANCHOR)
        val placed = place(anchor, epubPackage, timeline) ?: return Decision.Skipped(Skip.ANCHOR_NAMES_NO_FILE)
        return Decision.HandOff(Target(placed.spineIndex, placed.entry, anchor, isPlaying))
    }

    /**
     * Turns an audio position into a sentence and the chapter it is in.
     *
     * The media overlay is the bridge — the anchor names a file and an offset,
     * and the timeline says which sentence that is. Falling back to the file's
     * first entry when the offset lands before its first clip: the file still
     * names the chapter exactly, and only the sentence within it is
     * approximate. Landing nowhere at all would be worse, and it is the case a
     * chunk whose first clip starts a beat in produces every time.
     *
     * The spine index goes through `ReadiumLocator.matchesHref` rather than a
     * string comparison because the overlay and the OPF spell the same resource
     * differently often enough to matter.
     */
    fun place(anchor: AudioAnchor, epubPackage: EpubPackage, timeline: SmilTimeline): Placement? {
        val entry = timeline.entryInFile(anchor.audioHref, anchor.offset)
            ?: timeline.firstEntryInFile(anchor.audioHref)
            ?: return null
        val index = ReadiumLocator(href = entry.textHref, type = "application/xhtml+xml")
            .bestMatch(epubPackage.spine.map { it.href })
            ?: return null
        return Placement(index, entry)
    }
}
