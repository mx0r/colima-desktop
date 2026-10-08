import ColimaDomain
import Foundation
import Observation

/// Single source of truth for the menu: loads colima and Docker state, runs user intents, schedules refreshes.
///
/// Refresh tiers:
/// - T0 (`refresh()`): `colima list` and the container list. On heartbeat, file changes, Docker events,
///   every 2 s while the menu is open and every second during own VM operations.
/// - T1 (`connectDocker()`): `colima status` and the Docker connection. When the VM becomes running,
///   after a profile switch or a settings change.
/// - T2 (`refreshInformation()`): VM usage, engine facts and disk usage. Only while the information submenu is open.
@MainActor
@Observable
public final class AppStore {
    /// Current state.
    public private(set) var snapshot = AppSnapshot()
    /// Current settings.
    public private(set) var settings: AppSettings

    @ObservationIgnored private let dependencies: AppDependencies
    @ObservationIgnored private var colima: any ColimaControlling
    @ObservationIgnored private var paths: ColimaPaths
    @ObservationIgnored private var engine: (any DockerEngine)?
    @ObservationIgnored private var generation = 0
    /// Views that want live refreshes (the open menu, the main window).
    @ObservationIgnored private var liveViewers: Set<LiveViewer> = []
    /// Views that show VM usage and engine facts (the information submenu, the main window).
    @ObservationIgnored private var informationViewers: Set<LiveViewer> = []
    @ObservationIgnored private var lastRefresh: ContinuousClock.Instant?

    @ObservationIgnored private let refreshFlight = SingleFlight()
    @ObservationIgnored private let connectFlight = SingleFlight()
    @ObservationIgnored private let informationFlight = SingleFlight()

    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var watcherTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var informationTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    /// Start and finish times by container ID, with the state they were read in. The container list
    /// does not include them, so they come from inspect: once per container, and again when its
    /// state changes or a Docker event names it (a restart keeps the state "running").
    @ObservationIgnored private var runTimes: [String: RunTimes] = [:]

    private struct RunTimes {
        var state: ContainerState
        var startedAt: Date?
        var finishedAt: Date?
    }

    /// Debounce for file system changes.
    static let fileChangeDebounce = Duration.milliseconds(250)
    /// Debounce for Docker events.
    static let dockerEventDebounce = Duration.milliseconds(200)
    /// Refresh interval while the menu is open.
    static let liveInterval = Duration.seconds(2)
    /// Refresh interval of the information submenu.
    static let informationInterval = Duration.seconds(3)
    /// Refresh interval while a VM operation runs.
    static let operationInterval = Duration.seconds(1)

