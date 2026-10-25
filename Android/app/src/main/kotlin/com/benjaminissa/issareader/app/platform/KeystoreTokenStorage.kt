package com.benjaminissa.issareader.app.platform

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.benjaminissa.issareader.core.auth.TokenPersisting
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The sign-in token, encrypted with a key that never leaves this phone.
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
 */
class KeystoreTokenStorage(
    private val directory: File,
    private val keys: KeyProvider = AndroidKeystoreKeys,
) : TokenPersisting {
    /** The key the tokens are sealed with. */
    fun interface KeyProvider {
        fun key(): SecretKey
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
            // reader, not a crash.
            IssaLog.error("Couldn't read the stored token", mapOf("error" to error.javaClass.simpleName))
            null
        }
    }

    override fun write(token: String, account: String): Boolean = try {
        directory.mkdirs()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, keys.key())
        val sealed = cipher.iv + cipher.doFinal(token.toByteArray(Charsets.UTF_8))
        val target = file(account)
        val partial = File(directory, target.name + ".partial")
        partial.writeBytes(sealed)
        partial.renameTo(target) || run {
            partial.delete()
            false
        }
    } catch (error: Exception) {
        IssaLog.error("Couldn't store the token", mapOf("error" to error.javaClass.simpleName))
        false
    }

    override fun delete(account: String): Boolean {
        val file = file(account)
        return !file.exists() || file.delete()
    }

    /** One file per server, named by a hash of the account so no address is written in the clear. */
    private fun file(account: String): File {
        val digest = MessageDigest.getInstance("SHA-256").digest(account.toByteArray(Charsets.UTF_8))
        return File(directory, digest.joinToString("") { "%02x".format(it) } + ".token")
    }

    /** The production key: created once in the Android Keystore, never exported. */
    object AndroidKeystoreKeys : KeyProvider {
        private const val ALIAS = "issa.token"

        @Synchronized
        override fun key(): SecretKey {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            (store.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            generator.init(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
            return generator.generateKey()
        }
    }

    private companion object {
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_LENGTH = 12
        const val TAG_BITS = 128
    }
}
