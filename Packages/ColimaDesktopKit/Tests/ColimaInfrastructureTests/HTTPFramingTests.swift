import ColimaDomain
import Foundation
import Testing
@testable import ColimaInfrastructure

@Suite("HTTP response framing")
struct HTTPFramingTests {
    /// Feeds all chunks and returns (head, body, ended).
    private func parse(_ chunks: [[UInt8]], method: String = "GET", eof: Bool = true) throws -> (HTTPResponseHead?, [UInt8], Bool) {
        var parser = HTTPResponseParser(requestMethod: method)
        var head: HTTPResponseHead?
        var body: [UInt8] = []
        var ended = false
        var events: [HTTPResponseParser.Event] = []
        for chunk in chunks { events += try parser.feed(chunk) }
        if eof, !parser.isDone { events += try parser.finish() }
        for event in events {
            switch event {
            case .head(let value): head = value
            case .body(let bytes): body += bytes
            case .end: ended = true
            }
        }
        return (head, body, ended)
    }

    @Test("Content-Length body, any split")
    func contentLength() throws {
        let wire = Array("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\nhello world".utf8)
        for chunks in Splits.variants(of: wire) {
            let (head, body, ended) = try parse(chunks, eof: false)
            #expect(head?.status == 200)
            #expect(head?.headers["content-type"] == "application/json")
            #expect(String(decoding: body, as: UTF8.self) == "hello world")
            #expect(ended)
        }
    }

