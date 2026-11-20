package com.benjaminissa.issareader.ask

/**
 * How the engine asks one model: what it is told, how much of the book it is
 * shown and in what shape, and how hard it should think.
 *
 * Swift's `AskProfile`. The search tool is a reader's own provider's alone:
 * ML Kit has no tool calling, so Gemini Nano's profile never offers it.
 *
 * Every field of [DEVICE] is what shipped before 1.8.0, so the device's engine
 * is unchanged.
 */
data class AskProfile(
    /** For the log — never shown to a reader. */
    val name: String,
    /** The model's instructions. The question never goes here (it is the prompt's). */
    val instructions: String = AskPromptBuilder.instructions,
    /**
     * Whether the model may call `searchBook` — only ever a model that runs
     * its own tool loop ([AnswerModel.runsItsOwnToolLoop]).
     */
    val usesSearchTool: Boolean = AskEngine.usesSearchTool,
    /**
     * How many excerpts retrieval may hand the builder. Null scales with the
     * model's window ([AskRetriever.Limits.excerpts]).
     */
    val excerptLimit: Int? = null,
    /** How many of the passages just read are added behind what the search found. */
    val recencyPassages: Int = AskRetriever.Limits.recencyPassages,
    /**
     * The most tokens of excerpts a prompt may carry. Null grows with the
     * window from the 4K tuning ([AskPromptBuilder.Budget.passageCeiling]).
     */
    val passageCeiling: Int? = null,
    /** The answer's own budget. */
    val responseTokens: Int = AskPromptBuilder.Budget.responseTokens,
    /** How hard a model that can reason should think. Ignored by one that cannot. */
    val reasoning: AskGenerationOptions.Reasoning? = null,
    /** What of the book the model is shown. */
    val shape: ContextShape = ContextShape.PASSAGES,
    /**
     * Whether the excerpts are scrubbed of the book's title page, its chapter
     * headings and its authors' names before they are sent
     * ([BookIdentityScrubber]). On for a reader's own provider; Gemini Nano's
     * prompts are unchanged.
     */
    val scrubsBookIdentity: Boolean = false,
    /** The most tokens of book [ContextShape.EVERYTHING_READ] may send. */
    val everythingReadCeiling: Int = 0,
    /** How the excerpts and the question are laid out ([AskPromptBuilder.PromptStyle]). */
    val promptStyle: AskPromptBuilder.PromptStyle = AskPromptBuilder.PromptStyle.PLAIN,
    /** The rules said again after the question, for a style that wants them. */
    val reminder: String? = null,
) {
    /** What of the book goes with a question. */
    enum class ContextShape {
        /**
         * The passages retrieval found for the question, and the last few read
         * — what every answerer was asked with until 1.8.0.
         */
        PASSAGES,

        /**
         * Everything before the reader's place, oldest dropped first if it
         * does not fit the ceiling. Only a provider's window holds it.
         */
        EVERYTHING_READ,
    }

    companion object {
        /** What the app asks Gemini Nano with: the engine as it shipped. */
        val DEVICE = AskProfile(name = "device")

        /**
         * What the app asks a reader's own provider with, in the shape its
         * maker's guidance recommends: Claude's tagged documents, GPT's XML
         * with the rules repeated at the end. Passages sized as Swift's —
         * up to 60 excerpts, the last 40 passages read, a 20K-token ceiling
         * for them — the search, room for an answer and the thinking before
         * it, and a light effort.
         *
         * @param shape what of the book is sent.
         * @param ceiling the most of the model's own tokens of book
         *   [ContextShape.EVERYTHING_READ] sends.
         */
        fun provider(
            kind: ProviderKind,
            shape: ContextShape = ContextShape.PASSAGES,
            ceiling: Int = 150_000,
            usesSearchTool: Boolean = true,
            reasoning: AskGenerationOptions.Reasoning = AskGenerationOptions.Reasoning.LIGHT,
        ): AskProfile {
            val (instructions, style, reminder) = when (kind) {
                ProviderKind.ANTHROPIC -> Triple(AskPromptBuilder.anthropicInstructions, AskPromptBuilder.PromptStyle.TAGGED, null)
                ProviderKind.OPENAI ->
                    Triple(AskPromptBuilder.openAiInstructions, AskPromptBuilder.PromptStyle.SANDWICH, AskPromptBuilder.openAiReminder)
            }
            return AskProfile(
                name = "provider-${kind.rawValue}-${shape.name.lowercase()}",
                instructions = instructions,
                usesSearchTool = usesSearchTool,
                excerptLimit = 60,
                recencyPassages = 40,
                passageCeiling = 20_000,
                responseTokens = 8_000,
                reasoning = reasoning,
                shape = shape,
                scrubsBookIdentity = true,
                everythingReadCeiling = ceiling,
                promptStyle = style,
                reminder = reminder,
            )
        }

        /**
         * The provider profile for one model: everything read so far, with
         * the provider's own prompt — the 1.8.0 provider study's choice. On
         * two of the reader's library books it scored 94% (Claude Sonnet 5.5)
         * and 96% (GPT-6.2 Sol) against 60% and 71% with passages, held every
         * not-yet trap, and gave no spoiler, no wrong answer and no outside
         * knowledge in 256 graded answers.
         *
         * The whole window: everything read so far is sent, up to the model's
         * limit, and nothing is cut below it. The search is offered too, and
         * when the book did not fit the prompt says its beginning was left out
         * and to search it (`AskEngine.generateEverythingRead`): a reader
         * halfway through a long book asked how something at its start came
         * about, and the model, shown only its later part, could only say the
         * story hadn't revealed it.
         */
        fun provider(model: ProviderModel, kind: ProviderKind): AskProfile = provider(
            kind = kind,
            shape = ContextShape.EVERYTHING_READ,
            ceiling = model.contextSize,
            usesSearchTool = true,
        )
    }
}
