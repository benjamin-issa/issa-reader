package com.benjaminissa.issareader.app.ask

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.benjaminissa.issareader.ask.AskAnswer
import com.benjaminissa.issareader.ask.AskFailure
import com.benjaminissa.issareader.ask.AskPhase
import com.benjaminissa.issareader.ask.BookSource
import com.benjaminissa.issareader.ask.ReadingBoundary
import kotlinx.coroutines.Job

/**
 * One question about one book, and everything the sheet draws from it.
 *
 * It outlives the sheet on purpose. A first question about a long book on a
 * phone can take half a minute, and a reader who closes the sheet to carry on
 * reading — or leaves the app altogether — should come back to an answer
 * rather than to a blank field. So the job belongs to [AskCoordinator], which
 * lives above the reader, and the sheet is only a view of it.
 *
 * Observable (Compose snapshot state) and main-thread only, as the Swift class
 * is `@Observable @MainActor`.
 */
class AskJob(
    val bookUuid: String,
    val question: String,
    /**
     * The boundary the answer was actually bounded by, captured when the
     * question was asked. The footer names this and not wherever the reader
     * has turned to since.
     */
    val boundary: ReadingBoundary,
    /**
     * What the notification calls the book, when the answer finishes with
     * nobody looking at it.
     *
     * Carried by value beside the boundary and for the same reason: the job
     * outlives the reader screen, and `AppModel.readerDidClose` evicts the
     * `ReaderModel` this came from the moment the screen goes away.
     */
    val bookTitle: String? = null,
) {
    /**
     * Where the job has got to. `Working` carries the phase so the sheet can
     * say "Reading what you've read…" rather than showing a bare spinner for
     * eight seconds.
     */
    sealed interface State {
        data class Working(val phase: AskPhase) : State
        data class Answered(val answer: AskAnswer) : State
        data class Failed(val failure: AskFailure) : State

        val isWorking: Boolean get() = this is Working
        val isAnswered: Boolean get() = this is Answered
    }

    var state: State by mutableStateOf(State.Working(AskPhase.Thinking))

    /** The answer so far, already stripped of a half-typed `Sources:` line. */
    var partial: String by mutableStateOf("")

    /**
     * Whether the reader has been promised a notification about this answer.
     *
     * Named for what it means rather than for the one thing that used to set
     * it. Closing the sheet on a running question is one way to stop watching
     * it; leaving the app altogether is the other.
     */
    var owesNotification: Boolean by mutableStateOf(false)

    /**
     * Whether this question is waiting for the app to come back to the
     * foreground — Android's own case, with no Swift counterpart.
     *
     * Gemini Nano answers only for the app on screen: AICore refuses a
     * generation from the background (`BACKGROUND_USE_BLOCKED`), even from a
     * foreground service. The index is the app's own and goes on building
     * behind the reader's back; the generation cannot. So a question that
     * reaches the model with the app away fails with
     * [AskFailure.BackgroundBlocked], whose sentence promises "Your question
     * will be answered when you come back" — and this is the flag that keeps
     * the promise: the coordinator asks it again when the app returns.
     */
    var isHeld: Boolean by mutableStateOf(false)
        internal set

    /**
     * Whether the job is still going to produce something without the reader
     * doing anything: working, or held for the foreground. What decides that
     * a closed sheet keeps the job, and that the sparkle pulses.
     */
    val isPending: Boolean get() = state.isWorking || isHeld

    /** The pipeline, so `cancel` has something to cancel. */
    var task: Job? = null
        internal set

    /** The file the question was asked of, kept so a held question can be asked again with no reader open. */
    internal var source: BookSource? = null

    /**
     * Whether this job is the automatic re-asking of a held one. A re-asked
     * question that is blocked again while the app is in front is held for
     * the next return rather than re-asked at once, so the two can never
     * chase each other.
     */
    internal var isResumption: Boolean = false

    /**
     * What the status line says while the answer is being worked out.
     *
     * Two sentences for four phases, because the reader does not care which
     * index is being built — they care whether the app is reading or thinking.
     */
    val phaseLine: String?
        get() {
            val working = state as? State.Working ?: return null
            return when (working.phase) {
                is AskPhase.PreparingIndex, AskPhase.Retrieving -> "Reading what you've read…"
                AskPhase.Thinking, AskPhase.Answering -> "Thinking…"
            }
        }
}
