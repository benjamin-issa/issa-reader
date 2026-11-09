package com.benjaminissa.issareader.core.download

import com.benjaminissa.issareader.core.assertThrowing
import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.networking.StorytellerError
import com.benjaminissa.issareader.core.temporaryDirectory
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * A finished download that is not the book: a 200 is not a book. Ported from
 * `DownloadValidationTests` in `DownloadManagerValidationTests.swift`.
 *
 * A finished transfer was judged by its status alone, so whatever came back
 * with a 200 — a proxy's sign-in page, a captive portal — was moved into place
 * as the book, opened to "Couldn't open this book" every time, and never
 * removed.
 */
class DownloadValidationTest {
    private fun TestScope.manager(books: File): DownloadManager =
        downloadManager(destinationFor = { BookContentService.localUrl(books, it.bookUuid, it.format) })

    /** Runs the finished-download callback for a transfer answered this way, and returns where the book would have landed. */
    private fun TestScope.finish(
        answer: DownloadAnswer,
        format: BookContentService.Format,
        subject: DownloadManager,
        root: File,
        books: File,
    ): File {
        val job = DownloadManager.Job("b", format)
        val task = DownloadAnswer.finishedTask(answer)
        task.description = subject.liveTaskDescription(job)
        subject.onFinishedDownloading(task, DownloadAnswer.arrivedFile(answer, root))
        settle { subject.state(job) != null }
        return BookContentService.localUrl(books, "b", format)
    }

    /** A page or an error body answered with 200 is not moved into place as the book. */
    @Test
    fun aPageIsNotTheBook() {
        val cases = listOf(
            DownloadAnswer.HTML to BookContentService.Format.READALOUD,
            DownloadAnswer.HTML to BookContentService.Format.EBOOK,
            DownloadAnswer.JSON to BookContentService.Format.EBOOK,
            DownloadAnswer.HTML to BookContentService.Format.AUDIOBOOK,
            DownloadAnswer.JSON to BookContentService.Format.AUDIOBOOK,
        )
        for ((answer, format) in cases) {
            runTest {
                val root = temporaryDirectory("issa-validate")
                try {
                    val books = File(root, "Books")
                    val subject = manager(books)
                    val finished = mutableListOf<DownloadManager.Job>()
                    subject.onFinished = { finished.add(it) }

                    val destination = finish(answer, format, subject, root, books)

                    val job = DownloadManager.Job("b", format)
                    assertEquals("a page was taken for the book ($answer, $format)", true, subject.state(job)?.isFailure)
                    assertFalse(destination.exists())
                    assertTrue("onFinished would have put it on the shelf as downloaded", finished.isEmpty())
                    subject.shutDown()
                } finally {
                    root.deleteRecursively()
                }
            }
        }
    }

    /** Finishing a read-along whose body is a page fails it and moves nothing. */
    @Test
    fun finishingWithAPageFails() = runTest {
        val root = temporaryDirectory("issa-validate")
        try {
            val books = File(root, "Books")
            val subject = manager(books)
            val job = DownloadManager.Job("b", BookContentService.Format.READALOUD)
            val arrived = DownloadAnswer.arrivedFile(DownloadAnswer.HTML, root)

            subject.finishDownload(job, arrived, TransferResponse(200, "text/html"))
            settle { subject.state(job) != null }

            assertEquals(true, subject.state(job)?.isFailure)
            assertFalse(BookContentService.localUrl(books, "b", BookContentService.Format.READALOUD).exists())
            subject.shutDown()
        } finally {
            root.deleteRecursively()
        }
    }

    /** A refused status is still reported as the status. */
    @Test
    fun aRefusedStatusSaysSo() = runTest {
        val root = temporaryDirectory("issa-validate")
        try {
            val subject = manager(File(root, "Books"))
            val job = DownloadManager.Job("b", BookContentService.Format.EBOOK)
            val arrived = DownloadAnswer.arrivedFile(DownloadAnswer.EPUB, root)

            subject.finishDownload(job, arrived, TransferResponse(404, null))
            settle { subject.state(job) != null }

            assertEquals(DownloadManager.State.Failed("The server returned 404."), subject.state(job))
            subject.shutDown()
        } finally {
            root.deleteRecursively()
        }
    }

