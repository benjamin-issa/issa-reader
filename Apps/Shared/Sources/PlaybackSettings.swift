import Foundation
import IssaCore
import IssaPlayback
import IssaRender
import Observation

/// Persisted playback and reading preferences.
///
/// Stored in the App Group's defaults rather than the app's own, so the widget
/// and any extension read the same values without a second copy.
@Observable
@MainActor
public final class PlaybackSettings {
    public var commandMap: CommandMap { didSet { persist(commandMap, as: Self.commandMapKey) } }
    public var readerStyle: ReaderStyle { didSet { persist(readerStyle, as: Self.readerStyleKey) } }
    /// Clamped on the way in and on the way out.
    ///
    /// It accepted anything: the bound speed controls walked to 5.0×, a value
    /// no menu offers and the transport renders as "5×", and `storedRate > 0`
    /// let it back in on the next launch — so a rate reached by holding a
    /// button was persisted with no control able to show or undo it.
    public var playbackRate: Double {
        didSet {
            // Clamp, then persist the clamped value, in one pass. An earlier
            // form was `if legal != playbackRate { playbackRate = legal; return }`
            // and a review read it as skipping the write, on the rule that a
            // stored property's observer is not re-entered by an assignment
            // inside it. That rule does not hold here: this class is
            // `@Observable`, so the property is macro-synthesised and the
            // inner assignment ran the observer again, which then wrote. The
            // review was wrong on that point — `PlaybackRatePersistenceTests`
            // passed against both forms. This form is kept because it does not
            // depend on the reader knowing that.
            let legal = PlaybackRate.clamped(playbackRate)
            if legal != playbackRate { playbackRate = legal }
            defaults.set(legal, forKey: Self.rateKey)
        }
    }

    /// Whether a progress bar stands for the whole book or the current chapter.
    ///
    /// Stored as a raw string beside `playbackRate` rather than folded into
    /// `readerStyle` or `commandMap`: the first re-paginates the open book on
    /// any change, and the second tears down and re-registers every remote
    /// command. This is a display choice and should cost nothing.
    public var progressScope: ProgressScope {
        didSet { defaults.set(progressScope.rawValue, forKey: Self.progressScopeKey) }
    }

    /// Whether the reader offers to answer questions about the book.
    ///
    /// Off until asked for, and stored beside `progressScope` rather than in
    /// `readerStyle` for the same reason: a reading style change re-paginates
    /// the open book, and turning a toolbar button on or off should not cost
    /// the reader their place. It is also not a *style* — it decides whether a
    /// whole feature exists, which is a settings-screen question rather than an
    /// Aa-sheet one.
    public var askEnabled: Bool {
        didSet { defaults.set(askEnabled, forKey: Self.askEnabledKey) }
    }

    /// Per-book departures from `readerStyle`, keyed by book uuid.
    ///
    /// Device-local and deliberately not synced: a size that suits a phone is
    /// wrong on a Mac, and the server's `/api/v2/user/settings` is for
    /// preferences that should travel.
    public private(set) var bookStyles: [String: ReaderStyleOverride] {
        didSet { persist(bookStyles, as: Self.bookStylesKey) }
    }

    /// How far each book departs from the level it was recorded at, in
    /// decibels, keyed by book uuid.
    ///
    /// Beside `bookStyles` and for the same reason: this corrects one library's
    /// mastering on one device's speakers, and syncing it would push a phone's
    /// correction onto a Mac that does not need it. Only departures are stored,
    /// so a book returned to "as recorded" leaves nothing behind.
    public private(set) var bookVolumeTrims: [String: Int] {
        didSet { persist(bookVolumeTrims, as: Self.bookVolumeDecibelsKey) }
    }

    /// Posted when an account signs out, so per-book state keyed by a book
    /// uuid is dropped.
    ///
    /// A notification rather than a direct call because `AppModel` does not own
    /// this object — `AppServices` does — and clearing only the stored value
    /// would leave the live instance's copy in memory for the rest of the
    /// process, which is the half-fix that keeps the leak.
    public static let signOutNotification = Notification.Name("issa.playbackSettings.signOut")

    private static let commandMapKey = "issa.commandMap"
    private static let readerStyleKey = "issa.readerStyle"
    private static let bookStylesKey = "issa.bookStyles"
    /// Percentages, written by builds up to 1.1.0 (32) and read once by this
    /// one. Never written again, and deliberately left where it is: a reader who
    /// goes back to a shipped build should find their levels still there.
    private static let bookVolumesKey = "issa.bookVolumes"
    /// Decibels, which is what the slider offers now. A key of its own rather
    /// than the old one reused, so the two builds cannot read each other's
    /// numbers as their own units — a "−6" that means percent on one side and
    /// decibels on the other is a book that plays at half the level it should.
    private static let bookVolumeDecibelsKey = "issa.bookVolumeDecibels"
    private static let rateKey = "issa.playbackRate"
    private static let progressScopeKey = "issa.progressScope"
    private static let askEnabledKey = "issa.askAboutBook"
    private static let faceMigrationKey = "issa.migratedDefaultFaceToLiterata"

