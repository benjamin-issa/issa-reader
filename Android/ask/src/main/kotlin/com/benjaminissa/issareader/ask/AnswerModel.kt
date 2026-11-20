package com.benjaminissa.issareader.ask

import kotlinx.coroutines.flow.Flow

/**
 * The one thing [AskEngine] needs from a language model.
 *
 * An interface rather than a direct call into the platform's model, for two
 * reasons that are both about being able to prove the feature is safe. The
 * model is unavailable on most machines, so the pipeline would otherwise be
 * untestable on the JVM; and the spoiler defence — the boundary, the trimming,
 * the short-circuit, the retry — is exactly the part that must be tested
 * deterministically, which a real model cannot be.
 *
 * Deliberately narrow: a string in, a stream of strings out. On Android the
 * implementation is `GeminiNanoAnswerModel` in `:ask-android`, over ML Kit's
 * Prompt API; the tests use [ScriptedAnswerModel].
 */
interface AnswerModel {
    /**
     * Streamed answer text. Each element is the answer *so far*, not a delta —
     * the shape Apple's `streamResponse` produces, and the shape the Android
     * model accumulates its chunks into, so the engine reads one convention.
     */
    fun answer(
        instructions: String,
        prompt: String,
        tools: List<AskTool>,
        options: AskGenerationOptions,
    ): Flow<String>

    /**
     * The model's own count, used to pack the prompt to the byte. Falls back
     * to an estimate when the model cannot be asked.
     */
    suspend fun tokenCount(text: String): Int

    /**
     * Total window for instructions, prompt, tool schemas, tool output and the
     * answer together.
     */
    val contextSize: Int

    /** Warms the model up while the reader is still typing. */
    suspend fun prewarm()

    /**
     * Whether the model can answer about a book written in this language.
     *
     * Pre-flighted from the package's `dc:language` before a question is
     * sent, because an unsupported language otherwise fails after the reader
     * has watched a spinner for eight seconds — and it is the one failure that
     * will never come right on a retry.
     *
     * A model that has no opinion about languages answers about any book: the
     * scripted model in the tests.
     */
    fun supportsLanguage(bcp47: String?): Boolean = true

    /** Which model this is, for the log and the scorecard — never for a reader. */
    val modelDescription: String get() = "an answer model"

    /**
     * The sentence for a generation that produced nothing usable, naming who
     * could not answer: Gemini Nano by default, the company for a reader's own
     * provider. The engine says it when an answer comes back with no prose.
     */
    val couldNotAnswer: String get() = AskFailure.couldNotAnswer
}

/**
 * A tool the model may call, in terms the engine can hold without knowing the
 * platform's model API.
 *
 * Android's Prompt API has no tool calling, so nothing in the app ever passes
 * one: [AskEngine.usesSearchTool] is false and [AskEngine.forQuestion] builds
 * no tools. The interface stays because the engine's merge of what a tool
 * showed into the citations is part of the shared pipeline, and a test still
 * drives it — on a later model that can call tools, this is the seam.
 */
interface AskTool {
    val name: String
    val toolDescription: String

    /**
     * How many times this tool may be called for one question, after which it
     * answers with a refusal rather than more of the book.
     */
    val callLimit: Int

    /**
     * Called immediately before each generation, and nowhere else: the call
     * budget and the numbering both reset per generation, and the tool's
     * excerpts continue the prompt's numbering.
     */
    suspend fun beginGeneration(numberingFrom: Int) {}

    /**
     * The excerpts this tool handed the model during the last generation, by
     * the ordinal it numbered them with. A tool that answers nothing here is a
     * tool whose excerpts can be cited and never shown.
     */
    suspend fun passagesShown(): Map<Int, Passage> = emptyMap()
}

/**
 * What the engine asks the model to do with its sampler.
 *
 * The same question about the same book must give the same answer twice, or a
 * reader who asks again after a wrong answer cannot tell whether anything
 * changed. Greedy gets that for free. Sampling gets it from a seed, and only
 * from a seed — which is why [Sampling.Nucleus] has no form without one.
 */
