import Foundation
import Synchronization
import Testing
@testable import ColimaInfrastructure

@Suite("FoundationProcessRunner")
struct ProcessRunnerTests {
    private let sh = URL(filePath: "/bin/sh")
    private let runner = FoundationProcessRunner()

    private func run(_ script: String, timeout: Duration? = .seconds(20), onStderrLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        try await runner.run(executable: sh, arguments: ["-c", script], environment: [:], timeout: timeout, onStderrLine: onStderrLine)
    }

    @Test("Large output on both pipes does not deadlock")
    func largeOutput() async throws {
        // Regression: waiting for exit before draining the pipes hangs above the ~64 KB pipe buffer.
        let result = try await run("head -c 2000000 /dev/zero; head -c 1500000 /dev/zero >&2")
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 2_000_000)
        #expect(result.stderr.count == 1_500_000)
    }

    @Test("Exit code and both streams are captured")
    func exitCode() async throws {
        let result = try await run("echo out; echo err >&2; exit 3")
        #expect(result.exitCode == 3)
        #expect(result.stdoutText == "out\n")
        #expect(result.stderrText == "err\n")
    }

    @Test("Arguments are passed literally, without a shell")
    func literalArguments() async throws {
        let printf = URL(filePath: "/usr/bin/printf")
        let result = try await runner.run(
            executable: printf, arguments: ["%s|", "$(whoami)", "a;b"], environment: [:], timeout: nil, onStderrLine: nil
        )
        #expect(result.stdoutText == "$(whoami)|a;b|")
    }

    @Test("Stderr lines are reported while running, including a trailing partial line")
    func stderrLines() async throws {
        let lines = Mutex<[String]>([])
        _ = try await run("printf 'one\\ntwo\\nthree' >&2") { line in lines.withLock { $0.append(line) } }
        #expect(lines.withLock { $0 } == ["one", "two", "three"])
    }

    @Test("Timeout terminates the process")
    func timeout() async throws {
        let start = ContinuousClock.now
        await #expect(throws: ProcessRunnerError.timedOut) {
            _ = try await run("sleep 30", timeout: .milliseconds(200))
        }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test("Cancellation terminates the process")
    func cancellation() async throws {
        let task = Task { try await run("sleep 30", timeout: nil) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let start = ContinuousClock.now
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test("A daemonized grandchild holding the pipe does not block completion")
    func grandchildHoldsPipe() async throws {
        let start = ContinuousClock.now
        let result = try await FoundationProcessRunner(eofGracePeriod: .milliseconds(300))
            .run(executable: sh, arguments: ["-c", "sleep 5 & echo done"], environment: [:], timeout: nil, onStderrLine: nil)
        #expect(result.stdoutText.hasPrefix("done"))
        #expect(ContinuousClock.now - start < .seconds(4))
    }

    @Test("Missing executable throws")
    func missingExecutable() async {
        await #expect(throws: (any Error).self) {
            _ = try await runner.run(
                executable: URL(filePath: "/nonexistent/colima"), arguments: [], environment: [:], timeout: nil, onStderrLine: nil
            )
        }
    }
}

@Suite("ExecutableLocator")
struct ExecutableLocatorTests {
    private func locator(existing: Set<String>, path: String = "/custom/bin:/usr/bin") -> ExecutableLocator {
        ExecutableLocator(pathVariable: path, homeDirectory: "/Users/test") { existing.contains($0) }
    }

    @Test("PATH entries win over fallback directories")
    func pathFirst() {
        let sut = locator(existing: ["/custom/bin/colima", "/opt/homebrew/bin/colima"])
        #expect(sut.locateColima(override: nil)?.path(percentEncoded: false) == "/custom/bin/colima")
    }

    @Test("Homebrew is searched when PATH is minimal")
    func homebrewFallback() {
        let sut = locator(existing: ["/opt/homebrew/bin/colima"], path: "/usr/bin:/bin")
        #expect(sut.locateColima(override: nil)?.path(percentEncoded: false) == "/opt/homebrew/bin/colima")
    }

    @Test("Override is used when executable, and only then")
    func override() {
        let sut = locator(existing: ["/Users/test/bin/colima", "/opt/homebrew/bin/colima"])
        #expect(sut.locateColima(override: "~/bin/colima")?.path(percentEncoded: false) == "/Users/test/bin/colima")
        #expect(sut.locateColima(override: "/missing/colima") == nil)
        #expect(sut.locateColima(override: "  ")?.path(percentEncoded: false) == "/opt/homebrew/bin/colima")
    }

    @Test("Returns nil when nothing is found")
    func notFound() {
        #expect(locator(existing: []).locateColima(override: nil) == nil)
    }

    @Test("Child PATH gets the executable directory and fallbacks prepended once")
    func childEnvironment() {
        let env = ChildEnvironment.make(
            base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/test"],
            executable: URL(filePath: "/custom/bin/colima"),
            colimaHome: "/c",
            limaHome: nil
        )
        let path = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(path.first == "/custom/bin")
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.filter { $0 == "/usr/bin" }.count == 1)
        #expect(env["COLIMA_HOME"] == "/c")
        #expect(env["LIMA_HOME"] == nil)
        #expect(env["HOME"] == "/Users/test")
    }
}
