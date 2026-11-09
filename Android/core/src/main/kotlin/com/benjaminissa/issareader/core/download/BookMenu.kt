package com.benjaminissa.issareader.core.download

import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.BookFormat
import com.benjaminissa.issareader.core.model.Status
import com.benjaminissa.issareader.core.sync.StarRating

/**
 * What a book's hold or right-click menu offers, wherever the book is drawn.
 *
 * Every surface that shows a book — a grid cell, a rail cover, the Continue
 * card, a row in the Reading tab or the Downloads list, a television poster —
 * offers the same menu, so the decisions about it are made once, here, where
 * they can be tested, and the views only draw the answer. A menu that offers
 * Read on an audiobook or "Go to Series" on the series' own page goes wrong
 * without anything failing.
 *
 * The items come in groups, drawn with a divider between them:
 * 1. View details · Read or Resume · Listen or Now Playing
 * 2. Mark as ▸ · Rate ▸
 * 3. Go to Series · More by ‹author›
 * 4. The editions: one inline, or several behind "Downloads ▸"
 * 5. A Downloads row's own "Remove download", last
 */
data class BookMenu(
    /** The groups, in order, none of them empty. */
    val sections: List<List<Item>>,
) {
    /** Which screen the menu was opened on, so it does not offer the way to where the reader already is. */
    sealed interface Place {
        /** A shelf with no subject of its own: the library, the Reading tab, Browse, Listening, the Downloads list. */
        data object Shelf : Place

        /** A book's own page (its related rails), by uuid. */
        data class BookPage(val uuid: String) : Place

        /** A series page, by name. */
        data class Series(val name: String) : Place

        /** An author's page, by name. */
        data class Author(val name: String) : Place

        /** A tag's page, by name. */
        data class Tag(val name: String) : Place
    }

    /**
     * What the platform drawing the menu can do. Mark as and Rate are not
     * here: every platform can set a status and a rating, and on a
     * television the menu is the only place it can.
     */
    @JvmInline
    value class Capabilities(val rawValue: Int) {
        operator fun contains(other: Capabilities): Boolean = rawValue and other.rawValue == other.rawValue

        operator fun plus(other: Capabilities): Capabilities = Capabilities(rawValue or other.rawValue)

        companion object {
            /** A screen about the book to go to. */
            val DETAILS = Capabilities(1 shl 0)

            /** Open the reader. */
            val READ = Capabilities(1 shl 1)

            /** Start the audio, and somewhere to show it playing. */
            val LISTEN = Capabilities(1 shl 2)

            /** Push a series or an author's page. */
            val NAVIGATE = Capabilities(1 shl 3)

            /** Save, pause, resume and remove editions. */
            val DOWNLOADS = Capabilities(1 shl 4)

            /** Phones, tablets and the library window. */
            val ALL = DETAILS + READ + LISTEN + NAVIGATE + DOWNLOADS

            /** A settings window: no stack to push a page onto. */
            val SETTINGS_WINDOW = DETAILS + READ + LISTEN + DOWNLOADS

            /**
             * A television. Pressing a poster already opens the book's one
             * screen, which is the read-along; there is no detail page, no
             * series or author page, and nowhere to show playback controls but
             * that screen.
             */
            val TELEVISION = DOWNLOADS
        }
    }

    /** Everything the menu depends on besides the book. */
    data class Inputs(
        val isSignedIn: Boolean = true,
        /** The server's statuses. Empty hides Mark as. */
        val statuses: List<Status> = emptyList(),
        /** This reader's own rating of the book. */
        val rating: Double? = null,
        /** Whether this book's audio is what is playing. */
        val isPlaying: Boolean = false,
        /** Editions on this device and staying there (a removal inside its undo window is not one). */
        val downloadedFormats: Set<BookContentService.Format> = emptySet(),
        /** The download state of each edition that has one. */
        val downloadStates: Map<BookContentService.Format, DownloadManager.State> = emptyMap(),
        /** Names of the series the library groups — those with two books or more. A series of one has no page. */
        val groupedSeries: Set<String> = emptySet(),
        /** How many books the library holds by the book's first author, this one included. */
        val firstAuthorBookCount: Int = 0,
        val place: Place = Place.Shelf,
        /** The edition a Downloads row stands for. Its removal is the row's own, drawn last. */
        val focusEdition: BookContentService.Format? = null,
        val capabilities: Capabilities = Capabilities.ALL,
    )

    sealed interface Item {
        data object Details : Item

        /** "Read" or "Resume": [BookPrimaryAction.reading]'s compact title, so the menu and the book page agree. */
        data class Read(val title: String) : Item

        data object Listen : Item

        data object NowPlaying : Item

        /** One entry per server status, the book's own marked. */
        data class MarkAs(val choices: List<StatusChoice>) : Item

        /** The current whole-star rating, null when unrated. Clear rating is offered only when there is one. */
        data class Rate(val current: Int?) : Item

        data class GoToSeries(val name: String) : Item

        data class MoreBy(val author: String) : Item

        /** The one edition there is, drawn inline. */
        data class Edition(val action: EditionAction) : Item

        /** Several editions, behind a "Downloads" submenu. */
        data class Downloads(val actions: List<EditionAction>) : Item

        /** A Downloads row's own removal, destructive and last. */
        data class RemoveFocused(val format: BookContentService.Format) : Item
    }

    data class StatusChoice(val status: Status, val isCurrent: Boolean) {
        val id: String get() = status.uuid
    }

    /**
     * The one thing the menu offers for one edition: the same choice the
     * book page's edition menu makes, reduced to its first applicable item.
     */
    data class EditionAction(val format: BookContentService.Format, val kind: Kind) {
        enum class Kind { SAVE, PAUSE, RESUME, RETRY, REMOVE }

        val id: String get() = format.rawValue

        val isDestructive: Boolean get() = kind == Kind.REMOVE

        /**
         * The item's words. Inline, the menu holds one edition and the verb is
         * enough; inside "Downloads" it has to say which edition it means.
         */
        fun title(namingEdition: Boolean): String {
            val edition = format.displayName
            return when (kind) {
                Kind.SAVE -> if (namingEdition) "Save $edition for offline" else "Save for offline"
                Kind.PAUSE -> if (namingEdition) "Pause $edition download" else "Pause download"
                Kind.RESUME -> if (namingEdition) "Resume $edition download" else "Resume download"
                Kind.RETRY -> if (namingEdition) "Try $edition again" else "Try again"
                Kind.REMOVE -> if (namingEdition) "Remove $edition download" else "Remove download"
            }
        }

        /** The SF Symbol the Swift client draws; the Android app maps it to its own icon. */
        val systemImage: String
            get() = when (kind) {
                Kind.SAVE -> "arrow.down.circle"
                Kind.PAUSE -> "pause.circle"
                Kind.RESUME -> "play.circle"
                Kind.RETRY -> "arrow.clockwise"
                Kind.REMOVE -> "trash"
            }
    }

    /** Every item, for a caller that only needs to know what is there. */
    val items: List<Item> get() = sections.flatten()

    val isEmpty: Boolean get() = sections.isEmpty()

    companion object {
        /** The order the book page lists editions in. */
        internal val editionOrder = listOf(
            BookContentService.Format.EBOOK, BookContentService.Format.AUDIOBOOK, BookContentService.Format.READALOUD,
        )

        fun resolve(book: Book, inputs: Inputs): BookMenu {
            val can = inputs.capabilities
            val sections = mutableListOf<List<Item>>()
            fun add(group: List<Item>) {
                if (group.isNotEmpty()) sections.add(group)
            }

            if (!inputs.isSignedIn) {
                // Signed out there is no catalogue to act on and no server to
                // tell, but a file on this device is still the reader's to
                // delete — that is why signing out can keep downloads at all.
                if (Capabilities.DOWNLOADS in can) {
                    add(
                        editionItems(
                            editions(inputs.downloadedFormats, inputs.focusEdition)
                                .map { EditionAction(it, EditionAction.Kind.REMOVE) },
                        ),
                    )
                }
                inputs.focusEdition?.let { add(listOf(Item.RemoveFocused(it))) }
                return BookMenu(sections)
            }

            // 1. Opening the book.
            val opening = mutableListOf<Item>()
            if (Capabilities.DETAILS in can) opening.add(Item.Details)
            if (Capabilities.READ in can) {
                BookPrimaryAction.reading(book)?.let { opening.add(Item.Read(it.title(compact = true))) }
            }
            val formats = book.servableFormats
            if (Capabilities.LISTEN in can && (BookFormat.AUDIOBOOK in formats || BookFormat.READALOUD in formats)) {
                opening.add(if (inputs.isPlaying) Item.NowPlaying else Item.Listen)
            }
            add(opening)

            // 2. The reader's own say about it.
            val opinion = mutableListOf<Item>()
            if (inputs.statuses.isNotEmpty()) {
                opinion.add(Item.MarkAs(inputs.statuses.map { StatusChoice(it, isCurrent = it.uuid == book.status?.uuid) }))
            }
            // Through `StarRating`, never a bare conversion of the server's
            // number: a rating of 1e300 trapped every time this menu was built.
            opinion.add(Item.Rate(inputs.rating?.let(StarRating::wholeStars)))
            add(opinion)

            // 3. Where it sits in the library.
            val neighbours = mutableListOf<Item>()
            if (Capabilities.NAVIGATE in can) {
                val series = book.primarySeries?.name
                if (series != null && series in inputs.groupedSeries && inputs.place != Place.Series(series)) {
                    neighbours.add(Item.GoToSeries(series))
                }
                val author = book.authors.firstOrNull()?.name
                if (author != null && inputs.firstAuthorBookCount > 1 && inputs.place != Place.Author(author)) {
                    neighbours.add(Item.MoreBy(author))
                }
            }
            add(neighbours)

            // 4. Its editions.
            if (Capabilities.DOWNLOADS in can) {
                val servable = formats.mapNotNull { BookContentService.Format.fromRawValue(it.rawValue) }.toSet()
                add(
                    editionItems(
                        editions(servable, inputs.focusEdition).map {
                            EditionAction(it, kind(inputs.downloadStates[it], onDisk = it in inputs.downloadedFormats))
                        },
                    ),
                )
            }

            // 5. The row's own removal.
            inputs.focusEdition?.let { add(listOf(Item.RemoveFocused(it))) }
            return BookMenu(sections)
        }

        private fun editions(
            formats: Set<BookContentService.Format>,
            focus: BookContentService.Format?,
        ): List<BookContentService.Format> = editionOrder.filter { it in formats && it != focus }

        private fun editionItems(actions: List<EditionAction>): List<Item> = when (actions.size) {
            0 -> emptyList()
            1 -> listOf(Item.Edition(actions[0]))
            else -> listOf(Item.Downloads(actions))
        }

        /**
         * The book page's edition menu, in its order: a transfer in flight or
         * paused is the more urgent truth; then a file on disk, which nothing
         * should offer to fetch again — not even after a failed re-download,
         * for the reason [BookPrimaryAction] puts the file above a failure;
         * then a failure; and only then the offer to save it.
         */
        internal fun kind(state: DownloadManager.State?, onDisk: Boolean): EditionAction.Kind {
            if (state != null && state.isActive) return EditionAction.Kind.PAUSE
            if (state is DownloadManager.State.Paused) return EditionAction.Kind.RESUME
            if (onDisk) return EditionAction.Kind.REMOVE
            if (state?.isFailure == true) return EditionAction.Kind.RETRY
            return EditionAction.Kind.SAVE
        }
    }
}
