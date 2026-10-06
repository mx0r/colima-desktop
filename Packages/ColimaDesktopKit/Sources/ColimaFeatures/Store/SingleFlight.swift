import Foundation

/// Runs at most one operation at a time. Calls arriving while one runs are coalesced into a single re-run.
@MainActor
public final class SingleFlight {
    private var isRunning = false
    private var isQueued = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a single-flight gate.
    public init() {}

    /// Runs `operation`, or queues one re-run if it is already running.
    /// Returns once the run that covers this call has finished.
    public func run(_ operation: @MainActor () async -> Void) async {
        if isRunning {
            isQueued = true
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        isRunning = true
        repeat {
            isQueued = false
            let covered = waiters
            waiters = []
            await operation()
            covered.forEach { $0.resume() }
        } while isQueued
        isRunning = false
        // Callers that queued during the last pass are covered by it.
        let remaining = waiters
        waiters = []
        remaining.forEach { $0.resume() }
    }
}
