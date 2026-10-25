package com.benjaminissa.issareader.ask.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.benjaminissa.issareader.ask.AskAnswer
import com.benjaminissa.issareader.ask.AskAnswerParser
import com.benjaminissa.issareader.ask.AskEngine
import com.benjaminissa.issareader.ask.AskEvent
import com.benjaminissa.issareader.ask.AskFailure
import com.benjaminissa.issareader.ask.AskGenerationOptions
import com.benjaminissa.issareader.ask.AskIndexStore
import com.benjaminissa.issareader.ask.AskPhase
import com.benjaminissa.issareader.ask.AskPromptBuilder
import com.benjaminissa.issareader.ask.AskRetriever
import com.benjaminissa.issareader.ask.BookSource
import com.benjaminissa.issareader.ask.EvidenceFinder
import com.benjaminissa.issareader.ask.Passage
import com.benjaminissa.issareader.ask.PassageRanker
import com.benjaminissa.issareader.ask.QueryTerms
import com.benjaminissa.issareader.ask.QuestionKind
import com.benjaminissa.issareader.ask.ReadingBoundary
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.render.ArchiveImageSource
import com.benjaminissa.issareader.render.ChapterParser
import com.benjaminissa.issareader.render.ReaderStyle
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.coroutines.cancellation.CancellationException

/**
 * The Ask rethink experiments: the shipped pipeline and its alternatives, run
 * against Gemini Nano and recorded one JSON line per ask — IssaAsk's
 * `RethinkExperiments`, less what the Prompt API cannot express.
 *
 *     ./gradlew :ask-android:connectedDebugAndroidTest \
 *         -Pandroid.testInstrumentationRunnerArguments.class=com.benjaminissa.issareader.ask.android.RethinkExperiments \
 *         -Pandroid.testInstrumentationRunnerArguments.ISSA_ASK_RETHINK=1 \
 *         -Pandroid.testInstrumentationRunnerArguments.ISSA_ASK_RETHINK_VARIANTS=E0,P0,R
 *
 * Skipped without `ISSA_ASK_RETHINK`. An experiment, not a regression suite:
 * it fails only when a question cannot be asked at all. The variants that
 * need tool calling (T, TR, H, P1), Apple's guided generation (S, SR) or its
 * reasoning levels (Z) are not here; see PORTING.md.
 */
@RunWith(AndroidJUnit4::class)
class RethinkExperiments {
    @Before
    fun gate() = runBlocking {
        assumeTrue("ISSA_ASK_RETHINK is not set", Rethink.isRequested)
        assumeTrue("Gemini Nano is not available", GeminiNanoAnswerModel.isAvailableForTesting())
    }

    @Test
    fun probeTheModelThisDeviceHas() = runBlocking { RethinkBodies.probe() }

    @Test
    fun everyVariantEveryQuestion() = runBlocking { RethinkBodies.runAll() }

    @Test
    fun prewarmingAsShippedAndCold() = runBlocking { RethinkBodies.prewarm() }
}

// Switches

internal object Rethink {
    val isRequested: Boolean get() = Device.argument("ISSA_ASK_RETHINK") != null
    val variantNames: List<String> get() = (Device.argument("ISSA_ASK_RETHINK_VARIANTS") ?: "E0").split(",")
    val sampled: Boolean get() = Device.argument("ISSA_ASK_RETHINK_SAMPLED") == "1"
    val runs: Int get() = maxOf(1, Device.argument("ISSA_ASK_RETHINK_RUNS")?.toIntOrNull() ?: 1)
    val sets: Set<String> get() = (Device.argument("ISSA_ASK_RETHINK_SETS") ?: "alice,franklin,synthetic").split(",").toSet()
    val only: List<String> get() = Device.argument("ISSA_ASK_RETHINK_ONLY")?.split("|").orEmpty()
    val interleave: Boolean get() = Device.argument("ISSA_ASK_RETHINK_INTERLEAVE") == "1"
    val out: File get() = Device.argument("ISSA_ASK_RETHINK_OUT")?.let(::File) ?: File(Device.scratch, "ask-rethink.jsonl")

