package com.benjaminissa.issareader.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Which line of Storyteller is answering.
 *
 * Established by feature, never by the version string. A 3.x image built from
 * source has no release tag to read, falls back to its `package.json`, and
 * reports "2.14.21" — so the one thing the string cannot be trusted to say is
 * which generation it came from.
 */
@Serializable
enum class ServerGeneration {
    @SerialName("v2") V2,
    @SerialName("v3") V3,
    ;

    /** Swift's raw value: `v2`, `v3`. */
    val rawValue: String get() = name.lowercase()
}

/**
 * Which optional server features are present, and which line of Storyteller
 * is serving them.
 *
 * This client's baseline is 2.14.21, and it runs at parity with the 3.0.0 beta
 * line. Storyteller 3.x adds around fifty endpoints that 2.x lacks —
 * server-side home sections, shelves, a sidebar, library facets and counts —
 * and the client derives all of those locally from the one catalogue fetch, so
 * their absence costs nothing. The flags below record which of them a server
 * has, for Settings to show.
 *
 * An upgrade is not free of client changes, though. 3.x serves covers from a
 * new content-addressed route behind a redirect, and no longer advances a book
 * that has no status when a position is written. The places that differ ask
 * [generation], which is detected by feature — `GET /api/v2/server/public`
 * answers on 3.x and 404s on 2.x — rather than read from a version string.
 *
 * Probed once per sign-in and held on the session; a probe is a cheap
 * unauthenticated or authenticated GET that either 200s or 404s. Not
 * persisted: nothing that runs before the probe needs the answer, and the
 * cover route is chosen from the book's own data first.
 */
@Serializable
data class ServerCapabilities(
    /**
     * `GET /api/v2/server/public` — unauthenticated server identity and
     * branding. True exactly when [generation] is [ServerGeneration.V3].
     */
    val serverDiscovery: Boolean = false,
    /** `GET /api/v2/home/sections` and `/home/stats`. */
    val homeSections: Boolean = false,
    /** `GET /api/v2/shelves`. */
    val shelves: Boolean = false,
    /** `GET /api/v2/sidebar`. */
    val sidebar: Boolean = false,
    /** `GET /api/v2/library/facets` and `/library/counts`. */
    val libraryFacets: Boolean = false,
    /** `GET /api/v2/books/next-up`. */
    val nextUp: Boolean = false,
    /** `GET /api/v2/events` — the 3.x consolidated event stream. */
    val unifiedEvents: Boolean = false,
    /**
     * null until `/server/public` has answered with either a Storyteller 3.x
     * identity or a 404. A transport failure, a 5xx, or a 200 that is somebody
     * else's page — a proxy's login screen — decides nothing, and saying "2.x"
     * on the strength of one would be a guess presented as a finding.
     */
    val generation: ServerGeneration? = null,
    /**
     * `version` from `GET /api/v2/server/details`, e.g. "3.0.0-beta.40".
     * Display only: see [ServerGeneration] for why nothing keys on it. 2.x has
     * no route that exposes its running version, so it is always null there.
     */
    val reportedVersion: String? = null,
) {
    /**
     * The server version, as the Settings row states it.
     *
     * A 3.x server's own string is shown verbatim when it agrees with the
     * detected generation. When it does not — a self-built image reporting its
     * `package.json` fallback — both facts are shown, because either one alone
     * would mislead whoever is reading the row to diagnose something.
     */
    val displayVersion: String
        get() = when (generation) {
            null -> "Not detected"
            ServerGeneration.V2 -> "2.x (not reported)"
            ServerGeneration.V3 -> {
                val reported = reportedVersion
                if (reported == null) {
                    "3.x"
                } else {
                    // Swift's `split(separator: ".", maxSplits: 1).first`,
                    // which drops an empty leading piece.
                    val major = reported.split('.', limit = 2).firstOrNull { it.isNotEmpty() }
                    if (major == "3") reported else "3.x (reports $reported)"
                }
            }
        }

    companion object {
        /**
         * Everything this client can derive on its own, so a 2.x server loses
         * no user-visible capability — only the chance to offload the work.
         */
        val baseline = ServerCapabilities()
    }
}