data class AskGenerationOptions(
    val maximumResponseTokens: Int = 250,
    val temperature: Double = 0.0,
    val sampling: Sampling = Sampling.Greedy,
    /**
     * How hard a model that can reason should think. Gemini Nano cannot, and
     * ignores it; a reader's own provider sends it as its effort setting where
     * the model takes one.
     */
    val reasoning: Reasoning? = null,
    /**
     * How much of the start of the prompt, in UTF-16 units, stays the same
     * from one question to the next at this place in the book — everything
     * read before the chapter the reader is in. A provider that caches a
     * prompt's prefix marks the cache there; every other model ignores it.
     */
    val cacheablePrefix: Int? = null,
) {
    /** How hard a model that can reason should think. */
    enum class Reasoning { LIGHT, MODERATE, DEEP }

    /** How the model picks its next token. */
    sealed interface Sampling {
        /** The likeliest token, every time. */
        data object Greedy : Sampling

        /**
         * Nucleus sampling, with a fixed seed.
         *
         * The seed is not an optimisation, it is the product. Sampling without
         * one turns "ask again" into a coin toss dressed up as a second
         * opinion.
         */
        data class Nucleus(val probabilityThreshold: Double, val seed: ULong) : Sampling
    }
}

/** What the engine is doing, for the sheet's status line. */
sealed interface AskPhase {
    /**
     * Building the per-book index, with a chapter count so a long illustrated
     * book can show progress rather than an indefinite spinner.
     */
    data class PreparingIndex(val done: Int, val total: Int) : AskPhase

    /** Searching what has been read. */
    data object Retrieving : AskPhase

    /** Waiting on the model, before any text has arrived. */
    data object Thinking : AskPhase

    /** Text is arriving. */
    data object Answering : AskPhase
}

/** One thing that happened while answering. */
sealed interface AskEvent {
    data class Phase(val phase: AskPhase) : AskEvent

    /**
     * The answer so far, already passed through [AskAnswerParser.visible] so a
     * half-typed `Sources:` line never reaches the screen.
     */
    data class Partial(val text: String) : AskEvent

    data class Answered(val answer: AskAnswer) : AskEvent
}

/**
 * Where a question is answered.
 *
 * Gemini Nano on the phone, unless the reader registered a key of their own
 * in Settings › Advanced and chose that provider for the question. Android
 * has no counterpart to Apple's servers.
 */
enum class AskAnswerer(val rawValue: String) {
    /** Gemini Nano, on this phone: nothing leaves it. */
    DEVICE("device"),

    /**
     * Anthropic, with a key the reader registered themselves. The question
     * and the passages are sent to Anthropic under the reader's own account.
     */
    ANTHROPIC("anthropic"),

    /** OpenAI, with the reader's own key, on the same terms. */
    OPENAI("openai"),
    ;

    /** The name a reader knows each place by, for the sentences that say who could not answer. */
    val placeName: String
        get() = when (this) {
            DEVICE -> AskFailure.ASSISTANT
            ANTHROPIC -> ProviderKind.ANTHROPIC.displayName
            OPENAI -> ProviderKind.OPENAI.displayName
        }

    /** The reader's own provider this answerer is, if it is one. */
    val provider: ProviderKind?
        get() = when (this) {
            DEVICE -> null
            ANTHROPIC -> ProviderKind.ANTHROPIC
            OPENAI -> ProviderKind.OPENAI
        }

    companion object {
        fun of(provider: ProviderKind): AskAnswerer = when (provider) {
            ProviderKind.ANTHROPIC -> ANTHROPIC
            ProviderKind.OPENAI -> OPENAI
        }
    }
}

/**
 * Why an answer did not arrive, and what to tell the reader.
 *
 * The messages are the product here, so they live beside the cases rather than
 * in the view: every one of them has to say what happened, whether it is worth
 * trying again, and — where the answer is "turn something on" — where.
 *
 * The Swift cases are all here, worded for Android: the model is Gemini Nano
 * and the system is Android. Three are new, because ML Kit says three things
 * Apple's framework does not: a per-app quota ([QuotaExceeded]), a refusal to
 * run while the app is in the background ([BackgroundBlocked]), and a system
 * too old for the model ([NeedsSystemUpdate]).
 */
sealed class AskFailure(message: String) : Exception(message) {
    /** The model refused, or its safety filter did. */
    data object Declined : AskFailure("declined")

    /** Busy, or asked twice at once. */
    data object Busy : AskFailure("busy")

    /** The model is still downloading. */
    data object ModelDownloading : AskFailure("model downloading")

    /** The book is in a language the model does not support. */
    data object UnsupportedLanguage : AskFailure("unsupported language")

    /** The prompt would not fit even after both retries. */
    data object TooMuchContext : AskFailure("too much context")

    /** The model gave up before it finished: the advice is "try again", not "wait". */
    data object TimedOut : AskFailure("timed out")

    /** The device or the system cannot run the model at all. */
    data object Unavailable : AskFailure("unavailable")

    /** The index could not be built or read. */
    data object IndexFailed : AskFailure("index failed")

    /** The system suspended the app before the answer finished. */
    data object BackgroundExpired : AskFailure("background expired")