    fun sibling(extension: String): File = File(out.parentFile, out.nameWithoutExtension + ".$extension")
}

// Questions

internal data class RQ(
    val set: String,
    val name: String,
    val question: String,
    val spine: Int,
    /** answerable, trap, loose, violent */
    val category: String,
    val expectAny: List<String> = emptyList(),
    val expectAll: List<String> = emptyList(),
    val exclude: List<String> = emptyList(),
    val notYet: Boolean? = null,
    val allowsNewNames: Boolean = true,
)

internal object RethinkQuestions {
    fun fromFixture(set: String, resource: String): List<RQ> = QuestionFixture.all(resource).map { f ->
        val category = if (f.notYet == true) "trap" else if (f.answerContainsAny.isEmpty()) "loose" else "answerable"
        RQ(
            set = set, name = "fx: " + f.name, question = f.question, spine = f.spine, category = category,
            expectAny = f.answerContainsAny, exclude = f.answerExcludes, notYet = f.notYet, allowsNewNames = f.allowsNewNames,
        )
    }

    /** Harder and spoiler-trap questions about *Alice*. Spine 2 is Chapter I, 3 Chapter II, 5 Chapter IV, 7 Chapter VI. */
    val alice = listOf(
        RQ("alice", "trap: tea party from chapter I", "Who does Alice meet at the tea party?", 2, "trap",
            exclude = listOf("hatter", "march hare", "dormouse"), notYet = true, allowsNewNames = false),
        RQ("alice", "trap: the mushroom from chapter II", "What happens when Alice eats the mushroom?", 3, "trap",
            exclude = listOf("caterpillar", "neck", "serpent", "pigeon", "one side"), notYet = true, allowsNewNames = false),
        RQ("alice", "trap: does she reach the garden", "Does Alice ever get into the beautiful garden?", 3, "trap",
            exclude = listOf("croquet", "flamingo", "queen", "roses", "gardeners"), allowsNewNames = false),
        RQ("alice", "why the pool of tears", "Why does Alice cry so much that she makes a pool of tears?", 3, "answerable",
            expectAny = listOf("tall", "big", "grown", "nine feet", "garden", "door")),
        RQ("alice", "synthesis: what she ate and drank", "What has Alice eaten and drunk so far, and what did each one do to her?", 3,
            "answerable", expectAll = listOf("cake"), exclude = listOf("mushroom")),
        RQ("alice", "identity of a minor character", "Who is Bill?", 5, "answerable", expectAny = listOf("lizard", "chimney")),
        RQ("alice", "recap from chapter II", "What has happened so far?", 3, "loose",
            exclude = listOf("caterpillar", "duchess", "hatter", "cheshire"), allowsNewNames = false),
        // Memorised-future traps whose leak is lowercase, so the name vetting
        // cannot catch it: only grounding can.
        RQ("alice", "memory trap: what the Rabbit drops", "What does the White Rabbit drop?", 2, "trap", exclude = listOf("glove", "fan")),
        RQ("alice", "memory trap: how it ends", "How does the story end?", 3, "trap", exclude = listOf("wakes", "dream", "trial", "pack of cards")),
        RQ("alice", "guard trap: the Queen of Hearts", "Who is the Queen of Hearts?", 2, "trap",
            exclude = listOf("croquet", "off with", "execut", "head"), notYet = true, allowsNewNames = false),
    )

