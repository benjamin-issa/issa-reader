import Testing
@testable import IssaRender

/// Moving existing readers onto the new default face.
///
/// The whole style is persisted as one blob the first time any reading
/// preference changes, so nearly every existing reader has the old default
/// written down whether they picked it or not — and changing `defaultFamily`
/// alone would have reached none of them. This is the one-time move that does.
@Suite("Moving off the old default face")
struct DefaultFaceMigrationTests {
    @Test("a style still on the old default moves to the new one")
    func movesTheOldDefault() {
        var style = ReaderStyle()
        style.typeface = .bundled(ReaderStyle.legacyDefaultFamily)
        #expect(style.replacingLegacyDefaultFace().typeface
            == .bundled(ReaderStyle.defaultFamily))
    }

    /// Everything else is a choice somebody made, and a migration that reads
    /// "replace the face" rather than "replace *that* face" would erase all of
    /// them.
    @Test("nothing else is touched", arguments: [
        ReaderStyle.Typeface.publisher,
        .bundled("Public Sans"),
        .bundled("OpenDyslexic"),
        .bundled(ReaderStyle.defaultFamily),
        .custom("A Face The Reader Imported"),
    ])
    func leavesEveryOtherFaceAlone(_ typeface: ReaderStyle.Typeface) {
        var style = ReaderStyle()
        style.typeface = typeface
        #expect(style.replacingLegacyDefaultFace().typeface == typeface)
    }

    @Test("only the face moves — every other setting is carried through")
    func carriesTheRestThrough() {
        var style = ReaderStyle()
        style.typeface = .bundled(ReaderStyle.legacyDefaultFamily)
        style.fontSize = 27
        style.lineSpacing = .roomy
        style.theme = .night
        style.justified = true
        let moved = style.replacingLegacyDefaultFace()
        #expect(moved.fontSize == 27)
        #expect(moved.lineSpacing == .roomy)
        #expect(moved.theme == .night)
        #expect(moved.justified)
    }

    /// It runs behind a flag, but a migration that is not idempotent is a
    /// migration that cannot be re-run after a bug, which is when you most
    /// want to.
    @Test("running it twice changes nothing the second time")
    func idempotent() {
        var style = ReaderStyle()
        style.typeface = .bundled(ReaderStyle.legacyDefaultFamily)
        let once = style.replacingLegacyDefaultFace()
        #expect(once.replacingLegacyDefaultFace() == once)
    }

    @Test("a book that took the old default as its own is moved too")
    func movesABooksOverride() {
        let override = ReaderStyleOverride(typeface: .bundled(ReaderStyle.legacyDefaultFamily))
        #expect(override.replacingLegacyDefaultFace().typeface
            == .bundled(ReaderStyle.defaultFamily))
    }

    /// A book that departs only in size must not acquire a face it never had:
    /// setting `typeface` on it would freeze the global face for that book and
    /// stop it following a later change.
    @Test("a book that never chose a face does not gain one")
    func leavesAFacelessOverrideEmpty() {
        let override = ReaderStyleOverride(fontSize: 24)
        let moved = override.replacingLegacyDefaultFace()
        #expect(moved.typeface == nil)
        #expect(moved.fontSize == 24)
    }
}
