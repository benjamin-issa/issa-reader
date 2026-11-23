package com.benjaminissa.issareader.app.platform

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.benjaminissa.issareader.core.auth.TokenPersisting
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import java.io.File
import java.security.InvalidKeyException
import java.security.KeyStore
import java.security.MessageDigest
import java.security.UnrecoverableEntryException
import java.security.UnrecoverableKeyException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The sign-in token — and, in a directory and under a key of their own, the
 * reader's own AI keys — encrypted with a key that never leaves this phone.
 *
 * Android's counterpart of `KeychainStorage`. The key is an AES-256 key in the
 * Android Keystore — hardware-backed where the phone has the hardware — and
 * the ciphertext sits in `noBackupFilesDir`, one file per server. That keeps
 * the iPhone's two promises:
 *
 * - *After first unlock*: credential-encrypted storage and a key that does not
 *   require the user to authenticate are both available once the phone has
 *   been unlocked since boot, so a download or a queued position write can run
 *   with the screen locked.
 * - *This device only*: a no-backup file is never in a backup or a device
 *   transfer, and a Keystore key cannot be exported. A credential the server
 *   treats as lasting thirty-five years must not turn up working on another
 *   phone with no sign-in.
 *
 * The cipher is injectable so the file handling can be tested on the JVM,
 * where there is no Keystore.
 *
 * A key that exists but can no longer be used — the Keystore lost or
 * invalidated it, which some phones do when the lock screen changes — is
 * replaced, and only by [write]: an explicit sign-in or key save, where the
 * reader is there to sign in again. [read] never replaces or deletes anything,
 * so a passing Keystore fault cannot sign the reader out of every server and
 * take their AI keys with it. Nothing is ever stored without the key: a write
 * that cannot seal fails, and the caller refuses the sign-in.
 */
