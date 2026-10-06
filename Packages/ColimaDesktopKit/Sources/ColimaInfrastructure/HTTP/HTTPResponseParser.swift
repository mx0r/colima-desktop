import ColimaDomain
import Foundation

/// Incremental HTTP/1.1 response parser. Feed bytes as they arrive; it emits head, body and end events.
///
/// Supports `Content-Length`, chunked transfer encoding, read-until-close bodies and
/// `101 Switching Protocols` (after which all bytes are passed through raw).
public struct HTTPResponseParser: Sendable {
    /// Parser output.
    public enum Event: Sendable, Hashable {
        case head(HTTPResponseHead)
        case body([UInt8])
        case end
    }

    private enum State: Sendable {
        case head
        case fixedLength(remaining: Int)
        case chunked(ChunkedDecoder)
        case untilClose
        case upgraded
        case done
    }

    /// Maximum size of the status line plus headers.
    static let maxHeadSize = 64 * 1024

    private var state = State.head
    private var buffer: [UInt8] = []
    private let requestMethod: String

    /// Creates a parser for the response to a request with the given method.
    public init(requestMethod: String = "GET") {
        self.requestMethod = requestMethod
    }

    /// Whether the response is complete.
    public var isDone: Bool {
        if case .done = state { return true }
        return false
    }

    /// Consumes bytes.
    public mutating func feed(_ bytes: [UInt8]) throws -> [Event] {
        var events: [Event] = []
        var input = bytes[...]
        while !input.isEmpty {
            switch state {
            case .head:
                buffer.append(contentsOf: input)
                input = []
                guard let end = Self.headTerminator(in: buffer) else {
                    if buffer.count > Self.maxHeadSize { throw DockerError.invalidResponse("response head too large") }
                    break
                }
                let head = try Self.parseHead(buffer[..<end])
                let rest = Array(buffer[(end + 4)...])
                buffer = []
                if (100..<200).contains(head.status), head.status != 101 {
                    // Interim response (e.g. 100 Continue): parse the next head.
                    input = rest[...]
                    continue
                }
                events.append(.head(head))
                state = bodyState(for: head)
                if case .done = state { events.append(.end) }
                input = rest[...]

            case .fixedLength(let remaining):
                let take = min(remaining, input.count)
                events.append(.body(Array(input.prefix(take))))
                input = input.dropFirst(take)
                if remaining - take == 0 {
                    state = .done
                    events.append(.end)
                } else {
                    state = .fixedLength(remaining: remaining - take)
                }

            case .chunked(var decoder):
                let (decoded, consumed) = try decoder.decode(input)
                if !decoded.isEmpty { events.append(.body(decoded)) }
                input = input.dropFirst(consumed)
                if decoder.isDone {
                    state = .done
                    events.append(.end)
                } else {
                    state = .chunked(decoder)
                }

            case .untilClose, .upgraded:
                events.append(.body(Array(input)))
                input = []

            case .done:
                // Trailing bytes after a complete response are ignored (one request per connection).
                input = []
            }
        }
        return events
    }

    /// Signals EOF. Throws when the response was cut short.
    public mutating func finish() throws -> [Event] {
        switch state {
        case .untilClose, .upgraded:
            state = .done
            return [.end]
        case .done:
            return []
        case .head, .fixedLength, .chunked:
            throw DockerError.connectionClosed
        }
    }

    private func bodyState(for head: HTTPResponseHead) -> State {
        if head.status == 101 { return .upgraded }
        if requestMethod == "HEAD" || head.status == 204 || head.status == 304 { return .done }
        if let encoding = head.headers["Transfer-Encoding"], encoding.lowercased().contains("chunked") {
            return .chunked(ChunkedDecoder())
        }
        if let lengthText = head.headers["Content-Length"], let length = Int(lengthText.trimmingCharacters(in: .whitespaces)) {
            return length == 0 ? .done : .fixedLength(remaining: length)
        }
        return .untilClose
    }

    private static func headTerminator(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4)
        where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index
        }
        return nil
    }

    private static func parseHead(_ bytes: ArraySlice<UInt8>) throws -> HTTPResponseHead {
        let text = String(decoding: bytes, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw DockerError.invalidResponse("empty response head") }
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else {
            throw DockerError.invalidResponse("bad status line: \(statusLine)")
        }
        var headers = HTTPHeaders()
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.add(
                String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            )
        }
        return HTTPResponseHead(status: status, reason: parts.count > 2 ? String(parts[2]) : "", headers: headers)
    }
}

/// Incremental decoder for `Transfer-Encoding: chunked`.
public struct ChunkedDecoder: Sendable {
    private enum State: Sendable {
        case sizeLine
        case data(remaining: Int)
        case dataTerminator
        case trailer
        case done
    }

    private var state = State.sizeLine
    private var line: [UInt8] = []

    /// Creates a decoder.
    public init() {}

    /// Whether the terminating zero-size chunk and trailer were read.
    public var isDone: Bool {
        if case .done = state { return true }
        return false
    }

    /// Decodes as much of `input` as possible. Returns decoded payload bytes and the number of input bytes consumed.
    /// Bytes after the end of the chunked body are not consumed.
    public mutating func decode(_ input: ArraySlice<UInt8>) throws -> (payload: [UInt8], consumed: Int) {
        var payload: [UInt8] = []
        var index = input.startIndex
        while index < input.endIndex {
            switch state {
            case .sizeLine:
                if let lineEnd = takeLine(from: input, at: &index) {
                    let sizeText = String(decoding: lineEnd, as: UTF8.self)
                        .split(separator: ";", maxSplits: 1).first?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    guard let size = Int(sizeText, radix: 16), size >= 0 else {
                        throw DockerError.invalidResponse("bad chunk size: \(sizeText)")
                    }
                    state = size == 0 ? .trailer : .data(remaining: size)
                }

            case .data(let remaining):
                let take = min(remaining, input.endIndex - index)
                payload.append(contentsOf: input[index..<(index + take)])
                index += take
                state = remaining - take == 0 ? .dataTerminator : .data(remaining: remaining - take)

            case .dataTerminator:
                if let terminator = takeLine(from: input, at: &index) {
                    guard terminator.isEmpty else { throw DockerError.invalidResponse("missing chunk terminator") }
                    state = .sizeLine
                }

            case .trailer:
                if let trailerLine = takeLine(from: input, at: &index), trailerLine.isEmpty {
                    state = .done
                }

            case .done:
                return (payload, index - input.startIndex)
            }
        }
        return (payload, index - input.startIndex)
    }

    /// Accumulates bytes up to CRLF. Returns the line without CRLF once complete.
    private mutating func takeLine(from input: ArraySlice<UInt8>, at index: inout Int) -> [UInt8]? {
        while index < input.endIndex {
            let byte = input[index]
            index += 1
            if byte == 10 {
                defer { line = [] }
                return line.last == 13 ? Array(line.dropLast()) : line
            }
            line.append(byte)
            if line.count > 8 * 1024 { line.removeFirst(line.count - 8 * 1024) }
        }
        return nil
    }
}
