package com.benjaminissa.issareader.ask

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The pages just read, handed to the model behind what the search found.
 *
 * Measured in the 1.4.0 Ask review: "What did Alice drink?" from the end of
 * Chapter I retrieved her deciding the bottle was not marked poison and not
 * the paragraph where she drinks it, and the model told the reader she never
 * drank.
 */
class RecencyTopUpTest {
    @Test
    fun `the model is shown the paragraph where Alice drinks, which the search alone missed`() = runBlocking {
        val (store, source, directory) = AskFixture.preparedStore()
        try {
            val model = ScriptedAnswerModel()
            val engine = AskEngine(model, store)
            drain(engine.ask("What did Alice drink?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
            val sent = model.received.first()
            // The paragraph that says what the bottle tasted of, and that she
            // finished it.
            assertTrue(sent.prompt.contains("cherry-tart"))
        } finally {
            AskFixture.remove(directory)
        }
    }

    /** The spoiler test: every passage retrieval hands over, the recent ones included, ends at or before the reader. */
    @Test
    fun `nothing retrieval returns is past the reader, recent passages included`() = runBlocking {
        val (store, _, directory) = AskFixture.preparedStore()
        try {
            val end = AskFixture.endOf(AskFixture.Spine.chapterII)
            val middle = ReadingBoundary(spineIndex = end.spineIndex, charOffset = end.charOffset / 2)
            for (boundary in listOf(end, middle)) {
                val retriever = AskRetriever(store, AskFixture.bookUuid, boundary)
                for (question in listOf("What did Alice drink?", "Who is the White Rabbit?", "Why does Alice cry?")) {
                    val retrieval = retriever.retrieve(question) as? AskRetriever.Retrieval.Found
                    if (retrieval == null) {
                        fail("$question retrieved nothing")
                        continue
                    }
                    assertTrue(retrieval.ranked.isNotEmpty())
                    for (passage in retrieval.ranked.map { it.passage }) {
                        assertTrue(
                            "$question: ${passage.spineIndex}:${passage.start}-${passage.end} is past ${boundary.charOffset}",
                            passage.spineIndex < boundary.spineIndex ||
                                (passage.spineIndex == boundary.spineIndex && passage.end <= boundary.charOffset),
                        )
                    }
                }
            }
        } finally {
            AskFixture.remove(directory)
        }
    }

    /** A title page and a copyright page the book never tagged must not ride in on the top-up (R-26). */
    @Test
    fun `the pages just read never reach back into the untagged front matter`() = runBlocking {
        val (store, _, boundary, directory) = AskFixture.syntheticStore(
            listOf(
                listOf("The Lantern Keeper", "A Novel by Imogen Hartwell"),
                listOf("Copyright 2026 Imogen Hartwell. All rights reserved. First edition."),
                listOf(
                    "Chapter One",
                    "The girl sat on the harbour wall and cried, because the lantern boat had gone " +
                        "out without her and nobody on the quay would say where it was going.",
                    "Her uncle came down the steps with a coat over his arm and asked her why she " +
                        "was crying, and she would not tell him, and he sat down beside her anyway.",
                ),
            ),
        )
        try {
            val retriever = AskRetriever(store, AskFixture.bookUuid, boundary)
            val retrieval = retriever.retrieve("Why is the girl crying?") as? AskRetriever.Retrieval.Found
                ?: return@runBlocking fail("the question retrieved nothing")
            assertTrue(retrieval.ranked.isNotEmpty())
            val spines = retrieval.ranked.map { it.passage.spineIndex }.toSet()
            assertEquals("front matter was sent: ${spines.sorted()}", setOf(boundary.spineIndex), spines)
            val text = retrieval.ranked.joinToString("\n") { it.passage.text }
            assertFalse(text.contains("Hartwell"))
            assertFalse(text.contains("Lantern Keeper"))
        } finally {
            AskFixture.remove(directory)
        }
    }

    // The merge

    private fun ranked(spine: Int, start: Int, end: Int, priority: Int) = PassageRanker.Ranked(
        RetrievedPassage(
            Passage(spineIndex = spine, ordinal = start, start = start, end = end, words = 10, text = "p$spine-$start"),
            bm25 = 0.0, isTruncated = false,
        ),
        priority = priority,
    )

    private fun recent(spine: Int, start: Int, end: Int) = ranked(spine, start, end, priority = 0).retrieved

    @Test
    fun `recent passages rank behind everything found, so a small window drops them first`() {
        val found = listOf(ranked(1, 0, 100, priority = 0), ranked(2, 0, 50, priority = 3))
        val merged = AskRetriever.withRecency(found, listOf(recent(3, 0, 100), recent(3, 100, 200)))
        val recentPriorities = merged.filter { it.passage.spineIndex == 3 }.map { it.priority }
        assertEquals(2, recentPriorities.size)
        assertTrue(recentPriorities.all { it > 3 })
        assertEquals(found.map { it.passage }.toSet(), PassageRanker.best(merged, 2).map { it.passage }.toSet())
    }

    @Test
    fun `a recent passage that overlaps a found excerpt is not sent twice`() {
        val found = listOf(ranked(3, 120, 160, priority = 0))
        val merged = AskRetriever.withRecency(found, listOf(recent(3, 0, 100), recent(3, 100, 200)))
        assertEquals(listOf(0, 120), merged.map { it.passage.start })
    }

    @Test
    fun `the merge is in book order, which is the order the prompt numbers`() {
        val found = listOf(ranked(2, 500, 600, priority = 0))
        val merged = AskRetriever.withRecency(found, listOf(recent(1, 0, 100), recent(3, 0, 100)))
        assertEquals(listOf(1, 2, 3), merged.map { it.passage.spineIndex })
    }
}
