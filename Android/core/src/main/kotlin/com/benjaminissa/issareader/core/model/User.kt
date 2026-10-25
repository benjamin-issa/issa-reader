package com.benjaminissa.issareader.core.model

import kotlinx.serialization.Serializable

/** The signed-in user, from `GET /api/v2/user`. */
@Serializable
data class User(
    val id: String,
    val name: String? = null,
    val username: String? = null,
    val email: String? = null,
    val permissions: Permissions? = null,
)

/**
 * What the server will let this user do. Every v2 route self-gates on one of
 * these — there is no global middleware — so a client that hides unavailable
 * actions matches the server exactly.
 */
@Serializable
data class Permissions(
    val bookCreate: Boolean? = null,
    val bookDelete: Boolean? = null,
    val bookDownload: Boolean? = null,
    val bookList: Boolean? = null,
    val bookProcess: Boolean? = null,
    val bookRead: Boolean? = null,
    val bookUpdate: Boolean? = null,
    val collectionCreate: Boolean? = null,
    val inviteDelete: Boolean? = null,
    val inviteList: Boolean? = null,
    val settingsUpdate: Boolean? = null,
    val userCreate: Boolean? = null,
    val userDelete: Boolean? = null,
    val userList: Boolean? = null,
    val userPasswordReset: Boolean? = null,
    val userRead: Boolean? = null,
    val userUpdate: Boolean? = null,
) {
    /** The minimum needed to browse and read. */
    val canRead: Boolean get() = (bookList ?: false) && (bookRead ?: false)
    val canDownload: Boolean get() = bookDownload ?: false
}
