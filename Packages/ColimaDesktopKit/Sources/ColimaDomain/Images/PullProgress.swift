import Foundation

/// One progress message of an image pull (Docker's JSON message stream).
public struct PullMessage: Hashable, Sendable {
    /// Layer ID for layer messages; the tag for "Pulling from …"; nil for overall lines.
    public var id: String?
    public var status: String?
    /// Bytes done of the current phase (download or extraction).
    public var current: Int64?
    /// Size of the current phase.
    public var total: Int64?
    /// Set when the pull failed; Docker reports this inside a successful response.
    public var error: String?

    /// Creates a message.
    public init(id: String?, status: String?, current: Int64?, total: Int64?, error: String?) {
        self.id = id
        self.status = status
        self.current = current
        self.total = total
        self.error = error
    }
}

/// Progress of an image pull, folded from its messages.
public struct PullProgress: Hashable, Sendable {
    /// Where a layer is.
    public enum LayerPhase: Hashable, Sendable {
        case waiting
        case downloading
        case downloaded
        case extracting
        case complete
    }

    /// One image layer.
    public struct Layer: Hashable, Sendable {
        public var phase: LayerPhase
        /// Bytes downloaded.
        public var downloaded: Int64
        /// Compressed size, once known.
        public var size: Int64?
    }

    /// Layers by ID.
    public private(set) var layers: [String: Layer] = [:]
    /// Latest overall line, e.g. "Pulling from library/redis" or "Status: Downloaded newer image…".
    public private(set) var status: String?
    /// Error the engine reported.
    public private(set) var error: String?

    /// Creates empty progress.
    public init() {}

    /// Number of layers seen.
    public var layerCount: Int { layers.count }

    /// Layers already present or fully pulled.
    public var completedLayers: Int { layers.values.filter { $0.phase == .complete }.count }

    /// Downloaded share of the layers whose size is known; nil before any size is known.
    public var fractionCompleted: Double? {
        let sized = layers.values.compactMap { layer in layer.size.map { (layer, $0) } }
        let total = sized.reduce(Int64(0)) { $0 + $1.1 }
        guard total > 0 else { return nil }
        let done = sized.reduce(Int64(0)) { sum, entry in
            let (layer, size) = entry
            return sum + (layer.phase == .downloading || layer.phase == .waiting ? min(layer.downloaded, size) : size)
        }
        return Double(done) / Double(total)
    }

    /// Folds in one message.
    public mutating func apply(_ message: PullMessage) {
        if let error = message.error {
            self.error = error
            return
        }
        guard let status = message.status else { return }
        guard let id = message.id, let phase = Self.layerPhase(of: status) else {
            self.status = status
            return
        }
        var layer = layers[id] ?? Layer(phase: .waiting, downloaded: 0, size: nil)
        layer.phase = phase
        switch phase {
        case .downloading:
            if let current = message.current { layer.downloaded = current }
            if let total = message.total, total > 0 { layer.size = total }
        case .downloaded, .extracting, .complete:
            if let size = layer.size { layer.downloaded = size }
        case .waiting:
            break
        }
        layers[id] = layer
    }

    /// Layer phase for a status line; nil for lines about the whole pull.
    static func layerPhase(of status: String) -> LayerPhase? {
        switch status {
        case "Pulling fs layer", "Waiting": .waiting
        case "Downloading": .downloading
        case "Verifying Checksum", "Download complete": .downloaded
        case "Extracting": .extracting
        case "Pull complete", "Already exists": .complete
        default: status.hasPrefix("Retrying in") ? .waiting : nil
        }
    }
}
