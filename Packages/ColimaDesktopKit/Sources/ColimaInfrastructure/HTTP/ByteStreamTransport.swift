import ColimaDomain
import Foundation
import Network
import Synchronization

/// A bidirectional byte stream (one socket connection).
public protocol ByteStreamConnection: Sendable {
    /// Sends bytes.
    func send(_ bytes: [UInt8]) async throws
    /// Receives the next bytes; nil at EOF.
    func receive() async throws -> [UInt8]?
    /// Closes the connection. Pending receives fail or return nil.
    func close()
}

/// Opens byte stream connections.
public protocol ByteStreamTransport: Sendable {
    /// Opens a new connection.
    func connect() async throws -> any ByteStreamConnection
}

/// Connects to a unix domain socket with Network.framework.
public struct NWUnixTransport: ByteStreamTransport {
    /// Socket path.
    public let socketPath: String
    /// Connect timeout.
    public let connectTimeout: Duration

    /// Creates a transport for a socket path.
    public init(socketPath: String, connectTimeout: Duration = .seconds(5)) {
        self.socketPath = socketPath
        self.connectTimeout = connectTimeout
    }

    public func connect() async throws -> any ByteStreamConnection {
        let path = socketPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw DockerError.socketUnavailable(path: path, reason: "no such file")
        }
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        let queue = DispatchQueue(label: "ColimaDesktop.docker-socket")
        let gate = ResumeGate()
        let timeout = connectTimeout

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.set(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.resume(with: .success(()))
                    case .failed(let error), .waiting(let error):
                        // A unix socket that refuses connections never recovers by waiting.
                        connection.cancel()
                        gate.resume(with: .failure(DockerError.socketUnavailable(path: path, reason: error.localizedDescription)))
                    case .cancelled:
                        gate.resume(with: .failure(CancellationError()))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                Task.detached {
                    try? await Task.sleep(for: timeout)
                    if gate.resume(with: .failure(DockerError.socketUnavailable(path: path, reason: "connect timed out"))) {
                        connection.cancel()
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
        connection.stateUpdateHandler = nil
        return NWByteStreamConnection(connection: connection)
    }
}

/// Resumes a continuation at most once.
private final class ResumeGate: Sendable {
    private let continuation = Mutex<CheckedContinuation<Void, Error>?>(nil)

    func set(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation.withLock { $0 = continuation }
    }

    /// Returns true when this call resumed the continuation.
    @discardableResult
    func resume(with result: Result<Void, Error>) -> Bool {
        let pending = continuation.withLock { value -> CheckedContinuation<Void, Error>? in
            defer { value = nil }
            return value
        }
        pending?.resume(with: result)
        return pending != nil
    }
}

private struct NWByteStreamConnection: ByteStreamConnection {
    let connection: NWConnection

    func send(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive() async throws -> [UInt8]? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8]?, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: [UInt8](data))
                    } else if let error {
                        if case .posix(let code) = error, code == .ECANCELED {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: error)
                        }
                    } else if isComplete {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: [])
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func close() {
        connection.cancel()
    }
}