    /// The observer token, in a box `deinit` can reach.
    ///
    /// A nonisolated `deinit` cannot read a main-actor property, and dropping
    /// the removal instead is how a released object leaves a live observer
    /// behind — which is the same defect this codebase already carries in
    /// `RemoteCommandCenter`, and which `RemoteCommands` solves the same way
    /// for its route observer.
    private final class ObserverBox: @unchecked Sendable {
        var token: (any NSObjectProtocol)?
        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    private let signOutObserver = ObserverBox()

    private let defaults: UserDefaults

    /// The named defaults, or nil where an App Group suite is not actually
    /// available to this process.
    ///
    /// The iOS app, its widget and the Mac's Release build carry the App Group
    /// entitlement. tvOS has no entitlements file at all, and the Mac's Debug
    /// build deliberately omits the group — that entitlement needs a
    /// provisioning profile, and a macOS development profile needs a registered
    /// Mac. `UserDefaults(suiteName:)` hands back an object regardless — it does
    /// not fail, and it does not warn — so a reading preference could be written
    /// somewhere that is not the container and need not survive the app. Asking
    /// for the container is the only honest test, and `.standard` is a perfectly
    /// good home for preferences nothing else has to read.
    ///
    /// Scoped to `group.` names so a plain suite passed in by a caller is still
    /// taken at face value.
    private static func defaults(named name: String) -> UserDefaults? {
        if name.hasPrefix("group."),
           FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: name) == nil {
            return nil
        }
        return UserDefaults(suiteName: name)
    }

