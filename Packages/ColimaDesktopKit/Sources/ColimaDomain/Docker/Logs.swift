import Foundation

/// Origin of a log line.
public enum LogStream: Hashable, Sendable {
    case stdout
    case stderr
    /// Lines added by this app, e.g. user markers or stream notices.
    case system
}

/// One decoded log line.
public struct LogLine: Hashable, Sendable {
    /// Stream the line came from.
    public var stream: LogStream
    /// Engine timestamp, when requested and parseable.
    public var timestamp: Date?
    /// Line text without the trailing newline.
    public var text: String

    /// Creates a log line.
    public init(stream: LogStream, timestamp: Date?, text: String) {
        self.stream = stream
        self.timestamp = timestamp
        self.text = text
    }
}

/// Options for a container log request.
public struct LogOptions: Hashable, Sendable {
    /// Keep the stream open and deliver new lines.
    public var follow: Bool
    /// Number of lines from the end to deliver first; nil for all.
    public var tail: Int?
    /// Only lines at or after this time; nil for no limit.
    public var since: Date?

    /// Creates log options.
    public init(follow: Bool = true, tail: Int? = 1000, since: Date? = nil) {
        self.follow = follow
        self.tail = tail
        self.since = since
    }
}
