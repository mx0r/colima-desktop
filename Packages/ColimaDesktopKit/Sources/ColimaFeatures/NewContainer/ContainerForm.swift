import ColimaDomain
import Foundation

/// The New Container form as the user edits it: text fields and rows, turned into a
/// `ContainerSpec` by `validate(homeDirectory:)`.
public struct ContainerForm: Hashable, Sendable {
    /// A published port row.
    public struct PortRow: Identifiable, Hashable, Sendable {
        public let id: UUID
        /// Empty for a random host port.
        public var hostPort: String
        public var containerPort: String
        public var proto: PortProtocol

        /// Creates a row.
        public init(id: UUID = UUID(), hostPort: String = "", containerPort: String = "", proto: PortProtocol = .tcp) {
            self.id = id
            self.hostPort = hostPort
            self.containerPort = containerPort
            self.proto = proto
        }

        var isBlank: Bool { hostPort.trimmed.isEmpty && containerPort.trimmed.isEmpty }
    }

    /// An environment variable row.
    public struct EnvironmentRow: Identifiable, Hashable, Sendable {
        public let id: UUID
        public var name: String
        public var value: String

        /// Creates a row.
        public init(id: UUID = UUID(), name: String = "", value: String = "") {
            self.id = id
            self.name = name
            self.value = value
        }

        var isBlank: Bool { name.trimmed.isEmpty && value.isEmpty }
    }

    /// A volume row: a host folder or a named volume, mounted at a container path.
    public struct VolumeRow: Identifiable, Hashable, Sendable {
        public let id: UUID
        public var source: String
        public var target: String
        public var readOnly: Bool

        /// Creates a row.
        public init(id: UUID = UUID(), source: String = "", target: String = "", readOnly: Bool = false) {
            self.id = id
            self.source = source
            self.target = target
            self.readOnly = readOnly
        }

        var isBlank: Bool { source.trimmed.isEmpty && target.trimmed.isEmpty }
    }

    /// The field an issue belongs to.
    public enum Field: Hashable, Sendable {
        case image
        case tag
        case name
        case command
        case port(UUID)
        case environment(UUID)
        case volume(UUID)
    }

    /// A problem that keeps the form from being submitted.
    public struct Issue: Hashable, Sendable {
        public var field: Field
        public var message: String
    }

    /// Image as typed, e.g. `nginx`, `nginx:1.27` or `ghcr.io/owner/app`.
    public var image = ""
    /// Tag; empty uses the one in `image`, or `latest`.
    public var tag = ""
    /// Container name; empty lets Docker pick one.
    public var name = ""
    /// Command line replacing the image's default command; empty keeps it.
    public var command = ""
    public var ports: [PortRow] = []
    public var environment: [EnvironmentRow] = []
    public var volumes: [VolumeRow] = []
    public var restartPolicy: RestartPolicy = .no
    public var publishAllPorts = false
    public var startAfterCreating = true
    /// Pull the image even when it is already there (to get a newer `latest`).
    public var alwaysPull = false

    /// Creates an empty form.
    public init() {}

    /// The image with the tag field applied; nil while either is invalid.
    public var imageReference: ImageReference? {
        guard var reference = ImageReference(image) else { return nil }
        let tag = tag.trimmed
        guard !tag.isEmpty else { return reference }
        guard reference.tag == nil, reference.digest == nil, let tagged = ImageReference("\(reference.repository):\(tag)") else { return nil }
        reference = tagged
        return reference
    }

    /// The spec, or the issues that prevent it.
    ///
    /// - Parameter homeDirectory: Replaces a leading `~` in host paths.
    public func validate(homeDirectory: String) -> (spec: ContainerSpec?, issues: [Issue]) {
        var issues: [Issue] = []
        func issue(_ field: Field, _ message: String) { issues.append(Issue(field: field, message: message)) }

        let reference = validateImage(issue)

        let name = name.trimmed
        if !name.isEmpty, !ContainerSpec.isValidName(name) {
            issue(.name, "Use letters, digits, '_', '.' or '-': at least 2 characters, starting with a letter or digit.")
        }

        var command: [String]?
        if !self.command.trimmed.isEmpty {
            do {
                command = try ShellWords.split(self.command)
            } catch {
                issue(.command, error.localizedDescription)
            }
        }

        let ports = validatePorts(issue)
        let environment = validateEnvironment(issue)
        let volumes = validateVolumes(homeDirectory: homeDirectory, issue)

        guard issues.isEmpty, let reference else { return (nil, issues) }
        let spec = ContainerSpec(
            image: reference,
            name: name.isEmpty ? nil : name,
            command: command,
            environment: environment,
            ports: ports,
            volumes: volumes,
            restartPolicy: restartPolicy,
            publishAllPorts: publishAllPorts
        )
        return (spec, [])
    }

