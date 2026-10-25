package com.benjaminissa.issareader.ask

/**
 * Finds the people in a passage.
 *
 * Two jobs, both of which need the same answer: the suggestion chips offer
 * "Who is <the name you have seen most>?", and a question mentioning a name
 * the book knows promotes that token so retrieval weights it. Both are bounded
 * by the reading position, so the name table is per chapter and per offset,
 * not per book.
 *
 * On Apple's side this is `NLTagger` with `.nameType` and `.joinNames`. Android
 * has nothing of the kind, so the finding is behind [NameTagger] and the
 * default is [HeuristicNameTagger], which reads capitals the way a careful
 * reader would — see its own comment for what it does and does not catch. What
 * is here is the part both clients share: the honorifics, the folding, the
 * pooling of spellings and the earliest sighting the boundary compares
 * against.
 */
object NameFinder {
    /** A person the book has mentioned, and where it first did. */
    data class Name(
        val name: String,
        val spineIndex: Int,
        /**
         * UTF-16 offset of the first mention in that chapter, so the boundary
         * can exclude a character the reader has not met yet.
         */
        val firstOffset: Int,
        val mentions: Int,
    ) {
        /**
         * What two spellings of one person have in common.
         *
         * A book that shouts a name in a chapter heading and prints it normally
         * in the prose — "RYN" and "Ryn" — otherwise makes two rows, splits the
         * mention count between them, and drops its own protagonist out of the
         * top of the name table. That table is what promotes a token the finder
         * missed, so losing the protagonist from it is a question answered from
         * the wrong paragraphs.
         */
        val key: String get() = key(name)

        companion object {
            /**
             * Lowercased and diacritics folded, to match the index's own
             * `unicode61 remove_diacritics 2` tokeniser.
             */
            fun key(name: String): String = name.folded().trimmingWhitespaceAndNewlines()
        }
    }

    /**
     * What finds the names, swappable for a test or for a platform that grows
     * a real tagger. Read on every call, so it can be replaced at any time.
     */
    @Volatile
    var tagger: NameTagger = HeuristicNameTagger

    /**
     * Honorifics that get joined onto a name and then make two spellings of
     * one person. "Mr. Rabbit" and "Rabbit" must be the same row, or the most
     * mentioned character is split in half and neither half wins.
     */
    val honorifics: Set<String> = setOf(
        "mr", "mrs", "miss", "ms", "sir", "dr", "doctor", "lady", "lord",
        "madam", "madame", "master", "professor", "prof", "rev", "reverend",
        "st", "saint", "captain", "capt", "colonel", "major", "aunt", "uncle",
    )

    /**
     * Personal names in one chapter's rendered text, counted and located.
     *
     * @param spineIndex stamped onto the results; no I/O happens here.
     */
    fun names(text: String, spineIndex: Int): List<Name> {
        if (text.isEmpty()) return emptyList()
        val found = LinkedHashMap<String, Name>()
        for (tagged in tagger.personalNames(text)) {
            val cleaned = normalise(tagged.text) ?: continue
            // The offset the finder reported, not searched for again: the same
            // name occurs dozens of times in a chapter and a fresh search would
            // report the first one every time, which is the difference between
            // "first met on page 40" and "first met on page 1" — and therefore
            // between hiding a character the reader has not met and revealing
            // them.
            val existing = found[cleaned.key]
            found[cleaned.key] = if (existing != null) {
                existing.copy(mentions = existing.mentions + 1, firstOffset = minOf(existing.firstOffset, tagged.offset))
            } else {
                Name(name = cleaned.display, spineIndex = spineIndex, firstOffset = tagged.offset, mentions = 1)
            }
        }
        return found.values.toList()
    }

    /** A spelling worth indexing, and the key its counts are pooled under. */
    data class Normalised(val display: String, val key: String)

    /**
     * Strips the honorific, drops what is not worth indexing, and returns both
     * the display spelling and the key the counts are pooled under.
     */
    fun normalise(raw: String): Normalised? {
        val trimmed = raw.trimmingScalars { isWhitespaceOrNewline(it) || (it < 0x10000 && it.toChar() in NORMALISE_TRIM) }
        if (trimmed.isEmpty()) return null

        val words = trimmed.split(' ', '\n', ' ').filter { it.isNotEmpty() }.toMutableList()
        while (words.isNotEmpty()) {
            val bare = words.first().lowercasedSwift().trimmingCharacters(".")
            if (bare in honorifics && words.size > 1) words.removeAt(0) else break
        }
        val display = words.joinToString(" ")
        if (display.graphemeCount() <= 1) return null
        // A lowercase "name" is the tagger mis-firing on a common noun; an
        // initial on its own ("A.", "T.") is not a person anyone asks about.
        val initial = display.firstCodePoint ?: return null
        if (!isSwiftUppercase(initial)) return null
        return Normalised(display, Name.key(display))
    }

