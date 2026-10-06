import Foundation

/// A VM operation the user can trigger.
public enum VMOperation: Hashable, Sendable {
    case start
    case stop
    case restart

    /// Status the VM should have after the operation succeeded.
    public var targetStatus: VMStatus {
        switch self {
        case .start, .restart: .running
        case .stop: .stopped
        }
    }
}

/// Coarse state shown by the menu bar icon.
public enum IconState: Hashable, Sendable {
    case running
    case stopped
    case transitioning
    case error
    case unknown
}

/// State machine for one profile's VM lifecycle.
///
/// A pure reducer: callers feed events and execute the returned effects.
public struct VMLifecycle: Hashable, Sendable {
    /// Last observed status; nil until the first observation.
    public private(set) var observed: VMStatus?
    /// Operation in progress, if any.
    public private(set) var operation: VMOperation?
    /// Last failure (operation and message), cleared by a new request or when the goal is reached.
    public private(set) var failure: Failure?
    /// Whether the colima executable was found.
    public private(set) var colimaAvailable = true

    /// A failed operation and its message.
    public struct Failure: Hashable, Sendable {
        public var operation: VMOperation
        public var message: String
    }

    /// Inputs to the state machine.
    public enum Event: Hashable, Sendable {
        /// A status was read from colima.
        case observed(VMStatus)
        /// The user asked for an operation.
        case requested(VMOperation)
        /// The operation's process exited successfully.
        case finished(VMOperation)
        /// The operation failed with a message.
        case failed(VMOperation, String)
        /// The colima executable could not be found.
        case colimaMissing
    }

    /// Work the caller must do after an event.
    public enum Effect: Hashable, Sendable {
        case perform(VMOperation)
        case notifySucceeded(VMOperation)
        case notifyFailed(VMOperation, String)
        case refresh
    }

    /// Display phase derived from the state.
    public enum Phase: Hashable, Sendable {
        case loading
        case colimaMissing
        case operating(VMOperation)
        case failed(VMOperation, String)
        case status(VMStatus)
    }

    /// Creates the initial state.
    public init() {}

    /// Applies an event and returns the effects to execute.
    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .observed(let status):
            colimaAvailable = true
            observed = status
            if let failure, operation == nil, status == failure.operation.targetStatus {
                self.failure = nil
            }
            return []

        case .requested(let operation):
            guard isAllowed(operation) else { return [] }
            self.operation = operation
            failure = nil
            return [.perform(operation)]

        case .finished(let operation):
            guard self.operation == operation else { return [] }
            self.operation = nil
            return [.notifySucceeded(operation), .refresh]

        case .failed(let operation, let message):
            guard self.operation == operation else { return [] }
            self.operation = nil
            failure = Failure(operation: operation, message: message)
            return [.notifyFailed(operation, message), .refresh]

        case .colimaMissing:
            colimaAvailable = false
            return []
        }
    }

    /// Whether the operation may be requested now.
    public func isAllowed(_ operation: VMOperation) -> Bool {
        switch operation {
        case .start: canStart
        case .stop: canStop
        case .restart: canRestart
        }
    }

    /// Start is possible.
    public var canStart: Bool {
        guard isIdle, let observed else { return false }
        switch observed {
        case .stopped, .uninitialized, .broken: return true
        default: return false
        }
    }

    /// Stop is possible.
    public var canStop: Bool {
        guard isIdle, let observed else { return false }
        switch observed {
        case .running, .broken, .unknown: return true
        default: return false
        }
    }

    /// Restart is possible.
    public var canRestart: Bool {
        isIdle && observed == .running
    }

    private var isIdle: Bool { colimaAvailable && operation == nil }

    /// Phase for display.
    public var phase: Phase {
        if !colimaAvailable { return .colimaMissing }
        if let operation { return .operating(operation) }
        if let failure { return .failed(failure.operation, failure.message) }
        guard let observed else { return .loading }
        return .status(observed)
    }

    /// Icon state for the menu bar.
    public var iconState: IconState {
        switch phase {
        case .loading: return .unknown
        case .colimaMissing, .failed: return .error
        case .operating: return .transitioning
        case .status(let status):
            switch status {
            case .running: return .running
            case .stopped, .uninitialized: return .stopped
            case .installing: return .transitioning
            case .broken: return .error
            case .unknown: return .unknown
            }
        }
    }
}
