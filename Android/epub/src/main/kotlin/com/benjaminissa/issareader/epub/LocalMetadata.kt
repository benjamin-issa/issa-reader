package com.benjaminissa.issareader.epub

/**
 * The archive path of the book's cover image, or null when it names none.
 *
 * In the order reading systems take it: the manifest item EPUB 3 marks
 * `cover-image`; then the item EPUB 2's `<meta name="cover">` names by id (or,
 * as some tools write it, by href); then an image whose id or file name says
 * "cover" — one called exactly that first, and never one that says "back", in
 * the manifest's own order. A book with none of these has no cover to cut, and
 * the list draws its letter tile.
 */
val EpubPackage.coverImageHref: String?
    get() {
        val images = manifest.values
            .filter { it.mediaType.lowercase().startsWith("image/") }
            // In the book's order, so the last rule picks the same image every
            // time and the one the publisher listed first: the manifest is
            // keyed by id. Ordered by id, "back-cover" sorted before "cover"
            // and "BackCover" before "front-cover", and the back was cut.
            .sortedBy { it.documentOrder }
        images.firstOrNull { "cover-image" in it.properties }?.let { return it.href }
        val named = metadata.coverId
        if (named != null) {
            val item = manifest[named]
            if (item != null && item.mediaType.lowercase().startsWith("image/")) return item.href
            val path = EpubArchive.normalize(if (rootDirectory.isEmpty()) named else "$rootDirectory/$named")
            images.firstOrNull { it.href == path }?.let { return it.href }
        }
        fun names(item: EpubPackage.ManifestItem): List<String> {
            val file = item.href.lastPathComponent.deletingPathExtension
            return listOf(item.id.lowercase(), file.lowercase())
        }
        val covers = images.filter { item ->
            val said = names(item)
            said.any { "cover" in it } && said.none { "back" in it }
        }
        return (covers.firstOrNull { "cover" in names(it) } ?: covers.firstOrNull())?.href
    }

/**
 * What this book says about itself, for a book added from the reader's own
 * files.
 *
 * Creators are sorted by role the way Storyteller sorts them, so a local
 * book's screens read like a server book's: `aut` — or a `dc:creator` with no
 * role at all, which the spec reads as the author — become authors; `nrt`
 * narrators; everyone else keeps their role among `creators`, a
 * `dc:contributor` with none as `ctb`.
 *
 * @param fallbackTitle the file's name, for a book with no title.
 */
fun EpubPackage.localMetadata(fallbackTitle: String): LocalBookMetadata {
    val authors = ArrayList<LocalContributor>()
    val narrators = ArrayList<LocalContributor>()
    val creators = ArrayList<LocalContributor>()
    for (person in metadata.contributors) {
        val role = person.role ?: if (person.isCreator) "aut" else "ctb"
        val contributor = LocalContributor(name = person.name, fileAs = person.fileAs, role = role)
        when (role) {
            "aut" -> authors.add(contributor)
            "nrt" -> narrators.add(contributor)
            else -> creators.add(contributor)
        }
    }
    val title = metadata.title?.trimmingWhitespaceAndNewlines()?.nonEmpty ?: fallbackTitle
    return LocalBookMetadata(
        title = title,
        subtitle = metadata.subtitle,
        description = metadata.description,
        language = metadata.language?.nonEmpty,
        publisher = metadata.publisher,
        date = metadata.date,
        authors = authors,
        narrators = narrators,
        creators = creators,
        series = metadata.series?.let { LocalSeries(name = it.name, position = it.position) },
        identifier = metadata.uniqueIdentifier,
    )
}
