import Foundation
import IssaCore

public extension EPUBPackage {
    /// The archive path of the book's cover image, or nil when it names none.
    ///
    /// In the order reading systems take it: the manifest item EPUB 3 marks
    /// `cover-image`; then the item EPUB 2's `<meta name="cover">` names by
    /// id (or, as some tools write it, by href); then an image whose id or
    /// file name says "cover" — one called exactly that first, and never one
    /// that says "back", in the manifest's own order. A book with none of
    /// these has no cover to cut, and the list draws its letter tile.
    var coverImageHref: String? {
        let images = manifest.values
            .filter { $0.mediaType.lowercased().hasPrefix("image/") }
            // In the book's order, so the last rule picks the same image every
            // time and the one the publisher listed first: the manifest is a
            // dictionary. Ordered by id, "back-cover" sorted before "cover"
            // and "BackCover" before "front-cover", and the back was cut.
            .sorted { $0.documentOrder < $1.documentOrder }
        if let declared = images.first(where: { $0.properties.contains("cover-image") }) {
            return declared.href
        }
        if let named = metadata.coverID {
            if let item = manifest[named], item.mediaType.lowercased().hasPrefix("image/") {
                return item.href
            }
            let path = EPUBArchive.normalize(
                rootDirectory.isEmpty ? named : rootDirectory + "/" + named)
            if let item = images.first(where: { $0.href == path }) { return item.href }
        }
        func names(_ item: ManifestItem) -> [String] {
            let file = ((item.href as NSString).lastPathComponent as NSString).deletingPathExtension
            return [item.id.lowercased(), file.lowercased()]
        }
        let covers = images.filter { item in
            let said = names(item)
            return said.contains { $0.contains("cover") } && !said.contains { $0.contains("back") }
        }
        return (covers.first { names($0).contains("cover") } ?? covers.first)?.href
    }

    /// What this book says about itself, for a book added from the reader's
    /// own files.
    ///
    /// Creators are sorted by role the way Storyteller sorts them, so a local
    /// book's screens read like a server book's: `aut` — or a `dc:creator`
    /// with no role at all, which the spec reads as the author — become
    /// authors; `nrt` narrators; everyone else keeps their role among
    /// `creators`, a `dc:contributor` with none as `ctb`.
    ///
    /// - Parameter fallbackTitle: the file's name, for a book with no title.
    func localMetadata(fallbackTitle: String) -> LocalBookMetadata {
        var authors: [LocalContributor] = []
        var narrators: [LocalContributor] = []
        var creators: [LocalContributor] = []
        for person in metadata.contributors {
            let role = person.role ?? (person.isCreator ? "aut" : "ctb")
            let contributor = LocalContributor(name: person.name, fileAs: person.fileAs, role: role)
            switch role {
            case "aut": authors.append(contributor)
            case "nrt": narrators.append(contributor)
            default: creators.append(contributor)
            }
        }
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? fallbackTitle
        return LocalBookMetadata(
            title: title,
            subtitle: metadata.subtitle,
            description: metadata.description,
            language: metadata.language?.nonEmpty,
            publisher: metadata.publisher,
            date: metadata.date,
            authors: authors,
            narrators: narrators,
            creators: creators,
            series: metadata.series.map { LocalSeries(name: $0.name, position: $0.position) },
            identifier: metadata.uniqueIdentifier,
        )
    }
}

extension String {
    /// Nil for an empty string, so an absent field and a blank one are one case.
    var nonEmpty: String? { isEmpty ? nil : self }
}
