package com.benjaminissa.issareader.app.media

import android.content.Context
import android.net.Uri
import com.benjaminissa.issareader.core.model.Book
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.io.File
import java.io.FileNotFoundException
import java.nio.file.Files

/**
 * The car's covers: served from the cover cache's files by address, read-only,
 * and never a path.
 */
@RunWith(RobolectricTestRunner::class)
class CoverProviderTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private lateinit var directory: File

    @Before
    fun setUp() {
        directory = Files.createTempDirectory("covers").toFile()
        CarCovers.install(
            object : CarCovers.Source {
                override val directory: File get() = this@CoverProviderTest.directory
                override suspend fun fetch(book: Book): File? = null
            },
        )
        Robolectric.setupContentProvider(CoverProvider::class.java, CarCovers.authority(context))
    }

    @After
    fun tearDown() {
        CarCovers.install(null)
        directory.deleteRecursively()
    }

    /** A server book's address names its square cover's key in the cover cache. */
    @Test
    fun aBookHasAnAddress() {
        val dracula = book("Dracula")
        val uri = checkNotNull(CarCovers.uri(context, dracula))
        assertEquals("content", uri.scheme)
        assertEquals(CarCovers.authority(context), uri.authority)
        assertEquals(CarCovers.key(dracula), uri.lastPathSegment)
        assertTrue(CarCovers.key(dracula).endsWith("-square"))
    }

    /** A book from the reader's own files has none: it never reaches the car. */
    @Test
    fun aLocalBookHasNone() {
        assertNull(CarCovers.uri(context, book("Mine", narrated = true, local = true)))
    }

    /** A cover on disk is served as it is. */
    @Test
    fun servesTheCachedFile() {
        val dracula = book("Dracula")
        val bytes = byteArrayOf(1, 2, 3, 4)
        File(directory, "${CarCovers.key(dracula)}.jpg").writeBytes(bytes)
        val uri = checkNotNull(CarCovers.uri(context, dracula))
        val read = context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
        assertArrayEquals(bytes, read)
        assertEquals("image/jpeg", context.contentResolver.getType(uri))
    }

    /** Never a path, and never a write. */
    @Test
    fun refusesWhatIsNotACover() {
        File(directory.parentFile, "secret.jpg").writeText("no")
        for (path in listOf("..%2Fsecret", "missing")) {
            val uri = Uri.parse("content://${CarCovers.authority(context)}/$path")
            assertThrowsNotFound { context.contentResolver.openInputStream(uri) }
        }
        assertTrue(!CarCovers.isKey("..") && !CarCovers.isKey("a/b") && !CarCovers.isKey(""))
        val dracula = book("Dracula")
        File(directory, "${CarCovers.key(dracula)}.jpg").writeBytes(byteArrayOf(1))
        val uri = checkNotNull(CarCovers.uri(context, dracula))
        try {
            context.contentResolver.openOutputStream(uri)
            throw AssertionError("a cover must not be writable")
        } catch (_: SecurityException) {
        } catch (_: FileNotFoundException) {
        }
    }

    private fun assertThrowsNotFound(block: () -> Unit) {
        try {
            block()
            throw AssertionError("expected FileNotFoundException")
        } catch (_: FileNotFoundException) {
        }
    }
}
