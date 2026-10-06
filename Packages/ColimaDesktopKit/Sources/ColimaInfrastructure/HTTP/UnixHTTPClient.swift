import ColimaDomain
import Foundation

/// A streaming response: the head plus the decoded body as it arrives.
public struct HTTPStreamingResponse: Sendable {
    /// Status line and headers.
    public var head: HTTPResponseHead
    /// Body bytes after transfer decoding. Finishes at the end of the response.
    public var body: AsyncThrowingStream<[UInt8], Error>
}

/// A connection taken over after `101 Switching Protocols`.
public struct HijackedConnection: Sendable {
    /// Status line and headers of the upgrade response.
    public var head: HTTPResponseHead
    /// The raw connection; use it to send.
    public var connection: any ByteStreamConnection
    /// Bytes that arrived together with the response head.
    public var initialBytes: [UInt8]
}

/// Minimal HTTP/1.1 client. One connection per request, as the Docker CLI does for streams.
public struct UnixHTTPClient: Sendable {
    private let transport: any ByteStreamTransport

    /// Creates a client.
    public init(transport: any ByteStreamTransport) {
        self.transport = transport
    }

    /// Sends a request and buffers the whole response body.
    public func send(_ request: HTTPRequest, maxBodyBytes: Int = 32 * 1024 * 1024) async throws -> HTTPResponse {
        let connection = try await transport.connect()
        defer { connection.close() }
        try await connection.send(request.encoded())

        var parser = HTTPResponseParser(requestMethod: request.method)
        var head: HTTPResponseHead?
        var body: [UInt8] = []
        while true {
            let chunk = try await connection.receive()
            let events = try chunk.map { try parser.feed($0) } ?? parser.finish()
            for event in events {
                switch event {
                case .head(let value):
                    head = value
                case .body(let bytes):
                    body.append(contentsOf: bytes)
                    if body.count > maxBodyBytes { throw DockerError.invalidResponse("response body too large") }
                case .end:
                    guard let head else { throw DockerError.invalidResponse("missing response head") }
                    return HTTPResponse(head: head, body: body)
                }
            }
            if chunk == nil { throw DockerError.connectionClosed }
        }
    }

    /// Sends a request and returns once the head arrived; the body streams afterwards.
    /// Cancelling the consumer of `body` closes the connection.
    public func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        let connection = try await transport.connect()
        do {
            try await connection.send(request.encoded())
            var parser = HTTPResponseParser(requestMethod: request.method)
            var pending: [[UInt8]] = []
            var ended = false
            var head: HTTPResponseHead?
            while head == nil {
                let chunk = try await connection.receive()
                let events = try chunk.map { try parser.feed($0) } ?? parser.finish()
                for event in events {
                    switch event {
                    case .head(let value): head = value
                    case .body(let bytes): pending.append(bytes)
                    case .end: ended = true
                    }
                }
                if chunk == nil, head == nil { throw DockerError.connectionClosed }
            }
            guard let head else { throw DockerError.connectionClosed }
            let parserState = parser
            let initial = pending
            let alreadyEnded = ended
            let body = AsyncThrowingStream<[UInt8], Error> { continuation in
                let task = Task {
                    var parser = parserState
                    for bytes in initial { continuation.yield(bytes) }
                    if alreadyEnded {
                        continuation.finish()
                        connection.close()
                        return
                    }
                    do {
                        reading: while true {
                            let chunk = try await connection.receive()
                            let events = try chunk.map { try parser.feed($0) } ?? parser.finish()
                            for event in events {
                                switch event {
                                case .head: break
                                case .body(let bytes): continuation.yield(bytes)
                                case .end: break reading
                                }
                            }
                            if chunk == nil { break }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                    }
                    connection.close()
                }
                continuation.onTermination = { _ in
                    task.cancel()
                    connection.close()
                }
            }
            return HTTPStreamingResponse(head: head, body: body)
        } catch {
            connection.close()
            throw error
        }
    }

    /// Sends an upgrade request (`Connection: Upgrade`, `Upgrade: tcp`) and hands over the raw connection.
    ///
    /// Docker answers `101 UPGRADED` and then streams raw bytes in both directions.
    /// On any other status the body is read and thrown as `DockerError.api`.
    public func upgrade(_ request: HTTPRequest) async throws -> HijackedConnection {
        var request = request
        request.headers.add("Connection", "Upgrade")
        request.headers.add("Upgrade", "tcp")
        let connection = try await transport.connect()
        do {
            try await connection.send(request.encoded())
            var parser = HTTPResponseParser(requestMethod: request.method)
            var initial: [UInt8] = []
            var head: HTTPResponseHead?
            var errorBody: [UInt8] = []
            var ended = false
            while !ended {
                let chunk = try await connection.receive()
                let events = try chunk.map { try parser.feed($0) } ?? parser.finish()
                for event in events {
                    switch event {
                    case .head(let value): head = value
                    case .body(let bytes): if head?.status == 101 { initial += bytes } else { errorBody += bytes }
                    case .end: ended = true
                    }
                }
                if let head, head.status == 101 || head.status == 200 { break }
                if chunk == nil { break }
            }
            guard let head else { throw DockerError.connectionClosed }
            guard head.status == 101 || head.status == 200 else {
                throw DockerError.api(status: head.status, message: DockerErrorBody.message(from: errorBody))
            }
            if head.status == 200 { initial = errorBody }
            return HijackedConnection(head: head, connection: connection, initialBytes: initial)
        } catch {
            connection.close()
            throw error
        }
    }
}

/// Decodes Docker's `{"message": "..."}` error bodies.
enum DockerErrorBody {
    private struct Body: Decodable { let message: String }

    static func message(from bytes: [UInt8]) -> String {
        if let body = try? JSONDecoder().decode(Body.self, from: Data(bytes)) { return body.message }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
