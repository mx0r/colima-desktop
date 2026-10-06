import ColimaDomain
import Foundation
import Observation

/// State of a logs window: streams container logs into a bounded buffer and provides
/// the filtered, optionally frozen list of rows the table shows.
@MainActor
@Observable
public final class LogsViewModel {
    /// Stream state.
    public enum StreamState: Hashable, Sendable {
        case connecting
        case streaming
        /// The stream ended (usually the container stopped).
        case ended
        case failed(String)
    }

    /// Container ID.
    public let containerID: String
    /// Container name for the window title.
    public let containerName: String

    /// Stream state.
    public private(set) var state = StreamState.connecting
    /// Bumped whenever `visibleIDs` changes; the table reloads on change.
    public private(set) var revision = 0
    /// Sequence numbers of the rows shown, oldest first.
    public private(set) var visibleIDs: [Int] = []
    /// Lines received while paused.
    public private(set) var newLinesWhilePaused = 0
    /// Lines dropped because the buffer was full.
    public private(set) var droppedLineCount = 0

    /// Follow new lines (auto-scroll). When false the view is frozen.
    public var isFollowing = true {
        didSet {
            guard isFollowing != oldValue, isFollowing else { return }
            newLinesWhilePaused = 0
            rebuildVisibleIDs()
        }
    }

    /// Show timestamps in rows and exports.
    public var showsTimestamps = true

    /// Case-insensitive substring filter. Markers always stay visible.
    public var filterText = "" {
        didSet {
            guard filterText != oldValue else { return }
            scheduleFilter()
        }
    }

    @ObservationIgnored private var buffer: LogRingBuffer
    @ObservationIgnored private var pendingLines: [LogLine] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var appliedFilter = ""
    @ObservationIgnored private let engine: any DockerEngine
    @ObservationIgnored private let tailLines: Int
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: @Sendable () -> Date

    /// UI updates are batched at this interval.
    static let flushInterval = Duration.milliseconds(100)
    /// Filter typing debounce.
    static let filterDebounce = Duration.milliseconds(150)

    /// Creates a view model. Call `start()` to begin streaming.
    public init(
        containerID: String,
        containerName: String,
        engine: any DockerEngine,
        tailLines: Int,
        capacity: Int,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.containerID = containerID
        self.containerName = containerName
        self.engine = engine
        self.tailLines = tailLines
        buffer = LogRingBuffer(capacity: capacity)
        self.clock = clock
        self.now = now
    }

    /// Number of rows.
    public var rowCount: Int { visibleIDs.count }

    /// Entry for a row; nil if it was dropped from the buffer.
    public func entry(atRow row: Int) -> LogEntry? {
        guard visibleIDs.indices.contains(row) else { return nil }
        return buffer.entry(id: visibleIDs[row])
    }

    /// Starts streaming the last `tailLines` lines and follows new ones.
    public func start() {
        startStream(options: LogOptions(follow: true, tail: tailLines))
    }

    /// Restarts the stream after it ended, continuing after the last received line.
    public func reconnect() {
        let lastTimestamp = buffer.entries.last { !$0.isMarker && $0.line.timestamp != nil }?.line.timestamp
        appendSystemLine("Reconnected")
        if let lastTimestamp {
            // `since` is inclusive with second precision in older engines; nudge past the last line.
            startStream(options: LogOptions(follow: true, tail: nil, since: lastTimestamp.addingTimeInterval(0.000_001)))
        } else {
            startStream(options: LogOptions(follow: true, tail: tailLines))
        }
    }

