import Foundation

/// Containers that belong together in the menu.
public struct ContainerGroup: Identifiable, Hashable, Sendable {
    /// Compose project name; nil for standalone containers.
    public var project: String?
    /// Members, running ones first.
    public var containers: [Container]

    /// Stable ID derived from the project.
    public var id: String { project.map { "project:\($0)" } ?? "standalone" }

    /// Creates a group.
    public init(project: String?, containers: [Container]) {
        self.project = project
        self.containers = containers
    }
}

/// Groups containers by Compose project.
public enum ContainerGrouping {
    /// Groups containers by their Compose project label.
    ///
    /// Projects are sorted by name; standalone containers come last.
    /// Inside a group, alive containers come first, then by name.
    public static func group(_ containers: [Container]) -> [ContainerGroup] {
        let byProject = Dictionary(grouping: containers, by: \.composeProject)
        let projects = byProject.keys.compactMap { $0 }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var groups = projects.map { ContainerGroup(project: $0, containers: sortMembers(byProject[$0] ?? [])) }
        if let standalone = byProject[nil], !standalone.isEmpty {
            groups.append(ContainerGroup(project: nil, containers: sortMembers(standalone)))
        }
        return groups
    }

    private static func sortMembers(_ containers: [Container]) -> [Container] {
        containers.sorted { lhs, rhs in
            if lhs.state.isAlive != rhs.state.isAlive { return lhs.state.isAlive }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
