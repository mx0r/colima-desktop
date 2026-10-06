import Foundation
import Synchronization
@testable import ColimaInfrastructure

/// Transport whose connections replay scripted server bytes and record what the client sent.
final class InMemoryTransport: ByteStreamTransport {
    private let scripts = Mutex<[InMemoryConnection]>([])
    private let opened = Mutex<[InMemoryConnection]>([])

    /// Queues a connection that will deliver `chunks` and then EOF (or stay open when `keepOpen`).
    @discardableResult
    func enqueue(_ chunks: [[UInt8]], keepOpen: Bool = false) -> InMemoryConnection {
        let connection = InMemoryConnection(chunks: chunks, keepOpen: keepOpen)
        scripts.withLock { $0.append(connection) }
        return connection
    }

    /// Queues a full response given as text.
    @discardableResult
    func enqueue(_ response: String) -> InMemoryConnection {
        enqueue([Array(response.utf8)])
    }

    var connections: [InMemoryConnection] { opened.withLock { $0 } }

    /// Request lines (`METHOD target`) of all connections, in order.
    var requestLines: [String] {
        connections.map { connection in
            String(decoding: connection.sentBytes, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        }
    }

    func connect() async throws -> any ByteStreamConnection {
        let next = scripts.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        guard let next else { throw POSIXError(.ECONNREFUSED) }
        opened.withLock { $0.append(next) }
        return next
    }
}

final class InMemoryConnection: ByteStreamConnection {
    private struct State {
        var chunks: [[UInt8]]
        var sent: [UInt8] = []
        var closed = false
        var waiter: CheckedContinuation<[UInt8]?, Error>?
    }

    private let state: Mutex<State>
    private let keepOpen: Bool

    init(chunks: [[UInt8]], keepOpen: Bool) {
        state = Mutex(State(chunks: chunks))
        self.keepOpen = keepOpen
    }

    var sentBytes: [UInt8] { state.withLock { $0.sent } }
    var isClosed: Bool { state.withLock { $0.closed } }

    /// Delivers more server bytes to a kept-open connection.
    func push(_ bytes: [UInt8]) {
        let waiter = state.withLock { state -> CheckedContinuation<[UInt8]?, Error>? in
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.chunks.append(bytes)
            return nil
        }
        waiter?.resume(returning: bytes)
    }

    func send(_ bytes: [UInt8]) async throws {
        state.withLock { $0.sent += bytes }
    }

    func receive() async throws -> [UInt8]? {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                if !state.chunks.isEmpty {
                    continuation.resume(returning: state.chunks.removeFirst())
                } else if state.closed || !keepOpen {
                    continuation.resume(returning: nil)
                } else {
                    state.waiter = continuation
                }
            }
        }
    }

    func close() {
        let waiter = state.withLock { state -> CheckedContinuation<[UInt8]?, Error>? in
            state.closed = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }
}

/// Deterministic random splits for framing tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Splits {
    /// The same bytes delivered whole, byte by byte, and at seeded random split points.
    static func variants(of bytes: [UInt8], seeds: [UInt64] = [1, 2, 3]) -> [[[UInt8]]] {
        var result: [[[UInt8]]] = [[bytes], bytes.map { [$0] }]
        for seed in seeds {
            var rng = SplitMix64(seed: seed)
            var chunks: [[UInt8]] = []
            var index = 0
            while index < bytes.count {
                let length = Int.random(in: 1...max(1, min(17, bytes.count - index)), using: &rng)
                chunks.append(Array(bytes[index..<(index + length)]))
                index += length
            }
            result.append(chunks)
        }
        return result
    }

    /// Encodes a body with chunked transfer encoding using the given chunk sizes.
    static func chunked(_ body: [UInt8], chunkSize: Int = 7, extensions: Bool = false, trailer: Bool = false) -> [UInt8] {
        var out: [UInt8] = []
        var index = 0
        while index < body.count {
            let length = min(chunkSize, body.count - index)
            out += Array((String(length, radix: 16) + (extensions ? ";ext=1" : "") + "\r\n").utf8)
            out += body[index..<(index + length)]
            out += Array("\r\n".utf8)
            index += length
        }
        out += Array("0\r\n".utf8)
        if trailer { out += Array("X-Trailer: yes\r\n".utf8) }
        out += Array("\r\n".utf8)
        return out
    }
}
