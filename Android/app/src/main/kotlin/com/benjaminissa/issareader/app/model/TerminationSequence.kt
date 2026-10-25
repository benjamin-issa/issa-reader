package com.benjaminissa.issareader.app.model

/**
 * The bookkeeping behind "may this process stop yet?", with no platform in it.
 *
 * Only the Mac asks the question on Apple's side, but the part that has had
 * bugs in it is not the platform's: two exit requests overlapping, and a
 * deadline and a completion both racing to answer one. Android asks a version
 * of it too — the app going to the background starts a flush that the process
 * may be stopped in the middle of — so the rule is kept, and tested, here.
 *
 * What it does not know about: the flush itself, the clock and the reply.
 * Main-thread only.
 */
class TerminationSequence {
    /** What the process should be told. */
    enum class Request {
        /** Nothing to save. Go. */
        NOW,

        /** Wait: a flush is running and [replyOnce] will answer for it. */
        LATER,

        /** Refuse this request. Only ever the *second* one. */
        CANCEL,
    }

    private var isFlushing = false

    /** One reply per [Request.LATER]: the deadline and the completion can both reach it. */
    private var hasReplied = false

    /**
     * Answers one request, and arms the reply when the answer is
     * [Request.LATER].
     *
     * @param flush what the caller would run before stopping, or null if
     *   nothing is installed yet — only its presence is read. A second request
     *   while the first is flushing is [Request.CANCEL], not [Request.NOW]:
     *   answering now killed the first mid-save.
     */
    fun begin(flush: (suspend () -> Unit)?): Request {
        if (flush == null) return Request.NOW
        if (isFlushing) return Request.CANCEL
        isFlushing = true
        hasReplied = false
        return Request.LATER
    }

    /**
     * Sends the one reply this sequence owes, and ignores every later attempt.
     * Replying also clears the in-flight flag, so a sequence that was answered
     * and somehow did not end the process can be used again.
     */
    fun replyOnce(send: () -> Unit) {
        if (hasReplied) return
        hasReplied = true
        isFlushing = false
        send()
    }
}
