import ColimaDomain
import Foundation
import Testing
@testable import ColimaInfrastructure

@Suite("Docker API mapping")
struct DockerAPIMappingTests {
    @Test("Container list from a real engine")
    func containerList() throws {
        let summaries = try DockerJSON.decode([DockerAPI.ContainerSummary].self, from: Array(Fixture.data("containers.json")), endpoint: "test")
        let containers = summaries.map(\.domain)
        #expect(!containers.isEmpty)
        let redis = try #require(containers.first { $0.name == "redis-cache-1" })
        #expect(redis.state == .running)
        #expect(redis.composeProject == "redis")
        #expect(redis.composeService == "cache")
        #expect(redis.ports == [PublishedPort(privatePort: 6379, publicPort: 6379, proto: "tcp")])
        #expect(redis.statusText.hasPrefix("Up"))
        #expect(!containers.contains { $0.name.hasPrefix("/") })
    }

    @Test("Inspect from a real engine")
    func inspect() throws {
        let details = try DockerJSON.decode(DockerAPI.ContainerInspect.self, from: Array(Fixture.data("container-inspect.json")), endpoint: "test").domain
        #expect(details.name == "redis-cache-1")
        #expect(!details.tty)
        #expect(details.state == .running)
        #expect(details.startedAt != nil)
        #expect(details.finishedAt == nil)
        #expect(!details.command.isEmpty)
    }

    @Test("System df from a real engine")
    func systemDF() throws {
        let summary = try DockerJSON.decode(DockerAPI.SystemDF.self, from: Array(Fixture.data("system-df.json")), endpoint: "test").domain
        #expect(summary.images.count > 0)
        #expect(summary.images.sizeBytes > 0)
        #expect(summary.containers.count > 0)
        #expect(summary.containers.active <= summary.containers.count)
    }

    @Test("Info and version from a real engine")
    func infoAndVersion() throws {
        let info = try DockerJSON.decode(DockerAPI.Info.self, from: Array(Fixture.data("info.json")), endpoint: "test")
        let version = try DockerJSON.decode(DockerAPI.Version.self, from: Array(Fixture.data("version.json")), endpoint: "test")
        #expect(info.nCPU == 4)
        #expect(info.serverVersion == "29.5.2")
        #expect(info.operatingSystem?.isEmpty == false)
        #expect(version.apiVersion == "1.54")
        #expect(version.minAPIVersion == "1.40")
    }

    @Test("API versions compare numerically")
    func apiVersionOrdering() {
        #expect(DockerAPIVersion("1.9")! < DockerAPIVersion("1.44")!)
        #expect(DockerAPIVersion("2.0")! > DockerAPIVersion("1.54")!)
        #expect(DockerAPIVersion("x") == nil)
    }
}

@Suite("DockerEngineClient")
struct DockerEngineClientTests {
    private func json(_ status: String, _ body: String) -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    @Test("Lists all containers at the pinned API version")
    func listRequest() async throws {
        let transport = InMemoryTransport()
        transport.enqueue(json("200 OK", try Fixture.text("containers.json")))
        let containers = try await DockerEngineClient(transport: transport).containers()
        #expect(!containers.isEmpty)
        #expect(transport.requestLines == ["GET /v1.44/containers/json?all=1 HTTP/1.1"])
        #expect(transport.connections.allSatisfy { $0.isClosed })
    }

