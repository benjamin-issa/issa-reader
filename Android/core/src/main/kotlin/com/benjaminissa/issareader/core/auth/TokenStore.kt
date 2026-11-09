package com.benjaminissa.issareader.core.auth

import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.networking.TokenProviding
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Holds the bearer token for one server.
 *
 * The server's `/api/v2/token` response carries an `expires_in` of
 * `epochMillis * 1000`, which is not a duration and not usable for anything.
 * Token validity is therefore established by calling the API — `GET
 * /api/v2/user` on adopt — never by arithmetic on that number.
 *
 * Swift's actor, as a class whose state is guarded by a [Mutex].
 */
class TokenStore(private val serverKey: String, private val keychain: TokenPersisting) : TokenProviding {
    private val mutex = Mutex()
    private var token: String? = keychain.read(serverKey)

    /**
     * Called when the token stops working, so the app can ask for a new one
     * instead of quietly failing every request.
     */
    @Volatile private var onInvalidated: (() -> Unit)? = null

    fun setInvalidationHandler(handler: () -> Unit) {
        onInvalidated = handler
    }

    override suspend fun currentToken(): String? = mutex.withLock { token }

    /**
     * Holds a new token, and says whether it reached storage.
     *
     * A token storage refused is not held either. Memory mirrors storage, so
     * [hasToken] never vouches for a credential the next launch will not find;
     * what a refusal means is the caller's to decide, and `Session` fails the
     * sign-in on it rather than reporting one that will not last.
     */
    suspend fun set(newToken: String): Boolean = mutex.withLock {
        if (!keychain.write(newToken, serverKey)) return@withLock false
        token = newToken
        true
    }

    /**
     * Called on any 401. Drops the token so the UI can prompt for a new
     * sign-in; there is no refresh token to exchange.
     *
     * This matters more than it looks: the device grant mints a 30-day token
     * and the server offers no refresh, so every install reaches this path
     * eventually. Announcing it is the difference between "sign in again" and
     * an app where nothing loads and nothing says why.
     *
     * Returns nothing because it is [TokenProviding]'s requirement, which every
     * request path and test double shares; a refused delete is logged here
     * instead. [forget] is the path that reports one.
     */
    override suspend fun invalidate() {
        val handler = mutex.withLock {
            if (token == null) return
            token = null
            if (!keychain.delete(serverKey)) {
                IssaLog.error("rejected token could not be deleted", mapOf("server" to serverKey))
            }
            onInvalidated
        }
        handler?.invoke()
    }

    /**
     * Drops the token on purpose — signing out — and says whether storage
     * confirmed it gone.
     *
     * Unlike [invalidate], it asks storage even when nothing is held in memory
     * (a 401 may have dropped the token over a delete that failed), and it
     * announces nothing: a sign-out is not an expiry.
     */
    suspend fun forget(): Boolean = mutex.withLock {
        token = null
        keychain.delete(serverKey)
    }

    suspend fun hasToken(): Boolean = mutex.withLock { token != null }
}

/**
 * Persistence for a token. Backed by encrypted storage in the app (the
 * keychain on Apple platforms; on Android, a store keyed by the Android
 * Keystore), and by an in-memory map in tests.
 */
interface TokenPersisting {
    fun read(account: String): String?

    /**
     * Whether the token actually reached storage.
     *
     * Not `Unit`. Storage can refuse a write — on iOS, a background task
     * refreshing a token before first unlock — and a caller that cannot tell
     * the difference reports a successful sign-in over a credential that was
     * never saved.
     */
    fun write(token: String, account: String): Boolean

    /**
     * Whether the token is now definitely gone.
     *
     * A silent failure here is worse than a silent failed write: the UI shows
     * the reader signed out while a working credential stays on disk, and the
     * next launch restores into the library they believed they had left.
     */
    fun delete(account: String): Boolean
}