    /// Stops streaming.
    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        flushTask?.cancel()
        flushTask = nil
        filterTask?.cancel()
    }

    /// Inserts a marker line with the current time.
    public func insertMarker() {
        flushPending()
        let date = now()
        let entry = buffer.append(LogLine(stream: .system, timestamp: date, text: "Marker \(Format.time(date))"), isMarker: true)
        if isFollowing {
            visibleIDs.append(entry.id)
            trimVisibleIDs()
            revision += 1
        } else {
            newLinesWhilePaused += 1
        }
    }

    /// Removes all lines from the window.
    public func clear() {
        flushPending()
        buffer.removeAll()
        visibleIDs = []
        newLinesWhilePaused = 0
        revision += 1
    }

    /// Text of the shown rows (respecting the filter), one line each.
    public func visibleText() -> String {
        visibleIDs.compactMap { buffer.entry(id: $0) }.map(format).joined(separator: "\n") + "\n"
    }

    /// Text of specific rows.
    public func text(forRows rows: IndexSet) -> String {
        rows.compactMap { entry(atRow: $0) }.map(format).joined(separator: "\n")
    }

    /// Formats a line for export: optional timestamp, stream tag for stderr.
    public func format(_ entry: LogEntry) -> String {
        var parts: [String] = []
        if showsTimestamps, let timestamp = entry.line.timestamp {
            parts.append(Format.logTimestamp(timestamp))
        }
        if entry.isMarker {
            parts.append("──── \(entry.line.text) ────")
        } else {
            if entry.line.stream == .stderr { parts.append("[stderr]") }
            parts.append(entry.line.text)
        }
        return parts.joined(separator: " ")
    }

    // MARK: Streaming

    private func startStream(options: LogOptions) {
        streamTask?.cancel()
        state = .connecting
        let stream = engine.logs(containerID: containerID, options: options)
        streamTask = Task { [weak self] in
            do {
                for try await batch in stream {
                    guard let self else { return }
                    if self.state != .streaming { self.state = .streaming }
                    self.enqueue(batch)
                }
                guard let self, !Task.isCancelled else { return }
                self.flushPending()
                self.state = .ended
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.flushPending()
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func enqueue(_ lines: [LogLine]) {
        pendingLines += lines
        guard flushTask == nil else { return }
        let clock = clock
        flushTask = Task { [weak self] in
            try? await clock.sleep(for: Self.flushInterval)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flushPending()
        }
    }

    /// Moves pending lines into the buffer and updates the visible rows.
    func flushPending() {
        guard !pendingLines.isEmpty else { return }
        let lines = pendingLines
        pendingLines = []
        let filter = appliedFilter
        var added: [Int] = []
        for line in lines {
            if buffer.count == buffer.capacity { droppedLineCount += 1 }
            let entry = buffer.append(line)
            if Self.matches(entry, filter: filter) { added.append(entry.id) }
        }
        if isFollowing {
            visibleIDs += added
            trimVisibleIDs()
            revision += 1
        } else {
            newLinesWhilePaused += added.count
        }
    }

    private func appendSystemLine(_ text: String) {
        flushPending()
        let entry = buffer.append(LogLine(stream: .system, timestamp: now(), text: text), isMarker: true)
        visibleIDs.append(entry.id)
        trimVisibleIDs()
        revision += 1
    }

    // MARK: Filtering

    private func scheduleFilter() {
        filterTask?.cancel()
        let clock = clock
        filterTask = Task { [weak self] in
            do { try await clock.sleep(for: Self.filterDebounce) } catch { return }
            self?.applyFilterNow()
        }
    }

    /// Applies the filter text immediately.
    func applyFilterNow() {
        appliedFilter = filterText
        flushPending()
        rebuildVisibleIDs()
    }

    private func rebuildVisibleIDs() {
        let filter = appliedFilter
        visibleIDs = buffer.entries.filter { Self.matches($0, filter: filter) }.map(\.id)
        revision += 1
    }

    /// Drops IDs that fell out of the buffer.
    private func trimVisibleIDs() {
        let first = buffer.firstID
        if let index = visibleIDs.firstIndex(where: { $0 >= first }), index > 0 {
            visibleIDs.removeFirst(index)
        } else if let last = visibleIDs.last, last < first {
            visibleIDs = []
        }
    }

    static func matches(_ entry: LogEntry, filter: String) -> Bool {
        filter.isEmpty || entry.isMarker || entry.line.text.localizedCaseInsensitiveContains(filter)
    }
}
