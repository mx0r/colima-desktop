import ColimaDomain
import Foundation
import Observation

/// Drives one interactive shell in a container: connects, forwards input in order, debounces resizes.
@MainActor
@Observable
public final class TerminalSessionModel {
    /// Session state.
    public enum State: Hashable, Sendable {
        case idle
        case connecting
        case connected
        /// The process exited; the exit code when known.
        case exited(Int?)
        case failed(String)
    }

    /// Container ID.
    public let containerID: String
    /// Container name for the window title.
    public let containerName: String
    /// Current state.
    public private(set) var state = State.idle

    /// Receives terminal output on the main actor. Set by the view before `connect`.
    @ObservationIgnored public var onOutput: (([UInt8]) -> Void)?

    @ObservationIgnored private let engine: any DockerEngine
    @ObservationIgnored private let command: [String]
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var session: (any ExecSession)?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var writer: AsyncStream<[UInt8]>.Continuation?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var size = TerminalSize(columns: 80, rows: 24)

    /// Last size passed to `connect` or `resize`.
    public var lastSize: TerminalSize { size }

    /// Resize requests are coalesced over this interval.
    static let resizeDebounce = Duration.milliseconds(100)

    /// Creates a model.
    public init(
        containerID: String,
        containerName: String,
        engine: any DockerEngine,
        command: [String],
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.containerID = containerID
        self.containerName = containerName
        self.engine = engine
        self.command = command
        self.clock = clock
    }

    /// Starts the shell with the given terminal size.
    public func connect(size: TerminalSize) {
        guard state != .connecting, state != .connected else { return }
        self.size = size
        state = .connecting
        let engine = engine
        let containerID = containerID
        let command = command
        Task { [weak self] in
            do {
                let session = try await engine.exec(containerID: containerID, command: command, size: size)
                guard let self else {
                    await session.close()
                    return
                }
                self.attach(session)
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Sends keyboard input. Order is preserved.
    public func send(_ bytes: [UInt8]) {
        writer?.yield(bytes)
    }

    /// Reports a new terminal size; sent to the engine after a short debounce.
    public func resize(_ newSize: TerminalSize) {
        guard newSize != size, newSize.columns > 0, newSize.rows > 0 else { return }
        size = newSize
        guard let session else { return }
        resizeTask?.cancel()
        let clock = clock
        resizeTask = Task {
            do { try await clock.sleep(for: Self.resizeDebounce) } catch { return }
            try? await session.resize(newSize)
        }
    }

    /// Closes the connection.
    public func close() {
        readTask?.cancel()
        writeTask?.cancel()
        resizeTask?.cancel()
        writer?.finish()
        writer = nil
        if let session {
            Task { await session.close() }
        }
        session = nil
    }

    private func attach(_ session: any ExecSession) {
        self.session = session
        state = .connected

        let (inputs, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        writer = continuation
        writeTask = Task {
            for await bytes in inputs {
                try? await session.write(bytes)
            }
        }

        readTask = Task { [weak self] in
            do {
                for try await bytes in session.output {
                    self?.onOutput?(bytes)
                }
                let code = try? await session.exitCode()
                self?.finish(.exited(code))
            } catch is CancellationError {
                return
            } catch {
                self?.finish(.failed(error.localizedDescription))
            }
        }
    }

    private func finish(_ state: State) {
        writer?.finish()
        writer = nil
        session = nil
        self.state = state
    }
}
