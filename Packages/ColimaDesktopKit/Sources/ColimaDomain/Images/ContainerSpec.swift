import Foundation

/// Everything needed to create a container (`POST /containers/create`).
public struct ContainerSpec: Hashable, Sendable {
    public var image: ImageReference
    /// Container name; nil lets Docker pick one.
    public var name: String?
    /// Arguments replacing the image's default command; nil keeps it.
    public var command: [String]?
    public var environment: [EnvironmentVariable]
    public var ports: [PortBinding]
    public var volumes: [VolumeBinding]
    public var restartPolicy: RestartPolicy
    /// Publish every port the image exposes on a random host port.
    public var publishAllPorts: Bool

    /// Creates a spec.
    public init(
        image: ImageReference,
        name: String? = nil,
        command: [String]? = nil,
        environment: [EnvironmentVariable] = [],
        ports: [PortBinding] = [],
        volumes: [VolumeBinding] = [],
        restartPolicy: RestartPolicy = .no,
        publishAllPorts: Bool = false
    ) {
        self.image = image
        self.name = name
        self.command = command
        self.environment = environment
        self.ports = ports
        self.volumes = volumes
        self.restartPolicy = restartPolicy
        self.publishAllPorts = publishAllPorts
    }

    /// Whether Docker accepts a container name: a letter or digit, then at least one more of
    /// letters, digits, `_`, `.` and `-`.
    public static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9_.-]+/#) != nil
    }

    /// Whether Docker accepts a named volume's name (same rule as container names).
    public static func isValidVolumeName(_ name: String) -> Bool {
        isValidName(name)
    }
}

/// An environment variable.
public struct EnvironmentVariable: Hashable, Sendable {
    public var name: String
    public var value: String

    /// Creates a variable.
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Transport protocol of a port.
public enum PortProtocol: String, CaseIterable, Hashable, Sendable {
    case tcp
    case udp
}

/// A container port published on the host.
public struct PortBinding: Hashable, Sendable {
    /// Host port; nil for a random free port.
    public var hostPort: Int?
    public var containerPort: Int
    public var proto: PortProtocol

    /// Creates a binding.
    public init(hostPort: Int?, containerPort: Int, proto: PortProtocol) {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
    }

    /// Docker's port key, e.g. `80/tcp`.
    public var key: String { "\(containerPort)/\(proto.rawValue)" }
}

/// A host folder or a named volume mounted into the container.
public struct VolumeBinding: Hashable, Sendable {
    /// Absolute host path, or a volume name.
    public var source: String
    /// Absolute path in the container.
    public var target: String
    public var readOnly: Bool

    /// Creates a binding.
    public init(source: String, target: String, readOnly: Bool) {
        self.source = source
        self.target = target
        self.readOnly = readOnly
    }

    /// Docker's bind string, e.g. `/Users/me/site:/usr/share/nginx/html:ro`.
    public var bind: String {
        "\(source):\(target)" + (readOnly ? ":ro" : "")
    }
}

/// When Docker restarts a container.
public enum RestartPolicy: String, CaseIterable, Hashable, Sendable {
    case no
    case always
    case unlessStopped = "unless-stopped"
    case onFailure = "on-failure"

    /// Name shown in the form.
    public var displayName: String {
        switch self {
        case .no: "Never"
        case .always: "Always"
        case .unlessStopped: "Unless stopped"
        case .onFailure: "On failure"
        }
    }
}

/// A container the engine created.
public struct CreatedContainer: Hashable, Sendable {
    public var id: String
    /// Warnings the engine returned with it.
    public var warnings: [String]

    /// Creates a value.
    public init(id: String, warnings: [String]) {
        self.id = id
        self.warnings = warnings
    }
}
