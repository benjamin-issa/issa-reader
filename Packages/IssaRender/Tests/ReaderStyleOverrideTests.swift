import CoreGraphics
import Foundation
import Testing

@testable import IssaRender

/// Per-book typography, stored as a departure from the reading settings.
///
/// The sparseness is the whole design: a book that changed its face must still
/// follow a later change to the global line spacing, which storing a resolved
/// style would silently freeze.
@Suite("Per-book typography")
struct ReaderStyleOverrideTests {
    @Test("a book with no override reads exactly as the defaults")
    func emptyOverrideChangesNothing() {
        let defaults = ReaderStyle()
        #expect(defaults.applying(nil) == defaults)
        #expect(defaults.applying(ReaderStyleOverride()) == defaults)
    }

    @Test("an override changes only what it names")
    func overrideIsSparse() {
        let defaults = ReaderStyle(typeface: .bundled("Newsreader"), fontSize: 18)
        let resolved = defaults.applying(ReaderStyleOverride(fontSize: 24))
        #expect(resolved.fontSize == 24)
        #expect(resolved.typeface == .bundled("Newsreader"))
        #expect(resolved.lineSpacing == defaults.lineSpacing)
        #expect(resolved.justified == defaults.justified)
    }

    /// The reason for storing a difference rather than a style. The reader sets
    /// one book in a bigger size, then later changes their default line
    /// spacing — and that book must follow.
    @Test("a later change to the defaults still reaches an overridden book")
    func unsetFieldsFollowTheDefaults() {
        let override = ReaderStyleOverride(fontSize: 24)
        var defaults = ReaderStyle(fontSize: 18, lineSpacing: .normal)
        #expect(defaults.applying(override).lineSpacing == .normal)
        defaults.lineSpacing = .roomy
        #expect(defaults.applying(override).lineSpacing == .roomy)
        #expect(defaults.applying(override).fontSize == 24, "the book keeps what it set")
    }

    @Test("a difference records only the fields that actually differ")
    func differenceIsMinimal() {
        let defaults = ReaderStyle(typeface: .bundled("Newsreader"), fontSize: 18)
        var edited = defaults
        edited.fontSize = 22
        let difference = defaults.difference(to: edited)
        #expect(difference.fontSize == 22)
        #expect(difference.typeface == nil)
        #expect(difference.count == 1)
    }

    @Test("editing a book back to the defaults leaves nothing behind")
    func differenceToDefaultsIsEmpty() {
        let defaults = ReaderStyle()
        #expect(defaults.difference(to: defaults).isEmpty)
    }

    @Test("a round trip through storage keeps the override intact")
    func overrideSurvivesEncoding() throws {
        let override = ReaderStyleOverride(
            typeface: .custom("Some Imported Face"), fontSize: 21, justified: true)
        let data = try JSONEncoder().encode(override)
        #expect(try JSONDecoder().decode(ReaderStyleOverride.self, from: data) == override)
    }
}

/// `typeface` replaced `fontFamily`, and the settings blob on a reader's device
/// still names a family. The migration precedent is `ReaderStyleMigrationTests`.
@Suite("Choosing a typeface")
struct TypefaceTests {
    func decode(_ json: String) throws -> ReaderStyle {
        try JSONDecoder().decode(ReaderStyle.self, from: Data(json.utf8))
    }

    @Test("a settings blob written before typeface keeps the face it named")
    func migratesFontFamily() throws {
        let style = try decode(#"{"fontFamily":"Public Sans","fontSize":21,"justified":true}"#)
        #expect(style.typeface == .bundled("Public Sans"))
        #expect(style.fontSize == 21, "the rest of the blob must survive too")
        #expect(style.justified == true)
    }

    @Test("a blob naming neither falls back to the app's own face")
    func defaultsWhenAbsent() throws {
        #expect(try decode("{}").typeface == .bundled(ReaderStyle.defaultFamily))
    }

    @Test("every case survives a round trip", arguments: [
        ReaderStyle.Typeface.publisher,
        .bundled("Newsreader"),
        .custom("A Face With Spaces"),
    ])
    func roundTrips(_ typeface: ReaderStyle.Typeface) throws {
        var style = ReaderStyle()
        style.typeface = typeface
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(ReaderStyle.self, from: data).typeface == typeface)
    }

    /// A face named "publisher", or one whose name contains a colon, must not
    /// be confused with the tag that encodes the case.
    @Test("an awkward family name is not mistaken for a case")
    func distinguishesAwkwardNames() throws {
        for name in ["publisher", "custom:thing", "bundled:other"] {
            var style = ReaderStyle()
            style.typeface = .custom(name)
            let data = try JSONEncoder().encode(style)
            #expect(try JSONDecoder().decode(ReaderStyle.self, from: data).typeface == .custom(name))
        }
    }

    /// The publisher's face is a property of the book, not of the settings.
    /// Persisting it would set the next book in the last one's font.
    @Test("the publisher's family is never written to settings")
    func publisherFamilyIsNotPersisted() throws {
        var style = ReaderStyle()
        style.typeface = .publisher
        style.publisherFamily = "Some Book Face"
        let data = try JSONEncoder().encode(style)
        #expect(!String(data: data, encoding: .utf8)!.contains("Some Book Face"))
        #expect(try JSONDecoder().decode(ReaderStyle.self, from: data).publisherFamily == nil)
    }

    @Test("a book with no usable face still sets its text in something deliberate")
    func fallsBackToTheAppFace() {
        var style = ReaderStyle()
        style.typeface = .publisher
        style.publisherFamily = nil
        #expect(style.resolvedFamily == nil)
        // Newsreader is registered by the app, so this is the bundled face and
        // not the system's.
        #expect(style.bodyFont().familyName != nil)
    }
}
