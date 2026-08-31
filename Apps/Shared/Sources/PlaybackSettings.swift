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
    public var playbackRate: Double { didSet { defaults.set(playbackRate, forKey: Self.rateKey) } }

    /// Whether a progress bar stands for the whole book or the current chapter.
    ///
    /// Stored as a raw string beside `playbackRate` rather than folded into
    /// `readerStyle` or `commandMap`: the first re-paginates the open book on
    /// any change, and the second tears down and re-registers every remote
    /// command. This is a display choice and should cost nothing.
    public var progressScope: ProgressScope {
        didSet { defaults.set(progressScope.rawValue, forKey: Self.progressScopeKey) }
    }

    /// Per-book departures from `readerStyle`, keyed by book uuid.
    ///
    /// Device-local and deliberately not synced: a size that suits a phone is
    /// wrong on a Mac, and the server's `/api/v2/user/settings` is for
    /// preferences that should travel.
    public private(set) var bookStyles: [String: ReaderStyleOverride] {
        didSet { persist(bookStyles, as: Self.bookStylesKey) }
    }

    private static let commandMapKey = "issa.commandMap"
    private static let readerStyleKey = "issa.readerStyle"
    private static let bookStylesKey = "issa.bookStyles"
    private static let rateKey = "issa.playbackRate"
    private static let progressScopeKey = "issa.progressScope"

    private let defaults: UserDefaults

    public init(suiteName: String? = CurrentBookSnapshotStore.appGroup) {
        let store = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        defaults = store
        commandMap = Self.load(CommandMap.self, from: store, key: Self.commandMapKey) ?? CommandMap()
        readerStyle = Self.load(ReaderStyle.self, from: store, key: Self.readerStyleKey) ?? ReaderStyle()
        bookStyles = Self.load(
            [String: ReaderStyleOverride].self, from: store, key: Self.bookStylesKey) ?? [:]
        let storedRate = store.double(forKey: Self.rateKey)
        playbackRate = storedRate > 0 ? storedRate : 1.0
        progressScope = store.string(forKey: Self.progressScopeKey)
            .flatMap(ProgressScope.init(rawValue:)) ?? .book
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
