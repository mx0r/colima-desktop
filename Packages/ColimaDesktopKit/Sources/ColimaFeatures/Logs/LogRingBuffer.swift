import ColimaDomain
import Foundation

/// A log line with a sequence number, as kept by a logs window.
public struct LogEntry: Identifiable, Hashable, Sendable {
    /// Monotonic sequence number; unique per window.
    public let id: Int
    /// The line.
    public var line: LogLine
    /// Whether this is a user-inserted marker.
    public var isMarker: Bool

    /// Creates an entry.
    public init(id: Int, line: LogLine, isMarker: Bool = false) {
        self.id = id
        self.line = line
        self.isMarker = isMarker
    }
}

/// Fixed-capacity buffer that drops the oldest entries. Entries keep contiguous sequence numbers.
public struct LogRingBuffer: Sendable {
    /// Maximum number of entries kept.
    public let capacity: Int
    private var storage: [LogEntry] = []
    private var head = 0
    private var nextID = 0

    /// Creates a buffer.
    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(min(self.capacity, 4096))
    }

    /// Number of stored entries.
    public var count: Int { storage.count }

    /// Sequence number of the oldest stored entry.
    public var firstID: Int { nextID - storage.count }

    /// Sequence number the next entry gets.
    public var nextSequence: Int { nextID }

    /// Appends a line; returns the new entry.
    @discardableResult
    public mutating func append(_ line: LogLine, isMarker: Bool = false) -> LogEntry {
        let entry = LogEntry(id: nextID, line: line, isMarker: isMarker)
        nextID += 1
        if storage.count < capacity {
            storage.append(entry)
        } else {
            storage[head] = entry
            head = (head + 1) % capacity
        }
        return entry
    }

    /// Entry with a sequence number, nil if dropped or not yet written.
    public func entry(id: Int) -> LogEntry? {
        let offset = id - firstID
        guard offset >= 0, offset < storage.count else { return nil }
        return storage[(head + offset) % storage.count]
    }

    /// All entries, oldest first.
    public var entries: [LogEntry] {
        Array(storage[head...]) + Array(storage[..<head])
    }

    /// Removes all entries; sequence numbers keep increasing.
    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}