    /**
     * ML Kit's `PER_APP_BATTERY_USE_QUOTA_EXCEEDED`: this app has asked the
     * model a great deal recently, and the system is making it wait. Not the
     * reader's doing and not permanent — "try again shortly".
     */
    data object QuotaExceeded : AskFailure("quota exceeded")

    /**
     * ML Kit's `BACKGROUND_USE_BLOCKED`: the model only runs for an app in the
     * foreground. Distinct from [BackgroundExpired] because the fix is not to
     * ask again but to come back: the app holds the question and asks it when
     * it is on screen again.
     */
    data object BackgroundBlocked : AskFailure("background use blocked")

    /** ML Kit's `NEEDS_SYSTEM_UPDATE` and `AICORE_INCOMPATIBLE`: the system's AI service is too old. */
    data object NeedsSystemUpdate : AskFailure("needs system update")

    /**
     * The reader's provider refused their key: revoked, mistyped, or not
     * allowed to use this model.
     */
    data object KeyRefused : AskFailure("key refused")

    /**
     * The reader's provider account has no credit left, or has reached a
     * spending limit the reader set.
     */
    data object OutOfCredit : AskFailure("out of credit")

    /** The reader's provider is limiting how fast their key may ask. */
    data object RateLimited : AskFailure("rate limited")

    /** The model chosen for the reader's key is gone or not available to it. */
    data object ModelUnavailable : AskFailure("model unavailable")

    /** The reader's provider could not be reached, or failed mid-answer. */
    data object ProviderUnreachable : AskFailure("provider unreachable")

    /** Anything else, with the sentence already composed. */
    data class Other(val sentence: String) : AskFailure(sentence)

    /**
     * Whether answering on the phone instead is worth offering: the reader's
     * provider refused, ran out or could not be reached, and Gemini Nano —
     * with its own guardrails — might still answer. The sheet offers it only
     * where Gemini Nano is ready, and never asks it on its own.
     */
    val offersDeviceInstead: Boolean
        get() = when (this) {
            Declined, Busy, TimedOut, Unavailable,
            KeyRefused, OutOfCredit, RateLimited, ModelUnavailable, ProviderUnreachable,
            -> true
            else -> false
        }

    /**
     * @param deviceNoun "phone", "tablet" or the like. The sentence names the
     *   device the reader is holding, because "this device" reads as a support
     *   article and the answer is about *their* machine.
     * @param answerer who was asked: the sentences that say who could not
     *   answer name it.
     */
    fun message(deviceNoun: String, answerer: AskAnswerer = AskAnswerer.DEVICE): String {
        val place = answerer.placeName
        return when (this) {
            Declined -> "$place declined to answer that one."
            Busy -> "$place is busy. Try again in a moment."
            ModelDownloading -> "$ASSISTANT is still downloading its model on this $deviceNoun. Try again once it has finished."
            UnsupportedLanguage -> "$place doesn't support this book's language yet."
            TooMuchContext -> "That question needed more of the book than fits. Try asking something narrower."
            TimedOut -> "$place took too long to answer. Try again."
            Unavailable ->
                if (answerer == AskAnswerer.DEVICE) {
                    "This $deviceNoun doesn't support $ASSISTANT, so asking isn't available here."
                } else {
                    "$place isn't available right now. Try again later."
                }
            IndexFailed -> "Couldn't read this book to answer. Try again."
            BackgroundExpired -> "Android paused the app before the answer finished. Ask again."
            QuotaExceeded -> "$ASSISTANT has answered a lot of questions from this app recently. Try again shortly."
            BackgroundBlocked -> "$ASSISTANT only answers while the app is open. Your question will be answered when you come back."
            NeedsSystemUpdate -> "$ASSISTANT needs a system update on this $deviceNoun before it can answer. Check for updates in Settings."
            KeyRefused -> "$place refused your key. Check it in Settings › Advanced."
            OutOfCredit -> "Your $place account is out of credit or has reached its spending limit."
            RateLimited -> "$place is limiting how often your key can ask. Try again in a minute."
            ModelUnavailable -> "The $place model you chose isn't available to your key. Choose another in Settings › Advanced."
            ProviderUnreachable -> "Couldn't reach $place. Check your connection and try again."
            is Other -> sentence
        }
    }

    companion object {
        /** What the reader knows the model as. */
        const val ASSISTANT = "Gemini Nano"

        /**
         * The sentence for a generation that produced nothing usable, wherever
         * it was noticed. Here rather than on the Android model because the
         * engine reaches the same conclusion on its own.
         */
        const val couldNotAnswer = "$ASSISTANT couldn't answer that one. Try again."
    }
}