    private const val NORMALISE_TRIM = ".,;:!?'’\"“”()"

    /**
     * Pools per-chapter results into one table, summing mentions and keeping
     * the earliest sighting so the boundary can hide a character not yet met.
     */
    fun merge(names: List<Name>): List<Name> {
        // Two passes, because choosing which spelling to show is a comparison
        // of two complete counts. Fold straight into the key and the incumbent
        // is a running total while the challenger is one chapter's — which
        // makes the answer depend on the order the chapters arrived in.
        val bySpelling = LinkedHashMap<String, Name>()
        for (name in names) {
            val identity = name.key + "\u0000" + name.name
            val existing = bySpelling[identity]
            if (existing == null) {
                bySpelling[identity] = name
                continue
            }
            var merged = existing.copy(mentions = existing.mentions + name.mentions)
            if (earlier(name, merged)) merged = merged.copy(spineIndex = name.spineIndex, firstOffset = name.firstOffset)
            bySpelling[identity] = merged
        }

        // The spelling is chosen from complete per-spelling counts, before
        // anything is added up. The Swift client once compared each challenger
        // against the incumbent's running total, walking an unordered
        // dictionary, so BRONTE(9), Bronte(10), Brontë(5) pooled to "Bronte" on
        // some launches and "BRONTE" on others.
        val byKey = HashMap<String, MutableList<Name>>()
        for (spelling in bySpelling.values) byKey.getOrPut(spelling.key) { mutableListOf() }.add(spelling)

        val pooled = ArrayList<Name>()
        // Sorted keys, so nothing downstream can inherit the map's order either.
        for (key in byKey.keys.sorted()) {
            val spellings = byKey[key] ?: continue
            if (spellings.isEmpty()) continue
            // Whichever spelling the book prints more often wins the row, so
            // "RYN" in a heading does not become the name a chip offers.
            // `prefers` is a total order — count, then not-shouting, then
            // alphabetical — so this picks one answer and always the same one.
            var winner = spellings.sortedWith { left, right ->
                when {
                    prefers(left.name, right.name, left.mentions, right.mentions) -> -1
                    prefers(right.name, left.name, right.mentions, left.mentions) -> 1
                    else -> 0
                }
            }[0]
            winner = winner.copy(mentions = spellings.sumOf { it.mentions })
            for (spelling in spellings) {
                if (earlier(spelling, winner)) winner = winner.copy(spineIndex = spelling.spineIndex, firstOffset = spelling.firstOffset)
            }
            pooled.add(winner)
        }
        return pooled.sortedWith { left, right ->
            if (left.mentions == right.mentions) left.name.compareTo(right.name) else right.mentions.compareTo(left.mentions)
        }
    }

    /**
     * Whichever sighting the reader would have reached first, which is the one
     * the boundary has to compare against.
     */
    internal fun earlier(candidate: Name, incumbent: Name): Boolean =
        candidate.spineIndex < incumbent.spineIndex ||
            (candidate.spineIndex == incumbent.spineIndex && candidate.firstOffset < incumbent.firstOffset)

    /**
     * Which of two spellings of one name to show.
     *
     * Whichever the book prints more often; on a tie the one that is not
     * shouted, because an all-capitals spelling is a chapter heading and the
     * ordinary one is the character.
     */
    fun prefers(candidate: String, incumbent: String, mentions: Int, existing: Int): Boolean {
        if (mentions != existing) return mentions > existing
        val candidateShouts = isAllCaps(candidate)
        val incumbentShouts = isAllCaps(incumbent)
        if (candidateShouts != incumbentShouts) return incumbentShouts
        return candidate < incumbent
    }

    internal fun isAllCaps(name: String): Boolean {
        val letters = name.codePointList().filter(::isSwiftLetter)
        return letters.isNotEmpty() && letters.all(::isSwiftUppercase)
    }
}

/** One name the tagger found: the text as printed and where it starts. */
data class TaggedName(val text: String, val offset: Int)

/**
 * What finds personal names in a piece of text: `NLTagger(.nameType)` with
 * `.joinNames` on Apple's platforms.
 */
fun interface NameTagger {
    /** Every mention of a person, in order, with its UTF-16 offset in [text]. */
    fun personalNames(text: String): List<TaggedName>
}
