import ColimaDomain
import Foundation
import Synchronization

/// Engine API version as `major.minor`.
public struct DockerAPIVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int

    /// Creates a version.
    public init(_ major: Int, _ minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Parses `1.44`.
    public init?(_ text: String) {
        let parts = text.split(separator: ".")
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        self.init(major, minor)
    }

    public var description: String { "\(major).\(minor)" }

    public static func < (lhs: DockerAPIVersion, rhs: DockerAPIVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

/// Docker Engine API client over a unix socket.
public final class DockerEngineClient: DockerEngine {
    /// API version this app is written against. Accepted by Docker 25 through 29.
    public static let pinnedVersion = DockerAPIVersion(1, 44)

    private let http: UnixHTTPClient
    private let apiVersion = Mutex(DockerEngineClient.pinnedVersion)

    /// Creates a client for a socket path.
    public convenience init(socketPath: String) {
        self.init(transport: NWUnixTransport(socketPath: socketPath))
    }

    /// Creates a client over any transport (tests use an in-memory one).
    public init(transport: any ByteStreamTransport) {
        http = UnixHTTPClient(transport: transport)
    }

    private func path(_ suffix: String) -> String {
        "/v\(apiVersion.withLock { $0 })\(suffix)"
    }

    // MARK: Queries

    public func verifyCompatibility() async throws {
        let version = try await getJSON(DockerAPI.Version.self, "/version", versioned: false)
        let maximum = version.apiVersion.flatMap(DockerAPIVersion.init) ?? Self.pinnedVersion
        let minimum = version.minAPIVersion.flatMap(DockerAPIVersion.init) ?? Self.pinnedVersion
        guard maximum >= Self.pinnedVersion else {
            throw DockerError.unsupportedEngine("API \(maximum) is older than the required \(Self.pinnedVersion)")
        }
        // A future engine may drop 1.44; use its minimum and rely on tolerant decoding.
        apiVersion.withLock { $0 = max(Self.pinnedVersion, minimum) }
    }

    public func summary() async throws -> EngineSummary {
        async let versionResponse = getJSON(DockerAPI.Version.self, "/version", versioned: false)
        async let infoResponse = getJSON(DockerAPI.Info.self, "/info")
        let (version, info) = try await (versionResponse, infoResponse)
        return EngineSummary(
            serverVersion: info.serverVersion ?? version.version ?? "",
            apiVersion: version.apiVersion ?? "",
            operatingSystem: info.operatingSystem ?? "",
            kernelVersion: info.kernelVersion ?? "",
            architecture: info.architecture ?? "",
            cpuCount: info.nCPU ?? 0,
            memoryTotalBytes: info.memTotal ?? 0,
            containersTotal: info.containers ?? 0,
            containersRunning: info.containersRunning ?? 0,
            containersPaused: info.containersPaused ?? 0,
            containersStopped: info.containersStopped ?? 0,
            images: info.images ?? 0,
            storageDriver: info.driver ?? ""
        )
    }

    public func diskUsage() async throws -> DiskUsageSummary {
        try await getJSON(DockerAPI.SystemDF.self, "/system/df").domain
    }

    public func containers() async throws -> [Container] {
        try await getJSON([DockerAPI.ContainerSummary].self, "/containers/json?all=1").map(\.domain)
    }

    public func inspect(containerID: String) async throws -> ContainerDetails {
        try await getJSON(DockerAPI.ContainerInspect.self, "/containers/\(escape(containerID))/json").domain
    }

    public func searchImages(term: String, limit: Int) async throws -> [ImageSearchResult] {
        let response = try await http.send(HTTPRequest(method: "GET", target: path("/images/search?term=\(queryValue(term))&limit=\(limit)")))
        try check(response, allowed: [200])
        // Plain decoder: these keys are snake_case.
        return try JSONDecoder().decode([DockerAPI.SearchResult].self, from: Data(response.body)).compactMap(\.domain)
    }

    // MARK: Actions

    public func perform(_ action: ContainerAction, containerID: String) async throws {
        let container = "/containers/\(escape(containerID))"
        let request = switch action {
        case .start: HTTPRequest(method: "POST", target: path("\(container)/start"))
        case .stop: HTTPRequest(method: "POST", target: path("\(container)/stop"))
        case .restart: HTTPRequest(method: "POST", target: path("\(container)/restart"))
        // Without `force`, the engine refuses (409) to delete a running container.
        case .remove: HTTPRequest(method: "DELETE", target: path(container))
        }
        let response = try await http.send(request)
        // 304: already started / stopped.
        try check(response, allowed: [200, 204, 304])
    }

    public func createContainer(_ spec: ContainerSpec) async throws -> CreatedContainer {
        let query = spec.name.map { "?name=\(queryValue($0))" } ?? ""
        let response = try await postJSON("/containers/create\(query)", body: DockerAPI.ContainerCreateBody(spec))
        try check(response, allowed: [201])
        let created = try DockerJSON.decode(DockerAPI.ContainerCreateResponse.self, from: response.body, endpoint: "container create")
        return CreatedContainer(id: created.id, warnings: created.warnings ?? [])
    }

    // MARK: Streams

    public func pullImage(_ reference: ImageReference) -> AsyncThrowingStream<PullMessage, Error> {
        let parameters = reference.pullParameters
        let target = path("/images/create?fromImage=\(queryValue(parameters.fromImage))&tag=\(queryValue(parameters.tag))")
        let request = HTTPRequest(method: "POST", target: target)
        let http = http

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await http.stream(request)
                    guard response.head.status == 200 else {
                        var body: [UInt8] = []
                        for try await bytes in response.body { body += bytes }
                        throw DockerError.api(status: response.head.status, message: DockerErrorBody.message(from: body))
                    }
                    var decoder = PullMessageDecoder()
                    // An error arrives as a message once the pull has started.
                    func deliver(_ messages: [PullMessage]) throws {
                        for message in messages {
                            if let error = message.error { throw DockerError.pullFailed(error) }
                            continuation.yield(message)
                        }
                    }
                    for try await bytes in response.body {
                        try deliver(decoder.feed(bytes))
                    }
                    try deliver(decoder.flush())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Closing the connection cancels the pull in the engine.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func logs(containerID: String, options: LogOptions) -> AsyncThrowingStream<[LogLine], Error> {
        var query = "follow=\(options.follow ? 1 : 0)&stdout=1&stderr=1&timestamps=1"
        query += "&tail=\(options.tail.map(String.init) ?? "all")"
        if let since = options.since {
            query += "&since=" + String(format: "%.9f", since.timeIntervalSince1970)
        }
        let request = HTTPRequest(method: "GET", target: path("/containers/\(escape(containerID))/logs?\(query)"))
        let http = http

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await http.stream(request)
                    guard response.head.status == 200 else {
                        var body: [UInt8] = []
                        for try await bytes in response.body { body += bytes }
                        throw DockerError.api(status: response.head.status, message: DockerErrorBody.message(from: body))
                    }
                    let multiplexed = try await self.isMultiplexed(response.head, containerID: containerID)
                    var demuxer = MultiplexedStreamDemuxer()
                    var assembler = LogLineAssembler(parsesTimestamps: true)
                    for try await bytes in response.body {
                        var lines: [LogLine] = []
                        if multiplexed {
                            for frame in try demuxer.feed(bytes) {
                                lines += assembler.feed(frame.payload, stream: frame.stream)
                            }
                        } else {
                            lines = assembler.feed(bytes, stream: .stdout)
                        }
                        if !lines.isEmpty { continuation.yield(lines) }
                    }
                    let rest = assembler.flush()
                    if !rest.isEmpty { continuation.yield(rest) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func events() -> AsyncThrowingStream<DockerEvent, Error> {
        let filters = #"{"type":["container"]}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let request = HTTPRequest(method: "GET", target: path("/events?filters=\(filters)"))
        let http = http

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await http.stream(request)
                    guard response.head.status == 200 else {
                        throw DockerError.api(status: response.head.status, message: response.head.reason)
                    }
                    var buffer: [UInt8] = []
                    let decoder = DockerJSON.decoder
                    for try await bytes in response.body {
                        buffer += bytes
                        while let newline = buffer.firstIndex(of: 10) {
                            let line = Array(buffer[..<newline])
                            buffer.removeSubrange(...newline)
                            guard let event = try? decoder.decode(DockerAPI.Event.self, from: Data(line)) else { continue }
                            continuation.yield(DockerEvent(type: event.type ?? "", action: event.action ?? "", actorID: event.actor?.iD ?? ""))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func exec(containerID: String, command: [String], size: TerminalSize) async throws -> any ExecSession {
        struct CreateBody: Encodable {
            let AttachStdin = true
            let AttachStdout = true
            let AttachStderr = true
            let Tty = true
            let Cmd: [String]
            let Env = ["TERM=xterm-256color", "COLORTERM=truecolor"]
            let ConsoleSize: [Int]
        }
        struct StartBody: Encodable {
            let Detach = false
            let Tty = true
            let ConsoleSize: [Int]
        }
        let consoleSize = [max(size.rows, 1), max(size.columns, 1)]
        let create = try await postJSON(
            "/containers/\(escape(containerID))/exec",
            body: CreateBody(Cmd: command, ConsoleSize: consoleSize)
        )
        try check(create, allowed: [201])
        let execID = try DockerJSON.decode(DockerAPI.ExecCreated.self, from: create.body, endpoint: "exec create").id

        let startBody = try JSONEncoder().encode(StartBody(ConsoleSize: consoleSize))
        let hijacked = try await http.upgrade(HTTPRequest(
            method: "POST",
            target: path("/exec/\(escape(execID))/start"),
            headers: ["Content-Type": "application/json"],
            body: Array(startBody)
        ))
        return DockerExecSession(execID: execID, hijacked: hijacked, engine: self)
    }

    // MARK: Exec helpers used by DockerExecSession

    func resizeExec(_ execID: String, size: TerminalSize) async throws {
        let response = try await http.send(HTTPRequest(
            method: "POST",
            target: path("/exec/\(escape(execID))/resize?h=\(max(size.rows, 1))&w=\(max(size.columns, 1))")
        ))
        try check(response, allowed: [200, 201])
    }

    func inspectExec(_ execID: String) async throws -> (running: Bool, exitCode: Int?) {
        let exec = try await getJSON(DockerAPI.ExecInspect.self, "/exec/\(escape(execID))/json")
        return (exec.running ?? false, exec.exitCode)
    }

    // MARK: Plumbing

    private func getJSON<T: Decodable>(_ type: T.Type, _ suffix: String, versioned: Bool = true) async throws -> T {
        let target = versioned ? path(suffix) : suffix
        let response = try await http.send(HTTPRequest(method: "GET", target: target))
        try check(response, allowed: [200])
        return try DockerJSON.decode(type, from: response.body, endpoint: suffix)
    }

    private func postJSON<Body: Encodable>(_ suffix: String, body: Body) async throws -> HTTPResponse {
        let bytes = try JSONEncoder().encode(body)
        return try await http.send(HTTPRequest(
            method: "POST",
            target: path(suffix),
            headers: ["Content-Type": "application/json"],
            body: Array(bytes)
        ))
    }

    private func check(_ response: HTTPResponse, allowed: Set<Int>) throws {
        guard allowed.contains(response.head.status) else {
            throw DockerError.api(status: response.head.status, message: DockerErrorBody.message(from: response.body))
        }
    }

    private func isMultiplexed(_ head: HTTPResponseHead, containerID: String) async throws -> Bool {
        let contentType = head.headers["Content-Type"] ?? ""
        if contentType.contains("multiplexed-stream") { return true }
        if contentType.contains("raw-stream") { return false }
        // Engines before API 1.42 send no stream content type; TTY containers are not multiplexed.
        return try await !inspect(containerID: containerID).tty
    }

    /// Percent-encodes a query value; `+`, `&` and `=` must not reach the engine raw.
    private func queryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/:@"))) ?? value
    }

    private func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? component
    }
}