    /** Franklin: spine k is the file `h-(k-1)`. */
    val franklin = listOf(
        RQ("franklin", "the father's trade", "What trade did the author's father follow in New England?", 2, "answerable",
            expectAny = listOf("tallow", "chandler", "soap", "sope", "candle")),
        RQ("franklin", "why he left grammar school", "Why did the author leave the grammar school?", 2, "answerable",
            expectAny = listOf("expense", "afford", "cost", "college", "money")),
        RQ("franklin", "the brother's newspaper", "What newspaper did the author's brother print?", 2, "answerable", expectAny = listOf("courant")),
        RQ("franklin", "trap: the son's death from spine 2", "How did the author's son die?", 2, "trap",
            exclude = listOf("small-pox", "smallpox", "pox", "inoculat"), notYet = true),
        RQ("franklin", "trap: the club from spine 2", "What club did the author start in Philadelphia?", 2, "trap",
            exclude = listOf("junto"), notYet = true),
        RQ("franklin", "trap: marrying Miss Read from spine 3", "Does the author end up marrying Miss Read?", 3, "trap",
            exclude = listOf("deborah", "1730", "took her to wife", "they married", "they marry", "he married her", "marries her")),
        RQ("franklin", "memory trap: the kite", "What did the author discover by flying a kite?", 2, "trap", exclude = listOf("lightning", "electric")),
    )

    /** The invented novella: spine k is chapter k + 1. */
    val synthetic = listOf(
        RQ("synthetic", "identity at first sight", "Who is Corvan?", 0, "answerable", expectAny = listOf("stranger", "box", "grey", "ear", "hollin")),
        RQ("synthetic", "a detail", "What did Corvan pay with?", 0, "answerable", expectAny = listOf("green glass", "glass coin", "glass")),
        RQ("synthetic", "trap: the box from chapter 1", "What is in Corvan's box?", 0, "trap",
            exclude = listOf("ring", "letter", "confession", "heron"), notYet = true),
        RQ("synthetic", "trap: the ear from chapter 3", "How did Corvan lose his ear?", 2, "trap",
            exclude = listOf("edric", "teeth", "torn", "tore", "bit "), notYet = true),
        RQ("synthetic", "cause of an injury", "How did Oswin break his leg?", 1, "answerable", expectAny = listOf("ramp")),
        RQ("synthetic", "identity of an absent character", "Who is Edric?", 1, "answerable", expectAny = listOf("brother", "uncle")),
        RQ("synthetic", "trap: the killer, a met name, from chapter 2", "Who killed Edric?", 1, "trap",
            exclude = listOf("corvan", "stab", "knife"), notYet = true),
        RQ("synthetic", "a reason across chapters", "Why did Mirelle take the ferry across alone?", 2, "answerable",
            expectAny = listOf("leg", "broke", "injur", "hurt")),
        RQ("synthetic", "a relationship stated once", "How is Tamsin related to Corvan?", 2, "answerable",
            expectAny = listOf("uncle", "niece", "mother's brother")),
        RQ("synthetic", "trap: the letter from chapter 3", "What does the letter in the box say?", 2, "trap",
            exclude = listOf("confess", "stab", "murder", "kill", "milestone"), notYet = true),
        RQ("synthetic", "violent: how Edric died", "How did Edric die?", 3, "violent", expectAny = listOf("stab", "knife")),
        RQ("synthetic", "violent: killer and grave", "Who killed Edric, and where is his body?", 3, "violent",
            expectAll = listOf("corvan", "milestone")),
        RQ("synthetic", "trap: Corvan's fate from chapter 4", "What happens to Corvan in the end?", 3, "trap",
            exclude = listOf("drown", "goes over the side", "into the water", "never found"), notYet = true),
        RQ("synthetic", "recap from chapter 3", "What has happened so far?", 2, "loose",
            exclude = listOf("ring", "stab", "drown", "confess", "milestone")),
        RQ("synthetic", "motive across chapters", "Why was Corvan going to Hollin?", 3, "answerable",
            expectAny = listOf("confess", "abbess", "hennet")),
    )
}

// Books

