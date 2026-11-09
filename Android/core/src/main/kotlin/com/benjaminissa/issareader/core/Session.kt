package com.benjaminissa.issareader.core

import com.benjaminissa.issareader.core.auth.TokenPersisting
import com.benjaminissa.issareader.core.auth.TokenStore
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.model.ServerCapabilities
import com.benjaminissa.issareader.core.model.ServerGeneration
import com.benjaminissa.issareader.core.model.User
import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.networking.AppFacingError
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.networking.ProbeResponse
import com.benjaminissa.issareader.core.networking.StorytellerError
import com.benjaminissa.issareader.core.networking.TokenProviding
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import okhttp3.OkHttpClient
import java.net.URI
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * One signed-in connection to a Storyteller server.
 *
 * Multi-server is modelled from the start — the token store's account, the
 * local store and the widget snapshot are all keyed by server — because
 * retrofitting it later means migrating all three.
 *
 * Swift's `@Observable @MainActor` class, as a plain class exposing its state
 * as [StateFlow]s. The background work it starts — the capability probes, and
 * moving to [State.Expired] when the token dies — runs on [dispatcher].
 *
 * @param http the transport, so a test can answer without a server. The same
 *   seam `LibraryStore` has for its directory and `DownloadManager` for its
 *   destination — without one, the states this type exists to distinguish
 *   can only be reached by running the app.
 * @param logoutTimeout how long sign-out waits for the server to revoke the
 *   token before going on without it. A seam for the same reason: a test
 *   cannot wait five seconds per case.
 */
