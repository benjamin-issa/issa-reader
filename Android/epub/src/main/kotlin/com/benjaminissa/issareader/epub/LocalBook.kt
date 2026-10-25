package com.benjaminissa.issareader.epub

// STAND-IN, to be deleted. These three are IssaCore's (`Model/LocalBook.swift`),
// and belong in `:core` as `core.model.LocalBookMetadata`, `LocalContributor`
// and `LocalSeries`. `:core` had not ported them when `:epub` was, and `:epub`
// does not add to `:core`, so they live here in the same shape until it does;
// then this file goes and `LocalMetadata.kt` (and its tests) import the core
// types instead. Nothing else in `:epub` uses them.

/**
 * What an EPUB says about itself, in the shape `Book.local` needs.
 *
 * Built by [localMetadata].
 */
data class LocalBookMetadata(
    val title: String,
    val subtitle: String? = null,
    val description: String? = null,
    val language: String? = null,
    val publisher: String? = null,
    /** `dc:date` as written. */
    val date: String? = null,
    val authors: List<LocalContributor> = emptyList(),
    val narrators: List<LocalContributor> = emptyList(),
    /** Everyone else — translators, illustrators, editors — with their role. */
    val creators: List<LocalContributor> = emptyList(),
    val series: LocalSeries? = null,
    val identifier: String? = null,
)

data class LocalContributor(
    val name: String,
    val fileAs: String? = null,
    /** The MARC relator code, when the book gave one. */
    val role: String? = null,
)

data class LocalSeries(
    val name: String,
    val position: Double? = null,
)