internal class RBook(
    val name: String,
    val store: AskIndexStore,
    val source: BookSource,
    val directory: File,
    val boundaryAt: (Int) -> ReadingBoundary,
) {
    companion object {
        suspend fun fixture(name: String, book: DeviceBook): RBook {
            val (store, source, directory) = book.preparedStore()
            return RBook(name, store, source, directory) { spine -> book.endOf(spine) }
        }

        /** The invented novella, written to an EPUB and indexed like any book. */
        suspend fun synthetic(): RBook {
            val directory = Device.temporaryDirectory()
            val file = File(directory, "synthetic.epub")
            SyntheticEpub.write(RethinkSyntheticBook.chapters, file)
            val source = BookSource("5e5e5e5e-7777-4888-8999-aaaaaaaaaaaa", file)
            val store = AskIndexStore(directory)
            store.prepare(source)
            val epub = EpubPackage.open(file)
            val lengths = epub.spine.map { item ->
                val images = ArchiveImageSource(epub.archive)
                ChapterParser(ReaderStyle(), loadImage = { images.image(it) }).parse(epub.archive.read(item.href), item.href).text.length
            }
            return RBook("synthetic", store, source, directory) { spine -> ReadingBoundary(spine, lengths[spine]) }
        }
    }
}

// Variants

internal data class RVariant(
    val name: String,
    /** The real engine, as the app builds it. */
    val engine: Boolean = false,
    /** The context size the builder and the retriever are sized for; null is the model's own. */
    val packContext: Int? = null,
    /** The last N passages before the boundary, merged with what retrieval found. */
    val recency: Int = 0,
    /** The most recent read text only, packed to the ceiling, no retrieval. */
    val fullText: Boolean = false,
    /** shipped, revised, noexample */
    val instructions: String = "shipped",
    val maxResponseTokens: Int = 250,
    val questionGuard: Boolean = true,
) {
    companion object {
        /**
         * The Swift experiments' variants the Prompt API can run. E0 is the
         * app's engine, which on Android has no search tool — so E0 and EN
         * are the same engine, kept as two names so result files line up.
         */
        val all: Map<String, RVariant> = listOf(
            RVariant("E0", engine = true),
            RVariant("EN", engine = true),
            RVariant("P0"),
            RVariant("N", packContext = 4_096),
            RVariant("R", recency = 12),
            RVariant("F", fullText = true),
            RVariant("I", instructions = "revised"),
            RVariant("G0", questionGuard = false),
            RVariant("X", instructions = "noexample"),
            RVariant("XR", recency = 12, instructions = "noexample"),
            RVariant("IR", recency = 12, instructions = "revised"),
        ).associateBy { it.name }
    }
}

// Instructions

internal object RethinkInstructions {
    private val example: String = AskPromptBuilder.instructions.split("Example:").last().let { "Example:$it" }

    val revised: String = """
        You are a reading companion. A reader is part-way through a book and asks you a question about it.

        You receive numbered excerpts from the pages the reader has already read, in reading order. Treat them as everything you know about this book. Do not use knowledge of any published book, film or author, even if you recognise the story, and never speculate about what happens later.

        If the excerpts don't contain the answer, respond with exactly this sentence and nothing else: The story hasn't revealed that yet.

        Otherwise answer in two to four sentences of plain prose, stating only what the excerpts say. Then, on a new line, write "Sources:" followed by the numbers of the excerpts you used.

    """.trimIndent() + "\n" + example

    /** The shipped rules with the example removed. */
    val noExample: String = AskPromptBuilder.instructions.split("\n\nExample:").first()
}

// Outcome

@Serializable
internal data class ROutcome(
    val set: String,
    val variant: String,
    val run: Int,
    val name: String,
    val category: String,
    val question: String,
    val spine: Int,
    var ms: Long = 0,
    var ttftMs: Long? = null,
    var answer: String = "",
    var rawAnswer: String = "",
    var citations: List<Int> = emptyList(),
    var sourcesResolved: Int = 0,
    var notYetRevealed: Boolean = false,
    var origin: String = "",
    var vetFired: Boolean = false,
    var modelCalled: Boolean = false,
    var excerptsInPrompt: Int = 0,
    var promptTokens: Int? = null,
    /** A passage handed to the model from past the boundary. Must be false. */
    var physicalLeak: Boolean = false,
    var leaked: List<String> = emptyList(),
    var rawLeaked: List<String> = emptyList(),
    var newNames: List<String> = emptyList(),
    var expectedMet: Boolean? = null,
    var error: String? = null,
    var pass: Boolean = false,
    var refusedAnswerable: Boolean = false,
)

// Running one question

