package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.render.TextRange
import java.text.BreakIterator
import java.text.StringCharacterIterator
import java.util.Locale

/**
 * Where sentences end: `NSString.enumerateSubstrings(in:options: .bySentences)`
 * on Apple's side, which is ICU's sentence rules.
 *
 * Behind an interface because the rules are the platform's and the platforms
 * differ. On Android `java.text.BreakIterator` is ICU underneath, so the
 * default [JavaSentenceBreaker] there agrees with the iPhone's; on a desktop
 * JVM it is the JDK's own, older rule set, which is why the unit tests supply
 * ICU4J's through [current]. Nothing is persisted in terms of
 * sentences except through [PassageChunker], whose passage boundaries are
 * covered by the index key's parser version — an index is never shared between
 * the two clients, so the two rule sets only have to agree well enough that
 * the same question finds the same paragraphs.
 *
 * Replaceable, through `ServiceLoader` or [current].
 */
fun interface SentenceBreaker {
    /**
     * The sentences of `text[start, end)`, in order, as ranges into [text].
     * Together they cover the range; the whitespace after a sentence belongs
     * to it.
     */
    fun sentences(text: String, start: Int, end: Int): List<TextRange>

    companion object {
        /**
         * The breaker every splitter in this module uses: one a
         * `ServiceLoader` finds, or else [JavaSentenceBreaker].
         *
         * Nothing registers one in the app, so on Android this is the
         * platform's own ICU. The JVM unit tests register ICU4J's, because the
         * JDK's rules are not ICU's — they do not end a sentence at a bare line
         * break ("CHAPTER I.\nDown the Rabbit-Hole\nAlice was…" is one
         * sentence to them and three to ICU) — and a suite that checked the
         * JDK's rules would be checking rules no device runs.
         */
        @Volatile
        var current: SentenceBreaker = java.util.ServiceLoader
            .load(SentenceBreaker::class.java, SentenceBreaker::class.java.classLoader)
            .firstOrNull() ?: JavaSentenceBreaker
    }
}

/** `java.text.BreakIterator`'s sentence instance, under the root locale. */
object JavaSentenceBreaker : SentenceBreaker {
    /** One iterator per thread: a `BreakIterator` is not safe to share. */
    private val iterators = ThreadLocal.withInitial { BreakIterator.getSentenceInstance(Locale.ROOT) }

    override fun sentences(text: String, start: Int, end: Int): List<TextRange> {
        if (end <= start) return emptyList()
        val iterator = iterators.get()
        iterator.text = StringCharacterIterator(text, start, end, start)
        val ranges = ArrayList<TextRange>()
        var from = iterator.first()
        var to = iterator.next()
        while (to != BreakIterator.DONE) {
            if (to > from) ranges.add(TextRange(from, to - from))
            from = to
            to = iterator.next()
        }
        return ranges
    }
}
