import Foundation

/// Live resource usage measured inside the VM.
public struct VMUsage: Hashable, Sendable {
    /// Load averages over 1, 5 and 15 minutes.
    public var loadAverage: LoadAverage
    /// Number of online CPUs in the guest.
    public var cpuCount: Int
    /// Total guest memory in bytes.
    public var memoryTotalBytes: Int64
    /// Memory available for new processes in bytes (`MemAvailable`).
    public var memoryAvailableBytes: Int64
    /// Filesystem usage, one entry per probed mount point.
    public var disks: [DiskUsage]

    /// Memory in use (total minus available).
    public var memoryUsedBytes: Int64 { max(0, memoryTotalBytes - memoryAvailableBytes) }

    /// Creates a usage value.
    public init(loadAverage: LoadAverage, cpuCount: Int, memoryTotalBytes: Int64, memoryAvailableBytes: Int64, disks: [DiskUsage]) {
        self.loadAverage = loadAverage
        self.cpuCount = cpuCount
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryAvailableBytes = memoryAvailableBytes
        self.disks = disks
    }
}

/// Unix load averages.
public struct LoadAverage: Hashable, Sendable {
    public var one: Double
    public var five: Double
    public var fifteen: Double

    /// Creates load averages.
    public init(one: Double, five: Double, fifteen: Double) {
        self.one = one
        self.five = five
        self.fifteen = fifteen
    }
}

/// Usage of one mounted filesystem.
public struct DiskUsage: Hashable, Sendable {
    /// Mount point, e.g. `/` or `/var/lib/docker`.
    public var mountPoint: String
    /// Size in bytes.
    public var totalBytes: Int64
    /// Used bytes.
    public var usedBytes: Int64
    /// Available bytes.
    public var availableBytes: Int64

    /// Creates a disk usage value.
    public init(mountPoint: String, totalBytes: Int64, usedBytes: Int64, availableBytes: Int64) {
        self.mountPoint = mountPoint
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
    }
}
