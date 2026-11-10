import CoreGraphics
import Foundation
import Testing

import IssaUI

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
        #expect(resolved.justification == defaults.justification)
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
            typeface: .custom("Some Imported Face"), fontSize: 21, justification: .always)
        let data = try JSONEncoder().encode(override)
        #expect(try JSONDecoder().decode(ReaderStyleOverride.self, from: data) == override)
    }

    /// The per-book switch before it had three positions. A book set ragged
    /// was a deliberate act, so it stays ragged rather than following the book.
    @Test("a stored justified switch becomes the matching justification")
    func legacyJustifiedDecodes() throws {
        func decode(_ json: String) throws -> ReaderStyleOverride {
            try JSONDecoder().decode(ReaderStyleOverride.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"justified": false}"#).justification == .never)
        #expect(try decode(#"{"justified": true}"#).justification == .always)
        #expect(try decode(#"{"justified": false, "fontSize": 19}"#).fontSize == 19)
        #expect(try decode(#"{"fontSize": 19}"#).justification == nil)
    }

    @Test("an absurd per-book size is brought into range, not trusted")
    func overrideSizeIsClamped() throws {
        let decoded = try JSONDecoder().decode(
            ReaderStyleOverride.self, from: Data(#"{"fontSize": 1e300}"#.utf8))
        #expect(decoded.fontSize == ReaderStyle.fontSizeRange.upperBound)
        let ordinary = try JSONDecoder().decode(
            ReaderStyleOverride.self, from: Data(#"{"fontSize": 21}"#.utf8))
        #expect(ordinary.fontSize == 21)
    }
}

/// `ReaderStyleOverride` exactly as 1.1.1 shipped it: synthesised `Codable`,
/// and a two-position `justified` switch. Copied verbatim but for its name and
/// the `ReaderStyle` methods it extended, so the test can be the older build.
private struct ReaderStyleOverride111: Sendable, Hashable, Codable {
    public var typeface: ReaderStyle.Typeface?
    public var fontSize: CGFloat?
    public var lineSpacing: ReaderStyle.LineSpacing?
    public var justified: Bool?

    public init(
        typeface: ReaderStyle.Typeface? = nil,
        fontSize: CGFloat? = nil,
        lineSpacing: ReaderStyle.LineSpacing? = nil,
        justified: Bool? = nil,
    ) {
        self.typeface = typeface
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.justified = justified
    }

    /// Whether this book has anything of its own left.
    ///
    /// An override that overrides nothing is deleted rather than stored, so
    /// "use my defaults" leaves no trace to go stale.
    public var isEmpty: Bool {
        typeface == nil && fontSize == nil && lineSpacing == nil && justified == nil
    }
}

/// A reader who moves back a build must not lose a book's justification: the
/// older build reads only `justified`, and the first time it saves any book's
/// typography it writes the whole map back without the newer key.
@Suite("Per-book typography survives a step back to 1.1.1")
struct ReaderStyleOverrideDowngradeTests {
    @Test("the map this build writes round-trips through 1.1.1's struct")
    func roundTripThroughTheOldBuild() throws {
        let written: [String: ReaderStyleOverride] = [
            "ragged": ReaderStyleOverride(justification: .never),
            "justified": ReaderStyleOverride(justification: .always),
            "follows": ReaderStyleOverride(fontSize: 20, justification: .followBook),
            "size-and-justified": ReaderStyleOverride(fontSize: 21, justification: .always),
            "face": ReaderStyleOverride(typeface: .custom("Some Face")),
        ]
        let blob = try JSONEncoder().encode(written)

        // What 1.1.1 sees: a switch, set or unset.
        let old = try JSONDecoder().decode([String: ReaderStyleOverride111].self, from: blob)
        #expect(old["ragged"]?.justified == false)
        #expect(old["justified"]?.justified == true)
        #expect(old["follows"]?.justified == nil, "following the book is not a thing it can say")
        #expect(old["size-and-justified"]?.justified == true)
        #expect(old["size-and-justified"]?.fontSize == 21)
        #expect(old["face"]?.justified == nil)
        #expect(old["ragged"]?.isEmpty == false, "not an empty husk the sheet would hide")

        // 1.1.1 saves the map — any book's change does — and this build reads
        // it back: the newer key is gone, and the switch carries it.
        let rewritten = try JSONEncoder().encode(old)
        let back = try JSONDecoder().decode([String: ReaderStyleOverride].self, from: rewritten)
        #expect(back["ragged"]?.justification == .never)
        #expect(back["justified"]?.justification == .always)
        #expect(back["size-and-justified"] == written["size-and-justified"])
        #expect(back["face"] == written["face"])
        #expect(back["follows"]?.fontSize == 20)
    }

    @Test("this build writes the switch only where it means something")
    func legacyKeyOnlyWhereExpressible() throws {
        func legacy(_ justification: ReaderStyle.Justification?) throws -> Any? {
            let data = try JSONEncoder().encode(
                ReaderStyleOverride(fontSize: 20, justification: justification))
            let object = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return object["justified"]
        }
        #expect(try legacy(.always) as? Bool == true)
        #expect(try legacy(.never) as? Bool == false)
        #expect(try legacy(.followBook) == nil)
        #expect(try legacy(nil) == nil)
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
        #expect(style.justification == .always)
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
    func fallsBackToTheAppFace() throws {
        // Registered here rather than relied on: the face was only on hand
        // when another suite happened to have registered it first, which is
        // why the old assertion could pass on nothing. Under the registry
        // lock like every other test that resolves a face by name — CoreText
        // resolves a family nondeterministically while another thread is at it.
        try CustomFonts.testRegistryLock.withLock {
            IssaFonts.register()
            var style = ReaderStyle()
            style.typeface = .publisher
            style.publisherFamily = nil
            #expect(style.resolvedFamily == nil)
            // The app's default face is registered, so this is the bundled
            // face and not the system's. `familyName` is never nil, so
            // comparing it to nil asserted nothing at all.
            #expect(style.bodyFont().familyName == ReaderStyle.defaultFamily)
        }
    }
}

/// The page margin as a per-book field, beside the global default it overrides.
@Suite("Per-book page margin")
struct ReaderStyleOverrideMarginTests {
    private func decode(_ json: String) throws -> ReaderStyleOverride {
        try JSONDecoder().decode(ReaderStyleOverride.self, from: Data(json.utf8))
    }

    @Test("an absent margin key decodes as no override")
    func absentKeyIsNil() throws {
        #expect(try decode(#"{"fontSize": 20}"#).pageMargin == nil)
    }

    @Test("a margin of the wrong type is dropped without losing the other fields")
    func wrongTypeKeepsTheRest() throws {
        let decoded = try decode(#"{"pageMargin": "wide", "fontSize": 21, "lineSpacing": "roomy"}"#)
        #expect(decoded.pageMargin == nil)
        #expect(decoded.fontSize == 21)
        #expect(decoded.lineSpacing == .roomy)
    }

    @Test("a huge or negative stored margin is bounded")
    func clamped() throws {
        #expect(try decode(#"{"pageMargin": 1e300}"#).pageMargin == ReaderStyle.pageMarginRange.upperBound)
        #expect(try decode(#"{"pageMargin": -40}"#).pageMargin == ReaderStyle.pageMarginRange.lowerBound)
    }

    @Test("a round trip keeps the margin, including a margin of zero")
    func roundTrip() throws {
        for margin: CGFloat in [0, 12, 48] {
            let override = ReaderStyleOverride(fontSize: 20, pageMargin: margin)
            let data = try JSONEncoder().encode(override)
            #expect(try JSONDecoder().decode(ReaderStyleOverride.self, from: data) == override)
        }
    }

    @Test("an override carrying only a margin is not empty and counts once")
    func marginCounts() {
        let override = ReaderStyleOverride(pageMargin: 4)
        #expect(!override.isEmpty)
        #expect(override.count == 1)
    }

    @Test("applying an override sets the margin and leaves a book without one alone")
    func applies() {
        let defaults = ReaderStyle(pageMargin: 24)
        #expect(defaults.applying(ReaderStyleOverride(pageMargin: 4)).pageMargin == 4)
        #expect(defaults.applying(ReaderStyleOverride(fontSize: 20)).pageMargin == 24)
    }

    @Test("a difference records the margin only when it changed")
    func difference() {
        let defaults = ReaderStyle(pageMargin: 24)
        var edited = defaults
        #expect(defaults.difference(to: edited).pageMargin == nil)
        edited.pageMargin = 48
        #expect(defaults.difference(to: edited).pageMargin == 48)
    }

    @Test("a book without a margin override follows a later global change")
    func followsTheDefault() {
        let override = ReaderStyleOverride(fontSize: 22)
        var defaults = ReaderStyle(pageMargin: 24)
        #expect(defaults.applying(override).pageMargin == 24)
        defaults.pageMargin = 12
        #expect(defaults.applying(override).pageMargin == 12)
    }

    /// The map the previous build wrote has no margin key anywhere, and is
    /// decoded under one `try?` — one book failing would drop every book.
    @Test("an override map from the previous build still decodes every book")
    func previousBuildMap() throws {
        let json = #"""
        {"a": {"fontSize": 20, "typeface": {"bundled": {"_0": "Newsreader"}}},
         "b": {"justified": true},
         "c": {"lineSpacing": "roomy", "pageMargin": 6}}
        """#
        let map = try JSONDecoder().decode([String: ReaderStyleOverride].self, from: Data(json.utf8))
        #expect(map.count == 3)
        #expect(map["a"]?.pageMargin == nil)
        #expect(map["b"]?.justification == .always)
        #expect(map["c"]?.pageMargin == 6)
    }
}

/// "Fill the screen with text" as a per-book field, beside the global default.
@Suite("Per-book fill the screen")
struct ReaderStyleOverrideFillTests {
    private func decode(_ json: String) throws -> ReaderStyleOverride {
        try JSONDecoder().decode(ReaderStyleOverride.self, from: Data(json.utf8))
    }

    @Test("an override map from before the setting decodes it as unset")
    func absentKeyIsNil() throws {
        #expect(try decode(#"{"fontSize": 20, "pageMargin": 6}"#).fillsScreen == nil)
    }

    @Test("a value of the wrong type is dropped without losing the other fields")
    func wrongType() throws {
        let decoded = try decode(#"{"fillsScreen": "yes", "fontSize": 21}"#)
        #expect(decoded.fillsScreen == nil)
        #expect(decoded.fontSize == 21)
    }

    @Test("a round trip keeps both positions")
    func roundTrip() throws {
        for value in [true, false] {
            let override = ReaderStyleOverride(fontSize: 20, fillsScreen: value)
            let data = try JSONEncoder().encode(override)
            #expect(try JSONDecoder().decode(ReaderStyleOverride.self, from: data) == override)
        }
    }

    @Test("an override carrying only this is not empty and counts once, off as well as on")
    func counts() {
        for value in [true, false] {
            let override = ReaderStyleOverride(fillsScreen: value)
            #expect(!override.isEmpty)
            #expect(override.count == 1)
        }
    }

    @Test("applying sets it and leaves a book without one alone")
    func applies() {
        let defaults = ReaderStyle()
        #expect(defaults.applying(ReaderStyleOverride(fillsScreen: true)).fillsScreen)
        #expect(!defaults.applying(ReaderStyleOverride(fontSize: 20)).fillsScreen)
        var on = ReaderStyle()
        on.fillsScreen = true
        #expect(!on.applying(ReaderStyleOverride(fillsScreen: false)).fillsScreen)
        #expect(on.applying(ReaderStyleOverride(fontSize: 20)).fillsScreen)
    }

    @Test("a difference records it only when it changed")
    func difference() {
        let defaults = ReaderStyle()
        var edited = defaults
        #expect(defaults.difference(to: edited).fillsScreen == nil)
        edited.fillsScreen = true
        #expect(defaults.difference(to: edited).fillsScreen == true)
    }

    @Test("a style round-trips it, and a blob without the key reads as off")
    func styleStorage() throws {
        var style = ReaderStyle()
        style.fillsScreen = true
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(ReaderStyle.self, from: data).fillsScreen)
        let old = try JSONDecoder().decode(ReaderStyle.self, from: Data(#"{"fontSize": 22, "pageMargin": 32}"#.utf8))
        #expect(!old.fillsScreen)
        #expect(old.fontSize == 22)
        let damaged = try JSONDecoder().decode(ReaderStyle.self, from: Data(#"{"fillsScreen": "yes", "fontSize": 22}"#.utf8))
        #expect(!damaged.fillsScreen)
        #expect(damaged.fontSize == 22)
    }
}
