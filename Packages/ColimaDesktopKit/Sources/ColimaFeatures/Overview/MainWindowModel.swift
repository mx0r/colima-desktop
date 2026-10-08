import ColimaDomain
import Foundation
import Observation

/// The main window: containers on the left (filterable, expandable), the environment on the right,
/// VM controls on top. Reads the store; actions go to the router like menu clicks.
@MainActor
@Observable
public final class MainWindowModel {
    /// Inspect details of an expanded container.
    public enum DetailsState: Hashable, Sendable {
        case loading
        case loaded(ContainerDetails)
        case failed(String)
    }

    /// Filter text: matches name, image and Compose project.
    public var filter = ""
    /// Container the menu bar's Container commands act on.
    public var selectedContainerID: String?
    public private(set) var expanded: Set<String> = []
    public private(set) var details: [String: DetailsState] = [:]

    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private let onAction: (MenuAction) -> Void
    /// State and start time the loaded details belong to; details load again when they differ.
    @ObservationIgnored private var detailsKeys: [String: DetailsKey] = [:]

    private struct DetailsKey: Equatable {
        var state: ContainerState
        var startedAt: Date?
    }

    /// Creates the model.
    ///
    /// - Parameter onAction: Runs an action like a menu click (confirmations included).
    public init(store: AppStore, onAction: @escaping (MenuAction) -> Void) {
        self.store = store
        self.onAction = onAction
    }

    // MARK: Content

    public var snapshot: AppSnapshot { store.snapshot }
    public var status: StatusSummary { StatusSummary.make(store.snapshot) }
    public var information: [InfoSection] { InformationSections.build(store.snapshot) }
    public var listState: ContainerListState { ContainerListState.make(store.snapshot) }

    /// Containers matching the filter, grouped by Compose project like the menu.
    public var groups: [ContainerGroup] {
        let term = filter.trimmingCharacters(in: .whitespaces)
        let containers = term.isEmpty ? store.snapshot.containers : store.snapshot.containers.filter { container in
            [container.name, container.image, container.composeProject ?? ""].contains { $0.localizedCaseInsensitiveContains(term) }
        }
        return ContainerGrouping.group(containers)
    }

    /// The same containers as `groups`, in one list: projects together, standalone ones last.
    public var containers: [Container] {
        groups.flatMap(\.containers)
    }

    /// One button for the VM: Stop while it can be stopped, Start otherwise.
    public var vmToggle: MainMenuCommand {
        store.snapshot.lifecycle.canStop ? .stopVM : .startVM
    }

    /// Profiles to pick from, including the selected one.
    public var profiles: [ProfileName] {
        var names = store.snapshot.profiles.map(\.profile)
        if !names.contains(store.snapshot.selectedProfile) { names.append(store.snapshot.selectedProfile) }
        return names.sorted()
    }

    /// Whether the profile can be switched now (not during a VM operation).
    public var canSwitchProfile: Bool { store.snapshot.lifecycle.operation == nil }

    /// Commands for a container.
    public func commands(for container: Container) -> ContainerCommands {
        ContainerCommands.available(for: container, in: store.snapshot)
    }

    /// The action of a menu bar command, or nil when it is not possible now.
    public func action(for command: MainMenuCommand) -> MenuAction? {
        MainMenuState.action(for: command, snapshot: store.snapshot, selectedContainerID: selectedContainerID)
    }

    // MARK: Actions

    /// Runs an action like a menu click.
    public func perform(_ action: MenuAction) {
        onAction(action)
    }

    /// Switches the profile.
    public func selectProfile(_ profile: ProfileName) {
        onAction(.selectProfile(profile))
    }

    /// Expands or collapses a container; expanding loads its details.
    public func toggleExpanded(_ id: String) {
        if expanded.remove(id) == nil {
            expanded.insert(id)
            syncDetails()
        }
    }

    /// Whether a container is expanded.
    public func isExpanded(_ id: String) -> Bool {
        expanded.contains(id)
    }

    /// Loads details for expanded containers that have none, or whose state or start time changed
    /// since. Call when the container list changes.
    public func syncDetails() {
        let containers = store.snapshot.containers
        expanded.formIntersection(containers.map(\.id))
        for container in containers where expanded.contains(container.id) {
            let key = DetailsKey(state: container.state, startedAt: container.startedAt)
            guard detailsKeys[container.id] != key else { continue }
            detailsKeys[container.id] = key
            loadDetails(container.id)
        }
    }

    private func loadDetails(_ id: String) {
        guard let engine = store.dockerEngine else { return }
        if details[id] == nil { details[id] = .loading }
        Task { [weak self] in
            let result: DetailsState
            do {
                result = .loaded(try await engine.inspect(containerID: id))
            } catch {
                result = .failed(error.localizedDescription)
            }
            self?.details[id] = result
        }
    }

    // MARK: Visibility

    /// The window became visible: keep the containers and the environment facts live.
    public func appear() {
        store.beginLiveUpdates(.mainWindow)
        store.beginInformationUpdates(.mainWindow)
    }

    /// The window closed.
    public func disappear() {
        store.endLiveUpdates(.mainWindow)
        store.endInformationUpdates(.mainWindow)
    }
}