internal class RethinkRunner(private val book: RBook, private val model: GeminiNanoAnswerModel) {
    suspend fun ask(q: RQ, v: RVariant, run: Int): ROutcome {
        val boundary = book.boundaryAt(q.spine)
        val start = System.nanoTime()
        val o = ROutcome(
            set = q.set, variant = v.name + if (Rethink.sampled) "~s" else "", run = run, name = q.name,
            category = q.category, question = q.question, spine = q.spine,
        )
        var final: AskAnswer? = null
        try {
            final = if (v.engine) viaEngine(q, boundary, start, o) else viaPipeline(q, v, boundary, start, run, o)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            o.error = if (error is AskFailure) "AskFailure.$error" else "${error.javaClass.simpleName}: ${error.message}"
        }
        o.ms = Device.elapsedMilliseconds(start)
        if (final != null) {
            o.answer = final.text
            o.citations = final.citations
            o.sourcesResolved = final.sources.size
            o.notYetRevealed = final.notYetRevealed
            o.origin = final.origin.name
        }
        score(q, boundary, o)
        return o
    }

    private suspend fun viaEngine(q: RQ, boundary: ReadingBoundary, start: Long, o: ROutcome): AskAnswer? {
        // Under ISSA_ASK_RETHINK_SAMPLED the engine's own seeded sampler, so a
        // sampled run measures the shipped seed rather than the harness's.
        val engine = AskEngine(model, book.store, tools = emptyList(), usesNucleusSampling = Rethink.sampled)
        var answer: AskAnswer? = null
        engine.ask(q.question, book.source, boundary).collect { event ->
            when (event) {
                is AskEvent.Answered -> answer = event.answer
                is AskEvent.Phase -> if (event.phase == AskPhase.Thinking) o.modelCalled = true
                is AskEvent.Partial -> if (o.ttftMs == null && event.text.isNotEmpty()) o.ttftMs = Device.elapsedMilliseconds(start)
            }
        }
        o.rawAnswer = answer?.text.orEmpty()
        return answer
    }

