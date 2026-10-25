package com.benjaminissa.issareader.app

import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.StoredPosition
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.playback.AudioExtraction
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.testing.Fixtures
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import java.io.File
import java.util.UUID
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * What a test needs to run `ReaderModel.open(pageSize)` itself rather than
 * stand in for it: a book file somewhere `open` will find it, and a server
 * whose answer to "where was I" the test decides — including when.
 *
 * @param position nil is a 404, which is what a book never opened gets.
 * @param holdingPosition whether the position read is held until
 *   [releasePosition] — the window in which `open` has a package and no chapter.
 */
class ReaderOpening(
    epub: ByteArray,
    position: StoredPosition? = null,
    holdingPosition: Boolean = false,
) {
    private val uuid = UUID.randomUUID().toString().lowercase()

    /** The book, under a uuid of its own so nothing else in the run is keyed the same way. */
    val book: Book = SharedFixtures.book("Opening $uuid", uuid = uuid)

    /** The directory the book's file was planted in, handed to the model. */
    val directory: File = temporaryDirectory("issa-reader-opening-$uuid")

    /** This opening's own server: it answers one question, where the reader was. */
    val server = OpeningServer(position)

    init {
        BookContentService.localUrl(directory, uuid, BookContentService.Format.EBOOK).writeBytes(epub)
        if (holdingPosition) server.hold(Endpoint.positions(uuid))
    }

    /** A model for the planted book, pointed at the planted file and this opening's server. */
    fun model(scope: CoroutineScope, style: ReaderStyle = ReaderStyle(), backend: () -> com.benjaminissa.issareader.playback.MediaBackend = { ScriptedBackend() }): ReaderModel {
        val model = ReaderModel(book, server.session(), testServices(scope, backend), style)
        model.booksDirectory = directory
        return model
    }

    /** Waits, for a bounded time, until the model's position read has reached the server. */
    suspend fun positionRequested(within: Duration = 10.seconds): Boolean {
        val deadline = System.nanoTime() + within.inWholeNanoseconds
        while (!server.hasRequestedPosition && System.nanoTime() < deadline) delay(10.milliseconds)
        return server.hasRequestedPosition
    }

    /** Answers a held position read. */
    fun releasePosition() = server.release(Endpoint.positions(uuid))

    /** Everything the opening left behind: the planted file, the narration `open` extracted, and the server. */
    fun tearDown() {
        server.close()
        directory.deleteRecursively()
        AudioExtraction.removeExtractedAudio(book.uuid)
    }

    companion object {
        /** The read-along fixture every suite in here uses. */
        fun readalongFixture(): ByteArray = Fixtures.epub("readalong.epub").readBytes()

        /** Alice, the long text fixture. */
        fun aliceFixture(): ByteArray = Fixtures.epub("alice.epub").readBytes()
    }
}

/** A Storyteller server that answers one question: where the reader was. */
class OpeningServer(position: StoredPosition?) : StubServer({ request -> (this as OpeningServer).answerFor(request) }) {
    private val body: String? = position?.let { IssaJson.encodeToString(StoredPosition.serializer(), it) }
    @Volatile var hasRequestedPosition = false
        private set

    internal fun answerFor(request: SentRequest): Answer {
        val isPosition = request.path.endsWith("/positions") && request.method == "GET"
        if (!isPosition) return Answer(404, "{}")
        hasRequestedPosition = true
        return if (body == null) Answer(404, "{}") else Answer(200, body)
    }
}
