package com.benjaminissa.issareader.core.networking

/**
 * The Storyteller v2 routes this client uses.
 *
 * Paths only — no query building — so they stay readable next to the server's
 * own route tree (`applications/web/src/app/api/v2/...`).
 */
object Endpoint {
    // Auth

    /**
     * Username and password, form-encoded. Not used by this client: the
     * browser route signs a reader in with their password *or* their identity
     * provider without the app needing to know which, so a second form asking
     * for one specifically was a choice nobody could make from the outside.
     */
    const val token = "/api/v2/token"

    /**
     * Mints a token for a native app from an existing *browser* session and
     * hands it back by redirecting to `storyteller://settings?token=…`.
     * Unauthenticated it redirects to `/login?callbackUrl=…` and comes back
     * here afterwards, so one URL covers both "already signed in" and "not".
     */
    const val appToken = "/api/v2/token/app"
    const val validate = "/api/v2/validate"

    /**
     * Auth.js's provider list — unauthenticated, and the only pre-auth
     * discovery this server offers. Recorded here because it is genuinely
     * useful and was hard to find; nothing reads it now that the browser
     * route covers every provider without naming any.
     */
    const val authProviders = "/api/v2/auth/providers"
    const val deviceStart = "/api/v2/device/start"
    const val deviceToken = "/api/v2/device/token"

    // Identity

    /** Revokes the session token server-side. */
    const val logout = "/api/v2/logout"
    const val user = "/api/v2/user"
    const val userRatings = "/api/v2/user/ratings"

    // Catalogue

    const val books = "/api/v2/books"
    const val statuses = "/api/v2/statuses"
    const val tags = "/api/v2/tags"
    const val series = "/api/v2/series"
    const val collections = "/api/v2/collections"
    const val creators = "/api/v2/creators"

    fun book(uuid: String): String = "/api/v2/books/$uuid"
    fun cover(uuid: String): String = "/api/v2/books/$uuid/cover"
    fun positions(uuid: String): String = "/api/v2/books/$uuid/positions"
    fun rating(uuid: String): String = "/api/v2/books/$uuid/rating"
    fun status(uuid: String): String = "/api/v2/books/$uuid/status"

    /** Bulk status change, for multi-select in the library. */
    const val bulkStatus = "/api/v2/books/status"

    /** Whole-file download. `format` is one of ebook / audiobook / audiobook-rpf / readaloud. */
    fun files(uuid: String): String = "/api/v2/books/$uuid/files"

    /** Readium Web Publication: `read/manifest.json` plus each EPUB resource. */
    fun read(uuid: String, path: String = "manifest.json"): String = "/api/v2/books/$uuid/read/$path"

    /** Readium audiobook manifest and per-chapter audio. */
    fun listen(uuid: String, path: String = "manifest.json"): String = "/api/v2/books/$uuid/listen/$path"

    /**
     * 3.x-only routes, each used only once something says it exists: a
     * probe, the detected generation, or a cover reference in the book itself.
     */
    object V3 {
        /**
         * Unauthenticated, and the route generation detection keys on: it
         * answers on every 3.x server and 404s on 2.x.
         */
        const val serverPublic = "/api/v2/server/public"

        /** Any signed-in user; the only place a server states its version. */
        const val serverDetails = "/api/v2/server/details"

        /**
         * A content-addressed image — where 3.x keeps covers, and where its
         * deprecated `/books/{uuid}/cover` redirects. `sha256` must already
         * have passed `CoverReference.isUsable`: it lands in a URL path.
         */
        fun image(sha256: String): String = "/api/v2/images/$sha256"
        const val homeSections = "/api/v2/home/sections"
        const val shelves = "/api/v2/shelves"
        const val sidebar = "/api/v2/sidebar"
        const val libraryFacets = "/api/v2/library/facets"
        const val nextUp = "/api/v2/books/next-up"
    }
}
