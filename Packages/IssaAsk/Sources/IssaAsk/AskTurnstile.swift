import Foundation

/// One turn at the on-device model, for the whole process.
///
/// A plain actor turnstile. There is one model on the device, so the constraint
/// belongs to the process rather than to an engine — and while it was engine
/// state it serialised nothing at all: `AskCoordinator` builds a fresh
/// `AskEngine` per question, so two books meant two engines, two turnstiles and
/// two concurrent generations. The reader who asked about a second book was
/// told "Apple Intelligence is busy" for a question that should have queued.
///
/// A reader who asks again before the first answer lands should get the second
/// answer rather than an error, so the second question waits rather than
/// racing. It waits *before* checking its own cancellation, which means a
/// cancelled second question still holds its place in the queue for as long as
/// the first one runs; that is the queue working, not a leak, and
/// `AskEngine.generate` throws at `try Task.checkCancellation()` the moment its
/// turn comes, so the cost is one actor hop.
public actor AskTurnstile {
    private var isAnswering = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Runs `body` holding the turn, and releases it whether it returns or
    /// throws.
    ///
    /// The release is written here, once, rather than at the call sites: `defer`
    /// cannot `await`, so a caller doing this for itself needs a release on the
    /// success path and another on the failure path, and the second one is what
    /// gets forgotten — a forgotten release wedges every later question in the
    /// process, with no error and nothing in the log.
    ///
    /// `isolation:` so `body` runs on the caller's executor rather than hopping
    /// onto this actor: the work under a turn is a twenty-second generation
    /// that touches the engine's own state, and running it here would park the
    /// turnstile behind it. The parameter is what decides that — a method with
    /// an `isolated` parameter cannot also be written `nonisolated`, because
    /// the parameter has already said where it runs.
    public func withTurn<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T,
    ) async rethrows -> T {
        await acquire()
        do {
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    /// Runs `body` only if the turn is free, and skips it otherwise.
    ///
    /// For work that is pointless once it has to wait. `AskEngine.prewarm`
    /// loads the model's weights so the reader's first question is faster; a
    /// prewarm that queues behind a generation would be loading what that
    /// generation has already loaded, twenty seconds after it stopped mattering.
    ///
    /// - Returns: whether `body` ran.
    @discardableResult
    public func ifFree(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async -> Void,
    ) async -> Bool {
        guard await claimIfFree() else { return false }
        await body()
        await release()
        return true
    }

    // MARK: - The turn itself

    private func acquire() async {
        guard isAnswering else { isAnswering = true; return }
        await withCheckedContinuation { queue.append($0) }
    }

    private func claimIfFree() -> Bool {
        guard !isAnswering else { return false }
        isAnswering = true
        return true
    }

    private func release() {
        guard !queue.isEmpty else { isAnswering = false; return }
        queue.removeFirst().resume()
    }
}