class Session(
    val serverUrl: URI,
    keychain: TokenPersisting,
    http: OkHttpClient = ApiClient.sharedHttpClient,
    private val logoutTimeout: Duration = 5.seconds,
    dispatcher: CoroutineDispatcher = Dispatchers.Default,
) {
    sealed interface State {
        data object SignedOut : State
        data object SigningIn : State
        data class SignedIn(val user: User) : State

        /**
         * Signed in once, but the token stopped working. Distinct from
         * [SignedOut] so the app can keep the server and say what happened
         * rather than dropping the reader back to a blank form.
         */
        data object Expired : State

        /**
         * Authenticated, but the identity call did not come back. The reason
         * is carried so the app can say it rather than dropping the reader on
         * a blank form with nothing to go on.
         */
        data class Failed(val reason: String) : State
    }

    private val mutableState = MutableStateFlow<State>(State.SignedOut)
    val state: StateFlow<State> = mutableState.asStateFlow()

    private val mutableCapabilities = MutableStateFlow(ServerCapabilities.baseline)
    val capabilities: StateFlow<ServerCapabilities> = mutableCapabilities.asStateFlow()

    private val tokens = TokenStore(serverKey = serverUrl.toString(), keychain = keychain)
    val client = ApiClient(baseUrl = serverUrl, tokens = tokens, http = http)

    /**
     * The transport, kept for the logout, which is sent through a client of
     * its own (see [revokeOnServer]).
     */
    private val transport = http

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)

    /**
     * A hold seam: awaited by the revoke just before its request is handed to
     * the transport, so a test can start it after the deadline has passed —
     * the race a loaded machine produces — on purpose rather than by luck.
     */
    internal var logoutWillSend: (suspend () -> Unit)? = null

    /**
     * The same token the API client uses, for the background downloads, which
     * build their own requests rather than going through [ApiClient].
     */
    val tokenProvider: TokenProviding get() = tokens

    init {
        // Set before anything can reach the store, so no 401 goes unannounced.
        tokens.setInvalidationHandler {
            // `Failed` too: a restore that could not reach the server leaves
            // the session there with the token still in use, and nothing
            // re-runs the identity call. A 401 then is the same lapse as one
            // while signed in — left in `Failed`, the token was gone and
            // nothing ever said so.
            mutableState.update { state ->
                when (state) {
                    is State.SignedIn, is State.Failed -> State.Expired
                    State.SignedOut, State.SigningIn, State.Expired -> state
                }
            }
        }
    }

    /**
     * Adopts a token obtained from either sign-in path and confirms it works.
     *
     * The server's `expires_in` is unusable (it is `epochMillis * 1000`), so
     * validity is established by calling the API, never by arithmetic.
     */
    suspend fun adopt(token: String) {
        mutableState.value = State.SigningIn
        // A token the device would not keep is a sign-in that ends at the next
        // launch, back at the form with nothing saying why. Said now, and
        // before the identity call: there is no point asking who a token
        // belongs to when it is not going to be kept.
        if (!tokens.set(token)) {
            IssaLog.error("sign-in token could not be saved", mapOf("server" to serverUrl.toString()))
            mutableState.value = State.Failed(UNSAVED_TOKEN_MESSAGE)
            return
        }
        loadIdentity()
    }

    /**
     * Whether a credential is stored for this server at all.
     *
     * Asked *before* showing the cached shelf: the offline-first path used to
     * present a whole library on the strength of the local database alone,
     * which meant signing out left every book still readable.
     */
    suspend fun hasStoredCredential(): Boolean = tokens.hasToken()

    /** Restores a previously stored token, if there is one that still works. */
    suspend fun restore() {
        if (!tokens.hasToken()) {
            mutableState.value = State.SignedOut
            return
        }
        mutableState.value = State.SigningIn
        // Restoring, not signing in fresh: we had a token and the server
        // refused it, which is a *lapsed session*, not "never signed in".
        // `loadIdentity` hard-coded `SignedOut` for both, so a returning
        // reader whose token had expired was dropped to a blank server form
        // with their address forgotten — which is precisely the state
        // `Expired` exists to avoid.
        loadIdentity(rejectionMeans = State.Expired)
    }

    suspend fun signOut() {
        // Tell the server, with the token it is to revoke. A token minted
        // through /token/app lasts thirty-five years; dropping it locally
        // without revoking it leaves a working credential behind on a device
        // the reader may be signing out of precisely because they lost it.
        // Best effort: no network must ever trap someone in a signed-in state.
        //
        // The token is read before it is forgotten and travels with the
        // request, so the revoke is authorised whenever it is sent — even
        // after this method has returned.
        val token = tokens.currentToken()
        val forgotten = tokens.forget()
        if (token != null) {
            revokeOnServer(token)
        } else {
            // A 401 already dropped it: the server refused that token, so
            // there is nothing left to revoke.
            IssaLog.info("no token held at sign-out; nothing to revoke")
        }
        if (!forgotten) {
            // Signed out all the same — the reader asked to be — but a
            // credential may still be on disk, and the next launch would
            // restore it. The log is the only place that can say so.
            IssaLog.error("sign-out could not delete the stored token", mapOf("server" to serverUrl.toString()))
        }
        mutableState.value = State.SignedOut
    }

    /**
     * The logout POST, bounded by [logoutTimeout].
     *
     * Unbounded, it waited out the transport's own timeout against a server
     * that does not answer — one switched off, or at a LAN address while the
     * reader is on cellular, where a SYN gets no reply at all — and the reader
     * stayed signed in, library open, for all of it. On the timeout sign-out
     * goes on locally and the revoke goes on without it.
     *
     * The revoke is never cancelled. It used to be — the loser of a race — and
     * on a loaded machine the deadline could pass before the request had even
     * reached the transport, so it was cancelled unsent and the server never
     * revoked a token that lasts thirty-five years. It now runs on its own
     * ([BoundedWait]), carrying the token it revokes through a client of its
     * own: [TokenStore.forget] has emptied the store by the time it may be
     * sent, and a 401 on it must not reach the store either. `/logout` is a
     * route 2.14.21 and every 3.x serve.
     */
    private suspend fun revokeOnServer(token: String) {
        val revoker = ApiClient(baseUrl = serverUrl, tokens = RevokedToken(token), http = transport)
        val hold = logoutWillSend
        val timeout = logoutTimeout
        val finished = BoundedWait.run(timeout) {
            hold?.invoke()
            // Nothing cancels this coroutine. Were anything to, the revoke
            // would be lost — and whether a request is still sent from a
            // cancelled call is a race it sometimes wins, which is how the
            // racing version passed alone and failed under load. Decided here
            // instead, every time, and said.
            if (!currentCoroutineContext().isActive) {
                IssaLog.error("logout cancelled before it was sent; the token was not revoked")
                return@run
            }
            try {
                revoker.post(Endpoint.logout, emptyMap<String, String>())
            } catch (_: StorytellerError) {
            }
        }
        if (!finished) {
            IssaLog.warning(
                "logout not answered in time; signing out locally, revoke still running",
                mapOf("timeout" to timeout.toString()),
            )
        }
    }

    private suspend fun loadIdentity(rejectionMeans: State = State.SignedOut) {
        for (attempt in 1..IDENTITY_ATTEMPTS) {
            // Cancellation is not a network fault and must not be retried as
            // one. A cancelled sign-in fails every request at once and returns
            // from every backoff at once, so the three attempts and both
            // backoffs were spent inside 153ms — and the reader was then told
            // to check they were on the same network as their server. Leaving
            // `state` alone is the point: whatever cancelled this knows more
            // about why than a guess at the network does.
            if (!currentCoroutineContext().isActive) {
                IssaLog.warning("identity check cancelled", mapOf("attempt" to attempt.toString()))
                return
            }
            try {
                val user = client.get(Endpoint.user, User.serializer())
                mutableState.value = State.SignedIn(user)
                // Off the critical path: six probes that all 404 on a 2.x
                // server used to run before the reader was considered signed
                // in, and every one widened the window for the failure above.
                val apiClient = client
                scope.launch { mutableCapabilities.value = probeCapabilities(apiClient) }
                return
            } catch (_: StorytellerError.NotAuthenticated) {
                // The token is genuinely bad; retrying cannot help. *What* that
                // means differs by caller: a fresh sign-in that is refused
                // never had a session, while a restore that is refused had one
                // that lapsed — and the second keeps the reader's server.
                mutableState.value = rejectionMeans
                return
            } catch (e: CancellationException) {
                IssaLog.warning("identity check cancelled", mapOf("attempt" to attempt.toString()))
                throw e
            } catch (e: StorytellerError) {
                if (e.isRetryable && attempt < IDENTITY_ATTEMPTS) {
                    delay(300L * attempt)
                    continue
                }
                IssaLog.failure("identity", e, mapOf("attempt" to attempt.toString()))
                mutableState.value = State.Failed(AppFacingError.text(e))
                return
            } catch (e: Exception) {
                IssaLog.failure("identity", e, mapOf("attempt" to attempt.toString()))
                mutableState.value = State.Failed(AppFacingError.text(e))
                return
            }
        }
        // The same reason as above: three transport failures caused by
        // cancellation must not arrive as a sentence about the reader's
        // network.
        if (!currentCoroutineContext().isActive) {
            IssaLog.warning("identity check cancelled", mapOf("attempt" to "final"))
            return
        }
        mutableState.value =
            State.Failed("Couldn't reach your server. Check that you're on the same network as your server.")
    }

    companion object {
        internal const val UNSAVED_TOKEN_MESSAGE = "Your sign-in couldn't be saved on this device. Try again."

        /**
         * How many times to ask for the identity before giving up.
         *
         * The device grant ends with the app returning from the browser after a
         * minute or so of the user approving there, and the very next request
         * reuses a pooled connection that idled through all of it. A
         * half-closed one fails as "network connection lost" and works
         * immediately on retry — which is exactly the "sign-in always fails the
         * first time" report. A token that was just minted deserves more than
         * one attempt.
         */
        private const val IDENTITY_ATTEMPTS = 3

        /**
         * Establishes which generation of Storyteller this is, and which
         * optional 3.x endpoints it has.
         *
         * The generation comes from `/server/public`, by feature: a 3.x server
         * answers it with its identity, 2.14.21 answers 404 (and so do 3.x
         * betas before beta.21, which the home, shelves and sidebar probes tell
         * apart — see [generation]), and anything else — no answer, a 5xx, a
         * proxy's HTML page with a 200 on it — leaves the generation
         * undetermined rather than guessed. On 3.x, `/server/details` then
         * supplies the version string, for display only: a self-built image
         * reports "2.14.21" there, so it cannot be what decides.
         *
         * 2.14.21 answers 404 for the five feature routes too; the client
         * derives the same information locally from the full catalogue, so a
         * missing endpoint costs no functionality. Probed once per sign-in and
         * held on the session.
         */
        internal suspend fun probeCapabilities(client: ApiClient): ServerCapabilities = coroutineScope {
            val discovery = async { client.probeResponse(Endpoint.V3.serverPublic) }
            val home = async { client.probeStatus(Endpoint.V3.homeSections) }
            val shelves = async { client.probeStatus(Endpoint.V3.shelves) }
            val sidebar = async { client.probeStatus(Endpoint.V3.sidebar) }
            val facets = async { client.probeStatus(Endpoint.V3.libraryFacets) }
            val nextUp = async { client.probeStatus(Endpoint.V3.nextUp) }

            fun present(status: Int) = status in 200..299
            var caps = ServerCapabilities(
                homeSections = present(home.await()),
                shelves = present(shelves.await()),
                sidebar = present(sidebar.await()),
                libraryFacets = present(facets.await()),
                nextUp = present(nextUp.await()),
            )
            val generation = generation(
                fromPublicProbe = discovery.await(),
                threeXRoutesAnswer = caps.homeSections || caps.shelves || caps.sidebar,
            )
            caps = caps.copy(generation = generation, serverDiscovery = generation == ServerGeneration.V3)

            if (caps.generation == ServerGeneration.V3) {
                val details = client.probeResponse(Endpoint.V3.serverDetails)
                if (details != null && present(details.status)) {
                    val version = runCatching {
                        IssaJson.decodeFromString(ServerDetails.serializer(), details.data.decodeToString()).version
                    }.getOrNull()
                    caps = caps.copy(reportedVersion = version)
                }
            }

            IssaLog.info(
                "server detected",
                mapOf(
                    "generation" to (caps.generation?.rawValue ?: "undetermined"),
                    "version" to (caps.reportedVersion ?: "unreported"),
                ),
            )
            caps
        }

        /**
         * What one `/server/public` answer says about the generation.
         *
         * A 2xx counts only if it is shaped like Storyteller's identity: a
         * reverse proxy that serves its own sign-in page with a 200 for every
         * unknown path would otherwise make every 2.x server behind it "3.x".
         *
         * A 404 counts as 2.x only when nothing else says otherwise. 3.x betas
         * up to beta.20 have no `/server/public` either, and 404 it just as
         * 2.14.21 does — but they answer home, shelves and the sidebar, which
         * no 2.x serves. Filed as `V2`, such a server never had a null-status
         * book filed; undetermined, it does, which is what null is for.
         *
         * @param threeXRoutesAnswer whether any of home, shelves or the sidebar
         *   answered 2xx.
         */
        fun generation(fromPublicProbe: ProbeResponse?, threeXRoutesAnswer: Boolean = false): ServerGeneration? {
            val probe = fromPublicProbe ?: return null
            return when (probe.status) {
                in 200..299 -> {
                    val identity = runCatching {
                        IssaJson.decodeFromString(ServerPublic.serializer(), probe.data.decodeToString())
                    }.getOrNull()
                    if (identity != null) ServerGeneration.V3 else null
                }
                404 -> if (threeXRoutesAnswer) null else ServerGeneration.V2
                else -> null
            }
        }
    }

    /**
     * The two fields that make a `/server/public` answer Storyteller's.
     * `publicUrl` and `publicKey` come too; nothing here needs them.
     */
    @Serializable
    private data class ServerPublic(val id: String, val capabilities: List<String>)

    /**
     * `/server/details` carries name, icon and capabilities as well; only the
     * version is shown, and anything more would be new functionality.
     */
    @Serializable
    private data class ServerDetails(val version: String)
}

/**
 * The one token a sign-out revokes, held apart from the store it has already
 * been dropped from. A 401 on the revoke changes nothing: the token is being
 * let go of either way.
 */
private class RevokedToken(private val token: String) : TokenProviding {
    override suspend fun currentToken(): String = token
    override suspend fun invalidate() {}
}
