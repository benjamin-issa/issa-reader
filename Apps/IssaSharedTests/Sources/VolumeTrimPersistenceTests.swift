import Foundation
import IssaPlayback
import Testing

@testable import IssaReader_iOS

/// What the reader hears next launch, and what an account leaves behind.
///
/// The trim is device-local per-book state keyed by a book uuid, which is
/// exactly the shape that outlives the account it belonged to: `bookStyles`
/// needed a sign-out hook for the same reason, and clearing only the stored
/// blob would leave the live dictionary in memory for the rest of the process.
@Suite("Persisting a book's volume trim", .serialized)
@MainActor
struct VolumeTrimPersistenceTests {
    /// The key builds up to 1.1.0 (32) wrote percentages under. Spelled out
    /// rather than read off `PlaybackSettings`, because the point of the tests
    /// below is what is on disk, and a constant shared with the code under test
    /// would follow it if it were renamed.
    static let legacyKey = "issa.bookVolumes"
    static let decibelKey = "issa.bookVolumeDecibels"

    static func write(_ trims: [String: Int], as key: String, in suite: String) throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(try JSONEncoder().encode(trims), forKey: key)
    }

    static func read(_ key: String, in suite: String) throws -> [String: Int]? {
        guard let data = UserDefaults(suiteName: suite)?.data(forKey: key) else { return nil }
        return try JSONDecoder().decode([String: Int].self, from: data)
    }

    @Test("a trim survives the relaunch that reads it back")
    func trimRoundTrips() {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings(suiteName: suite)
        settings.setVolumeTrim(-3, for: "book-a")
        settings.setVolumeTrim(5, for: "book-b")

        let relaunched = PlaybackSettings(suiteName: suite)
        #expect(relaunched.volumeTrim(for: "book-a") == -3)
        #expect(relaunched.volumeTrim(for: "book-b") == 5)
        #expect(relaunched.volumeTrim(for: "never-touched") == 0)
    }

    /// The slider steps by a decibel, but a nudge and a restored preference do
    /// not have to stay inside the range. Clamping on the way in is what stops a
    /// level the control cannot draw from being stored and restored forever.
    @Test("a trim off the end of the range is clamped before it is stored")
    func snappedOnTheWayIn() {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings(suiteName: suite)
        settings.setVolumeTrim(12, for: "book")
        #expect(settings.volumeTrim(for: "book") == 8)
        settings.setVolumeTrim(-12, for: "book")
        #expect(settings.volumeTrim(for: "book") == -8)
        settings.setVolumeTrim(3, for: "book")
        #expect(settings.volumeTrim(for: "book") == 3)
        #expect(PlaybackSettings(suiteName: suite).volumeTrim(for: "book") == 3,
                "the live value was clamped but the stored one was not")
    }

    @Test("returning a book to the recorded level removes it rather than storing a zero")
    func zeroRemovesTheKey() {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings(suiteName: suite)
        settings.setVolumeTrim(2, for: "book")
        #expect(settings.bookVolumeTrims["book"] == 2)

        settings.setVolumeTrim(0, for: "book")
        #expect(settings.bookVolumeTrims["book"] == nil, "a zero is not a preference")
        #expect(settings.bookVolumeTrims.isEmpty)
        #expect(PlaybackSettings(suiteName: suite).bookVolumeTrims.isEmpty)
    }

    @Test("signing out clears the live dictionary, not only the stored one")
    func signOutClearsTheTrims() async throws {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        try Self.write(["book": -30], as: Self.legacyKey, in: suite)
        // A centre of this test's own. The sign-out message is process-wide and
        // every observer of it registers with `object: nil`, so posting it on
        // the default centre reached into every suite running in parallel —
        // clearing their styles and trims, and purging whole question indexes.
        let centre = NotificationCenter()
        let settings = PlaybackSettings(suiteName: suite, centre: centre)
        settings.setVolumeTrim(-2, for: "book")
        #expect(settings.bookVolumeTrims.isEmpty == false)

        centre.post(name: PlaybackSettings.signOutNotification, object: nil)
        // The observer is delivered on the main queue; we are on it.
        await Task.yield()

        #expect(settings.bookVolumeTrims.isEmpty, "the next account inherits this book's level")
        #expect(PlaybackSettings(suiteName: suite).bookVolumeTrims.isEmpty)
        // And the percentages a shipped build would still read. Left alone by
        // the upgrade on purpose, but this hook exists to stop per-book state
        // outliving the account — leaving them behind is the same leak one
        // downgrade away.
        let leftBehind = try Self.read(Self.legacyKey, in: suite)
        #expect(leftBehind == nil)
    }

    // MARK: - The upgrade off percentages

    /// The constraint that could not move, asserted where it matters.
    ///
    /// Builds up to 1.1.0 (32) stored a percentage of the recorded level; this
    /// one stores decibels. Asserting the converted *integer* would let a unit
    /// mix-up through — −30 and −3 are both perfectly plausible numbers to find
    /// in a blob — so this asks what the book now plays at and compares it to
    /// what it used to play at. Rounding to the nearest rung is the only thing
    /// that moves it, and the worst case across every value a shipped build
    /// could hold is 0.4988 dB: half a just-noticeable difference.
    @Test("a book keeps the level it was already playing at")
    func migrationKeepsTheLevel() throws {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let percentages = ["a": -50, "b": -30, "c": -25, "d": 30, "e": 50, "f": 5]
        try Self.write(percentages, as: Self.legacyKey, in: suite)

        let settings = PlaybackSettings(suiteName: suite)
        for (book, percent) in percentages {
            let wasPlayingAt = 1 + Float(percent) / 100
            let nowPlaysAt = VolumeTrim.gain(settings.volumeTrim(for: book))
            let shift = abs(20 * log10(nowPlaysAt / wasPlayingAt))
            #expect(shift < 0.5, "\(book) was at \(percent)% and moved by \(shift) dB")
        }
        // +5% is 0.42 dB, which rounds to the recorded level — and a book at the
        // recorded level is not a preference, so it leaves nothing behind.
        #expect(settings.volumeTrim(for: "f") == 0)
        #expect(settings.bookVolumeTrims["f"] == nil)
    }

    /// Once, and without taking the old levels with it.
    ///
    /// The old key stays exactly as it was so a reader who goes back to a
    /// shipped build finds their levels still there; and the conversion must
    /// not run a second time over a reader's own later choices, which would
    /// silently undo them.
    @Test("the upgrade runs once and leaves the old levels where they are")
    func migrationRunsOnce() throws {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        try Self.write(["book": -50], as: Self.legacyKey, in: suite)

        let first = PlaybackSettings(suiteName: suite)
        #expect(first.volumeTrim(for: "book") == -6)
        let converted = try Self.read(Self.decibelKey, in: suite)
        #expect(converted == ["book": -6], "the converted levels were not written down")
        let legacy = try Self.read(Self.legacyKey, in: suite)
        #expect(legacy == ["book": -50], "a downgrade would find nothing to read")

        // The reader moves it, and relaunches. The conversion must not reach
        // back over their choice.
        first.setVolumeTrim(2, for: "book")
        let second = PlaybackSettings(suiteName: suite)
        #expect(second.volumeTrim(for: "book") == 2)
        let legacyAfterAChoice = try Self.read(Self.legacyKey, in: suite)
        #expect(legacyAfterAChoice == ["book": -50], "the old key is read, never written")

        // And a reader who clears every trim after upgrading stays cleared,
        // rather than having the old percentages handed back on next launch.
        second.setVolumeTrim(0, for: "book")
        #expect(PlaybackSettings(suiteName: suite).bookVolumeTrims.isEmpty)
    }

    /// Nothing to convert is not the same as nothing to do wrong: a reader with
    /// no stored levels at all must not end up with a key full of nothing, and
    /// one who has already upgraded must not be converted a second time.
    @Test("with no old levels the upgrade writes nothing")
    func migrationSkippedWithoutLegacyLevels() throws {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings(suiteName: suite)
        #expect(settings.bookVolumeTrims.isEmpty)
        let decibels = try Self.read(Self.decibelKey, in: suite)
        let leftBehind = try Self.read(Self.legacyKey, in: suite)
        #expect(decibels == nil, "a reader with nothing stored got a key full of nothing")
        #expect(leftBehind == nil)
    }

    /// A blob written by a build that offered ±50, sanitised on the way out of
    /// defaults rather than merely on the way in — and a level nothing on
    /// screen can show is the defect this shares with `playbackRate`.
    @Test("a stored level the slider cannot draw is clamped on the way out of defaults")
    func storedLevelsAreSanitised() throws {
        let suite = "test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        try Self.write(["loud": 40, "quiet": -40, "none": 0], as: Self.decibelKey, in: suite)

        let settings = PlaybackSettings(suiteName: suite)
        #expect(settings.volumeTrim(for: "loud") == 8)
        #expect(settings.volumeTrim(for: "quiet") == -8)
        #expect(settings.bookVolumeTrims["none"] == nil, "a zero is not a preference")
    }
}