    /**
     * The book itself still lands, whatever its edition — and an audiobook is
     * not held to being a zip, because nothing here knows what container the
     * server keeps its audio in.
     */
    @Test
    fun theBookStillLands() {
        val cases = listOf(
            DownloadAnswer.EPUB to BookContentService.Format.READALOUD,
            DownloadAnswer.EPUB to BookContentService.Format.EBOOK,
            DownloadAnswer.AUDIO to BookContentService.Format.AUDIOBOOK,
            DownloadAnswer.EPUB to BookContentService.Format.AUDIOBOOK,
        )
        for ((answer, format) in cases) {
            runTest {
                val root = temporaryDirectory("issa-validate")
                try {
                    val books = File(root, "Books")
                    val subject = manager(books)

                    val destination = finish(answer, format, subject, root, books)

                    assertEquals("$answer, $format", DownloadManager.State.Finished, subject.state(DownloadManager.Job("b", format)))
                    assertTrue(destination.exists())
                    subject.shutDown()
                } finally {
                    root.deleteRecursively()
                }
            }
        }
    }
}

/**
 * Telling a book from what came in its place: only what is true of every
 * server. Ported from `DownloadedFileValidationTests`.
 */
class DownloadedFileValidationTest {
    private fun file(bytes: ByteArray): File {
        val file = File(System.getProperty("java.io.tmpdir"), "issa-validate-${java.util.UUID.randomUUID()}.tmp")
        file.writeBytes(bytes)
        return file
    }

    /** An EPUB edition is kept only when it begins as a zip, whatever type it is labelled with. */
    @Test
    fun epubsAreZips() {
        for (format in listOf(BookContentService.Format.EBOOK, BookContentService.Format.READALOUD)) {
            val zip = file(DownloadAnswer.zipHead)
            val page = file(DownloadAnswer.page)
            val empty = file(ByteArray(0))
            try {
                for (type in listOf("application/epub+zip", "application/octet-stream", "text/html", null)) {
                    assertNull("$format $type", BookContentService.validateDownloadedFile(zip, format, type))
                    assertNotNull("$format $type", BookContentService.validateDownloadedFile(page, format, type))
                }
                assertNotNull(BookContentService.validateDownloadedFile(empty, format, null))
                assertNotNull(BookContentService.validateDownloadedFile(File(page, "absent"), format, null))
            } finally {
                listOf(zip, page, empty).forEach { it.delete() }
            }
        }
    }

    /** An audiobook is refused only as a page or JSON: nothing is assumed about its container. */
    @Test
    fun audiobooksAreJudgedByTheirType() {
        val audio = file(DownloadAnswer.AUDIO.body)
        try {
            for (type in listOf("audio/mp4", "audio/mpeg", "application/zip", "application/octet-stream", null)) {
                assertNull("$type", BookContentService.validateDownloadedFile(audio, BookContentService.Format.AUDIOBOOK, type))
            }
            for (type in listOf("text/html", "TEXT/HTML", "application/json")) {
                assertNotNull(type, BookContentService.validateDownloadedFile(audio, BookContentService.Format.AUDIOBOOK, type))
            }
        } finally {
            audio.delete()
        }
    }
}

/**
 * Fetching a book to open it takes the same care: it moves the file into
 * place before it can look at it, so a page that arrived there is deleted
 * again rather than kept. Ported from `EnsureDownloadedValidationTests`.
 */
class EnsureDownloadedValidationTest {
    private fun book(): Book {
        val json = bookJson(uuid = "0198f1c2-6f5a-7000-8000-abcdef012345", title = "Dracula")
        json["readaloud"] = mapOf("uuid" to "r", "filepath" to "r.epub", "identifiers" to emptyList<Any>())
        return decodeBook(json)
    }

    private fun content(answer: DownloadAnswer, directory: File): BookContentService {
        val client = ApiClient(baseUrl = DownloadAnswer.base(answer), tokens = StubTokens(), http = DownloadAnswer.http)
        return BookContentService(client, cacheDirectory = directory)
    }

    /** A page answered with 200 is deleted, and the open fails saying why. */
    @Test
    fun aPageIsDeletedAndRefused() = runBlocking {
        val directory = temporaryDirectory("issa-ensure")
        try {
            val book = book()
            val content = content(DownloadAnswer.HTML, directory)

            assertThrowing<StorytellerError> { content.ensureDownloaded(book, BookContentService.Format.READALOUD) }
            assertFalse(
                "kept, it is opened and refused again on every launch",
                content.isDownloaded(book, BookContentService.Format.READALOUD),
            )
        } finally {
            directory.deleteRecursively()
        }
    }

    /** The book itself is kept. */
    @Test
    fun theBookIsKept() = runBlocking {
        val directory = temporaryDirectory("issa-ensure")
        try {
            val file = content(DownloadAnswer.EPUB, directory).ensureDownloaded(book(), BookContentService.Format.READALOUD)
            assertTrue(file.exists())
        } finally {
            directory.deleteRecursively()
        }
    }
}
