import ColimaDomain
import Foundation

/// Connection state of the Docker engine of the selected profile.
public enum DockerReachability: Hashable, Sendable {
    /// VM not running, or runtime without a Docker socket.
    case notApplicable
    case connecting
    case reachable
    case unreachable(String)
}

/// Everything the menu shows, as one immutable value.
public struct AppSnapshot: Hashable, Sendable {
    /// All colima profiles.
    public var profiles: [ColimaInstance] = []
    /// Profile the menu acts on.
    public var selectedProfile: ProfileName = .default
    /// Lifecycle of the selected profile's VM.
    public var lifecycle = VMLifecycle()
    /// Latest progress line of a running VM operation.
    public var progressMessage: String?
    /// Error of the last `colima list`, if it failed.
    public var listError: String?
    /// Details of the running VM.
    public var details: ColimaInstanceDetails?
    /// Live usage inside the VM (loaded while the information submenu is open).
    public var usage: VMUsage?
    /// Engine facts (loaded while the information submenu is open).
    public var engine: EngineSummary?
    /// Docker disk usage (loaded while the information submenu is open).
    public var diskUsage: DiskUsageSummary?
    /// Docker reachability.
    public var docker: DockerReachability = .notApplicable
    /// Docker socket in use.
    public var socketPath: String?
    /// Containers of the selected profile.
    public var containers: [Container] = []
    /// Container actions in progress, by container ID.
    public var containerOperations: [String: ContainerAction] = [:]
    /// Error of the last failed container action.
    public var containerActionError: String?
    /// Installed colima version.
    public var colimaVersion: String?

    /// Creates an empty snapshot.
    public init() {}

    /// The selected profile's list entry, if it exists.
    public var selectedInstance: ColimaInstance? {
        profiles.first { $0.profile == selectedProfile }
    }
}