    /// `centre` is injectable so a test can post the sign-out message to a
    /// centre only its own instance observes. The observer below registers with
    /// `object: nil` on a process-wide centre, so a suite posting that
    /// notification reached into every other suite running beside it — clearing
    /// per-book styles and volume trims mid-test, and taking whole question
    /// indexes with it. swift-testing runs suites in parallel; the scope of the
    /// message has to be narrower than the process.
    public init(
        suiteName: String? = CurrentBookSnapshotStore.appGroup,
        centre: NotificationCenter = .default,
    ) {
        let store = suiteName.flatMap { Self.defaults(named: $0) } ?? .standard
        defaults = store
        commandMap = Self.load(CommandMap.self, from: store, key: Self.commandMapKey) ?? CommandMap()
        readerStyle = Self.load(ReaderStyle.self, from: store, key: Self.readerStyleKey) ?? ReaderStyle()
        bookStyles = Self.load(
            [String: ReaderStyleOverride].self, from: store, key: Self.bookStylesKey) ?? [:]
        let volumes = Self.volumeTrims(in: store)
        bookVolumeTrims = volumes.trims
        let storedRate = store.double(forKey: Self.rateKey)
        playbackRate = storedRate > 0 ? PlaybackRate.clamped(storedRate) : 1.0
        // No migration needed, and this is the part to get right: a stored
        // property assigned in `init` does not fire its `didSet`, so the key is
        // absent from defaults until someone actually moves the picker. Moving
        // the fallback therefore moves everyone who never chose, and leaves
        // alone everyone who did.
        progressScope = store.string(forKey: Self.progressScopeKey)
            .flatMap(ProgressScope.init(rawValue:)) ?? .chapter
        // `bool(forKey:)` is false for an absent key, which is the default this
        // wants: a reader who has never seen the switch has not turned it on.
        askEnabled = store.bool(forKey: Self.askEnabledKey)
        moveOffTheOldDefaultFace()
        // Assignments in `init` do not fire `didSet`, so the levels this build
        // just converted are written back by hand — once, and only when they
        // came from the old key. `moveOffTheOldDefaultFace` does the same for
        // the reading face, for the same reason.
        if volumes.migrated { persist(bookVolumeTrims, as: Self.bookVolumeDecibelsKey) }
        // After every stored property: `self` is not usable in a closure until
        // the initialiser has finished.
        signOutObserver.token = centre.addObserver(
            forName: Self.signOutNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.bookStyles = [:]
                self?.bookVolumeTrims = [:]
                // The old key as well. It is per-book state keyed by a book
                // uuid, which is the whole reason this hook exists, and leaving
                // the previous account's levels in a key a shipped build still
                // reads is the same leak one downgrade away.
                self?.defaults.removeObject(forKey: Self.bookVolumesKey)
            }
        }
    }

    /// This build's levels, and whether they had to be converted to get here.
    ///
    /// Decibels are read from their own key. Where that key is absent the
    /// percentages a build up to 1.1.0 (32) wrote are converted through the
    /// multiplier they always stood for, which moves nobody's book by more than
    /// half a just-noticeable difference — see `VolumeTrim.decibels(forLegacyPercent:)`.
    /// The old key is read and left exactly as it was, so going back to a
    /// shipped build still finds it.
    ///
    /// Sanitised on the way out of defaults, not merely on the way in: the blob
    /// is a file on disk that an older build — or a hand edit — may have
    /// written, and a level nothing on screen can show or undo is the same
    /// defect `playbackRate` already carries a clamp for. Entries that sanitise
    /// to zero are dropped rather than kept at zero, so the dictionary means
    /// "books that depart from the recording" for every reader of it.
    private static func volumeTrims(in store: UserDefaults) -> (trims: [String: Int], migrated: Bool) {
        if let stored = load([String: Int].self, from: store, key: bookVolumeDecibelsKey) {
            return (stored.compactMapValues(legalTrim), false)
        }
        guard let legacy = load([String: Int].self, from: store, key: bookVolumesKey) else {
            return ([:], false)
        }
        return (legacy.compactMapValues { legalTrim(VolumeTrim.decibels(forLegacyPercent: $0)) }, true)
    }

    /// A stored level, snapped onto the ladder, or nil for a book that is at the
    /// recorded level after all.
    private static func legalTrim(_ stored: Int) -> Int? {
        let legal = VolumeTrim.clamped(stored)
        return legal == 0 ? nil : legal
    }

    /// Moves anyone still on the previous default reading face onto the new one,
    /// once.
    ///
    /// Changing `ReaderStyle.defaultFamily` alone would have reached nobody who
    /// already had settings: the whole style is persisted as one blob the first
    /// time any reading preference changes, so an existing reader has the old
    /// face written down whether they chose it or not. The flag makes this a
    /// move and not a policy — pick Newsreader afterwards and it stays picked.
    ///
    /// Assignments in `init` do not fire `didSet`, so both blobs are written
    /// back by hand here.
    private func moveOffTheOldDefaultFace() {
        guard !defaults.bool(forKey: Self.faceMigrationKey) else { return }
        defaults.set(true, forKey: Self.faceMigrationKey)

        let movedStyle = readerStyle.replacingLegacyDefaultFace()
        let movedBooks = bookStyles.mapValues { $0.replacingLegacyDefaultFace() }
        guard movedStyle != readerStyle || movedBooks != bookStyles else { return }
        readerStyle = movedStyle
        bookStyles = movedBooks
        persist(readerStyle, as: Self.readerStyleKey)
        persist(bookStyles, as: Self.bookStylesKey)
    }

    /// The style to set this book in: the global settings, with the book's own
    /// choices laid over them.
    public func style(for bookUUID: String) -> ReaderStyle {
        readerStyle.applying(bookStyles[bookUUID])
    }

    public func override(for bookUUID: String) -> ReaderStyleOverride? {
        bookStyles[bookUUID]
    }

    /// Records what this book departs from the defaults in.
    ///
    /// An override with nothing left in it is removed rather than stored: a
    /// book that has been returned to the defaults should follow them from then
    /// on, including changes made later.
    public func setOverride(_ override: ReaderStyleOverride?, for bookUUID: String) {
        if let override, !override.isEmpty {
            bookStyles[bookUUID] = override
        } else {
            bookStyles.removeValue(forKey: bookUUID)
        }
    }

    /// How far this book departs from the recorded level, in decibels. Zero for
    /// every book nobody has trimmed, which is nearly all of them.
    public func volumeTrim(for bookUUID: String) -> Int {
        bookVolumeTrims[bookUUID] ?? 0
    }

    /// Records this book's level, in decibels.
    ///
    /// Zero removes the entry rather than storing it, on the same rule as
    /// `setOverride`: a book back at the recorded level has no preference, and
    /// keeping one would be a row that means nothing and never expires.
    public func setVolumeTrim(_ decibels: Int, for bookUUID: String) {
        if let legal = Self.legalTrim(decibels) {
            bookVolumeTrims[bookUUID] = legal
        } else {
            bookVolumeTrims.removeValue(forKey: bookUUID)
        }
    }

    private func persist(_ value: some Encodable, as key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Restores the shipped defaults for one surface, which is the escape hatch
    /// after someone has experimented themselves into a corner.
    public func resetBindings(for surface: ControlSurface) {
        commandMap.bindings[surface] = CommandMap.defaultBindings[surface]
    }
}