    private suspend fun viaPipeline(q: RQ, v: RVariant, boundary: ReadingBoundary, start: Long, run: Int, o: ROutcome): AskAnswer? {
        val uuid = book.source.bookUuid
        val store = book.store
        val ctx = v.packContext ?: model.contextSize
        val sanitised = QueryTerms.sanitise(q.question)
        var ranked: List<PassageRanker.Ranked> = emptyList()
        var isRecap = false
        val withheld = AskAnswer(
            text = AskAnswerParser.notYetSentinel, citations = emptyList(), notYetRevealed = true, origin = AskAnswer.Origin.WITHHELD,
        )

        if (!v.questionGuard) {
            // The original defect's shape: no question-side guard, so a question
            // naming somebody the book has not introduced reaches the model with
            // whatever the other words of the question retrieve.
            val retriever = AskRetriever(store, uuid, boundary, allowsFastPath = false, recencyPassages = 0)
            val known = runCatching { store.topNames(uuid, boundary, AskRetriever.Limits.knownNames) }.getOrDefault(emptyList())
            val terms = QueryTerms.extract(q.question, knownNames = known)
            var found = retriever.evidence(terms, AskRetriever.Limits.excerpts(ctx))
            if (found.isEmpty()) {
                val general = store.retrieve(terms, uuid, boundary, limit = 15)
                found = EvidenceFinder.passages(PassageRanker.rank(general, terms, limit = 15))
            }
            ranked = EvidenceFinder.ranked(found)
            if (ranked.isEmpty()) ranked = EngineHelpers.recapRanked(store.recapPassages(uuid, boundary, 15))
        } else if (!v.fullText) {
            val retriever = AskRetriever(store, uuid, boundary, allowsFastPath = true, recencyPassages = 0)
            when (val retrieval = retriever.retrieve(q.question, AskRetriever.Limits.excerpts(ctx))) {
                is AskRetriever.Retrieval.NotYet -> {
                    o.rawAnswer = AskAnswerParser.notYetSentinel
                    return withheld
                }
                is AskRetriever.Retrieval.Answered -> {
                    o.rawAnswer = retrieval.answer.text
                    val resolved = AskAnswerParser.resolving(retrieval.answer, EngineHelpers.numbered(retrieval.evidence.map { it.passage }))
                    return vet(resolved, boundary, o)
                }
                is AskRetriever.Retrieval.Found -> {
                    ranked = retrieval.ranked
                    isRecap = retrieval.kind is QuestionKind.Recap
                }
            }
        } else {
            // The question-side guard stays in every variant: it is SQL and free.
            val known = runCatching { store.topNames(uuid, boundary, AskRetriever.Limits.knownNames) }.getOrDefault(emptyList())
            val terms = QueryTerms.extract(q.question, knownNames = known)
            val unmet = if (terms.isRecap) emptyList() else store.unmetWords(terms.nameCandidates, uuid, boundary)
            if (unmet.isNotEmpty()) {
                o.rawAnswer = AskAnswerParser.notYetSentinel
                return withheld
            }
        }

        if (v.fullText || (v.recency > 0 && !isRecap)) {
            val limit = if (v.fullText) 2_000 else v.recency
            val recent = EngineHelpers.recapRanked(store.recapPassages(uuid, boundary, limit))
            if (v.fullText) {
                ranked = recent
            } else {
                val offset = (ranked.maxOfOrNull { it.priority } ?: -1) + 1
                val have = ranked.map { Triple(it.passage.spineIndex, it.passage.start, it.passage.end) }.toSet()
                // Recency passages overlap retrieved sentences often; skip any
                // whose range contains a retrieved window.
                val extra = recent.filter { r ->
                    Triple(r.passage.spineIndex, r.passage.start, r.passage.end) !in have &&
                        ranked.none {
                            it.passage.spineIndex == r.passage.spineIndex && it.passage.start >= r.passage.start &&
                                it.passage.end <= r.passage.end
                        }
                }.map { PassageRanker.Ranked(it.retrieved, it.priority + offset) }
                ranked = (ranked + extra).sortedWith(compareBy({ it.passage.spineIndex }, { it.passage.start }))
            }
        }

        val built = AskPromptBuilder.build(
            question = sanitised, ranked = ranked, contextSize = ctx, hasTool = false,
            tokenCount = { text -> model.tokenCount(text) },
        )
        o.excerptsInPrompt = built.passages.size
        o.promptTokens = built.promptTokens
        if (built.passages.any { !within(it, boundary) }) o.physicalLeak = true

        val instructions = when (v.instructions) {
            "revised" -> RethinkInstructions.revised
            "noexample" -> RethinkInstructions.noExample
            else -> AskPromptBuilder.instructions
        }
        val options = AskGenerationOptions(
            maximumResponseTokens = v.maxResponseTokens,
            temperature = if (Rethink.sampled) 0.3 else 0.0,
            sampling = if (Rethink.sampled) AskGenerationOptions.Sampling.Nucleus(0.9, run.toULong()) else AskGenerationOptions.Sampling.Greedy,
        )
        o.modelCalled = true
        var raw = ""
        model.answer(instructions, built.prompt, emptyList(), options).collect { text ->
            raw = text
            if (o.ttftMs == null && AskAnswerParser.visible(raw).isNotEmpty()) o.ttftMs = Device.elapsedMilliseconds(start)
        }
        o.rawAnswer = raw
        val parsed = AskAnswerParser.parse(raw)
        if (parsed.text.isEmpty()) throw AskFailure.Other("no prose")
        val resolved = AskAnswerParser.resolving(parsed, EngineHelpers.numbered(built.passages), EngineHelpers.priorities(ranked))
        return vet(resolved, boundary, o)
    }

    private suspend fun vet(answer: AskAnswer, boundary: ReadingBoundary, o: ROutcome): AskAnswer {
        if (answer.notYetRevealed) return answer
        val candidates = AskEngine.unvettedNames(answer.text)
        if (candidates.isEmpty()) return answer
        val unmet = book.store.unmetWords(candidates, book.source.bookUuid, boundary)
        if (unmet.isEmpty()) return answer
        o.vetFired = true
        return AskAnswer(
            text = AskAnswerParser.notYetSentinel, citations = emptyList(), notYetRevealed = true, origin = AskAnswer.Origin.WITHHELD,
        )
    }

