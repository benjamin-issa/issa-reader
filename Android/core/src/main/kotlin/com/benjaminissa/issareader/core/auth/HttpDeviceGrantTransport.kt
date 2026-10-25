package com.benjaminissa.issareader.core.auth

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.networking.StorytellerError
import com.benjaminissa.issareader.core.networking.await
import com.benjaminissa.issareader.core.networking.readableReason
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.net.URI

/**
 * Real network transport for the device grant.
 *
 * Both endpoints are unauthenticated by design — the whole point is that the
 * device has no credentials yet.
 */
class HttpDeviceGrantTransport(
    private val baseUrl: URI,
    private val http: OkHttpClient = ApiClient.sharedHttpClient,
) : DeviceGrantTransport {
    private fun url(path: String): HttpUrl {
        val base = baseUrl.toString().toHttpUrlOrNull() ?: throw IOException("unsupported URL")
        return base.newBuilder().addPathSegments(path.trimStart('/')).build()
    }

    override suspend fun start(): DeviceAuthorization {
        val request = Request.Builder()
            .url(url(Endpoint.deviceStart))
            .post(ByteArray(0).toRequestBody())
            // Mandatory. The server builds verification_uri,
            // verification_uri_complete and qr_svg_url from this header; the
            // configured webUrl is consulted only when the origin is literally
            // localhost. Omit it and the user is shown a URL pointing at
            // whatever address the server believes it has.
            .header("Origin", baseUrl.toString())
            .header("Accept", "application/json")
            .build()

        val (status, data) = http.newCall(request).await().use { response ->
            response.code to withContext(Dispatchers.IO) { response.body.bytes() }
        }
        if (status != 200) throw StorytellerError.Server(status, "device/start failed")
        return IssaJson.decodeFromString(DeviceAuthorization.serializer(), data.decodeToString())
    }

    override suspend fun poll(deviceCode: String): DevicePollResult {
        val body = IssaJson.encodeToString(JsonObject.serializer(), buildJsonObject { put("device_code", deviceCode) })
        return try {
            val request = Request.Builder()
                .url(url(Endpoint.deviceToken))
                .post(body.toRequestBody("application/json".toMediaType()))
                .header("Origin", baseUrl.toString())
                .build()
            val (status, data) = http.newCall(request).await().use { response ->
                response.code to withContext(Dispatchers.IO) { response.body.bytes() }
            }
            val text = data.decodeToString()
            if (status == 200) {
                runCatching { IssaJson.decodeFromString(DeviceToken.serializer(), text) }.getOrNull()
                    ?.let { return DevicePollResult.Token(it.accessToken) }
            }
            // Errors arrive as {"error": "..."} at 400, except server_error at 500.
            val code = runCatching {
                ((IssaJson.parseToJsonElement(text) as? JsonObject)?.get("error") as? JsonPrimitive)
                    ?.takeIf { it.isString }?.content
            }.getOrNull()
            code?.let { DeviceGrantError.fromRawValue(it) }?.let { return DevicePollResult.Error(it) }
            DevicePollResult.TransportFailure("Unexpected $status ${code ?: ""}")
        } catch (e: IOException) {
            IssaLog.failure("device grant poll", e)
            DevicePollResult.TransportFailure(e.readableReason())
        }
    }

    override suspend fun wait(seconds: Double) {
        try {
            delay((seconds * 1000).toLong())
        } catch (_: CancellationException) {
            // Swallowed, as `try? await Task.sleep` swallows it: the flow
            // checks for cancellation after every wait and says so itself.
        }
    }
}
