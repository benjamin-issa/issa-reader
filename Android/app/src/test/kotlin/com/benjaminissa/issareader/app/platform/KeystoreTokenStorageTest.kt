package com.benjaminissa.issareader.app.platform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import javax.crypto.KeyGenerator

/**
 * The token file round-trips, is per server, never holds the token in the
 * clear, and a lost key reads as signed out. A key that will not work is
 * replaced by a write and never by a read.
 */
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

    // A key that exists and will not work

    /**
     * A Keystore key standing in for the real one: it fails with [failure]
     * while [broken], counts its discards, and after a discard is a new key —
     * still broken if [staysBroken].
     */
    private class FlakyKey(var failure: () -> Exception, var broken: Boolean = true, val staysBroken: Boolean = false) :
        KeystoreTokenStorage.KeyProvider {
        var discards = 0

        /** How many times the key was asked for, and how many of those came before the first discard. */
        var keyCalls = 0
        var keyCallsBeforeDiscard = 0

        /** A fault that passes by itself: the key works again after this many more failing calls, with no discard. */
        var passesAfter: Int? = null
        private var current = newKey()

        override fun key(): javax.crypto.SecretKey {
            keyCalls += 1
            if (discards == 0) keyCallsBeforeDiscard += 1
            if (broken) {
                passesAfter?.let { left ->
                    if (left <= 0) {
                        broken = false
                        return current
                    }
                    passesAfter = left - 1
                }
                throw failure()
            }
            return current
        }

        override fun discard() {
            discards += 1
            current = newKey()
            broken = staysBroken
        }

        fun newKey(): javax.crypto.SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    }

    /** Every file in the store, as bytes. */
    private fun contents(): Map<String, ByteArray> =
        folder.root.walk().filter { it.isFile }.associate { it.relativeTo(folder.root).path to it.readBytes() }

    /** Whether any file holds [secret] in any form it could be written in. */
    private fun anyFileHolds(secret: String): Boolean = contents().values.any { bytes ->
        val forms = listOf(
            secret.toByteArray(Charsets.UTF_8),
            secret.toByteArray(Charsets.UTF_16LE),
            secret.toByteArray(Charsets.UTF_16BE),
            java.util.Base64.getEncoder().encode(secret.toByteArray(Charsets.UTF_8)),
        )
        forms.any { form -> bytes.indexOf(form) >= 0 }
    }

    private fun ByteArray.indexOf(part: ByteArray): Int {
        if (part.isEmpty() || part.size > size) return -1
        outer@ for (start in 0..size - part.size) {
            for (i in part.indices) if (this[start + i] != part[i]) continue@outer
            return start
        }
        return -1
    }

    /**
     * A key the Keystore can no longer use is discarded once on a sign-in, a
     * new one made, and the sign-in kept. What the old key sealed can never be
     * opened again, so it goes with it.
     */
    @Test
    fun `a write replaces a key that will not work, once, and removes what it sealed`() {
        val key = FlakyKey(failure = { java.security.InvalidKeyException("Keystore operation failed") }, broken = false)
        val storage = KeystoreTokenStorage(folder.root, key)
        assertTrue(storage.write("old-token", "https://old.example"))
        val orphan = folder.root.listFiles().orEmpty().single()
        key.broken = true

        assertTrue(storage.write("new-token", "https://new.example"))

        assertEquals(1, key.discards)
        assertEquals("new-token", storage.read("https://new.example"))
        assertFalse("an entry sealed with the discarded key was left to fail at every launch", orphan.exists())
        assertNull(storage.read("https://old.example"))
        assertEquals(1, folder.root.listFiles().orEmpty().size)
    }

    /** An unrecoverable key entry is the same fault, by another name. */
    @Test
    fun `an unrecoverable key is replaced on a write`() {
        val key = FlakyKey(failure = { java.security.UnrecoverableKeyException("key blob corrupted") })
        val storage = KeystoreTokenStorage(folder.root, key)

        assertTrue(storage.write("token", "https://a.example"))

        assertEquals(1, key.discards)
        assertEquals("token", storage.read("https://a.example"))
    }

    /** A key that will not work even when new: the write fails, after one discard, and nothing holds the token. */
    @Test
    fun `a key that stays broken refuses the write and stores nothing`() {
        val key = FlakyKey(
            // `KeyPermanentlyInvalidatedException` is one of these; the JVM has no Keystore to throw it.
            failure = { java.security.InvalidKeyException("Key permanently invalidated") },
            staysBroken = true,
        )
        val storage = KeystoreTokenStorage(folder.root, key)

        assertFalse(storage.write("secret-token-value", "https://a.example"))

        assertEquals(1, key.discards)
        assertFalse("the token was written in some form", anyFileHolds("secret-token-value"))
        assertTrue("a file was written with no key to seal it", contents().isEmpty())
        assertNull(storage.read("https://a.example"))
    }

    /** A file that cannot be written is not the key's fault, and never costs it. */
    @Test
    fun `a disk error does not discard the key`() {
        val key = FlakyKey(failure = { IllegalStateException("unused") }, broken = false)
        // A file where the store's directory should be: nothing can be written inside it.
        val notADirectory = folder.newFile("not-a-directory")
        val storage = KeystoreTokenStorage(notADirectory, key)

        assertFalse(storage.write("secret-token-value", "https://a.example"))

        assertEquals(0, key.discards)
        assertFalse(anyFileHolds("secret-token-value"))
    }

    /**
     * A read never discards anything: a passing Keystore fault at launch
     * must not sign the reader out of every server.
     */
    @Test
    fun `a read with a broken key discards nothing and leaves the files`() {
        val key = FlakyKey(failure = { java.security.InvalidKeyException("Keystore operation failed") }, broken = false)
        val storage = KeystoreTokenStorage(folder.root, key)
        assertTrue(storage.write("token-a", "https://a.example"))
        assertTrue(storage.write("token-b", "https://b.example"))
        val before = contents()
        key.broken = true

        assertNull(storage.read("https://a.example"))
        assertNull(storage.read("https://b.example"))

        assertEquals(0, key.discards)
        assertEquals(before.keys, contents().keys)
        for ((name, bytes) in before) assertTrue("$name changed", bytes.contentEquals(contents().getValue(name)))
        key.broken = false
        assertEquals("the key was kept: the fault passed and the sign-in is still there", "token-a", storage.read("https://a.example"))
    }

    /** A Keystore fault that may pass fails the write and keeps the key, and every sign-in sealed with it. */
    @Test
    fun `a transient error on a write does not discard the key`() {
        val key = FlakyKey(failure = { java.security.KeyStoreException("Keystore not available") }, broken = false)
        val storage = KeystoreTokenStorage(folder.root, key)
        assertTrue(storage.write("token-a", "https://a.example"))
        key.broken = true

        assertFalse(storage.write("token-b", "https://b.example"))
        key.failure = { java.security.ProviderException("Keystore operation failed") }
        assertFalse(storage.write("token-c", "https://c.example"))

        assertEquals(0, key.discards)
        key.broken = false
        assertEquals("token-a", storage.read("https://a.example"))
    }

    /** What a failure says about the key, wherever it sits in the chain. */
    @Test
    fun `key faults are told apart`() {
        val fault = KeystoreTokenStorage.Companion::keyFault
        assertEquals(KeystoreTokenStorage.KeyFault.PERMANENT, fault(java.security.UnrecoverableKeyException("x")))
        assertEquals(KeystoreTokenStorage.KeyFault.PERMANENT, fault(java.security.UnrecoverableEntryException("x")))
        // Before API 33 a passing Keystore fault and a broken key are both a
        // bare InvalidKeyException: neither can be called permanent.
        assertEquals(KeystoreTokenStorage.KeyFault.UNCLASSIFIED, fault(java.security.InvalidKeyException("Keystore operation failed")))
        assertEquals(KeystoreTokenStorage.KeyFault.UNCLASSIFIED, fault(java.security.ProviderException("x", java.security.InvalidKeyException("y"))))
        assertEquals(KeystoreTokenStorage.KeyFault.NOT_THE_KEY, fault(java.security.KeyStoreException("x")))
        assertEquals(KeystoreTokenStorage.KeyFault.NOT_THE_KEY, fault(java.io.IOException("disk full")))
        assertEquals(KeystoreTokenStorage.KeyFault.NOT_THE_KEY, fault(java.security.ProviderException("x")))
    }

    /** An unrecoverable key is replaced at once, with no second try of the same key. */
    @Test
    fun `a permanent fault is not retried on the same key`() {
        val key = FlakyKey(failure = { java.security.UnrecoverableKeyException("key blob corrupted") })
        assertTrue(KeystoreTokenStorage(folder.root, key).write("token", "https://a.example"))
        assertEquals(1, key.discards)
        assertEquals("the same key was tried again", 1, key.keyCallsBeforeDiscard)
    }

    /**
     * Android 11 and 12: a Keystore fault that passes arrives as an
     * InvalidKeyException. Tried once more with the same key, it seals, and
     * nothing is discarded: every other server's sign-in is still there.
     */
    @Test
    fun `an unclassified fault that passes on the same key costs nothing`() {
        val key = FlakyKey(failure = { java.security.InvalidKeyException("Keystore operation failed") }, broken = false)
        val storage = KeystoreTokenStorage(folder.root, key)
        assertTrue(storage.write("token-a", "https://a.example"))
        val before = contents()
        key.broken = true
        key.passesAfter = 1

        assertTrue(storage.write("token-b", "https://b.example"))

        assertEquals("a passing fault cost the key", 0, key.discards)
        assertEquals("token-a", storage.read("https://a.example"))
        assertEquals("token-b", storage.read("https://b.example"))
        for ((name, bytes) in before) assertTrue("$name changed", bytes.contentEquals(contents().getValue(name)))
    }

    /** One that fails on the same key too: the key is replaced once, the new entry reads back, and the old entries go after it. */
    @Test
    fun `an unclassified fault that does not pass replaces the key once`() {
        val key = FlakyKey(failure = { java.security.InvalidKeyException("Keystore operation failed") }, broken = false)
        val storage = KeystoreTokenStorage(folder.root, key)
        assertTrue(storage.write("token-a", "https://a.example"))
        val orphan = folder.root.listFiles().orEmpty().single()
        key.broken = true

        assertTrue(storage.write("token-b", "https://b.example"))

        assertEquals(1, key.discards)
        assertEquals("the same key was not tried again first", 3, key.keyCallsBeforeDiscard)
        assertEquals("token-b", storage.read("https://b.example"))
        assertFalse(orphan.exists())
    }

    /** The old entries go only once a new key has sealed: a new key that fails too leaves them where they are. */
    @Test
    fun `entries stay when the new key does not seal either`() {
        val key = FlakyKey(failure = { java.security.InvalidKeyException("Keystore operation failed") }, broken = false, staysBroken = true)
        val storage = KeystoreTokenStorage(folder.root, key)
        assertTrue(storage.write("token-a", "https://a.example"))
        val entry = folder.root.listFiles().orEmpty().single()
        key.broken = true

        assertFalse(storage.write("token-b", "https://b.example"))

        assertEquals(1, key.discards)
        assertTrue("an entry was removed though no new key sealed anything", entry.exists())
    }
}
