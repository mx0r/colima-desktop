import Foundation

/// Errors from controlling Colima.
public enum ColimaError: Error, LocalizedError, Hashable, Sendable {
    /// The colima executable was not found.
    case executableNotFound
    /// A command exited with a non-zero status.
    case commandFailed(command: String, exitCode: Int32, message: String)
    /// A command did not finish in time and was terminated.
    case timedOut(command: String)
    /// A command printed output this app cannot parse.
    case invalidOutput(command: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "The colima executable was not found. Install colima or set its path in Settings."
        case .commandFailed(let command, let exitCode, let message):
            message.isEmpty ? "\(command) failed with exit code \(exitCode)." : message
        case .timedOut(let command):
            "\(command) did not finish in time."
        case .invalidOutput(let command, let detail):
            "Unexpected output from \(command): \(detail)"
        }
    }
}

/// Errors from the Docker Engine API.
public enum DockerError: Error, LocalizedError, Hashable, Sendable {
    /// The socket could not be connected.
    case socketUnavailable(path: String, reason: String)
    /// The engine answered with an error status.
    case api(status: Int, message: String)
    /// The engine does not support the API version this app needs.
    case unsupportedEngine(String)
    /// The engine sent a response this app cannot parse.
    case invalidResponse(String)
    /// The connection closed before the response was complete.
    case connectionClosed

    public var errorDescription: String? {
        switch self {
        case .socketUnavailable(let path, let reason):
            "Docker socket \(path) is not reachable: \(reason)"
        case .api(let status, let message):
            message.isEmpty ? "Docker returned HTTP \(status)." : message
        case .unsupportedEngine(let detail):
            "Unsupported Docker engine: \(detail)"
        case .invalidResponse(let detail):
            "Unexpected response from Docker: \(detail)"
        case .connectionClosed:
            "The Docker connection closed unexpectedly."
        }
    }
}
