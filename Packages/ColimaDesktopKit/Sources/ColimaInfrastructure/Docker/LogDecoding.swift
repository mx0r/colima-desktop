import ColimaDomain
import Foundation

/// Splits Docker's multiplexed stream (non-TTY attach and logs) into frames.
///
/// Each frame starts with an 8-byte header: `[stream, 0, 0, 0, size (big-endian UInt32)]`,
/// where stream is 0 (stdin), 1 (stdout) or 2 (stderr).
public struct MultiplexedStreamDemuxer: Sendable {
    /// One frame payload.
    public struct Frame: Sendable, Hashable {
        public var stream: LogStream
        public var payload: [UInt8]
    }

    private var buffer: [UInt8] = []
    private var offset = 0

    /// Creates a demuxer.
    public init() {}

    /// Consumes bytes and returns all complete frames.
    public mutating func feed(_ bytes: [UInt8]) throws -> [Frame] {
        buffer.append(contentsOf: bytes)
        var frames: [Frame] = []
        while buffer.count - offset >= 8 {
            let streamByte = buffer[offset]
            guard streamByte <= 2 else {
                throw DockerError.invalidResponse("bad multiplexed stream header \(streamByte)")
            }
            let size = Int(buffer[offset + 4]) << 24 | Int(buffer[offset + 5]) << 16
                | Int(buffer[offset + 6]) << 8 | Int(buffer[offset + 7])
            guard buffer.count - offset - 8 >= size else { break }
            let start = offset + 8
            frames.append(Frame(stream: streamByte == 2 ? .stderr : .stdout, payload: Array(buffer[start..<(start + size)])))
            offset = start + size
        }
        // Compact once the consumed prefix gets large.
        if offset > 0, offset >= buffer.count / 2 {
            buffer.removeFirst(offset)
            offset = 0
        }
        return frames
    }

    /// Bytes of an incomplete frame still buffered.
    public var pendingByteCount: Int { buffer.count - offset }
}

/// Turns byte chunks into log lines, one partial-line buffer per stream.
public struct LogLineAssembler: Sendable {
    private var partial: [LogStream: [UInt8]] = [:]
    private let parsesTimestamps: Bool
    /// Lines longer than this are split, so a missing newline cannot grow memory without bound.
    private let maxLineBytes: Int

    /// Creates an assembler.
    ///
    /// - Parameter parsesTimestamps: Strip and parse the RFC 3339 prefix Docker adds with `timestamps=1`.
    public init(parsesTimestamps: Bool, maxLineBytes: Int = 64 * 1024) {
        self.parsesTimestamps = parsesTimestamps
        self.maxLineBytes = maxLineBytes
    }

    /// Consumes bytes of one stream and returns the completed lines.
    public mutating func feed(_ bytes: [UInt8], stream: LogStream) -> [LogLine] {
        var buffer = partial[stream, default: []]
        buffer.append(contentsOf: bytes)
        var lines: [LogLine] = []
        var lineStart = 0
        var index = 0
        while index < buffer.count {
            if buffer[index] == 10 {
                lines.append(makeLine(buffer[lineStart..<index], stream: stream))
                lineStart = index + 1
            } else if index - lineStart + 1 >= maxLineBytes {
                lines.append(makeLine(buffer[lineStart...index], stream: stream))
                lineStart = index + 1
            }
            index += 1
        }
        partial[stream] = lineStart == 0 ? buffer : Array(buffer[lineStart...])
        return lines
    }

    /// Returns the buffered partial lines (call at end of stream).
    public mutating func flush() -> [LogLine] {
        let lines = [LogStream.stdout, .stderr].compactMap { stream -> LogLine? in
            guard let rest = partial[stream], !rest.isEmpty else { return nil }
            return makeLine(rest[...], stream: stream)
        }
        partial = [:]
        return lines
    }

    private func makeLine(_ bytes: ArraySlice<UInt8>, stream: LogStream) -> LogLine {
        var content = bytes
        if content.last == 13 { content = content.dropLast() }
        var timestamp: Date?
        if parsesTimestamps, let space = content.firstIndex(of: 32), let date = RFC3339.parse(content[content.startIndex..<space]) {
            timestamp = date
            content = content[(space + 1)...]
        }
        // Colored output would show its escape codes as text ("[38;5;214m").
        return LogLine(stream: stream, timestamp: timestamp, text: TerminalEscapes.strip(String(decoding: content, as: UTF8.self)))
    }
}

/// Fast RFC 3339 parser for Docker timestamps such as `2026-10-06T06:49:28.909696474Z`.
public enum RFC3339 {
    /// Parses `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`. Returns nil for other formats.
    public static func parse<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> Date? {
        let b = Array(bytes)
        guard b.count >= 20, b[4] == 45, b[7] == 45, b[10] == 84 || b[10] == 116, b[13] == 58, b[16] == 58,
              let year = number(b, 0, 4), let month = number(b, 5, 2), let day = number(b, 8, 2),
              let hour = number(b, 11, 2), let minute = number(b, 14, 2), let second = number(b, 17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }

        var index = 19
        var fraction = 0.0
        if index < b.count, b[index] == 46 {
            index += 1
            var scale = 0.1
            while index < b.count, (48...57).contains(b[index]) {
                fraction += Double(b[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }
        guard index < b.count else { return nil }
        var offsetSeconds = 0
        switch b[index] {
        case 90, 122: // Z
            guard index + 1 == b.count else { return nil }
        case 43, 45: // + -
            guard index + 6 == b.count, b[index + 3] == 58,
                  let offsetHours = number(b, index + 1, 2), let offsetMinutes = number(b, index + 4, 2) else { return nil }
            offsetSeconds = (offsetHours * 3600 + offsetMinutes * 60) * (b[index] == 45 ? -1 : 1)
        default:
            return nil
        }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    private static func number(_ bytes: [UInt8], _ start: Int, _ length: Int) -> Int? {
        var value = 0
        for index in start..<(start + length) {
            let byte = bytes[index]
            guard (48...57).contains(byte) else { return nil }
            value = value * 10 + Int(byte - 48)
        }
        return value
    }

    /// Days since 1970-01-01 (Howard Hinnant's algorithm).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
