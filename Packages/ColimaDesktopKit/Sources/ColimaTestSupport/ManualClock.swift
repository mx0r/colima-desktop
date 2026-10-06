import Foundation
import Synchronization

/// A clock that only moves when `advance(by:)` is called. Sleepers resume in deadline order.
public final class ManualClock: Clock, Sendable {
    /// Instant of a manual clock.
    public struct Instant: InstantProtocol {
        public var offset: Duration

        public init(offset: Duration) { self.offset = offset }

        public func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
    }

    private let state = Mutex(State())

    /// Creates a clock at offset zero.
    public init() {}

    public var now: Instant { state.withLock { $0.now } }
    public var minimumResolution: Duration { .zero }

    /// Number of tasks currently sleeping.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumeNow = state.withLock { state -> Bool in
                    if Task.isCancelled { return true }
                    if deadline <= state.now { return true }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if resumeNow {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and resumes due sleepers, letting them run between steps.
    public func advance(by duration: Duration) async {
        let target = state.withLock { $0.now.advanced(by: duration) }
        while true {
            let due = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.indices.min(by: { state.sleepers[$0].deadline < state.sleepers[$1].deadline }),
                      state.sleepers[index].deadline <= target else { return nil }
                let sleeper = state.sleepers.remove(at: index)
                state.now = max(state.now, sleeper.deadline)
                return sleeper
            }
            guard let due else { break }
            due.continuation.resume()
            await Self.settle()
        }
        state.withLock { $0.now = target }
        await Self.settle()
    }

    /// Waits (in real time) until at least `count` tasks sleep on this clock.
    @discardableResult
    public func waitForSleepers(_ count: Int = 1, timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if sleeperCount >= count { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return sleeperCount >= count
    }

    /// Lets other tasks make progress.
    public static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

/// Polls a condition on the main actor until it holds or the timeout passes.
@MainActor
public func eventually(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
