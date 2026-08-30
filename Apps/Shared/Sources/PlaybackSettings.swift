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

    private static let commandMapKey = "issa.commandMap"
    private static let readerStyleKey = "issa.readerStyle"
    private static let rateKey = "issa.playbackRate"

    private let defaults: UserDefaults

    public init(suiteName: String? = CurrentBookSnapshotStore.appGroup) {
        let store = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        defaults = store
        commandMap = Self.load(CommandMap.self, from: store, key: Self.commandMapKey) ?? CommandMap()
        readerStyle = Self.load(ReaderStyle.self, from: store, key: Self.readerStyleKey) ?? ReaderStyle()
        let storedRate = store.double(forKey: Self.rateKey)
        playbackRate = storedRate > 0 ? storedRate : 1.0
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
