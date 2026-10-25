package com.benjaminissa.issareader.core

import okhttp3.Headers.Companion.toHeaders
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import java.io.IOException

/**
 * What a stubbed server does with one request: Swift's `URLProtocol` stubs,
 * which answer by the host or path a request names and never touch the
 * network.
 */
sealed interface Stub {
    data class Answer(
        val status: Int,
        val body: ByteArray = ByteArray(0),
        val headers: Map<String, String> = emptyMap(),
    ) : Stub {
        constructor(status: Int, body: String, headers: Map<String, String> = emptyMap()) :
            this(status, body.encodeToByteArray(), headers)
    }

    /** The request fails before any response exists, as a dead network does. */
    data class Fail(val exception: IOException) : Stub
}

/**
 * An OkHttp client whose every request is answered by [answer], on OkHttp's
 * own threads, without a socket — so any host name a test invents is its own.
 * An answer may block (sleep) to stand in for a slow server.
 */
fun stubHttp(answer: (Request) -> Stub): OkHttpClient = OkHttpClient.Builder()
    .addInterceptor { chain ->
        val request = chain.request()
        when (val stub = answer(request)) {
            is Stub.Fail -> throw stub.exception
            is Stub.Answer -> Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(stub.status)
                .message("")
                .headers(stub.headers.toHeaders())
                .body(stub.body.toResponseBody(stub.headers["Content-Type"]?.toMediaTypeOrNull()))
                .build()
        }
    }
    .build()

/** The body a request carries, as text: what Swift's stubs read from `httpBody`. */
fun Request.bodyText(): String? {
    val body = body ?: return null
    val buffer = Buffer()
    body.writeTo(buffer)
    return buffer.readUtf8()
}