    /// Creates the store. Call `start()` to begin loading.
    public init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        let settings = dependencies.settingsStore.load()
        self.settings = settings
        colima = dependencies.makeColima(settings)
        paths = dependencies.detectEnvironment(settings).paths
        snapshot.selectedProfile = settings.selectedProfile ?? .default
    }

    /// The Docker engine of the selected profile, when connected. Used by log and terminal windows.
    public var dockerEngine: (any DockerEngine)? { engine }

    /// Host values detected for the current settings.
    public var detectedEnvironment: DetectedEnvironment { dependencies.detectEnvironment(settings) }

    /// Host values detected for other settings (e.g. an unsaved draft).
    public func detectEnvironment(for settings: AppSettings) -> DetectedEnvironment {
        dependencies.detectEnvironment(settings)
    }

    // MARK: Lifecycle

    /// Starts background refreshing.
    public func start() {
        restartHeartbeat()
        restartWatcher()
        Task {
            await refresh()
            if let version = try? await colima.version() { snapshot.colimaVersion = version }
        }
    }

    /// Stops all background work.
    public func stop() {
        [heartbeatTask, watcherTask, eventsTask, liveTask, informationTask, debounceTask].forEach { $0?.cancel() }
    }

    // MARK: Intents

    /// Starts, stops or restarts the selected VM. Ignored when not allowed in the current state.
    public func requestVMOperation(_ operation: VMOperation) {
        handle(.requested(operation))
    }

    /// Starts, stops, restarts or deletes a container. Deleting requires a stopped container.
    public func performContainerAction(_ action: ContainerAction, containerID: String) {
        guard let engine, snapshot.containerOperations[containerID] == nil else { return }
        let container = snapshot.containers.first { $0.id == containerID }
        let name = container?.name ?? String(containerID.prefix(12))
        if action == .remove, container?.state.isAlive == true {
            snapshot.containerActionError = "Stop \(name) before deleting it."
            return
        }
        snapshot.containerOperations[containerID] = action
        snapshot.containerActionError = nil
        Task {
            do {
                try await engine.perform(action, containerID: containerID)
            } catch {
                let message = "Could not \(action.verb) \(name): \(error.localizedDescription)"
                snapshot.containerActionError = message
                if settings.notificationsEnabled {
                    await dependencies.notifier.post(title: "Container action failed", body: message)
                }
            }
            snapshot.containerOperations[containerID] = nil
            await refreshContainers()
        }
    }

    /// Switches the profile the menu acts on.
    public func selectProfile(_ profile: ProfileName) {
        guard profile != snapshot.selectedProfile, snapshot.lifecycle.operation == nil else { return }
        var updated = settings
        updated.selectedProfile = profile
        settings = updated
        dependencies.settingsStore.save(updated)
        resetForNewTarget(profile: profile)
        Task { await refresh() }
    }

    /// Applies new settings: persists them and rebuilds clients when paths changed.
    public func updateSettings(_ newSettings: AppSettings) {
        let old = settings
        guard newSettings != old else { return }
        settings = newSettings
        dependencies.settingsStore.save(newSettings)

        let colimaChanged = old.colimaExecutablePath != newSettings.colimaExecutablePath
            || old.colimaHomePath != newSettings.colimaHomePath
            || old.limaHomePath != newSettings.limaHomePath
        if colimaChanged {
            colima = dependencies.makeColima(newSettings)
            paths = dependencies.detectEnvironment(newSettings).paths
            resetForNewTarget(profile: snapshot.selectedProfile)
            Task {
                await refresh()
                snapshot.colimaVersion = try? await colima.version()
            }
        } else if old.dockerSocketOverrides != newSettings.dockerSocketOverrides {
            disconnectDocker()
            Task { await refresh() }
        }
        if old.heartbeatSeconds != newSettings.heartbeatSeconds {
            restartHeartbeat()
        }
    }

    /// Call when the status menu opens: refreshes if stale and keeps refreshing while open.
    public func menuWillOpen() {
        beginLiveUpdates(.menu)
    }

    /// Call when the status menu closed.
    public func menuDidClose() {
        endLiveUpdates(.menu)
        endInformationUpdates(.menu)
    }

    /// Call when the information submenu opens: loads usage data and keeps it fresh while open.
    public func informationMenuWillOpen() {
        beginInformationUpdates(.menu)
    }

    /// Call when the information submenu closed.
    public func informationMenuDidClose() {
        endInformationUpdates(.menu)
    }

    /// A view became visible that shows live state: refreshes if stale, then every `liveInterval`
    /// until the last such view is gone.
    public func beginLiveUpdates(_ viewer: LiveViewer) {
        if let lastRefresh, ContinuousClock.now - lastRefresh < .seconds(1) {
            // Fresh enough.
        } else {
            Task { await refresh() }
        }
        guard liveViewers.insert(viewer).inserted, liveViewers.count == 1 else { return }
        liveTask?.cancel()
        liveTask = repeating(every: Self.liveInterval) { store in await store.refresh() }
    }

    /// A live view went away.
    public func endLiveUpdates(_ viewer: LiveViewer) {
        guard liveViewers.remove(viewer) != nil, liveViewers.isEmpty else { return }
        liveTask?.cancel()
        liveTask = nil
    }

    /// A view became visible that shows VM usage and engine facts: loads them, then every
    /// `informationInterval` until the last such view is gone.
    public func beginInformationUpdates(_ viewer: LiveViewer) {
        Task { await refreshInformation() }
        guard informationViewers.insert(viewer).inserted, informationViewers.count == 1 else { return }
        informationTask?.cancel()
        informationTask = repeating(every: Self.informationInterval) { store in await store.refreshInformation() }
    }

    /// An information view went away.
    public func endInformationUpdates(_ viewer: LiveViewer) {
        guard informationViewers.remove(viewer) != nil, informationViewers.isEmpty else { return }
        informationTask?.cancel()
        informationTask = nil
    }

    // MARK: T0

    /// Reloads profiles and containers. Concurrent calls are coalesced.
    public func refresh() async {
        await refreshFlight.run { [self] in
            await performRefresh()
        }
    }

    private func performRefresh() async {
        let generation = generation
        let instances: [ColimaInstance]
        do {
            instances = try await colima.listInstances()
        } catch ColimaError.executableNotFound {
            guard generation == self.generation else { return }
            snapshot.profiles = []
            snapshot.listError = nil
            handle(.colimaMissing)
            disconnectDocker()
            return
        } catch {
            guard generation == self.generation else { return }
            snapshot.listError = error.localizedDescription
            return
        }
        guard generation == self.generation else { return }
        lastRefresh = .now
        snapshot.listError = nil
        snapshot.profiles = instances.sorted { $0.profile < $1.profile }

        // Without an explicit choice, follow `default`, or the first profile when `default` does not exist.
        if settings.selectedProfile == nil, !instances.contains(where: { $0.profile == .default }),
           let first = snapshot.profiles.first, first.profile != snapshot.selectedProfile {
            resetForNewTarget(profile: first.profile)
            return await performRefresh()
        }

        let status = snapshot.selectedInstance?.status ?? .uninitialized
        handle(.observed(status))

        if status == .running {
            if engine == nil, snapshot.docker != .notApplicable || snapshot.details == nil {
                await connectDocker()
            }
            await refreshContainers()
        } else if engine != nil || snapshot.details != nil {
            disconnectDocker()
        }
    }

    // MARK: T1

    /// Reads `colima status` and connects to the profile's Docker socket.
    func connectDocker() async {
        await connectFlight.run { [self] in
            let generation = generation
            let profile = snapshot.selectedProfile
            do {
                let details = try await colima.details(of: profile)
                guard generation == self.generation else { return }
                snapshot.details = details
                guard details != nil else {
                    disconnectDocker()
                    return
                }
                let override = settings.dockerSocketOverride(for: profile)
                guard override != nil || details?.dockerSocketPath != nil || details?.runtime == "docker" else {
                    snapshot.docker = .notApplicable
                    return
                }
                let socket = override ?? details?.dockerSocketPath ?? paths.defaultDockerSocket(profile).path(percentEncoded: false)
                if engine != nil, snapshot.socketPath == socket { return }
                snapshot.docker = .connecting
                let candidate = dependencies.makeDocker(socket)
                try await candidate.verifyCompatibility()
                guard generation == self.generation else { return }
                engine = candidate
                snapshot.socketPath = socket
                snapshot.docker = .reachable
                startEventStream(candidate, generation: generation)
            } catch {
                guard generation == self.generation else { return }
                engine = nil
                snapshot.docker = .unreachable(error.localizedDescription)
            }
        }
    }

    private func refreshContainers() async {
        guard let engine else { return }
        let generation = generation
        do {
            let containers = try await engine.containers()
            guard generation == self.generation else { return }
            let timed = await addRunTimes(to: containers, engine: engine)
            guard generation == self.generation else { return }
            snapshot.containers = timed
            snapshot.docker = .reachable
        } catch {
            guard generation == self.generation else { return }
            snapshot.docker = .unreachable(error.localizedDescription)
            snapshot.containers = []
            self.engine = nil
            eventsTask?.cancel()
        }
    }

    private func startEventStream(_ engine: any DockerEngine, generation: Int) {
        eventsTask?.cancel()
        let clock = dependencies.clock
        eventsTask = Task { [weak self] in
            var backoff = Duration.seconds(1)
            while !Task.isCancelled {
                do {
                    for try await event in engine.events() {
                        backoff = .seconds(1)
                        self?.runTimes[event.actorID] = nil
                        self?.scheduleRefresh(after: Self.dockerEventDebounce)
                    }
                } catch {}
                guard !Task.isCancelled else { return }
                try? await clock.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(30))
                self?.scheduleRefresh(after: .zero)
            }
        }
    }

    /// The containers with their start and finish times; inspects only those not cached for their state.
    /// A failed inspect is cached too (as unknown), so it is not repeated on every refresh.
    private func addRunTimes(to containers: [Container], engine: any DockerEngine) async -> [Container] {
        let stale = containers.filter { runTimes[$0.id]?.state != $0.state }
        if !stale.isEmpty {
            let fetched = await withTaskGroup(of: (String, RunTimes).self) { group in
                for container in stale {
                    group.addTask {
                        let details = try? await engine.inspect(containerID: container.id)
                        return (container.id, RunTimes(state: container.state, startedAt: details?.startedAt, finishedAt: details?.finishedAt))
                    }
                }
                var result: [String: RunTimes] = [:]
                for await (id, times) in group { result[id] = times }
                return result
            }
            runTimes.merge(fetched) { $1 }
        }
        let ids = Set(containers.map(\.id))
        runTimes = runTimes.filter { ids.contains($0.key) }
        return containers.map { container in
            var container = container
            container.startedAt = runTimes[container.id]?.startedAt
            container.finishedAt = runTimes[container.id]?.finishedAt
            return container
        }
    }

    private func disconnectDocker() {
        eventsTask?.cancel()
        eventsTask = nil
        runTimes = [:]
        engine = nil
        snapshot.details = nil
        snapshot.docker = .notApplicable
        snapshot.socketPath = nil
        snapshot.containers = []
        snapshot.containerOperations = [:]
        snapshot.usage = nil
        snapshot.engine = nil
        snapshot.diskUsage = nil
    }

    // MARK: T2

    /// Loads VM usage, engine facts and disk usage.
    func refreshInformation() async {
        await informationFlight.run { [self] in
            guard snapshot.lifecycle.observed == .running else { return }
            let generation = generation
            let profile = snapshot.selectedProfile
            let colima = colima
            let engine = engine
            async let usage = try? colima.usage(of: profile)
            async let summary = engineSummary(engine)
            async let diskUsage = engineDiskUsage(engine)
            let (newUsage, newSummary, newDiskUsage) = await (usage, summary, diskUsage)
            guard generation == self.generation else { return }
            snapshot.usage = newUsage ?? snapshot.usage
            snapshot.engine = newSummary ?? snapshot.engine
            snapshot.diskUsage = newDiskUsage ?? snapshot.diskUsage
        }
    }

    private nonisolated func engineSummary(_ engine: (any DockerEngine)?) async -> EngineSummary? {
        guard let engine else { return nil }
        return try? await engine.summary()
    }

    private nonisolated func engineDiskUsage(_ engine: (any DockerEngine)?) async -> DiskUsageSummary? {
        guard let engine else { return nil }
        return try? await engine.diskUsage()
    }

    // MARK: VM lifecycle

    private func handle(_ event: VMLifecycle.Event) {
        let effects = snapshot.lifecycle.handle(event)
        for effect in effects {
            switch effect {
            case .perform(let operation):
                operationTask = Task { await runOperation(operation) }
            case .notifySucceeded(let operation):
                notify(title: "Colima \(snapshot.selectedProfile)", body: operation.successText)
            case .notifyFailed(let operation, let message):
                notify(title: "Colima \(snapshot.selectedProfile): \(operation.noun) failed", body: message)
            case .refresh:
                Task { await refresh() }
            }
        }
    }

    private func runOperation(_ operation: VMOperation) async {
        let profile = snapshot.selectedProfile
        snapshot.progressMessage = nil
        let ticker = repeating(every: Self.operationInterval) { store in await store.refresh() }
        defer { ticker.cancel() }
        do {
            try await colima.perform(operation, on: profile) { [weak self] message in
                Task { @MainActor in self?.snapshot.progressMessage = message }
            }
            snapshot.progressMessage = nil
            if operation == .restart { disconnectDocker() }
            handle(.finished(operation))
        } catch {
            snapshot.progressMessage = nil
            handle(.failed(operation, error.localizedDescription))
        }
    }

    private func notify(title: String, body: String) {
        guard settings.notificationsEnabled else { return }
        let notifier = dependencies.notifier
        Task { await notifier.post(title: title, body: body) }
    }

    // MARK: Scheduling

    private func resetForNewTarget(profile: ProfileName) {
        generation += 1
        disconnectDocker()
        var snapshot = AppSnapshot()
        snapshot.profiles = self.snapshot.profiles
        snapshot.colimaVersion = self.snapshot.colimaVersion
        snapshot.selectedProfile = profile
        self.snapshot = snapshot
        restartWatcher()
    }

    private func restartHeartbeat() {
        heartbeatTask?.cancel()
        let interval = Duration.seconds(max(5, settings.heartbeatSeconds))
        heartbeatTask = repeating(every: interval) { store in
            if store.liveViewers.isEmpty { await store.refresh() }
        }
    }

    private func restartWatcher() {
        watcherTask?.cancel()
        let changes = dependencies.fileWatcher.changes(in: paths.watchedDirectories(for: snapshot.selectedProfile))
        watcherTask = Task { [weak self] in
            for await _ in changes {
                self?.scheduleRefresh(after: Self.fileChangeDebounce)
            }
        }
    }

    private func scheduleRefresh(after delay: Duration) {
        debounceTask?.cancel()
        let clock = dependencies.clock
        debounceTask = Task { [weak self] in
            if delay > .zero {
                do { try await clock.sleep(for: delay) } catch { return }
            }
            await self?.refresh()
        }
    }

    /// Runs `body` every `interval` until the task is cancelled.
    private func repeating(every interval: Duration, _ body: @escaping @MainActor (AppStore) async -> Void) -> Task<Void, Never> {
        let clock = dependencies.clock
        return Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: interval) } catch { return }
                guard let self else { return }
                await body(self)
            }
        }
    }
}

extension VMOperation {
    /// Noun for messages, e.g. "Start".
    public var noun: String {
        switch self {
        case .start: "Start"
        case .stop: "Stop"
        case .restart: "Restart"
        }
    }

    /// Notification text after success.
    var successText: String {
        switch self {
        case .start: "The VM is running."
        case .stop: "The VM is stopped."
        case .restart: "The VM was restarted."
        }
    }
}

extension ContainerAction {
    /// Verb for messages, e.g. "stop".
    public var verb: String {
        switch self {
        case .start: "start"
        case .stop: "stop"
        case .restart: "restart"
        case .remove: "delete"
        }
    }
}

/// A view that shows live state and keeps the store refreshing while it is visible.
public enum LiveViewer: Hashable, Sendable {
    case menu
    case mainWindow
}