    // Scoring

    private suspend fun score(q: RQ, boundary: ReadingBoundary, o: ROutcome) {
        val lowered = o.answer.lowercase()
        // At a word start, so "during" does not leak "ring".
        fun mentions(text: String, term: String) = Regex("\\b" + Regex.escape(term)).containsMatchIn(text)
        o.leaked = q.exclude.filter { mentions(lowered, it) }
        o.rawLeaked = q.exclude.filter { mentions(o.rawAnswer.lowercase(), it) }
        if (!q.allowsNewNames && !o.notYetRevealed && o.error == null) {
            o.newNames = book.store.unmetWords(AskEngine.unvettedNames(o.answer), book.source.bookUuid, boundary).sorted()
        }
        if (q.expectAny.isNotEmpty() || q.expectAll.isNotEmpty()) {
            val any = q.expectAny.isEmpty() || q.expectAny.any { lowered.contains(it) }
            val all = q.expectAll.all { lowered.contains(it) }
            o.expectedMet = !o.notYetRevealed && any && all
        }
        val answerable = q.category == "answerable" || q.category == "violent"
        o.refusedAnswerable = answerable && o.notYetRevealed
        val notYetOk = q.notYet?.let { it == o.notYetRevealed } ?: true
        o.pass = o.error == null && o.leaked.isEmpty() && o.newNames.isEmpty() && !o.physicalLeak &&
            (o.expectedMet ?: true) && notYetOk
    }

    companion object {
        fun within(passage: Passage, boundary: ReadingBoundary): Boolean =
            passage.spineIndex < boundary.spineIndex ||
                (passage.spineIndex == boundary.spineIndex && passage.end <= boundary.charOffset)
    }
}

// The bodies

internal object RethinkBodies {
    private val json = Json { encodeDefaults = true }

    /** What the model on this device is: its window, and what the books cost in its tokens. */
    suspend fun probe() {
        val model = GeminiNanoAnswerModel.create()
        val lines = mutableListOf(
            "description ${model.modelDescription}",
            "contextSize ${model.contextSize}",
            "instructionsTokens ${model.tokenCount(AskPromptBuilder.instructions)} chars ${AskPromptBuilder.instructions.length}",
        )
        for ((name, book, spines) in listOf(
            Triple("alice", DeviceBook.alice, listOf(2, 3, 7, 13)),
            Triple("franklin", DeviceBook.franklin, listOf(2, 6)),
        )) {
            val cumulative = StringBuilder()
            for (spine in 0..spines.max()) {
                cumulative.append(runCatching { book.text(spine) }.getOrDefault(""))
                if (spine in spines) {
                    val tokens = model.tokenCount(cumulative.toString())
                    lines.add(
                        "$name read through spine $spine: ${cumulative.length} chars, $tokens tokens " +
                            "(est ${AskPromptBuilder.estimatedTokens(cumulative.toString())})",
                    )
                }
            }
        }
        val synthetic = RethinkSyntheticBook.chapters.flatten().joinToString("\n")
        lines.add("synthetic whole: ${synthetic.length} chars, ${model.tokenCount(synthetic)} tokens")
        val text = lines.joinToString("\n")
        println("[rethink-probe]\n$text")
        Rethink.sibling("probe.txt").writeText(text)
    }

