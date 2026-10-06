import ColimaDomain
import Foundation

/// Controls Colima through its command line interface.
public struct ColimaCLIClient: ColimaControlling {
    /// Timeouts per command kind.
    public struct Timeouts: Sendable {
        /// `list`, `status`, `version`.
        public var query: Duration = .seconds(20)
        /// `ssh` usage probe.
        public var probe: Duration = .seconds(10)
        /// `start`, `stop`, `restart`. Starting a fresh VM downloads an image, so this is long.
        public var operation: Duration = .seconds(30 * 60)

        /// Default timeouts.
        public init() {}
    }

    private let executable: URL?
    private let environment: [String: String]
    private let runner: any ProcessRunning
    private let timeouts: Timeouts

    /// Creates a client.
    ///
    /// - Parameters:
    ///   - executable: colima path; nil makes every call throw `ColimaError.executableNotFound`.
    ///   - environment: Full environment for the child process (see `ChildEnvironment`).
    public init(executable: URL?, environment: [String: String], runner: any ProcessRunning, timeouts: Timeouts = Timeouts()) {
        self.executable = executable
        self.environment = environment
        self.runner = runner
        self.timeouts = timeouts
    }

    public func listInstances() async throws -> [ColimaInstance] {
        let result = try await run(["list", "--json"], timeout: timeouts.query)
        try check(result, command: "colima list")
        return try ColimaOutputParser.parseList(result.stdoutText)
    }

    public func details(of profile: ProfileName) async throws -> ColimaInstanceDetails? {
        let result = try await run(["status", "--profile", profile.rawValue, "--json"], timeout: timeouts.query)
        if result.exitCode != 0, ColimaOutputParser.isNotRunning(stderr: result.stderrText) {
            return nil
        }
        try check(result, command: "colima status")
        return try ColimaOutputParser.parseStatus(result.stdoutText)
    }

    public func perform(
        _ operation: VMOperation,
        on profile: ProfileName,
        progress: @escaping @Sendable (String) -> Void
    ) async throws {
        let verb = switch operation {
        case .start: "start"
        case .stop: "stop"
        case .restart: "restart"
        }
        let result = try await run([verb, "--profile", profile.rawValue], timeout: timeouts.operation) { line in
            if let message = ColimaOutputParser.logMessage(line) { progress(message) }
        }
        try check(result, command: "colima \(verb)")
    }

    public func usage(of profile: ProfileName) async throws -> VMUsage {
        let result = try await run(
            ["ssh", "--profile", profile.rawValue, "--", "sh", "-c", VMUsageProbe.script],
            timeout: timeouts.probe
        )
        try check(result, command: "colima ssh")
        return try VMUsageProbe.parse(result.stdoutText)
    }

    public func version() async throws -> String {
        let result = try await run(["version"], timeout: timeouts.query)
        try check(result, command: "colima version")
        guard let version = ColimaOutputParser.parseVersion(result.stdoutText) else {
            throw ColimaError.invalidOutput(command: "colima version", detail: result.stdoutText)
        }
        return version
    }

    private func run(
        _ arguments: [String],
        timeout: Duration,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        guard let executable else { throw ColimaError.executableNotFound }
        do {
            return try await runner.run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: timeout,
                onStderrLine: onStderrLine
            )
        } catch ProcessRunnerError.timedOut {
            throw ColimaError.timedOut(command: "colima " + (arguments.first ?? ""))
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoPermission {
            throw ColimaError.executableNotFound
        }
    }

    private func check(_ result: ProcessResult, command: String) throws {
        guard result.exitCode == 0 else {
            throw ColimaError.commandFailed(
                command: command,
                exitCode: result.exitCode,
                message: ColimaOutputParser.errorMessage(fromStderr: result.stderrText)
            )
        }
    }
}
