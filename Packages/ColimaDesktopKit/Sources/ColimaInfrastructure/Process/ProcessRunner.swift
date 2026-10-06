import Foundation
import Synchronization

/// Output of a finished process.
public struct ProcessResult: Sendable, Hashable {
    /// Exit status (or signal number when terminated by a signal).
    public var exitCode: Int32
    /// Captured standard output.
    public var stdout: Data
    /// Captured standard error.
    public var stderr: Data

    /// Standard output as UTF-8 text.
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    /// Standard error as UTF-8 text.
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs external programs.
public protocol ProcessRunning: Sendable {
    /// Runs a program without a shell and collects its output.
    ///
    /// - Parameters:
    ///   - timeout: Terminates the process and throws `ProcessRunnerError.timedOut` when exceeded.
    ///   - onStderrLine: Receives each complete stderr line while the process runs.
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration?,
        onStderrLine: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult
}

/// Errors raised by `FoundationProcessRunner`.
public enum ProcessRunnerError: Error, Hashable, Sendable {
    /// The process did not finish in time and was terminated.
    case timedOut
}

/// `Process` based runner.
///
/// Drains both pipes while the process runs (no pipe-buffer deadlock), never blocks a thread,
/// terminates the process on task cancellation and on timeout.
public struct FoundationProcessRunner: ProcessRunning {
    /// How long to wait for pipe EOF after exit. Daemonized grandchildren may keep the pipe open.
    let eofGracePeriod: Duration

    /// Creates a runner.
    public init(eofGracePeriod: Duration = .seconds(2)) {
        self.eofGracePeriod = eofGracePeriod
    }

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration?,
        onStderrLine: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = OutputCollector(onStderrLine: onStderrLine)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                collector.setContinuation(continuation)

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        collector.finishStream(.stdout)
                    } else {
                        collector.append(data, to: .stdout)
                    }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        collector.finishStream(.stderr)
                    } else {
                        collector.append(data, to: .stderr)
                    }
                }
                process.terminationHandler = { process in
                    collector.processExited(code: process.terminationStatus)
                    // Stop waiting for EOF after a grace period.
                    let grace = eofGracePeriod
                    Task.detached {
                        try? await Task.sleep(for: grace)
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        collector.forceFinish()
                    }
                }

                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    collector.fail(error)
                    return
                }
                // Close our copies of the write ends so EOF arrives when the child exits.
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()

                if let timeout {
                    Task.detached {
                        try? await Task.sleep(for: timeout)
                        if process.isRunning {
                            collector.markTimedOut()
                            process.terminate()
                        }
                    }
                }
                if collector.isCancelled, process.isRunning {
                    process.terminate()
                }
            }
        } onCancel: {
            collector.markCancelled()
            if process.isRunning { process.terminate() }
        }
    }
}

/// Collects pipe output and resumes the continuation once the process exited and both pipes ended.
private final class OutputCollector: Sendable {
    enum Stream { case stdout, stderr }

    private struct State {
        var continuation: CheckedContinuation<ProcessResult, Error>?
        var stdout = Data()
        var stderr = Data()
        var stderrLineBuffer = Data()
        var stdoutDone = false
        var stderrDone = false
        var exitCode: Int32?
        var timedOut = false
        var cancelled = false
        var finished = false
    }

    private let state = Mutex(State())
    private let onStderrLine: (@Sendable (String) -> Void)?

    init(onStderrLine: (@Sendable (String) -> Void)?) {
        self.onStderrLine = onStderrLine
    }

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func setContinuation(_ continuation: CheckedContinuation<ProcessResult, Error>) {
        state.withLock { $0.continuation = continuation }
    }

    func append(_ data: Data, to stream: Stream) {
        let lines: [String] = state.withLock { state in
            switch stream {
            case .stdout:
                state.stdout.append(data)
                return []
            case .stderr:
                state.stderr.append(data)
                guard onStderrLine != nil else { return [] }
                state.stderrLineBuffer.append(data)
                return Self.takeLines(from: &state.stderrLineBuffer)
            }
        }
        lines.forEach { onStderrLine?($0) }
    }

    func finishStream(_ stream: Stream) {
        let trailing: String? = state.withLock { state in
            switch stream {
            case .stdout:
                state.stdoutDone = true
                return nil
            case .stderr:
                state.stderrDone = true
                defer { state.stderrLineBuffer.removeAll() }
                return state.stderrLineBuffer.isEmpty ? nil : String(decoding: state.stderrLineBuffer, as: UTF8.self)
            }
        }
        if let trailing { onStderrLine?(trailing) }
        resumeIfComplete()
    }

    func processExited(code: Int32) {
        state.withLock { $0.exitCode = code }
        resumeIfComplete()
    }

    func forceFinish() {
        state.withLock { state in
            state.stdoutDone = true
            state.stderrDone = true
        }
        resumeIfComplete()
    }

    func markTimedOut() { state.withLock { $0.timedOut = true } }
    func markCancelled() { state.withLock { $0.cancelled = true } }

    func fail(_ error: Error) {
        let continuation = state.withLock { state -> CheckedContinuation<ProcessResult, Error>? in
            guard !state.finished else { return nil }
            state.finished = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(throwing: error)
    }

    private func resumeIfComplete() {
        let outcome = state.withLock { state -> (CheckedContinuation<ProcessResult, Error>, Result<ProcessResult, Error>)? in
            guard !state.finished, state.stdoutDone, state.stderrDone, let exitCode = state.exitCode,
                  let continuation = state.continuation else { return nil }
            state.finished = true
            state.continuation = nil
            if state.cancelled { return (continuation, .failure(CancellationError())) }
            if state.timedOut { return (continuation, .failure(ProcessRunnerError.timedOut)) }
            return (continuation, .success(ProcessResult(exitCode: exitCode, stdout: state.stdout, stderr: state.stderr)))
        }
        if let (continuation, result) = outcome {
            continuation.resume(with: result)
        }
    }

    private static func takeLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            lines.append(String(decoding: line, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }
}
