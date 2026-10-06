import Foundation

/// Case-insensitive HTTP header list that keeps the original order.
public struct HTTPHeaders: Sendable, Hashable, ExpressibleByDictionaryLiteral {
    /// Header fields in wire order.
    public private(set) var fields: [(name: String, value: String)]

    /// Creates headers from fields.
    public init(_ fields: [(name: String, value: String)] = []) {
        self.fields = fields
    }

    public init(dictionaryLiteral elements: (String, String)...) {
        fields = elements.map { (name: $0.0, value: $0.1) }
    }

    /// First value of a header, matched case-insensitively.
    public subscript(name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Appends a header field.
    public mutating func add(_ name: String, _ value: String) {
        fields.append((name: name, value: value))
    }

    public static func == (lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool {
        lhs.fields.elementsEqual(rhs.fields) { $0.name == $1.name && $0.value == $1.value }
    }

    public func hash(into hasher: inout Hasher) {
        for field in fields {
            hasher.combine(field.name)
            hasher.combine(field.value)
        }
    }
}

/// An HTTP/1.1 request.
public struct HTTPRequest: Sendable, Hashable {
    /// Method, e.g. `GET`.
    public var method: String
    /// Path including the query string, e.g. `/v1.44/containers/json?all=1`.
    public var target: String
    /// Extra header fields.
    public var headers: HTTPHeaders
    /// Body bytes; nil for none.
    public var body: [UInt8]?

    /// Creates a request.
    public init(method: String, target: String, headers: HTTPHeaders = [:], body: [UInt8]? = nil) {
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
    }

    /// Serializes the request. Adds `Host`, `User-Agent` and `Content-Length` when missing.
    public func encoded() -> [UInt8] {
        var text = "\(method) \(target) HTTP/1.1\r\n"
        var headers = headers
        if headers["Host"] == nil { headers.add("Host", "docker") }
        if headers["User-Agent"] == nil { headers.add("User-Agent", "ColimaDesktop") }
        if let body, headers["Content-Length"] == nil { headers.add("Content-Length", String(body.count)) }
        for field in headers.fields {
            text += "\(field.name): \(field.value)\r\n"
        }
        text += "\r\n"
        return Array(text.utf8) + (body ?? [])
    }
}

/// Status line and headers of a response.
public struct HTTPResponseHead: Sendable, Hashable {
    /// Status code, e.g. 200.
    public var status: Int
    /// Reason phrase, e.g. `OK`.
    public var reason: String
    /// Header fields.
    public var headers: HTTPHeaders

    /// Creates a response head.
    public init(status: Int, reason: String, headers: HTTPHeaders) {
        self.status = status
        self.reason = reason
        self.headers = headers
    }
}

/// A complete response with a buffered body.
public struct HTTPResponse: Sendable, Hashable {
    /// Status line and headers.
    public var head: HTTPResponseHead
    /// Body bytes after transfer decoding.
    public var body: [UInt8]

    /// Creates a response.
    public init(head: HTTPResponseHead, body: [UInt8]) {
        self.head = head
        self.body = body
    }
}
