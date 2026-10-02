import Foundation
import IssaCore

/// Where a book that is not the signed-in server's keeps what its reader writes.
///
/// `AppModel.reader(for:persistence:)` installs these as the model's hooks, as
/// `reader(for:session:)` installs the server's: the reader model asks the same
/// questions of either and never knows which it is talking to. Only books the
/// reader added from their own files use it — `LocalLibrary` is the one
/// implementation — and their place, highlights and narration anchor stay on
/// this device.
///
/// Class-bound so the hooks capture it weakly: the model outlives its screen,
/// and must not keep the library alive through a closure it stores.
@MainActor
public protocol ReaderPersistence: AnyObject {
    /// The book's folder and everything in it.
    func files(for bookUUID: String) -> LocalBookFiles
    /// Where the reader was, for the open to land on.
    func storedPosition(for bookUUID: String) async -> StoredPosition?
    /// Records a position through this store's own `PositionGuard`.
    ///
    /// Returns false when refused: nothing is published and no audio anchor is
    /// recorded for it, which `ReaderModel.saveProgress` already obeys.
    func writePosition(
        _ locator: ReadiumLocator, timestamp: Double,
        origin: PositionOrigin, for bookUUID: String,
    ) async -> Bool
    func recordAudioAnchor(_ anchor: AudioAnchor, for bookUUID: String) async
    func audioAnchor(for bookUUID: String) async -> AudioAnchor?
    func annotations(for bookUUID: String) async -> [Annotation]
    func save(_ annotation: Annotation)
    func delete(_ annotation: Annotation)
    /// The reader has opened this book: the list is ordered by it.
    func didOpen(_ bookUUID: String)
}
