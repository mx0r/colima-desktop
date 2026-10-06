import ColimaDomain
import Foundation
import Synchronization
import Testing
@testable import ColimaInfrastructure

/// Records invocations and returns canned results.
final class FakeProcessRunner: ProcessRunning {
    struct Call: Sendable {
        var executable: URL
        var arguments: [String]
    }

    private let calls = Mutex<[Call]>([])
    private let respond: @Sendable ([String], (@Sendable (String) -> Void)?) throws -> ProcessResult

    init(respond: @escaping @Sendable ([String], (@Sendable (String) -> Void)?) throws -> ProcessResult) {
        self.respond = respond
    }

    var recordedCalls: [Call] { calls.withLock { $0 } }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration?,
        onStderrLine: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        calls.withLock { $0.append(Call(executable: executable, arguments: arguments)) }
        return try respond(arguments, onStderrLine)
    }
}

private func result(_ stdout: String = "", stderr: String = "", exit: Int32 = 0) -> ProcessResult {
    ProcessResult(exitCode: exit, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
}

@Suite("Colima output parsing")
struct ColimaOutputParserTests {
    @Test("List of one profile from a real colima")
    func listSingle() throws {
        let instances = try ColimaOutputParser.parseList(Fixture.text("colima-list.ndjson"))
        #expect(instances.count == 1)
        let instance = try #require(instances.first)
        #expect(instance.profile == .default)
        #expect(instance.status == .running)
        #expect(instance.cpus == 4)
        #expect(instance.memoryBytes == 8_589_934_592)
        #expect(instance.runtime == "docker")
    }

    @Test("List is newline-delimited JSON, one object per profile")
    func listMultiple() throws {
        let instances = try ColimaOutputParser.parseList(Fixture.text("colima-list-two-profiles.ndjson"))
        #expect(instances.map(\.profile.rawValue) == ["default", "work"])
        #expect(instances[1].status == .stopped)
        #expect(instances[1].address == "192.168.106.2")
    }

    @Test("Empty list output yields no profiles")
    func listEmpty() throws {
        #expect(try ColimaOutputParser.parseList("").isEmpty)
    }

    @Test("Broken list line reports the line")
    func listBroken() {
        #expect {
            _ = try ColimaOutputParser.parseList("{\"name\": 1}")
        } throws: { error in
            guard case ColimaError.invalidOutput(_, let detail) = error else { return false }
            return detail.contains("{\"name\": 1}")
        }
    }

    @Test("Status uses snake_case keys and strips the unix:// scheme")
    func status() throws {
        let details = try ColimaOutputParser.parseStatus(Fixture.text("colima-status.json"))
        #expect(details.driver == "macOS Virtualization.Framework")
        #expect(details.mountType == "virtiofs")
        #expect(details.dockerSocketPath?.hasSuffix("/.colima/default/docker.sock") == true)
        #expect(details.dockerSocketPath?.hasPrefix("unix://") == false)
        #expect(details.cpus == 4)
        #expect(!details.kubernetes)
    }

    @Test("Not-running stderr is recognized")
    func notRunning() throws {
        #expect(ColimaOutputParser.isNotRunning(stderr: try Fixture.text("colima-status-not-running.stderr.txt")))
    }

    @Test("Logrus messages are extracted", arguments: [
        (#"time="2026-10-06T09:47:26+02:00" level=info msg="starting colima""#, "starting colima"),
        (#"level=info msg="say \"hi\"" extra=1"#, #"say "hi""#),
        ("level=info msg=bare other=x", "bare"),
        ("  plain text  ", "plain text"),
    ])
    func logMessage(line: String, expected: String) {
        #expect(ColimaOutputParser.logMessage(line) == expected)
    }

    @Test("Error message prefers the last fatal line")
    func errorMessage() {
        let stderr = """
        time="x" level=info msg="starting"
        time="x" level=fatal msg="error starting vm: boom"
        exit status 1
        """
        #expect(ColimaOutputParser.errorMessage(fromStderr: stderr) == "error starting vm: boom")
    }

    @Test("Version line is parsed")
    func version() {
        #expect(ColimaOutputParser.parseVersion("colima version 0.10.3\ngit commit: abc\n") == "0.10.3")
        #expect(ColimaOutputParser.parseVersion("garbage") == nil)
    }

    @Test("VM usage probe output from a real VM")
    func usage() throws {
        let usage = try VMUsageProbe.parse(Fixture.text("vm-usage-probe.txt"))
        #expect(usage.cpuCount == 4)
        #expect(usage.memoryTotalBytes == 8_112_412 * 1024)
        #expect(usage.memoryAvailableBytes == 7_400_984 * 1024)
        #expect(usage.memoryUsedBytes == (8_112_412 - 7_400_984) * 1024)
        #expect(usage.disks.map(\.mountPoint) == ["/", "/var/lib/docker"])
        #expect(usage.disks[1].totalBytes == 105_087_164_416)
    }

    @Test("Truncated probe output throws")
    func usageTruncated() {
        #expect(throws: ColimaError.self) { _ = try VMUsageProbe.parse("0.1 0.2 0.3 1/2 3\n@@\n") }
    }
}

@Suite("ColimaCLIClient")
struct ColimaCLIClientTests {
    private let colima = URL(filePath: "/opt/homebrew/bin/colima")

    @Test("Status of a stopped profile is nil, not an error")
    func statusNotRunning() async throws {
        let runner = FakeProcessRunner { _, _ in
            result(stderr: #"level=fatal msg="colima [profile=work] is not running""#, exit: 1)
        }
        let sut = ColimaCLIClient(executable: colima, environment: [:], runner: runner)
        #expect(try await sut.details(of: ProfileName("work")) == nil)
        #expect(runner.recordedCalls.first?.arguments == ["status", "--profile", "work", "--json"])
    }

    @Test("Operations pass the profile and report progress messages")
    func operationProgress() async throws {
        let runner = FakeProcessRunner { _, onLine in
            onLine?(#"time="x" level=info msg="starting colima""#)
            onLine?("")
            return result()
        }
        let messages = Mutex<[String]>([])
        let sut = ColimaCLIClient(executable: colima, environment: [:], runner: runner)
        try await sut.perform(.start, on: ProfileName("work")) { message in messages.withLock { $0.append(message) } }
        #expect(runner.recordedCalls.first?.arguments == ["start", "--profile", "work"])
        #expect(messages.withLock { $0 } == ["starting colima"])
    }

    @Test("Failed command surfaces the colima error message")
    func failure() async {
        let runner = FakeProcessRunner { _, _ in result(stderr: #"level=fatal msg="vm is broken""#, exit: 1) }
        let sut = ColimaCLIClient(executable: colima, environment: [:], runner: runner)
        await #expect(throws: ColimaError.commandFailed(command: "colima stop", exitCode: 1, message: "vm is broken")) {
            try await sut.perform(.stop, on: .default) { _ in }
        }
    }

    @Test("Missing executable throws executableNotFound without running anything")
    func missingExecutable() async {
        let runner = FakeProcessRunner { _, _ in result() }
        let sut = ColimaCLIClient(executable: nil, environment: [:], runner: runner)
        await #expect(throws: ColimaError.executableNotFound) { _ = try await sut.listInstances() }
        #expect(runner.recordedCalls.isEmpty)
    }

    @Test("Timeout maps to a colima error")
    func timeout() async {
        let runner = FakeProcessRunner { _, _ in throw ProcessRunnerError.timedOut }
        let sut = ColimaCLIClient(executable: colima, environment: [:], runner: runner)
        await #expect(throws: ColimaError.timedOut(command: "colima list")) { _ = try await sut.listInstances() }
    }

    @Test("Usage probe runs the script over ssh")
    func usageProbe() async throws {
        let runner = FakeProcessRunner { _, _ in result(try Fixture.text("vm-usage-probe.txt")) }
        let sut = ColimaCLIClient(executable: colima, environment: [:], runner: runner)
        let usage = try await sut.usage(of: .default)
        #expect(usage.cpuCount == 4)
        #expect(runner.recordedCalls.first?.arguments.prefix(5) == ["ssh", "--profile", "default", "--", "sh"])
    }
}