    @Test("Error bodies become DockerError.api with the engine message")
    func errorMapping() async {
        let transport = InMemoryTransport()
        transport.enqueue(json("404 Not Found", #"{"message":"No such container: abc"}"#))
        await #expect(throws: DockerError.api(status: 404, message: "No such container: abc")) {
            _ = try await DockerEngineClient(transport: transport).inspect(containerID: "abc")
        }
    }

    @Test("304 on start counts as success")
    func notModified() async throws {
        let transport = InMemoryTransport()
        transport.enqueue("HTTP/1.1 304 Not Modified\r\n\r\n")
        try await DockerEngineClient(transport: transport).perform(.start, containerID: "abc")
        #expect(transport.requestLines == ["POST /v1.44/containers/abc/start HTTP/1.1"])
    }

    @Test("Remove deletes the container without force or volumes")
    func remove() async throws {
        let transport = InMemoryTransport()
        transport.enqueue("HTTP/1.1 204 No Content\r\n\r\n")
        try await DockerEngineClient(transport: transport).perform(.remove, containerID: "abc")
        #expect(transport.requestLines == ["DELETE /v1.44/containers/abc HTTP/1.1"])
    }

    @Test("Removing a running container reports the engine conflict")
    func removeRunning() async {
        let message = "cannot remove container: container is running: stop the container before removing or force remove"
        let transport = InMemoryTransport()
        transport.enqueue(json("409 Conflict", #"{"message":"\#(message)"}"#))
        await #expect(throws: DockerError.api(status: 409, message: message)) {
            try await DockerEngineClient(transport: transport).perform(.remove, containerID: "abc")
        }
    }

    @Test("Engines older than the pinned API are rejected")
    func tooOld() async {
        let transport = InMemoryTransport()
        transport.enqueue(json("200 OK", #"{"ApiVersion":"1.41","MinAPIVersion":"1.12"}"#))
        await #expect(throws: DockerError.self) { try await DockerEngineClient(transport: transport).verifyCompatibility() }
    }

    @Test("A newer minimum API version is adopted")
    func newerMinimum() async throws {
        let transport = InMemoryTransport()
        transport.enqueue(json("200 OK", #"{"ApiVersion":"1.60","MinAPIVersion":"1.50"}"#))
        transport.enqueue(json("200 OK", "[]"))
        let client = DockerEngineClient(transport: transport)
        try await client.verifyCompatibility()
        _ = try await client.containers()
        #expect(transport.requestLines.last == "GET /v1.50/containers/json?all=1 HTTP/1.1")
    }

    @Test("Follow logs decode chunked multiplexed frames into lines")
    func followLogs() async throws {
        let transport = InMemoryTransport()
        let head = Array("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        let frames = try Array(Fixture.data("logs-multiplexed.bin"))
        let body = Splits.chunked(frames, chunkSize: 50)
        let connection = transport.enqueue([head] + Splits.variants(of: body, seeds: [11])[2], keepOpen: true)

        let client = DockerEngineClient(transport: transport)
        var lines: [LogLine] = []
        for try await batch in client.logs(containerID: "abc", options: LogOptions(follow: true, tail: 5)) {
            lines += batch
        }
        #expect(lines.count == 2) // the fixture holds two log lines
        #expect(lines.first?.text.contains("Starting Redis Server") == true)
        #expect(lines.allSatisfy { $0.timestamp != nil })
        #expect(transport.requestLines == ["GET /v1.44/containers/abc/logs?follow=1&stdout=1&stderr=1&timestamps=1&tail=5 HTTP/1.1"])
        #expect(connection.isClosed)
    }

    @Test("Cancelling a log stream closes the connection")
    func cancelLogs() async throws {
        let transport = InMemoryTransport()
        let connection = transport.enqueue(
            [Array("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\n\r\nfirst line\n".utf8)],
            keepOpen: true
        )
        let client = DockerEngineClient(transport: transport)
        let task = Task {
            var count = 0
            for try await batch in client.logs(containerID: "abc", options: LogOptions()) { count += batch.count }
            return count
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(connection.isClosed)
    }

    @Test("Exec creates, hijacks, streams output and sends input")
    func exec() async throws {
        let transport = InMemoryTransport()
        transport.enqueue(json("201 Created", #"{"Id":"exec123"}"#))
        let hijack = transport.enqueue(
            [Array("HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.raw-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n# ".utf8)],
            keepOpen: true
        )
        transport.enqueue("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        transport.enqueue(json("200 OK", #"{"Running":false,"ExitCode":130}"#))

        let client = DockerEngineClient(transport: transport)
        let session = try await client.exec(containerID: "abc", command: ["sh"], size: TerminalSize(columns: 80, rows: 24))
        var iterator = session.output.makeAsyncIterator()
        #expect(try await iterator.next() == Array("# ".utf8))

        try await session.write(Array("ls\r".utf8))
        let sent = String(decoding: hijack.sentBytes, as: UTF8.self)
        #expect(sent.contains("Upgrade: tcp\r\n"))
        #expect(sent.contains(#""ConsoleSize":[24,80]"#))
        #expect(sent.hasSuffix("ls\r"))

        hijack.push(Array("bin\r\n".utf8))
        #expect(try await iterator.next() == Array("bin\r\n".utf8))

        try await session.resize(TerminalSize(columns: 120, rows: 40))
        hijack.close()
        #expect(try await iterator.next() == nil)
        #expect(try await session.exitCode() == 130)

        let createBody = String(decoding: transport.connections[0].sentBytes, as: UTF8.self)
        #expect(createBody.contains(#""Tty":true"#))
        #expect(transport.requestLines == [
            "POST /v1.44/containers/abc/exec HTTP/1.1",
            "POST /v1.44/exec/exec123/start HTTP/1.1",
            "POST /v1.44/exec/exec123/resize?h=40&w=120 HTTP/1.1",
            "GET /v1.44/exec/exec123/json HTTP/1.1",
        ])
    }

    @Test("Exec on a stopped container reports the engine error")
    func execConflict() async {
        let transport = InMemoryTransport()
        transport.enqueue(json("409 Conflict", #"{"message":"container abc is not running"}"#))
        await #expect(throws: DockerError.api(status: 409, message: "container abc is not running")) {
            _ = try await DockerEngineClient(transport: transport).exec(containerID: "abc", command: ["sh"], size: TerminalSize(columns: 80, rows: 24))
        }
    }

    @Test("Events stream yields container events")
    func events() async throws {
        let transport = InMemoryTransport()
        let lines = #"{"Type":"container","Action":"start","Actor":{"ID":"abc","Attributes":{}}}"# + "\n"
            + #"{"Type":"container","Action":"die","Actor":{"ID":"def"}}"# + "\n"
        transport.enqueue([Array("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n".utf8) + Splits.chunked(Array(lines.utf8), chunkSize: 9)])
        var events: [DockerEvent] = []
        for try await event in DockerEngineClient(transport: transport).events() { events.append(event) }
        #expect(events == [DockerEvent(type: "container", action: "start", actorID: "abc"), DockerEvent(type: "container", action: "die", actorID: "def")])
        #expect(transport.requestLines.first?.hasPrefix("GET /v1.44/events?filters=%7B%22type%22") == true)
    }

    @Test("Missing socket file is reported as unavailable")
    func missingSocket() async {
        await #expect(throws: DockerError.self) {
            _ = try await DockerEngineClient(socketPath: "/nonexistent/docker.sock").containers()
        }
    }
}
