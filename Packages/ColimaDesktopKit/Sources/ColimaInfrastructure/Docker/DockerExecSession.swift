import ColimaDomain
import Foundation

/// An interactive exec session over a hijacked Engine API connection.
///
/// With `Tty: true` the stream is raw (not multiplexed) in both directions.
final class DockerExecSession: ExecSession {
    let output: AsyncThrowingStream<[UInt8], Error>

    private let execID: String
    private let connection: any ByteStreamConnection
    private let engine: DockerEngineClient

    init(execID: String, hijacked: HijackedConnection, engine: DockerEngineClient) {
        self.execID = execID
        connection = hijacked.connection
        self.engine = engine
        let connection = hijacked.connection
        let initial = hijacked.initialBytes
        output = AsyncThrowingStream { continuation in
            let task = Task {
                if !initial.isEmpty { continuation.yield(initial) }
                do {
                    while let bytes = try await connection.receive() {
                        if !bytes.isEmpty { continuation.yield(bytes) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                connection.close()
            }
        }
    }

    func write(_ bytes: [UInt8]) async throws {
        try await connection.send(bytes)
    }

    func resize(_ size: TerminalSize) async throws {
        try await engine.resizeExec(execID, size: size)
    }

    func exitCode() async throws -> Int? {
        let state = try await engine.inspectExec(execID)
        return state.running ? nil : state.exitCode
    }

    func close() async {
        connection.close()
    }
}
