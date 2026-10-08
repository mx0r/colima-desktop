import ColimaDomain
import Foundation

// Content the status menu and the main window both show, built once so they never disagree.

/// The Colima status line: title, detail and color.
public struct StatusSummary: Hashable, Sendable {
    public var title: String
    public var subtitle: String
    public var color: StatusColor

    /// Creates a summary.
    public init(title: String, subtitle: String, color: StatusColor) {
        self.title = title
        self.subtitle = subtitle
        self.color = color
    }

    /// The summary for a snapshot.
    public static func make(_ snapshot: AppSnapshot) -> StatusSummary {
        let profile = snapshot.selectedProfile
        let (title, color): (String, StatusColor) = switch snapshot.lifecycle.phase {
        case .loading: ("Colima: checking…", .gray)
        case .colimaMissing: ("Colima not found", .red)
        case .operating(.start): ("Colima is starting…", .yellow)
        case .operating(.stop): ("Colima is stopping…", .yellow)
        case .operating(.restart): ("Colima is restarting…", .yellow)
        case .failed(let operation, _): ("Colima: \(operation.noun.lowercased()) failed", .red)
        case .status(let status): ("Colima is \(status.displayName.lowercased())", status.statusColor)
        }

        var subtitle = "Profile: \(profile)"
        switch snapshot.lifecycle.phase {
        case .colimaMissing:
            subtitle = "Install colima or set its path in Settings"
        case .operating:
            if let progress = snapshot.progressMessage { subtitle = progress }
        case .failed(_, let message):
            subtitle = message
        case .status(.running):
            if case .unreachable(let message) = snapshot.docker {
                subtitle = "Profile: \(profile) · Docker unreachable: \(message)"
            } else if let instance = snapshot.selectedInstance {
                subtitle = "Profile: \(profile) · \(instance.cpus) CPU · \(Format.memory(instance.memoryBytes)) · \(instance.arch)"
            }
        default:
            if let error = snapshot.listError { subtitle = error }
        }
        return StatusSummary(title: title, subtitle: subtitle, color: color)
    }
}

