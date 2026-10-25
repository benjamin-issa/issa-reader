package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.render.TextRange
import com.ibm.icu.text.BreakIterator
import com.ibm.icu.util.ULocale
import java.text.StringCharacterIterator

/**
 * ICU's sentence rules on the JVM, registered for every suite in this module
 * through `META-INF/services` — see [SentenceBreaker.current].
 *
 * The rules a device runs: Android's `java.text.BreakIterator` is ICU, and so
 * is the `.bySentences` enumeration the Swift suites were written against. The
 * JDK's own rule set differs where it matters here — it does not end a
 * sentence at a bare line break, so a chapter heading runs into the first
 * sentence of the chapter — and a JVM suite reading the JDK's rules would be
 * checking behaviour no reader gets.
 */
class IcuSentenceBreaker : SentenceBreaker {
    private val iterators = ThreadLocal.withInitial { BreakIterator.getSentenceInstance(ULocale.ROOT) }

    override fun sentences(text: String, start: Int, end: Int): List<TextRange> {
        if (end <= start) return emptyList()
        val iterator = iterators.get()
        iterator.setText(StringCharacterIterator(text, start, end, start))
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
