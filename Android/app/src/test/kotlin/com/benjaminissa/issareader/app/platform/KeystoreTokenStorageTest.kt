package com.benjaminissa.issareader.app.platform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import javax.crypto.KeyGenerator

/** The token file round-trips, is per server, never holds the token in the clear, and a lost key reads as signed out. */
class KeystoreTokenStorageTest {
    @get:Rule val folder = TemporaryFolder()

    private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private fun storage(k: javax.crypto.SecretKey = key) = KeystoreTokenStorage(folder.root, { k })

    @Test
    fun `a token round-trips per server`() {
        val storage = storage()
        assertTrue(storage.write("token-a", "https://a.example"))
        assertTrue(storage.write("token-b", "http://192.168.1.2:8001"))
        assertEquals("token-a", storage.read("https://a.example"))
        assertEquals("token-b", storage.read("http://192.168.1.2:8001"))
        assertNull(storage.read("https://unknown.example"))
    }

    @Test
    fun `nothing on disk names the server or holds the token`() {
        storage().write("secret-token-value", "https://library.example")
        for (file in folder.root.listFiles().orEmpty()) {
            assertFalse(file.name.contains("library"))
            assertFalse(String(file.readBytes(), Charsets.ISO_8859_1).contains("secret-token-value"))
        }
    }

    @Test
    fun `delete is definite, and deleting nothing succeeds`() {
        val storage = storage()
        storage.write("t", "s")
        assertTrue(storage.delete("s"))
        assertNull(storage.read("s"))
        assertTrue(storage.delete("s"))
    }

    @Test
    fun `ciphertext the key can no longer open reads as signed out`() {
        storage().write("t", "s")
        val other = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        assertNull(storage(other).read("s"))
    }
}