    // MARK: Parts

    private func validateImage(_ issue: (Field, String) -> Void) -> ImageReference? {
        guard !image.trimmed.isEmpty else {
            issue(.image, "Enter an image, for example nginx or ghcr.io/owner/app.")
            return nil
        }
        guard let reference = ImageReference(image) else {
            issue(.image, "This is not a valid image name.")
            return nil
        }
        let tag = tag.trimmed
        guard !tag.isEmpty else { return reference }
        if reference.tag != nil || reference.digest != nil {
            issue(.tag, "The image already names a tag. Remove one of them.")
            return nil
        }
        guard let tagged = imageReference else {
            issue(.tag, "This is not a valid tag.")
            return nil
        }
        return tagged
    }

    private func validatePorts(_ issue: (Field, String) -> Void) -> [PortBinding] {
        var bindings: [PortBinding] = []
        var usedHostPorts = Set<String>()
        for row in ports where !row.isBlank {
            guard let containerPort = Self.port(row.containerPort) else {
                issue(.port(row.id), "Enter the container port, a number from 1 to 65535.")
                continue
            }
            var hostPort: Int?
            if !row.hostPort.trimmed.isEmpty {
                guard let value = Self.port(row.hostPort) else {
                    issue(.port(row.id), "The host port must be a number from 1 to 65535.")
                    continue
                }
                let key = "\(value)/\(row.proto.rawValue)"
                guard usedHostPorts.insert(key).inserted else {
                    issue(.port(row.id), "Host port \(key) is used twice.")
                    continue
                }
                hostPort = value
            }
            bindings.append(PortBinding(hostPort: hostPort, containerPort: containerPort, proto: row.proto))
        }
        return bindings
    }

    private func validateEnvironment(_ issue: (Field, String) -> Void) -> [EnvironmentVariable] {
        var variables: [EnvironmentVariable] = []
        var names = Set<String>()
        for row in environment where !row.isBlank {
            let name = row.name.trimmed
            guard !name.isEmpty else {
                issue(.environment(row.id), "Enter a name.")
                continue
            }
            guard !name.contains("="), !name.contains(where: \.isWhitespace) else {
                issue(.environment(row.id), "A name cannot contain '=' or spaces.")
                continue
            }
            guard names.insert(name).inserted else {
                issue(.environment(row.id), "\(name) is set twice.")
                continue
            }
            variables.append(EnvironmentVariable(name: name, value: row.value))
        }
        return variables
    }

    private func validateVolumes(homeDirectory: String, _ issue: (Field, String) -> Void) -> [VolumeBinding] {
        var bindings: [VolumeBinding] = []
        var targets = Set<String>()
        for row in volumes where !row.isBlank {
            var source = row.source.trimmed
            if source == "~" || source.hasPrefix("~/") {
                source = homeDirectory + source.dropFirst()
            }
            guard source.hasPrefix("/") || ContainerSpec.isValidVolumeName(source) else {
                issue(.volume(row.id), source.isEmpty ? "Enter a host folder or a volume name." : "Use an absolute host path (/…, ~/…) or a volume name.")
                continue
            }
            let target = row.target.trimmed
            guard target.hasPrefix("/") else {
                issue(.volume(row.id), "The container path must start with /.")
                continue
            }
            guard targets.insert(target).inserted else {
                issue(.volume(row.id), "Two volumes use \(target).")
                continue
            }
            bindings.append(VolumeBinding(source: source, target: target, readOnly: row.readOnly))
        }
        return bindings
    }

    private static func port(_ text: String) -> Int? {
        guard let value = Int(text.trimmed), (1...65535).contains(value) else { return nil }
        return value
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
