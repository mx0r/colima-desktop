import ColimaDomain
import Foundation

/// Builds the status menu from a snapshot. Pure and deterministic, so it is unit tested without AppKit.
public enum MenuModelBuilder {
    /// Builds the top-level menu items.
    public static func build(_ snapshot: AppSnapshot, now: Date = Date()) -> [MenuNode] {
        var nodes: [MenuNode] = [statusNode(snapshot)]
        nodes.append(informationNode(snapshot))
        nodes.append(profileNode(snapshot))
        nodes.append(.separator("sep.vm"))
        nodes += vmActionNodes(snapshot)
        nodes.append(.separator("sep.containers"))
        nodes += containerSection(snapshot, now: now)
        nodes.append(.separator("sep.app"))
        nodes.append(MenuNode(id: "settings", title: "Settings…", action: .showSettings, keyEquivalent: ","))
        nodes.append(MenuNode(id: "about", title: "About Colima Desktop", action: .showAbout))
        nodes.append(.separator("sep.quit"))
        nodes.append(MenuNode(id: "quit", title: "Quit Colima Desktop", action: .quit, keyEquivalent: "q"))
        return nodes
    }

    // MARK: Status

    static func statusNode(_ snapshot: AppSnapshot) -> MenuNode {
        let profile = snapshot.selectedProfile
        let (title, color): (String, StatusColor) = switch snapshot.lifecycle.phase {
        case .loading: ("Colima: checking…", .gray)
        case .colimaMissing: ("Colima not found", .red)
        case .operating(.start): ("Colima is starting…", .yellow)
        case .operating(.stop): ("Colima is stopping…", .yellow)
        case .operating(.restart): ("Colima is restarting…", .yellow)
        case .failed(let operation, _): ("Colima: \(operation.noun.lowercased()) failed", .red)
        case .status(let status): ("Colima is \(status.displayName.lowercased())", color(for: status))
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
        return MenuNode(id: "status", kind: .banner, title: title, subtitle: subtitle, image: .dot(color), isEnabled: false)
    }

    private static func color(for status: VMStatus) -> StatusColor {
        switch status {
        case .running: .green
        case .stopped, .uninitialized: .gray
        case .installing: .yellow
        case .broken: .red
        case .unknown: .orange
        }
    }

    // MARK: Information

    static func informationNode(_ snapshot: AppSnapshot) -> MenuNode {
        var rows: [MenuNode] = [.header("info.colima", "Colima")]
        let profile = snapshot.selectedProfile
        rows.append(.value("info.profile", "Profile", profile.rawValue))
        if let version = snapshot.colimaVersion {
            rows.append(.value("info.version", "Version", version))
        }
        if let instance = snapshot.selectedInstance {
            rows.append(.value("info.status", "Status", instance.status.displayName))
            rows.append(.value("info.arch", "Architecture", instance.arch))
            if let runtime = instance.runtime { rows.append(.value("info.runtime", "Runtime", runtime)) }
            rows.append(.value("info.cpus", "CPUs", String(instance.cpus)))
            rows.append(.value("info.memory", "Memory", Format.memory(instance.memoryBytes)))
            rows.append(.value("info.disk", "Disk", Format.memory(instance.diskBytes)))
            if let address = instance.address { rows.append(.value("info.address", "Address", address)) }
        } else {
            rows.append(.note("info.missing", "Profile not created yet"))
        }
        if let details = snapshot.details {
            rows.append(.value("info.driver", "Driver", details.driver))
            rows.append(.value("info.mount", "Mount type", details.mountType))
            rows.append(.value("info.kubernetes", "Kubernetes", details.kubernetes ? "enabled" : "disabled"))
        }
        if let socket = snapshot.socketPath {
            rows.append(.value("info.socket", "Docker socket", socket))
        }

        if snapshot.lifecycle.observed == .running {
            rows.append(.separator("info.sep.usage"))
            rows.append(.header("info.usage", "VM usage"))
            if let usage = snapshot.usage {
                rows.append(.value("info.load", "Load average", Format.load(usage.loadAverage)))
                rows.append(.value("info.mem.used", "Memory used", Format.usage(used: usage.memoryUsedBytes, total: usage.memoryTotalBytes)))
                for disk in usage.disks {
                    rows.append(.value("info.disk.\(disk.mountPoint)", "Disk \(disk.mountPoint)", Format.usage(used: disk.usedBytes, total: disk.totalBytes)))
                }
            } else {
                rows.append(.note("info.usage.loading", "Loading…"))
            }

            if snapshot.docker != .notApplicable {
                rows.append(.separator("info.sep.docker"))
                rows.append(.header("info.docker", "Docker"))
                if let engine = snapshot.engine {
                    rows.append(.value("info.engine", "Engine", "\(engine.serverVersion) (API \(engine.apiVersion))"))
                    rows.append(.value("info.os", "OS", engine.operatingSystem))
                    rows.append(.value("info.kernel", "Kernel", engine.kernelVersion))
                    rows.append(.value("info.containers", "Containers", "\(engine.containersRunning) running, \(engine.containersTotal) total"))
                    rows.append(.value("info.images", "Images", String(engine.images)))
                    rows.append(.value("info.driver.storage", "Storage driver", engine.storageDriver))
                } else {
                    rows.append(.note("info.docker.loading", "Loading…"))
                }
                if let disk = snapshot.diskUsage {
                    rows.append(.separator("info.sep.df"))
                    rows.append(.header("info.df", "Docker disk usage"))
                    rows.append(dfRow("images", "Images", disk.images))
                    rows.append(dfRow("containers", "Containers", disk.containers))
                    rows.append(dfRow("volumes", "Volumes", disk.volumes))
                    rows.append(dfRow("cache", "Build cache", disk.buildCache))
                }
            }
        }
        return MenuNode(id: MenuNodeID.information, title: "Information", image: .symbol("info.circle"), children: rows)
    }

    private static func dfRow(_ id: String, _ label: String, _ category: DiskUsageSummary.Category) -> MenuNode {
        .value(
            "info.df.\(id)",
            label,
            "\(Format.fileSize(category.sizeBytes)) · \(category.count) total, \(category.active) active · \(Format.fileSize(category.reclaimableBytes)) reclaimable"
        )
    }

    // MARK: Profiles

    static func profileNode(_ snapshot: AppSnapshot) -> MenuNode {
        let canSwitch = snapshot.lifecycle.operation == nil
        var profiles = snapshot.profiles.map(\.profile)
        if !profiles.contains(snapshot.selectedProfile) {
            profiles.append(snapshot.selectedProfile)
            profiles.sort()
        }
        let children = profiles.map { profile in
            let status = snapshot.profiles.first { $0.profile == profile }?.status
            return MenuNode(
                id: "profile.\(profile.rawValue)",
                title: profile.rawValue,
                subtitle: status?.displayName ?? VMStatus.uninitialized.displayName,
                image: .dot(status.map(color(for:)) ?? .gray),
                isEnabled: canSwitch,
                isChecked: profile == snapshot.selectedProfile,
                action: .selectProfile(profile)
            )
        }
        return MenuNode(
            id: "profiles",
            title: "Profile: \(snapshot.selectedProfile)",
            image: .symbol("square.stack.3d.up"),
            children: children
        )
    }

    // MARK: VM actions

    static func vmActionNodes(_ snapshot: AppSnapshot) -> [MenuNode] {
        let lifecycle = snapshot.lifecycle
        return [
            MenuNode(id: "vm.start", title: "Start", image: .symbol("play.fill"), isEnabled: lifecycle.canStart, action: .startVM),
            MenuNode(id: "vm.stop", title: "Stop…", image: .symbol("stop.fill"), isEnabled: lifecycle.canStop, action: .stopVM),
            MenuNode(id: "vm.restart", title: "Restart…", image: .symbol("arrow.clockwise"), isEnabled: lifecycle.canRestart, action: .restartVM),
        ]
    }

    // MARK: Containers

    static func containerSection(_ snapshot: AppSnapshot, now: Date) -> [MenuNode] {
        guard snapshot.lifecycle.observed == .running else {
            return [.note("containers.none", "Containers are available while Colima runs")]
        }
        switch snapshot.docker {
        case .notApplicable:
            if snapshot.details != nil {
                return [.note("containers.runtime", "No Docker runtime in this profile")]
            }
            return [.note("containers.connecting", "Connecting to Docker…")]
        case .connecting:
            return [.note("containers.connecting", "Connecting to Docker…")]
        case .unreachable(let message):
            return [MenuNode(id: "containers.unreachable", title: "Docker not reachable", subtitle: message, image: .dot(.red), isEnabled: false)]
        case .reachable:
            break
        }

        var nodes: [MenuNode] = []
        if let error = snapshot.containerActionError {
            nodes.append(MenuNode(id: "containers.error", title: "Last action failed", subtitle: error, image: .symbol("exclamationmark.triangle"), isEnabled: false))
        }
        guard !snapshot.containers.isEmpty else {
            return nodes + [.note("containers.empty", "No containers")]
        }
        let running = snapshot.containers.filter { $0.state == .running }.count
        nodes.append(.header("containers.header", "Containers (\(running) of \(snapshot.containers.count) running)"))
        for group in ContainerGrouping.group(snapshot.containers) {
            nodes.append(.header("group.\(group.id)", group.project ?? "Other"))
            nodes += group.containers.map { containerNode($0, snapshot: snapshot, now: now) }
        }
        return nodes
    }

    static func containerNode(_ container: Container, snapshot: AppSnapshot, now: Date) -> MenuNode {
        let pending = snapshot.containerOperations[container.id]
        let idle = pending == nil
        let name = container.name
        let isRunning = container.state == .running
        let prefix = "container.\(container.id)"

        var children: [MenuNode] = [
            .value("\(prefix).image", "Image", container.image),
            .value("\(prefix).status", "Status", container.statusText.isEmpty ? container.state.displayName : container.statusText),
            .value("\(prefix).id", "ID", container.shortID),
            .value("\(prefix).created", "Created", "\(Format.dateTime(container.created)) (\(Format.relative(container.created, now: now)))"),
        ]
        if let service = container.composeService {
            children.append(.value("\(prefix).service", "Service", service))
        }
        if !container.ports.isEmpty {
            children.append(.value("\(prefix).ports", "Ports", container.ports.map(\.displayText).joined(separator: ", ")))
        }
        children.append(.separator("\(prefix).sep.tools"))
        children.append(MenuNode(
            id: "\(prefix).logs",
            title: "Logs…",
            image: .symbol("doc.text.magnifyingglass"),
            action: .showLogs(containerID: container.id, name: name)
        ))
        children.append(MenuNode(
            id: "\(prefix).terminal",
            title: "Terminal…",
            image: .symbol("terminal"),
            isEnabled: isRunning,
            action: .openTerminal(containerID: container.id, name: name)
        ))
        let browsable = container.browsablePorts
        if !browsable.isEmpty {
            children.append(.separator("\(prefix).sep.ports"))
            for port in browsable {
                guard let url = port.browsableURL, let publicPort = port.publicPort else { continue }
                children.append(MenuNode(
                    id: "\(prefix).open.\(publicPort)",
                    title: "Open localhost:\(publicPort)",
                    image: .symbol("safari"),
                    action: .openURL(url)
                ))
            }
        }
        children.append(.separator("\(prefix).sep.actions"))
        if container.state.isAlive {
            children.append(MenuNode(id: "\(prefix).stop", title: "Stop…", image: .symbol("stop.fill"), isEnabled: idle,
                                     action: .container(.stop, containerID: container.id, name: name)))
            children.append(MenuNode(id: "\(prefix).restart", title: "Restart…", image: .symbol("arrow.clockwise"), isEnabled: idle,
                                     action: .container(.restart, containerID: container.id, name: name)))
        } else {
            children.append(MenuNode(id: "\(prefix).start", title: "Start", image: .symbol("play.fill"), isEnabled: idle,
                                     action: .container(.start, containerID: container.id, name: name)))
        }
        children.append(.separator("\(prefix).sep.delete"))
        children.append(MenuNode(
            id: "\(prefix).delete",
            title: "Delete…",
            image: .symbol("trash"),
            isEnabled: idle && !container.state.isAlive,
            action: .container(.remove, containerID: container.id, name: name),
            toolTip: container.state.isAlive ? "Stop the container first" : nil
        ))

        let subtitle: String = if let pending {
            "\(pending.progressText)…"
        } else {
            [container.statusText, container.image].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return MenuNode(
            id: prefix,
            title: name,
            subtitle: subtitle,
            image: .dot(pending != nil ? .yellow : color(for: container.state)),
            isDimmed: !container.state.isAlive,
            indentation: 1,
            children: children
        )
    }

    private static func color(for state: ContainerState) -> StatusColor {
        switch state {
        case .running: .green
        case .paused, .restarting, .removing: .yellow
        case .dead: .red
        case .created, .exited: .gray
        case .unknown: .orange
        }
    }
}

extension ContainerAction {
    /// Progress text, e.g. "Stopping".
    var progressText: String {
        switch self {
        case .start: "Starting"
        case .stop: "Stopping"
        case .restart: "Restarting"
        case .remove: "Deleting"
        }
    }
}
