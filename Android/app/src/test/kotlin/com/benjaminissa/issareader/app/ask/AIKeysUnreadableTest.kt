package com.benjaminissa.issareader.app.ask

import com.benjaminissa.issareader.app.platform.KeystoreTokenStorage
import com.benjaminissa.issareader.app.ui.settings.KEY_NOT_SAVED
import com.benjaminissa.issareader.app.ui.settings.keyUnreadable
import com.benjaminissa.issareader.ask.ProviderKind
import com.benjaminissa.issareader.ask.ProviderModel
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.security.InvalidKeyException
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/**
 * A reader's own AI key whose Keystore key stops working: it is asked for
 * again, and nothing — not the registration, not the sealed file — is deleted
 * on the way, because the fault may pass.
 */
class AIKeysUnreadableTest {
    @get:Rule val folder = TemporaryFolder()

    private val model = ProviderModel(id = "test-model", displayName = "Test Model", contextSize = 100_000)

    /** The Keystore key the AI keys are sealed with, which can be made to fail. */
    private class Key : KeystoreTokenStorage.KeyProvider {
        var broken = false
        var discards = 0
        private val key: SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

        override fun key(): SecretKey {
            if (broken) throw InvalidKeyException("Keystore operation failed")
            return key
        }

        override fun discard() {
            discards += 1
        }
    }

    @Test
    fun `a key that no longer decrypts is asked for again and nothing is deleted`() {
        val defaults = InMemoryKeyValueStore()
        val key = Key()
        val storage = KeystoreTokenStorage(folder.root, key)
        assertTrue(AIKeys(storage, defaults).register(ProviderKind.OPENAI, "sk-test-1", model))
        val sealed = folder.root.listFiles().orEmpty().toList()
        val registration = defaults.getString(AIKeys.REGISTRATIONS_KEY)
        key.broken = true

        val keys = AIKeys(storage, defaults)

        assertFalse("an unreadable key was offered to Ask", keys.hasAny)
        assertEquals(listOf(ProviderKind.OPENAI), keys.unreadable)
        assertTrue(keys.needsKeyAgain(ProviderKind.OPENAI))
        assertFalse(keys.needsKeyAgain(ProviderKind.ANTHROPIC))
        assertEquals("the registration was forgotten", registration, defaults.getString(AIKeys.REGISTRATIONS_KEY))
        assertTrue("the sealed key was deleted", sealed.isNotEmpty() && sealed.all { it.exists() })
        assertEquals("a read discarded the Keystore key", 0, key.discards)

        // The fault passes: the key is back, with nothing entered again.
        key.broken = false
        keys.refresh()
        assertEquals(listOf(ProviderKind.OPENAI), keys.registered)
        assertEquals("sk-test-1", keys.key(ProviderKind.OPENAI))
        assertTrue(keys.unreadable.isEmpty())
    }

    /** What Settings says for a key it cannot read, and for one it could not save. */
    @Test
    fun `the key screens say what happened`() {
        assertEquals(
            "Your OpenAI key can't be read on this phone any more. Enter it again to keep using it.",
            keyUnreadable(ProviderKind.OPENAI, noun = "phone"),
        )
        assertEquals(
            "The key couldn't be saved securely on this device, so it wasn't added. Restart the device and try again.",
            KEY_NOT_SAVED,
        )
    }
}
