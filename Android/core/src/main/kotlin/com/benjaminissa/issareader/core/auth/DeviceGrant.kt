package com.benjaminissa.issareader.core.auth

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.net.URI

/** Response to `POST /api/v2/device/start`. */
@Serializable
data class DeviceAuthorization(
    /**
     * The polling secret. Also embedded in [verificationUriComplete] and the QR
     * code, which is a deviation from RFC 8628 §3.3.1 (which puts the *user*
     * code there). Treat it as a credential and show it for as short a time as
     * possible.
     */
    @SerialName("device_code") val deviceCode: String,
    /** Short human-transcribable code, formatted `XXXX-XXXX` from an alphabet with no I/O/0/1. */
    @SerialName("user_code") val userCode: String,
    /** Where the user types the code by hand. */
    @SerialName("verification_uri") val verificationUri: String,
    /** Deep link that pre-identifies this request; the user only has to approve. */
    @SerialName("verification_uri_complete") val verificationUriComplete: String? = null,
    /** Seconds until this authorization expires. 900 on a default server. */
    @SerialName("expires_in") val expiresIn: Int,
    /** Minimum seconds between polls. */
    val interval: Int,
    /** Server-rendered SVG QR pointing at [verificationUriComplete]. */
    @SerialName("qr_svg_url") val qrSvgUrl: String? = null,
) {
    /**
     * What the tappable link and the QR carry: the pre-identified URL when the
     * server offers one, the plain address otherwise.
     *
     * Decision, 2026-09: use the complete URL everywhere, the QR on a
     * television included. It embeds `device_code`, the polling secret, so
     * someone who photographs the screen can race this app to redeem the
     * approval. That is accepted knowingly. The window is at most `expiresIn`
     * seconds and the code now rotates when it lapses; the approver still has
     * to be signed in to the server; and the thing readers actually gave up on
     * was scanning a code that then asked them to type eight more characters.
     *
     * The plain [verificationUri] is still what the screen prints, because
     * that is the address a person can type.
     */
    val approvalPayload: String get() = verificationUriComplete ?: verificationUri

    /** The same, as a URL, for opening or encoding. */
    val approvalUrl: URI? get() = runCatching { URI(approvalPayload) }.getOrNull()
}

/**
 * Successful `POST /api/v2/device/token` response.
 *
 * The same shape `POST /api/v2/token` returns, so both grants decode one type;
 * see [AccessTokenResponse] for why `expires_in` is not among its fields.
 */
typealias DeviceToken = AccessTokenResponse

/** The error codes `POST /api/v2/device/token` returns. */
enum class DeviceGrantError(val rawValue: String) {
    AUTHORIZATION_PENDING("authorization_pending"),

    /**
     * Returned for ANY poll arriving inside `interval`. This server uses it as
     * a plain rate limiter and does not advance its own clock, so a client must
     * keep polling at `interval` and must NOT add to the interval the way
     * RFC 8628 §3.5 prescribes — doing so ratchets the delay upward forever.
     */
    SLOW_DOWN("slow_down"),
    ACCESS_DENIED("access_denied"),
    EXPIRED_TOKEN("expired_token"),
    INVALID_REQUEST("invalid_request"),
    INVALID_GRANT("invalid_grant"),
    SERVER_ERROR("server_error"),
    ;

    companion object {
        fun fromRawValue(raw: String): DeviceGrantError? = entries.firstOrNull { it.rawValue == raw }
    }
}

sealed interface DeviceGrantOutcome {
    data class Granted(val token: String) : DeviceGrantOutcome
    data object Denied : DeviceGrantOutcome
    data object Expired : DeviceGrantOutcome
    data class Failed(val reason: String) : DeviceGrantOutcome

    /**
     * The caller walked away — the sign-in screen closed, or a fresh code
     * replaced this one.
     */
    data object Cancelled : DeviceGrantOutcome
}

/** One poll's result, as reported by the transport. */
sealed interface DevicePollResult {
    data class Token(val token: String) : DevicePollResult
    data class Error(val code: DeviceGrantError) : DevicePollResult

    /** Network failure — retried, never fatal on its own. */
    data class TransportFailure(val message: String) : DevicePollResult
}

/** Lets the flow be driven in tests without a network or a clock. */
interface DeviceGrantTransport {
    suspend fun start(): DeviceAuthorization
    suspend fun poll(deviceCode: String): DevicePollResult

    /**
     * Suspends for [seconds]. Tests substitute an instant implementation. Like
     * Swift's `try? await Task.sleep`, it returns rather than throws when the
     * caller is cancelled; the flow checks for that itself.
     */
    suspend fun wait(seconds: Double)
}

/**
 * Drives the RFC 8628 device authorization grant to completion.
 *
 * The only sign-in path on a television, and elsewhere the pairing-code route.
 *
 * It no longer runs behind "In your browser": that route is
 * [AppTokenSignInFlow], which takes a token straight out of a redirect and
 * never polls. The Swift doc described the older arrangement for two builds
 * after it was deleted, which is an invitation to wire the poll back in.
 *
 * Approval happens in the server's own web login either way, so whichever
 * OIDC provider the server admin configured is the one the reader sees, and
 * the client never implements an OIDC client itself.
 */
class DeviceGrantFlow(private val transport: DeviceGrantTransport) {
    /** Begins the grant and returns the codes to display. */
    suspend fun begin(): DeviceAuthorization = transport.start()

    /**
     * Polls until the request is approved, denied, or expires.
     *
     * `elapsed` is measured in whole poll intervals rather than wall-clock so
     * the loop is deterministic under a test transport.
     */
    suspend fun awaitApproval(authorization: DeviceAuthorization): DeviceGrantOutcome {
        val interval = maxOf(authorization.interval, 1).toDouble()
        val deadline = maxOf(authorization.expiresIn, 1).toDouble()
        var waited = 0.0
        var consecutiveTransportFailures = 0

        while (waited < deadline) {
            transport.wait(interval)
            waited += interval
            // The wait swallows cancellation, so without this the loop stops
            // waiting and then polls a server it has been told to leave alone,
            // as fast as it can, until the deadline.
            if (!currentCoroutineContext().isActive) return DeviceGrantOutcome.Cancelled

            when (val result = transport.poll(authorization.deviceCode)) {
                is DevicePollResult.Token -> return DeviceGrantOutcome.Granted(result.token)
                is DevicePollResult.Error -> when (result.code) {
                    DeviceGrantError.AUTHORIZATION_PENDING, DeviceGrantError.SLOW_DOWN ->
                        // Keep the cadence unchanged; see DeviceGrantError.SLOW_DOWN.
                        consecutiveTransportFailures = 0
                    DeviceGrantError.ACCESS_DENIED -> return DeviceGrantOutcome.Denied
                    DeviceGrantError.EXPIRED_TOKEN -> return DeviceGrantOutcome.Expired
                    DeviceGrantError.INVALID_REQUEST, DeviceGrantError.INVALID_GRANT ->
                        return DeviceGrantOutcome.Failed(result.code.rawValue)
                    DeviceGrantError.SERVER_ERROR -> {
                        // A 500 is worth retrying a few times; it is not a
                        // verdict on the authorization itself.
                        consecutiveTransportFailures += 1
                        if (consecutiveTransportFailures >= 5) return DeviceGrantOutcome.Failed(result.code.rawValue)
                    }
                }
                is DevicePollResult.TransportFailure -> {
                    consecutiveTransportFailures += 1
                    if (consecutiveTransportFailures >= 5) return DeviceGrantOutcome.Failed(result.message)
                }
            }
        }
        return DeviceGrantOutcome.Expired
    }
}