class KeystoreTokenStorage(
    private val directory: File,
    private val keys: KeyProvider = AndroidKeystoreKeys,
) : TokenPersisting {
    /** The key the tokens are sealed with. */
    fun interface KeyProvider {
        fun key(): SecretKey

        /**
         * Deletes the key, so the next [key] makes a new one. Asked only after
         * the key has failed to seal, permanently.
         */
        fun discard() {}
    }

    override fun read(account: String): String? {
        val file = file(account)
        if (!file.exists()) return null
        return try {
            val bytes = file.readBytes()
            if (bytes.size <= IV_LENGTH) return null
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, keys.key(), GCMParameterSpec(TAG_BITS, bytes, 0, IV_LENGTH))
            String(cipher.doFinal(bytes, IV_LENGTH, bytes.size - IV_LENGTH), Charsets.UTF_8)
        } catch (error: Exception) {
            // A key that was wiped (the phone's lock screen removed on some
            // devices) leaves ciphertext nothing can open. That is a signed-out
            // reader, not a crash. Nothing is discarded here, whatever the
            // error: a fault that passes must not cost every sign-in.
            IssaLog.error("Couldn't read the stored token", describe(error))
            null
        }
    }

    /**
     * Seals [token] and writes it. Sealing and writing fail apart: a key that
     * will not seal may be replaced once, a file that will not write never
     * costs the key.
     */
    override fun write(token: String, account: String): Boolean = synchronized(this) {
        val sealed = seal(token) ?: return false
        try {
            directory.mkdirs()
            val target = file(account)
            val partial = File(directory, target.name + PARTIAL_SUFFIX)
            partial.writeBytes(sealed)
            partial.renameTo(target) || run {
                partial.delete()
                IssaLog.error("Couldn't store the token", mapOf("error" to "rename failed"))
                false
            }
        } catch (error: Exception) {
            IssaLog.error("Couldn't store the token", describe(error))
            false
        }
    }

    /**
     * [text] sealed under the key, or null when no key will seal it.
     *
     * A permanent key error replaces the key and tries once more. Entries
     * sealed with the old key can no longer be opened by anything, so they go
     * with it rather than being retried, and failing, at every launch.
     */
    private fun seal(text: String): ByteArray? {
        try {
            return encrypt(text)
        } catch (error: Exception) {
            if (!isPermanentKeyFailure(error)) {
                IssaLog.error("Couldn't seal the token", describe(error))
                return null
            }
            IssaLog.error("The token's key can no longer be used; replacing it", describe(error))
        }
        try {
            keys.discard()
        } catch (error: Exception) {
            IssaLog.error("Couldn't discard the unusable key", describe(error))
            return null
        }
        removeOrphans()
        return try {
            encrypt(text)
        } catch (error: Exception) {
            IssaLog.error("Couldn't seal the token with a new key", describe(error))
            null
        }
    }

    private fun encrypt(text: String): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, keys.key())
        return cipher.iv + cipher.doFinal(text.toByteArray(Charsets.UTF_8))
    }

    /** Every entry this store holds: sealed under the key just discarded, so nothing can open them now. */
    private fun removeOrphans() {
        val orphans = directory.listFiles().orEmpty().filter { it.name.endsWith(SUFFIX) || it.name.endsWith(SUFFIX + PARTIAL_SUFFIX) }
        val removed = orphans.count { it.delete() }
        IssaLog.warning(
            "removed entries sealed with the discarded key",
            mapOf("removed" to removed.toString(), "found" to orphans.size.toString()),
        )
    }

    override fun delete(account: String): Boolean {
        val file = file(account)
        return !file.exists() || file.delete()
    }

    /** One file per server, named by a hash of the account so no address is written in the clear. */
    private fun file(account: String): File {
        val digest = MessageDigest.getInstance("SHA-256").digest(account.toByteArray(Charsets.UTF_8))
        return File(directory, digest.joinToString("") { "%02x".format(it) } + SUFFIX)
    }

    /** The sign-in token's key: created once in the Android Keystore, never exported. */
    object AndroidKeystoreKeys : KeyProvider by AndroidKeystoreKey("issa.token")

    /**
     * A key created once in the Android Keystore under [alias], never
     * exported. The sign-in token and the reader's own AI keys are sealed
     * under different aliases, so neither store can open the other's files.
     */
    class AndroidKeystoreKey(private val alias: String) : KeyProvider {
        override fun discard() = synchronized(LOCK) {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(alias)
        }

        override fun key(): SecretKey = synchronized(LOCK) {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            (store.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            generator.init(
                KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
            generator.generateKey()
        }

        private companion object {
            /** One lock for every alias: two stores asking at once must not both create a key. */
            val LOCK = Any()
        }
    }

    internal companion object {
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_LENGTH = 12
        const val TAG_BITS = 128
        const val SUFFIX = ".token"
        const val PARTIAL_SUFFIX = ".partial"

        /** An error's class and message for the log: never the token, the key or the ciphertext, which no error here carries. */
        fun describe(error: Throwable): Map<String, String> =
            mapOf("error" to error.javaClass.simpleName, "message" to (error.message ?: ""))

        /**
         * Whether [error] says the key itself is unusable for good: lost,
         * invalidated, or unrecoverable from the Keystore. Not a file error,
         * and not a Keystore fault that says it may pass — on API 33 and later
         * the Keystore marks those, and one is honoured wherever it appears in
         * the chain — nor a key waiting for the reader to authenticate.
         */
        fun isPermanentKeyFailure(error: Throwable): Boolean {
            val chain = generateSequence(error) { it.cause }.take(8).toList()
            if (chain.any(::isTransientKeystoreFailure)) return false
            if (chain.any { it.javaClass.name == USER_NOT_AUTHENTICATED }) return false
            return chain.any {
                it is InvalidKeyException || it is UnrecoverableKeyException || it is UnrecoverableEntryException
            }
        }

        /** `android.security.keystore.UserNotAuthenticatedException`, named so the check costs no class load on the JVM. */
        private const val USER_NOT_AUTHENTICATED = "android.security.keystore.UserNotAuthenticatedException"

        /** `android.security.KeyStoreException.isTransientFailure()`, API 33: by name, as the class is not there before it. */
        private fun isTransientKeystoreFailure(error: Throwable): Boolean {
            if (error.javaClass.name != "android.security.KeyStoreException") return false
            return runCatching { error.javaClass.getMethod("isTransientFailure").invoke(error) as Boolean }.getOrDefault(false)
        }
    }
}
