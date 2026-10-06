import Foundation

/// Facts about the Docker engine, combined from `/version` and `/info`.
public struct EngineSummary: Hashable, Sendable {
    /// Engine version, e.g. `29.5.2`.
    public var serverVersion: String
    /// Highest API version the engine supports.
    public var apiVersion: String
    /// Guest operating system, e.g. `Ubuntu 24.04.4 LTS`.
    public var operatingSystem: String
    /// Guest kernel version.
    public var kernelVersion: String
    /// Engine architecture, e.g. `aarch64`.
    public var architecture: String
    /// CPUs visible to the engine.
    public var cpuCount: Int
    /// Memory visible to the engine in bytes.
    public var memoryTotalBytes: Int64
    /// Total container count.
    public var containersTotal: Int
    /// Running container count.
    public var containersRunning: Int
    /// Paused container count.
    public var containersPaused: Int
    /// Stopped container count.
    public var containersStopped: Int
    /// Image count.
    public var images: Int
    /// Storage driver, e.g. `overlayfs`.
    public var storageDriver: String

    /// Creates an engine summary.
    public init(
        serverVersion: String,
        apiVersion: String,
        operatingSystem: String,
        kernelVersion: String,
        architecture: String,
        cpuCount: Int,
        memoryTotalBytes: Int64,
        containersTotal: Int,
        containersRunning: Int,
        containersPaused: Int,
        containersStopped: Int,
        images: Int,
        storageDriver: String
    ) {
        self.serverVersion = serverVersion
        self.apiVersion = apiVersion
        self.operatingSystem = operatingSystem
        self.kernelVersion = kernelVersion
        self.architecture = architecture
        self.cpuCount = cpuCount
        self.memoryTotalBytes = memoryTotalBytes
        self.containersTotal = containersTotal
        self.containersRunning = containersRunning
        self.containersPaused = containersPaused
        self.containersStopped = containersStopped
        self.images = images
        self.storageDriver = storageDriver
    }
}

/// Disk usage of Docker objects (`/system/df`).
public struct DiskUsageSummary: Hashable, Sendable {
    /// Images.
    public var images: Category
    /// Container writable layers.
    public var containers: Category
    /// Local volumes.
    public var volumes: Category
    /// Build cache.
    public var buildCache: Category

    /// Creates a disk usage summary.
    public init(images: Category, containers: Category, volumes: Category, buildCache: Category) {
        self.images = images
        self.containers = containers
        self.volumes = volumes
        self.buildCache = buildCache
    }

    /// Usage of one object kind.
    public struct Category: Hashable, Sendable {
        /// Object count.
        public var count: Int
        /// Objects in use.
        public var active: Int
        /// Total size in bytes.
        public var sizeBytes: Int64
        /// Bytes that a prune could free.
        public var reclaimableBytes: Int64

        /// Creates a category.
        public init(count: Int, active: Int, sizeBytes: Int64, reclaimableBytes: Int64) {
            self.count = count
            self.active = active
            self.sizeBytes = sizeBytes
            self.reclaimableBytes = reclaimableBytes
        }

        /// An empty category.
        public static let empty = Category(count: 0, active: 0, sizeBytes: 0, reclaimableBytes: 0)
    }
}
