import ColimaDomain
import Foundation

/// Builds the status menu from a snapshot. Pure and deterministic, so it is unit tested without AppKit.
public enum MenuModelBuilder {
    /// Builds the top-level menu items.
    ///
    /// - Parameter updates: The update entry; `.hidden` for builds without an updater.
    public static func build(_ snapshot: AppSnapshot, updates: UpdatesMenuItem = .hidden, now: Date = Date()) -> [MenuNode] {
        var nodes: [MenuNode] = [statusNode(snapshot)]
        nodes.append(informationNode(snapshot))
        nodes.append(profileNode(snapshot))
        nodes.append(.separator("sep.open"))
        nodes.append(MenuNode(id: "open", title: "Open Colima Desktop", image: .symbol("macwindow"), action: .openMainWindow))
        nodes.append(.separator("sep.vm"))
        nodes += vmActionNodes(snapshot)
        nodes.append(.separator("sep.containers"))
        nodes += containerSection(snapshot, now: now)
        nodes.append(.separator("sep.app"))
        nodes.append(MenuNode(id: "settings", title: "Settings…", action: .showSettings, keyEquivalent: ","))
        nodes.append(MenuNode(id: "about", title: "About Colima Desktop", action: .showAbout))
        if let node = updateNode(updates) { nodes.append(node) }
        nodes.append(.separator("sep.quit"))
        nodes.append(MenuNode(id: "quit", title: "Quit Colima Desktop", action: .quit, keyEquivalent: "q"))
        return nodes
    }

    /// "Check for Updates…", "Update to X…" once a background check found one, "Restart to Update
    /// to X" once one is downloaded, or nothing without an updater.
    static func updateNode(_ item: UpdatesMenuItem) -> MenuNode? {
        switch item {
        case .hidden:
            nil
        case .check:
            MenuNode(id: "updates", title: "Check for Updates…", action: .checkForUpdates)
        case .pending(let version):
            MenuNode(id: "updates", title: "Update to \(version)…", image: .symbol("arrow.down.circle.fill"), action: .checkForUpdates)
        case .readyToInstall(let version):
            MenuNode(id: "updates", title: "Restart to Update to \(version)", image: .symbol("arrow.down.circle.fill"), action: .installUpdate)
        }
    }

    // MARK: Status

    static func statusNode(_ snapshot: AppSnapshot) -> MenuNode {
        let summary = StatusSummary.make(snapshot)
        return MenuNode(id: "status", kind: .banner, title: summary.title, subtitle: summary.subtitle, image: .dot(summary.color), isEnabled: false)
    }

    // MARK: Information