    @Test("Chunked body with extensions and trailers, any split")
    func chunked() throws {
        let payload = Array(String(repeating: "0123456789abcdef", count: 20).utf8)
        let wire = Array("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
            + Splits.chunked(payload, chunkSize: 13, extensions: true, trailer: true)
        for chunks in Splits.variants(of: wire) {
            let (_, body, ended) = try parse(chunks, eof: false)
            #expect(body == payload)
            #expect(ended)
        }
    }

    @Test("Real chunked list response from the engine")
    func chunkedRealPayload() throws {
        let json = try Array(Fixture.data("containers.json"))
        let wire = Array("HTTP/1.1 200 OK\r\nApi-Version: 1.54\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
            + Splits.chunked(json, chunkSize: 4096)
        let (_, body, _) = try parse(Splits.variants(of: wire, seeds: [7])[2], eof: false)
        #expect(body == json)
    }

    @Test("204 has no body even without Content-Length")
    func noContent() throws {
        let (head, body, ended) = try parse([Array("HTTP/1.1 204 No Content\r\n\r\n".utf8)], eof: false)
        #expect(head?.status == 204)
        #expect(body.isEmpty)
        #expect(ended)
    }

    @Test("Body without length or chunking runs until close")
    func untilClose() throws {
        let (_, body, ended) = try parse([Array("HTTP/1.1 200 OK\r\n\r\nabc".utf8), Array("def".utf8)])
        #expect(String(decoding: body, as: UTF8.self) == "abcdef")
        #expect(ended)
    }

    @Test("101 Switching Protocols passes the following bytes through raw")
    func upgrade() throws {
        let wire = Array("HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.raw-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n$ ls\r\n".utf8)
        for chunks in Splits.variants(of: wire) {
            let (head, body, _) = try parse(chunks, eof: false)
            #expect(head?.status == 101)
            #expect(String(decoding: body, as: UTF8.self) == "$ ls\r\n")
        }
    }

    @Test("100 Continue is skipped")
    func interimResponse() throws {
        let (head, body, _) = try parse([Array("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8)], eof: false)
        #expect(head?.status == 200)
        #expect(body == Array("ok".utf8))
    }

    @Test("Truncated responses throw at EOF")
    func truncated() {
        #expect(throws: DockerError.connectionClosed) {
            _ = try parse([Array("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc".utf8)])
        }
        #expect(throws: DockerError.connectionClosed) {
            _ = try parse([Array("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nab".utf8)])
        }
    }

    @Test("Garbage status line throws")
    func badStatusLine() {
        #expect(throws: DockerError.self) { _ = try parse([Array("NOPE\r\n\r\n".utf8)], eof: false) }
    }

    @Test("Request encoding adds Host and Content-Length")
    func requestEncoding() {
        let request = HTTPRequest(method: "POST", target: "/v1.44/x", headers: ["Content-Type": "application/json"], body: Array("{}".utf8))
        let text = String(decoding: request.encoded(), as: UTF8.self)
        #expect(text.hasPrefix("POST /v1.44/x HTTP/1.1\r\n"))
        #expect(text.contains("Host: docker\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{}"))
    }
}

@Suite("Log decoding")
struct LogDecodingTests {
    @Test("Real multiplexed log bytes decode identically for any split")
    func demuxRealFixture() throws {
        let bytes = try Array(Fixture.data("logs-multiplexed.bin"))
        var reference: [MultiplexedStreamDemuxer.Frame]?
        for chunks in Splits.variants(of: bytes) {
            var demuxer = MultiplexedStreamDemuxer()
            var frames: [MultiplexedStreamDemuxer.Frame] = []
            for chunk in chunks { frames += try demuxer.feed(chunk) }
            #expect(demuxer.pendingByteCount == 0)
            if let reference { #expect(frames == reference) } else { reference = frames }
        }
        let frames = try #require(reference)
        #expect(!frames.isEmpty)
        #expect(String(decoding: frames[0].payload, as: UTF8.self).contains("Starting Redis Server"))
    }

    @Test("Stderr frames are tagged as stderr")
    func demuxStderr() throws {
        var demuxer = MultiplexedStreamDemuxer()
        let frames = try demuxer.feed([2, 0, 0, 0, 0, 0, 0, 3] + Array("err".utf8) + [1, 0, 0, 0, 0, 0, 0, 2] + Array("ok".utf8))
        #expect(frames.map(\.stream) == [.stderr, .stdout])
    }

    @Test("Invalid stream byte throws")
    func demuxInvalid() {
        var demuxer = MultiplexedStreamDemuxer()
        #expect(throws: DockerError.self) { _ = try demuxer.feed([9, 0, 0, 0, 0, 0, 0, 0]) }
    }

    @Test("Lines are assembled across chunks, per stream, with CRLF stripped")
    func assembleLines() {
        var assembler = LogLineAssembler(parsesTimestamps: false)
        #expect(assembler.feed(Array("hel".utf8), stream: .stdout).isEmpty)
        #expect(assembler.feed(Array("oops\n".utf8), stream: .stderr).map(\.text) == ["oops"])
        let lines = assembler.feed(Array("lo\r\nwor".utf8), stream: .stdout)
        #expect(lines == [LogLine(stream: .stdout, timestamp: nil, text: "hello")])
        #expect(assembler.flush() == [LogLine(stream: .stdout, timestamp: nil, text: "wor")])
    }

    @Test("Timestamps are parsed and stripped")
    func assembleTimestamps() throws {
        var assembler = LogLineAssembler(parsesTimestamps: true)
        let lines = assembler.feed(Array("2026-10-06T06:49:28.909696474Z Starting Redis\n".utf8), stream: .stdout)
        let line = try #require(lines.first)
        #expect(line.text == "Starting Redis")
        let timestamp = try #require(line.timestamp)
        #expect(abs(timestamp.timeIntervalSince1970 - 1_791_269_368.909696474) < 0.000_01)
    }

    @Test("Overlong lines are split")
    func overlongLine() {
        var assembler = LogLineAssembler(parsesTimestamps: false, maxLineBytes: 4)
        #expect(assembler.feed(Array("abcdefghij\n".utf8), stream: .stdout).map(\.text) == ["abcd", "efgh", "ij"])
    }

    @Test("RFC 3339 variants", arguments: [
        ("1970-01-01T00:00:00Z", 0.0),
        ("2026-10-06T07:46:57Z", 1_791_272_817.0),
        ("2026-10-06T09:46:57+02:00", 1_791_272_817.0),
        ("2000-02-29T12:00:00.5Z", 951_825_600.5),
    ])
    func rfc3339(text: String, expected: Double) throws {
        let date = try #require(RFC3339.parse(Array(text.utf8)))
        #expect(abs(date.timeIntervalSince1970 - expected) < 0.000_1)
    }

    @Test("RFC 3339 rejects other formats", arguments: ["", "hello world", "2026-13-01T00:00:00Z", "2026-10-06 07:46:57Z", "2026-10-06T07:46:57"])
    func rfc3339Invalid(text: String) {
        #expect(RFC3339.parse(Array(text.utf8)) == nil)
    }
}