    suspend fun runAll() {
        val out = Rethink.out
        out.parentFile?.mkdirs()
        val model = GeminiNanoAnswerModel.create()
        val books = ArrayList<Pair<RBook, List<RQ>>>()
        try {
            if ("alice" in Rethink.sets) {
                books.add(RBook.fixture("alice", DeviceBook.alice) to RethinkQuestions.fromFixture("alice", "questions-alice") + RethinkQuestions.alice)
            }
            if ("franklin" in Rethink.sets) {
                books.add(
                    RBook.fixture("franklin", DeviceBook.franklin) to
                        RethinkQuestions.fromFixture("franklin", "questions-franklin") + RethinkQuestions.franklin,
                )
            }
            if ("synthetic" in Rethink.sets) books.add(RBook.synthetic() to RethinkQuestions.synthetic)

            val variants = Rethink.variantNames.map { RVariant.all[it] ?: error("unknown or unported variant $it") }
            fun selected(q: RQ) = Rethink.only.isEmpty() || Rethink.only.any { q.name.contains(it) }

            if (Rethink.interleave) {
                // Question-major, so every variant sees the same device load.
                for (run in 1..Rethink.runs) {
                    for ((book, questions) in books) {
                        val runner = RethinkRunner(book, model)
                        for (q in questions.filter(::selected)) {
                            for (variant in if (run % 2 == 0) variants.reversed() else variants) {
                                out.appendText(json.encodeToString(ROutcome.serializer(), runner.ask(q, variant, run)) + "\n")
                            }
                        }
                    }
                }
                return
            }
            for (variant in variants) {
                var passed = 0
                var total = 0
                for (run in 1..Rethink.runs) {
                    for ((book, questions) in books) {
                        val runner = RethinkRunner(book, model)
                        for (q in questions.filter(::selected)) {
                            val o = runner.ask(q, variant, run)
                            out.appendText(json.encodeToString(ROutcome.serializer(), o) + "\n")
                            total += 1
                            if (o.pass) passed += 1
                            println(
                                "[rethink] ${variant.name} r$run ${if (o.pass) "PASS" else "FAIL"} ${o.ms}ms ${q.set} — ${q.name}\n" +
                                    "   A: ${o.answer.take(220)}${o.error?.let { "  ERR $it" } ?: ""}",
                            )
                        }
                    }
                }
                println("[rethink] variant ${variant.name}: $passed/$total")
            }
        } finally {
            for ((book, _) in books) Device.remove(book.directory)
        }
    }

    /**
     * Two ways to start a question, alternated so drift cancels: cold, and
     * warmed as the app warms it (`prewarm`, then the question 1.5 s later).
     * Apple's third mode — prewarming the answering session itself — has no
     * counterpart: ML Kit has no session to warm.
     */
    suspend fun prewarm() {
        val book = RBook.synthetic()
        try {
            val questions = RethinkQuestions.synthetic.filter { it.category != "trap" }
            val lines = ArrayList<String>()
            for (round in 1..2) {
                for (q in questions) {
                    for (mode in listOf("cold", "shipped")) {
                        val model = GeminiNanoAnswerModel()
                        model.refreshLimits()
                        val boundary = book.boundaryAt(q.spine)
                        val retriever = AskRetriever(book.store, book.source.bookUuid, boundary, recencyPassages = 0)
                        val retrieval = retriever.retrieve(q.question, 30) as? AskRetriever.Retrieval.Found ?: continue
                        val built = AskPromptBuilder.build(
                            question = QueryTerms.sanitise(q.question), ranked = retrieval.ranked, contextSize = model.contextSize,
                            hasTool = false, tokenCount = { text -> model.tokenCount(text) },
                        )
                        if (mode == "shipped") {
                            model.prewarm()
                            delay(1_500)
                        }
                        val start = System.nanoTime()
                        var ttft: Long? = null
                        model.answer(AskPromptBuilder.instructions, built.prompt, emptyList(), AskGenerationOptions()).collect { text ->
                            if (ttft == null && text.isNotEmpty()) ttft = Device.elapsedMilliseconds(start)
                        }
                        val total = Device.elapsedMilliseconds(start)
                        val line = "round=$round mode=$mode ttft=${ttft ?: -1} total=$total promptTokens=${built.promptTokens} q=${q.name}"
                        println("[rethink-prewarm] $line")
                        lines.add(line)
                    }
                }
            }
            Rethink.sibling("prewarm.txt").writeText(lines.joinToString("\n"))
        } finally {
            Device.remove(book.directory)
        }
    }
}