/// One "label: value" fact, or a note when `label` is nil ("Loading…").
public struct InfoItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String?
    public var value: String

    /// Creates an item.
    public init(id: String, label: String?, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

/// A titled group of facts.
public struct InfoSection: Identifiable, Hashable, Sendable {
    /// Short key, e.g. `colima` or `usage`.
    public var id: String
    public var title: String
    public var items: [InfoItem]

    /// Creates a section.
    public init(id: String, title: String, items: [InfoItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

/// Facts about the environment: Colima, VM usage, Docker and its disk usage. The Information
/// submenu and the main window's right side.
public enum InformationSections {
    /// Sections for a snapshot; VM usage and Docker only while the VM runs.
    public static func build(_ snapshot: AppSnapshot) -> [InfoSection] {
        func value(_ id: String, _ label: String, _ value: String) -> InfoItem { InfoItem(id: id, label: label, value: value) }
        func note(_ id: String, _ text: String) -> InfoItem { InfoItem(id: id, label: nil, value: text) }

        var colima: [InfoItem] = [value("info.profile", "Profile", snapshot.selectedProfile.rawValue)]
        if let version = snapshot.colimaVersion {
            colima.append(value("info.version", "Version", version))
        }
        if let instance = snapshot.selectedInstance {
            colima.append(value("info.status", "Status", instance.status.displayName))
            colima.append(value("info.arch", "Architecture", instance.arch))
            if let runtime = instance.runtime { colima.append(value("info.runtime", "Runtime", runtime)) }
            colima.append(value("info.cpus", "CPUs", String(instance.cpus)))
            colima.append(value("info.memory", "Memory", Format.memory(instance.memoryBytes)))
            colima.append(value("info.disk", "Disk", Format.memory(instance.diskBytes)))
            if let address = instance.address { colima.append(value("info.address", "Address", address)) }
        } else {
            colima.append(note("info.missing", "Profile not created yet"))
        }
        if let details = snapshot.details {
            colima.append(value("info.driver", "Driver", details.driver))
            colima.append(value("info.mount", "Mount type", details.mountType))
            colima.append(value("info.kubernetes", "Kubernetes", details.kubernetes ? "enabled" : "disabled"))
        }
        if let socket = snapshot.socketPath {
            colima.append(value("info.socket", "Docker socket", socket))
        }
        var sections = [InfoSection(id: "colima", title: "Colima", items: colima)]
        guard snapshot.lifecycle.observed == .running else { return sections }

        var usage: [InfoItem] = []
        if let vm = snapshot.usage {
            usage.append(value("info.load", "Load average", Format.load(vm.loadAverage)))
            usage.append(value("info.mem.used", "Memory used", Format.usage(used: vm.memoryUsedBytes, total: vm.memoryTotalBytes)))
            for disk in vm.disks {
                usage.append(value("info.disk.\(disk.mountPoint)", "Disk \(disk.mountPoint)", Format.usage(used: disk.usedBytes, total: disk.totalBytes)))
            }
        } else {
            usage.append(note("info.usage.loading", "Loading…"))
        }
        sections.append(InfoSection(id: "usage", title: "VM usage", items: usage))

        guard snapshot.docker != .notApplicable else { return sections }
        var docker: [InfoItem] = []
        if let engine = snapshot.engine {
            docker.append(value("info.engine", "Engine", "\(engine.serverVersion) (API \(engine.apiVersion))"))
            docker.append(value("info.os", "OS", engine.operatingSystem))
            docker.append(value("info.kernel", "Kernel", engine.kernelVersion))
            docker.append(value("info.containers", "Containers", "\(engine.containersRunning) running, \(engine.containersTotal) total"))
            docker.append(value("info.images", "Images", String(engine.images)))
            docker.append(value("info.driver.storage", "Storage driver", engine.storageDriver))
        } else {
            docker.append(note("info.docker.loading", "Loading…"))
        }
        sections.append(InfoSection(id: "docker", title: "Docker", items: docker))

        if let disk = snapshot.diskUsage {
            func row(_ id: String, _ label: String, _ category: DiskUsageSummary.Category) -> InfoItem {
                value(
                    "info.df.\(id)",
                    label,
                    "\(Format.fileSize(category.sizeBytes)) · \(category.count) total, \(category.active) active · \(Format.fileSize(category.reclaimableBytes)) reclaimable"
                )
            }
            sections.append(InfoSection(id: "df", title: "Docker disk usage", items: [
                row("images", "Images", disk.images),
                row("containers", "Containers", disk.containers),
                row("volumes", "Volumes", disk.volumes),
                row("cache", "Build cache", disk.buildCache),
            ]))
        }
        return sections
    }
}

/// The first facts about a container: image, status, ID, created and Compose service.
public enum ContainerFacts {
    /// Facts with short IDs (`image`, `status`, …); the menu prefixes them with the container's node ID.
    public static func rows(_ container: Container, now: Date = Date()) -> [InfoItem] {
        var rows = [
            InfoItem(id: "image", label: "Image", value: container.image),
            InfoItem(id: "status", label: "Status", value: Format.status(of: container, now: now)),
            InfoItem(id: "id", label: "ID", value: container.shortID),
            InfoItem(id: "created", label: "Created", value: "\(Format.dateTime(container.created)) (\(Format.duration(now.timeIntervalSince(container.created))) ago)"),
        ]
        if let service = container.composeService {
            rows.append(InfoItem(id: "service", label: "Service", value: service))
        }
        return rows
    }
}

/// What can be done with a container now.
public struct ContainerCommands: Hashable, Sendable {
    public var canStart: Bool
    public var canStop: Bool
    public var canRestart: Bool
    public var canShowLogs: Bool
    public var canOpenTerminal: Bool
    /// Only stopped containers can be deleted.
    public var canDelete: Bool
    /// Action in progress; it blocks the other actions.
    public var pending: ContainerAction?

    /// Creates a value.
    public init(canStart: Bool, canStop: Bool, canRestart: Bool, canShowLogs: Bool, canOpenTerminal: Bool, canDelete: Bool, pending: ContainerAction?) {
        self.canStart = canStart
        self.canStop = canStop
        self.canRestart = canRestart
        self.canShowLogs = canShowLogs
        self.canOpenTerminal = canOpenTerminal
        self.canDelete = canDelete
        self.pending = pending
    }

    /// Commands for a container in a snapshot.
    public static func available(for container: Container, in snapshot: AppSnapshot) -> ContainerCommands {
        let pending = snapshot.containerOperations[container.id]
        let idle = pending == nil
        let alive = container.state.isAlive
        return ContainerCommands(
            canStart: idle && !alive,
            canStop: idle && alive,
            canRestart: idle && alive,
            canShowLogs: true,
            canOpenTerminal: container.state == .running,
            canDelete: idle && !alive,
            pending: pending
        )
    }
}

/// Whether containers can be listed, and why not.
public enum ContainerListState: Hashable, Sendable {
    case vmNotRunning
    case noDockerRuntime
    case connecting
    case unreachable(String)
    case ready

    /// The state for a snapshot.
    public static func make(_ snapshot: AppSnapshot) -> ContainerListState {
        guard snapshot.lifecycle.observed == .running else { return .vmNotRunning }
        switch snapshot.docker {
        case .notApplicable: return snapshot.details != nil ? .noDockerRuntime : .connecting
        case .connecting: return .connecting
        case .unreachable(let message): return .unreachable(message)
        case .reachable: return .ready
        }
    }

    /// What to show instead of the list.
    public var message: String {
        switch self {
        case .vmNotRunning: "Containers are available while Colima runs"
        case .noDockerRuntime: "No Docker runtime in this profile"
        case .connecting: "Connecting to Docker…"
        case .unreachable: "Docker not reachable"
        case .ready: ""
        }
    }
}

extension VMStatus {
    /// Color of the status dot.
    public var statusColor: StatusColor {
        switch self {
        case .running: .green
        case .stopped, .uninitialized: .gray
        case .installing: .yellow
        case .broken: .red
        case .unknown: .orange
        }
    }
}

extension ContainerState {
    /// Color of the status dot.
    public var statusColor: StatusColor {
        switch self {
        case .running: .green
        case .paused, .restarting, .removing: .yellow
        case .dead: .red
        case .created, .exited: .gray
        case .unknown: .orange
        }
    }
}

/// Commands of the app's menu bar (shown while a window is open).
public enum MainMenuCommand: Hashable, Sendable, CaseIterable {
    case startVM, stopVM, restartVM, refresh
    case startContainer, stopContainer, restartContainer, showLogs, openTerminal, deleteContainer
    case newContainer
}

/// Turns menu bar commands into actions for the current state; nil disables the item.
public enum MainMenuState {
    /// The action for a command, or nil when it is not possible now. Container commands act on the
    /// container selected in the main window.
    public static func action(for command: MainMenuCommand, snapshot: AppSnapshot, selectedContainerID: String?) -> MenuAction? {
        let lifecycle = snapshot.lifecycle
        switch command {
        case .startVM: return lifecycle.canStart ? .startVM : nil
        case .stopVM: return lifecycle.canStop ? .stopVM : nil
        case .restartVM: return lifecycle.canRestart ? .restartVM : nil
        case .refresh: return .refresh
        case .newContainer: return snapshot.docker == .reachable ? .newContainer : nil
        default: break
        }
        guard ContainerListState.make(snapshot) == .ready,
              let id = selectedContainerID,
              let container = snapshot.containers.first(where: { $0.id == id }) else { return nil }
        let commands = ContainerCommands.available(for: container, in: snapshot)
        let name = container.name
        switch command {
        case .startContainer: return commands.canStart ? .container(.start, containerID: id, name: name) : nil
        case .stopContainer: return commands.canStop ? .container(.stop, containerID: id, name: name) : nil
        case .restartContainer: return commands.canRestart ? .container(.restart, containerID: id, name: name) : nil
        case .showLogs: return commands.canShowLogs ? .showLogs(containerID: id, name: name) : nil
        case .openTerminal: return commands.canOpenTerminal ? .openTerminal(containerID: id, name: name) : nil
        case .deleteContainer: return commands.canDelete ? .container(.remove, containerID: id, name: name) : nil
        default: return nil
        }
    }
}
