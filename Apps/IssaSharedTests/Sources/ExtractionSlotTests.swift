import Foundation
import Testing

@testable import IssaReader_iOS

/// The handle a removal revokes a narration extraction through.
///
/// A rotation during a cold open of a long read-along runs `open` again while
/// the first extraction is still writing. The handle was a bare optional: the
/// second open overwrote it, so a removal revoked only the extraction queued
/// behind the lock and then waited on the main actor for the one writing — the
/// hang the handle exists to prevent — and when the first open woke it cleared
/// the handle unconditionally, leaving the second extraction out of reach.
@Suite("Revoking the narration extraction")
@MainActor
struct ExtractionSlotTests {
    /// An extraction that runs until it is cancelled or the test ends.
    static func extraction() -> Task<[String: URL]?, Never> {
        Task.detached { () -> [String: URL]? in
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
    }

    @Test("superseding keeps the newer extraction, and a removal reaches it")
    func supersedingKeepsTheNewerTask() {
        var slot = ExtractionSlot()
        let first = Self.extraction()
        let second = Self.extraction()
        defer {
            first.cancel()
            second.cancel()
        }

        slot.hold(first)
        slot.hold(second)
        #expect(first.isCancelled, "the superseded open's extraction stands down")
        #expect(!second.isCancelled)

        // The superseded open wakes when its extraction ends, and lets go of
        // the slot on its way out — which is no longer its to let go of.
        slot.release(first)
        #expect(slot.isHeld, "only the extraction holding the slot may clear it")

        // A removal arriving now has to reach the extraction doing the work.
        slot.cancel()
        #expect(second.isCancelled)
        slot.release(second)
        #expect(!slot.isHeld)
    }

    @Test("an empty slot revokes nothing")
    func anEmptySlotIsANoOp() {
        let slot = ExtractionSlot()
        slot.cancel()
        #expect(!slot.isHeld)
    }
}
