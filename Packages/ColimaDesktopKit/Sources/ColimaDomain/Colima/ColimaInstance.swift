import Foundation

/// One Colima profile as listed by `colima list --json`.
public struct ColimaInstance: Identifiable, Hashable, Sendable {
    /// Profile name.
    public var profile: ProfileName
    /// Current VM status.
    public var status: VMStatus
    /// Guest architecture, e.g. `aarch64`.
    public var arch: String
    /// Allocated CPUs.
    public var cpus: Int
    /// Allocated memory in bytes.
    public var memoryBytes: Int64
    /// Allocated disk in bytes.
    public var diskBytes: Int64
    /// Container runtime, e.g. `docker` or `containerd`.
    public var runtime: String?
    /// VM IP address, when a reachable address is configured.
    public var address: String?

    public var id: ProfileName { profile }

    /// Creates an instance description.
    public init(
        profile: ProfileName,
        status: VMStatus,
        arch: String,
        cpus: Int,
        memoryBytes: Int64,
        diskBytes: Int64,
        runtime: String? = nil,
        address: String? = nil
    ) {
        self.profile = profile
        self.status = status
        self.arch = arch
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.runtime = runtime
        self.address = address
    }
}

/// Details of a running profile as reported by `colima status --json`.
public struct ColimaInstanceDetails: Hashable, Sendable {
    /// Display name, e.g. `colima` or `colima [profile=work]`.
    public var displayName: String
    /// Virtualization driver, e.g. `macOS Virtualization.Framework`.
    public var driver: String
    /// Guest architecture.
    public var arch: String
    /// Container runtime.
    public var runtime: String
    /// Host file sharing type, e.g. `virtiofs`.
    public var mountType: String
    /// Filesystem path of the Docker socket (without the `unix://` scheme), if the runtime is Docker.
    public var dockerSocketPath: String?
    /// Filesystem path of the containerd socket, if present.
    public var containerdSocketPath: String?
    /// Whether Kubernetes is enabled.
    public var kubernetes: Bool
    /// Allocated CPUs.
    public var cpus: Int
    /// Allocated memory in bytes.
    public var memoryBytes: Int64
    /// Allocated disk in bytes.
    public var diskBytes: Int64

    /// Creates a details value.
    public init(
        displayName: String,
        driver: String,
        arch: String,
        runtime: String,
        mountType: String,
        dockerSocketPath: String?,
        containerdSocketPath: String?,
        kubernetes: Bool,
        cpus: Int,
        memoryBytes: Int64,
        diskBytes: Int64
    ) {
        self.displayName = displayName
        self.driver = driver
        self.arch = arch
        self.runtime = runtime
        self.mountType = mountType
        self.dockerSocketPath = dockerSocketPath
        self.containerdSocketPath = containerdSocketPath
        self.kubernetes = kubernetes
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
    }
}
