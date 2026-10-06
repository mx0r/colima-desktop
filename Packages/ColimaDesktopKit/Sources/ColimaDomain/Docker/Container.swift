import Foundation

/// A Docker container as listed by the Engine API.
public struct Container: Identifiable, Hashable, Sendable {
    /// Compose label holding the project name.
    public static let composeProjectLabel = "com.docker.compose.project"
    /// Compose label holding the service name.
    public static let composeServiceLabel = "com.docker.compose.service"

    /// Full container ID.
    public let id: String
    /// Container name without the leading slash.
    public var name: String
    /// Image reference the container was created from.
    public var image: String
    /// Lifecycle state.
    public var state: ContainerState
    /// Human readable status, e.g. `Up 27 minutes`.
    public var statusText: String
    /// Creation time.
    public var created: Date
    /// Published ports, de-duplicated across IPv4 and IPv6 bindings.
    public var ports: [PublishedPort]
    /// Container labels.
    public var labels: [String: String]

    /// Creates a container value.
    public init(
        id: String,
        name: String,
        image: String,
        state: ContainerState,
        statusText: String,
        created: Date,
        ports: [PublishedPort] = [],
        labels: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.statusText = statusText
        self.created = created
        self.ports = ports
        self.labels = labels
    }

    /// First 12 characters of the ID, as the docker CLI shows it.
    public var shortID: String { String(id.prefix(12)) }

    /// Compose project name, if the container belongs to one.
    public var composeProject: String? { labels[Self.composeProjectLabel] }

    /// Compose service name, if the container belongs to a Compose project.
    public var composeService: String? { labels[Self.composeServiceLabel] }

    /// Ports that can be opened in a browser.
    public var browsablePorts: [PublishedPort] { ports.filter { $0.browsableURL != nil } }
}

/// Lifecycle state of a container (Engine API `State`).
public enum ContainerState: Hashable, Sendable {
    case created
    case running
    case paused
    case restarting
    case removing
    case exited
    case dead
    /// A state this app does not know, kept verbatim.
    case unknown(String)

    /// Maps the Engine API state string.
    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "created": self = .created
        case "running": self = .running
        case "paused": self = .paused
        case "restarting": self = .restarting
        case "removing": self = .removing
        case "exited": self = .exited
        case "dead": self = .dead
        default: self = .unknown(rawValue)
        }
    }

    /// Whether the container's processes are alive (running, paused or restarting).
    public var isAlive: Bool {
        switch self {
        case .running, .paused, .restarting: true
        default: false
        }
    }

    /// Human readable state.
    public var displayName: String {
        switch self {
        case .created: "Created"
        case .running: "Running"
        case .paused: "Paused"
        case .restarting: "Restarting"
        case .removing: "Removing"
        case .exited: "Exited"
        case .dead: "Dead"
        case .unknown(let raw): raw
        }
    }
}

/// A port binding published to the host.
public struct PublishedPort: Hashable, Sendable, Comparable {
    /// Port inside the container.
    public var privatePort: Int
    /// Port on the host, if published.
    public var publicPort: Int?
    /// Protocol, `tcp`, `udp` or `sctp`.
    public var proto: String

    /// Creates a port binding.
    public init(privatePort: Int, publicPort: Int?, proto: String) {
        self.privatePort = privatePort
        self.publicPort = publicPort
        self.proto = proto
    }

    /// `http://localhost:<publicPort>` for published TCP ports, otherwise nil.
    public var browsableURL: URL? {
        guard proto == "tcp", let publicPort else { return nil }
        return URL(string: "http://localhost:\(publicPort)")
    }

    /// Display form, e.g. `8080→80/tcp` or `5432/tcp` (not published).
    public var displayText: String {
        if let publicPort { return "\(publicPort)→\(privatePort)/\(proto)" }
        return "\(privatePort)/\(proto)"
    }

    public static func < (lhs: PublishedPort, rhs: PublishedPort) -> Bool {
        (lhs.publicPort ?? Int.max, lhs.privatePort, lhs.proto) < (rhs.publicPort ?? Int.max, rhs.privatePort, rhs.proto)
    }

    /// Removes duplicates (the Engine API lists IPv4 and IPv6 bindings separately) and sorts.
    public static func deduplicated(_ ports: [PublishedPort]) -> [PublishedPort] {
        Array(Set(ports)).sorted()
    }
}

/// Container details from the inspect endpoint.
public struct ContainerDetails: Hashable, Sendable {
    /// Full container ID.
    public var id: String
    /// Container name without the leading slash.
    public var name: String
    /// Image reference from the container config.
    public var image: String
    /// Whether the container was created with a TTY (logs are then not multiplexed).
    public var tty: Bool
    /// Command line (entrypoint plus command).
    public var command: [String]
    /// Lifecycle state.
    public var state: ContainerState
    /// Start time of the current or last run.
    public var startedAt: Date?
    /// Exit time of the last run.
    public var finishedAt: Date?
    /// Exit code of the last run.
    public var exitCode: Int?
    /// Health check status, if the container has a health check.
    public var health: String?
    /// Restart count.
    public var restartCount: Int
    /// Platform, e.g. `linux`.
    public var platform: String?
    /// IP addresses per network name.
    public var networks: [String: String]
    /// Mounts as `source → destination`.
    public var mounts: [String]

    /// Creates a details value.
    public init(
        id: String,
        name: String,
        image: String,
        tty: Bool,
        command: [String],
        state: ContainerState,
        startedAt: Date?,
        finishedAt: Date?,
        exitCode: Int?,
        health: String?,
        restartCount: Int,
        platform: String?,
        networks: [String: String],
        mounts: [String]
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.tty = tty
        self.command = command
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.health = health
        self.restartCount = restartCount
        self.platform = platform
        self.networks = networks
        self.mounts = mounts
    }
}

/// An event from the Engine API event stream.
public struct DockerEvent: Hashable, Sendable {
    /// Object type, e.g. `container`.
    public var type: String
    /// Action, e.g. `start`, `die`, `destroy`.
    public var action: String
    /// ID of the affected object.
    public var actorID: String

    /// Creates an event.
    public init(type: String, action: String, actorID: String) {
        self.type = type
        self.action = action
        self.actorID = actorID
    }
}
