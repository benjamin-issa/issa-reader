package com.benjaminissa.issareader.core.auth

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.fixture
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Drives the flow with a scripted transport so the polling semantics are
 * tested without a network or a real clock.
 */
private class ScriptedTransport(
    results: List<DevicePollResult>,
    interval: Int = 5,
    expiresIn: Int = 900,
) : DeviceGrantTransport {
    private val lock = Mutex()
    private val results = results.toMutableList()
    var pollCount = 0
        private set
    var totalWaited = 0.0
        private set

    private val authorization = DeviceAuthorization(
        deviceCode = "dev-code",
        userCode = "ABCD-EFGH",
        verificationUri = "http://example.test/device",
        verificationUriComplete = "http://example.test/device?device_code=dev-code",
        expiresIn = expiresIn,
        interval = interval,
        qrSvgUrl = null,
    )

    override suspend fun start(): DeviceAuthorization = authorization

    override suspend fun poll(deviceCode: String): DevicePollResult = lock.withLock {
        pollCount += 1
        if (results.isEmpty()) DevicePollResult.Error(DeviceGrantError.AUTHORIZATION_PENDING) else results.removeAt(0)
    }

    override suspend fun wait(seconds: Double) {
        lock.withLock { totalWaited += seconds }
    }
}

/** The device-code grant. Ported from `DeviceGrantTests.swift`. */
class DeviceGrantTest {
    private fun pending() = DevicePollResult.Error(DeviceGrantError.AUTHORIZATION_PENDING)

    private suspend fun approve(transport: ScriptedTransport): DeviceGrantOutcome =
        DeviceGrantFlow(transport).awaitApproval(transport.start())

    /** Decodes a real /device/start response. */
    @Test
    fun decodesStartResponse() {
        val auth = IssaJson.decodeFromString(DeviceAuthorization.serializer(), fixture("device-start"))
        assertEquals(5, auth.interval)
        assertEquals(900, auth.expiresIn)
        // XXXX-XXXX from an alphabet excluding I, O, 0 and 1.
        assertEquals(9, auth.userCode.length)
        assertTrue(auth.userCode.contains("-"))
        assertNotNull(auth.qrSvgUrl)
        // The polling secret, not the user code, is what the deep link carries.
        val complete = auth.verificationUriComplete!!
        assertTrue(complete.contains(auth.deviceCode))
        assertFalse(complete.contains(auth.userCode))
    }

    /** Keeps polling through authorization_pending and returns the token. */
    @Test
    fun pollsUntilGranted() = runBlocking {
        val transport = ScriptedTransport(listOf(pending(), pending(), DevicePollResult.Token("granted-token")))
        assertEquals(DeviceGrantOutcome.Granted("granted-token"), approve(transport))
        assertEquals(3, transport.pollCount)
    }

    /**
     * slow_down does not lengthen the polling interval. This server returns
     * slow_down for any poll inside the interval and does not advance its own
     * clock; RFC 8628's extra 5s per slow_down would ratchet the delay upward
     * without limit.
     */
    @Test
    fun slowDownDoesNotRatchet() = runBlocking {
        val slow = DevicePollResult.Error(DeviceGrantError.SLOW_DOWN)
        val transport = ScriptedTransport(listOf(slow, slow, slow, DevicePollResult.Token("t")), interval = 5)
        assertEquals(DeviceGrantOutcome.Granted("t"), approve(transport))
        // Four polls at a flat 5s each. A ratcheting client would have waited 50s.
        assertEquals(20.0, transport.totalWaited, 0.0)
    }

    /** access_denied and expired_token end the flow immediately. */
    @Test
    fun terminalErrors() = runBlocking {
        val denied = ScriptedTransport(listOf(DevicePollResult.Error(DeviceGrantError.ACCESS_DENIED)))
        assertEquals(DeviceGrantOutcome.Denied, approve(denied))

        val expired = ScriptedTransport(listOf(DevicePollResult.Error(DeviceGrantError.EXPIRED_TOKEN)))
        assertEquals(DeviceGrantOutcome.Expired, approve(expired))
    }

    /** Gives up after repeated server errors rather than polling forever. */
    @Test
    fun toleratesThenGivesUpOnServerErrors() = runBlocking {
        val transport = ScriptedTransport(List(5) { DevicePollResult.Error(DeviceGrantError.SERVER_ERROR) })
        assertEquals(DeviceGrantOutcome.Failed("server_error"), approve(transport))
    }

    /** A transient server error does not abort a flow that then succeeds. */
    @Test
    fun recoversFromTransientServerError() = runBlocking {
        val transport = ScriptedTransport(
            listOf(
                DevicePollResult.Error(DeviceGrantError.SERVER_ERROR),
                DevicePollResult.TransportFailure("offline"),
                DevicePollResult.Token("t"),
            ),
        )
        assertEquals(DeviceGrantOutcome.Granted("t"), approve(transport))
    }

    /** Stops once the authorization window closes. */
    @Test
    fun expiresAtDeadline() = runBlocking {
        val transport = ScriptedTransport(List(100) { pending() }, interval = 5, expiresIn = 20)
        assertEquals(DeviceGrantOutcome.Expired, approve(transport))
        assertEquals(4, transport.pollCount)
    }
}

/**
 * What the sign-in QR carries, and the trade-off accepted to put it there.
 * Ported from `DeviceCodeQRPayloadTests` in `DeviceGrantTests.swift`.
 */
class DeviceCodeQrPayloadTest {
    private fun authorization(complete: String?): DeviceAuthorization {
        val completeField = complete?.let { ",\n \"verification_uri_complete\":\"$it\"" } ?: ""
        val json = """
            {"device_code":"SECRET-abc","user_code":"WXYZ-1234",
             "verification_uri":"https://library.example/link",
             "expires_in":900,"interval":5$completeField}
        """.trimIndent()
        return IssaJson.decodeFromString(DeviceAuthorization.serializer(), json)
    }

    /** The payload is the pre-identified URL, secret and all. */
    @Test
    fun payloadIsTheCompleteUri() {
        val auth = authorization(complete = "https://library.example/link?code=SECRET-abc")
        assertEquals(auth.verificationUriComplete, auth.approvalPayload)
        // Stated rather than implied: this is the exposure that was accepted,
        // so a future change that reverts it fails here and has to say why.
        assertTrue(auth.approvalPayload.contains(auth.deviceCode))
        assertEquals("https", auth.approvalUrl?.scheme)
    }

    /** A server without a complete URI falls back to the address people type. */
    @Test
    fun payloadFallsBack() {
        val auth = authorization(complete = null)
        assertEquals(auth.verificationUri, auth.approvalPayload)
        assertFalse(auth.approvalPayload.contains(auth.deviceCode))
    }
}