    static func informationNode(_ snapshot: AppSnapshot) -> MenuNode {
        var rows: [MenuNode] = []
        for (index, section) in InformationSections.build(snapshot).enumerated() {
            if index > 0 { rows.append(.separator("info.sep.\(section.id)")) }
            rows.append(.header("info.\(section.id)", section.title))
            rows += section.items.map { item in
                item.label.map { MenuNode.value(item.id, $0, item.value) } ?? .note(item.id, item.value)
            }
        }
        return MenuNode(id: MenuNodeID.information, title: "Information", image: .symbol("info.circle"), children: rows)
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
                image: .dot(status?.statusColor ?? .gray),
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

    /// Containers listed in the main menu; more go into a submenu. Counts running and stopped ones,
    /// since both take a row.
    static let inlineContainerLimit = 6

    static func containerSection(_ snapshot: AppSnapshot, now: Date) -> [MenuNode] {
        let state = ContainerListState.make(snapshot)
        switch state {
        case .vmNotRunning: return [.note("containers.none", state.message)]
        case .noDockerRuntime: return [.note("containers.runtime", state.message)]
        case .connecting: return [.note("containers.connecting", state.message)]
        case .unreachable(let message):
            return [MenuNode(id: "containers.unreachable", title: state.message, subtitle: message, image: .dot(.red), isEnabled: false)]
        case .ready: break
        }

        var nodes: [MenuNode] = []
        if let error = snapshot.containerActionError {
            nodes.append(MenuNode(id: "containers.error", title: "Last action failed", subtitle: error, image: .symbol("exclamationmark.triangle"), isEnabled: false))
        }
        // Set apart below the list, so it does not read as one more container.
        let newContainer: [MenuNode] = [
            .separator("sep.new"),
            MenuNode(id: "containers.new", title: "New Container…", image: .symbol("plus.circle"), action: .newContainer),
        ]
        guard !snapshot.containers.isEmpty else {
            return nodes + [.note("containers.empty", "No containers")] + newContainer
        }
        let running = snapshot.containers.filter { $0.state == .running }.count
        let title = "Containers (\(running) of \(snapshot.containers.count) running)"
        var list: [MenuNode] = []
        for group in ContainerGrouping.group(snapshot.containers) {
            list.append(.header("group.\(group.id)", group.project ?? "Other"))
            list += group.containers.map { containerNode($0, snapshot: snapshot, now: now) }
        }
        // A long list moves into a submenu, so the main menu keeps a fixed size.
        if snapshot.containers.count > inlineContainerLimit {
            nodes.append(MenuNode(id: "containers.menu", title: title, image: .symbol("shippingbox"), children: list))
        } else {
            nodes.append(.header("containers.header", title))
            nodes += list
        }
        return nodes + newContainer
    }

    static func containerNode(_ container: Container, snapshot: AppSnapshot, now: Date) -> MenuNode {
        let commands = ContainerCommands.available(for: container, in: snapshot)
        let pending = commands.pending
        let name = container.name
        let prefix = "container.\(container.id)"

        var children: [MenuNode] = ContainerFacts.rows(container, now: now).map { item in
            .value("\(prefix).\(item.id)", item.label ?? "", item.value)
        }
        // One port fits in a row; more get their own submenu with their Open items.
        let groupsPorts = container.ports.count > 1
        if groupsPorts {
            children.append(portsNode(container, prefix: prefix))
        } else if let port = container.ports.first {
            children.append(.value("\(prefix).ports", "Ports", port.displayText))
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
            isEnabled: commands.canOpenTerminal,
            action: .openTerminal(containerID: container.id, name: name)
        ))
        let openNodes = openPortNodes(container, prefix: prefix)
        if !groupsPorts, !openNodes.isEmpty {
            children.append(.separator("\(prefix).sep.ports"))
            children += openNodes
        }
        children.append(.separator("\(prefix).sep.actions"))
        if container.state.isAlive {
            children.append(MenuNode(id: "\(prefix).stop", title: "Stop…", image: .symbol("stop.fill"), isEnabled: commands.canStop,
                                     action: .container(.stop, containerID: container.id, name: name)))
            children.append(MenuNode(id: "\(prefix).restart", title: "Restart…", image: .symbol("arrow.clockwise"), isEnabled: commands.canRestart,
                                     action: .container(.restart, containerID: container.id, name: name)))
        } else {
            children.append(MenuNode(id: "\(prefix).start", title: "Start", image: .symbol("play.fill"), isEnabled: commands.canStart,
                                     action: .container(.start, containerID: container.id, name: name)))
        }
        children.append(.separator("\(prefix).sep.delete"))
        children.append(MenuNode(
            id: "\(prefix).delete",
            title: "Delete…",
            image: .symbol("trash"),
            isEnabled: commands.canDelete,
            action: .container(.remove, containerID: container.id, name: name),
            toolTip: container.state.isAlive ? "Stop the container first" : nil
        ))

        let subtitle: String = if let pending {
            "\(pending.progressText)…"
        } else {
            [Format.status(of: container, now: now), container.image].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return MenuNode(
            id: prefix,
            title: name,
            subtitle: subtitle,
            image: .dot(pending != nil ? .yellow : container.state.statusColor),
            isDimmed: !container.state.isAlive,
            indentation: 1,
            children: children
        )
    }

    /// "Ports (N)": each mapping (click to copy), then an Open item per browsable port.
    static func portsNode(_ container: Container, prefix: String) -> MenuNode {
        var rows = container.ports.enumerated().map { index, port in
            MenuNode(id: "\(prefix).port.\(index)", title: port.displayText, action: .copy(port.displayText), toolTip: "Click to copy")
        }
        let openNodes = openPortNodes(container, prefix: prefix)
        if !openNodes.isEmpty {
            rows.append(.separator("\(prefix).ports.sep"))
            rows += openNodes
        }
        return MenuNode(id: "\(prefix).ports", title: "Ports (\(container.ports.count))", image: .symbol("network"), children: rows)
    }

    /// "Open localhost:PORT" for each published TCP port.
    static func openPortNodes(_ container: Container, prefix: String) -> [MenuNode] {
        container.browsablePorts.compactMap { port in
            guard let url = port.browsableURL, let publicPort = port.publicPort else { return nil }
            return MenuNode(id: "\(prefix).open.\(publicPort)", title: "Open localhost:\(publicPort)", image: .symbol("safari"), action: .openURL(url))
        }
    }

}

extension ContainerAction {
    /// Progress text, e.g. "Stopping".
    public var progressText: String {
        switch self {
        case .start: "Starting"
        case .stop: "Stopping"
        case .restart: "Restarting"
        case .remove: "Deleting"
        }
    }
}
