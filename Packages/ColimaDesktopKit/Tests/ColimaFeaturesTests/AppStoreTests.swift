import ColimaDomain
import ColimaTestSupport
import Foundation
import Synchronization
import Testing
@testable import ColimaFeatures

@MainActor
struct StoreHarness {
    let store: AppStore
    let colima: FakeColima
    let docker: FakeDockerEngine
    let watcher = FakeFileWatcher()
    let notifier = RecordingNotifier()
    let settingsStore: InMemorySettingsStore
    let clock = ManualClock()
    let colimaFactoryCalls = Locked(0)
    let dockerSockets = Locked<[String]>([])

    init(
        instances: [ColimaInstance] = [Sample.instance()],
        details: [ProfileName: ColimaInstanceDetails] = [.default: Sample.details()],
        containers: [Container] = [],
        settings: AppSettings = .defaults
    ) {
        var colimaState = FakeColima.State()
        colimaState.instances = instances
        colimaState.details = details
        let colima = FakeColima(colimaState)
        var dockerState = FakeDockerEngine.State()
        dockerState.containers = containers
        let docker = FakeDockerEngine(dockerState)
        let settingsStore = InMemorySettingsStore(settings)
        self.colima = colima
        self.docker = docker
        self.settingsStore = settingsStore

        let colimaFactoryCalls = colimaFactoryCalls
        let dockerSockets = dockerSockets
        let dependencies = AppDependencies(
            settingsStore: settingsStore,
            detectEnvironment: { _ in DetectedEnvironment(colimaExecutable: "/opt/homebrew/bin/colima", autoColimaExecutable: "/opt/homebrew/bin/colima", paths: Sample.paths()) },
            makeColima: { _ in
                colimaFactoryCalls.withLock { $0 += 1 }
                return colima
            },
            makeDocker: { socket in
                dockerSockets.withLock { $0.append(socket) }
                return docker
            },
            fileWatcher: watcher,
            notifier: notifier,
            clock: clock
        )
        store = AppStore(dependencies: dependencies)
    }

    func started() async -> StoreHarness {
        store.start()
        _ = await eventually { colima.current.listCalls > 0 && store.snapshot.lifecycle.observed != nil }
        await store.refresh()
        return self
    }
}

@MainActor
@Suite("AppStore")
struct AppStoreTests {
    @Test("A running VM connects Docker and loads containers")
    func runningVM() async throws {
        let h = await StoreHarness(containers: [Sample.container("web"), Sample.container("db")]).started()
        #expect(await eventually { h.store.snapshot.containers.count == 2 })
        #expect(h.store.snapshot.lifecycle.observed == .running)
        #expect(h.store.snapshot.docker == .reachable)
        #expect(h.store.snapshot.socketPath == "/tmp/docker.sock")
        #expect(h.dockerSockets.withLock { $0 } == ["/tmp/docker.sock"])
        // Set by the start task after its first refresh; wait instead of racing it.
        #expect(await eventually { h.store.snapshot.colimaVersion == "0.10.3" })
    }

    @Test("Socket override wins over the socket colima reports")
    func socketOverride() async throws {
        let h = await StoreHarness(settings: AppSettings(dockerSocketOverrides: ["default": "/custom.sock"])).started()
        #expect(await eventually { h.store.snapshot.docker == .reachable })
        #expect(h.dockerSockets.withLock { $0 } == ["/custom.sock"])
    }

    @Test("A stopped VM has no Docker connection")
    func stoppedVM() async throws {
        let h = await StoreHarness(instances: [Sample.instance(status: .stopped)]).started()
        #expect(h.store.snapshot.lifecycle.observed == .stopped)
        #expect(h.store.snapshot.docker == .notApplicable)
        #expect(h.store.snapshot.containers.isEmpty)
        #expect(h.store.snapshot.lifecycle.canStart)
        #expect(h.dockerSockets.withLock { $0 }.isEmpty)
    }

    @Test("Missing colima shows the missing state")
    func colimaMissing() async throws {
        let h = StoreHarness()
        h.colima.update { $0.listError = .executableNotFound }
        h.store.start()
        #expect(await eventually { h.store.snapshot.lifecycle.phase == .colimaMissing })
        #expect(h.store.snapshot.lifecycle.iconState == .error)
    }

    @Test("Other list errors are shown without changing the lifecycle")
    func listError() async throws {
        let h = await StoreHarness().started()
        h.colima.update { $0.listError = .commandFailed(command: "colima list", exitCode: 1, message: "boom") }
        await h.store.refresh()
        #expect(h.store.snapshot.listError == "boom")
        #expect(h.store.snapshot.lifecycle.observed == .running)
    }

    @Test("Stop runs colima, notifies and disconnects Docker")
    func stopVM() async throws {
        let h = await StoreHarness(containers: [Sample.container("web")]).started()
        #expect(await eventually { h.store.snapshot.containers.count == 1 })
        h.store.requestVMOperation(.stop)
        #expect(await eventually { h.store.snapshot.lifecycle.operation == nil && h.store.snapshot.lifecycle.observed == .stopped })
        #expect(h.colima.current.performed.map(\.0) == [.stop])
        #expect(h.store.snapshot.containers.isEmpty)
        #expect(h.store.snapshot.docker == .notApplicable)
        #expect(await eventually { h.notifier.posted.count == 1 })
        #expect(h.notifier.posted.first?.body == "The VM is stopped.")
    }

    @Test("Progress lines are shown while an operation runs")
    func progress() async throws {
        let h = await StoreHarness(instances: [Sample.instance(status: .stopped)]).started()
        h.colima.update {
            $0.holdOperations = true
            $0.progressLines = ["starting colima"]
        }
        h.store.requestVMOperation(.start)
        #expect(await eventually { h.store.snapshot.progressMessage == "starting colima" })
        #expect(h.store.snapshot.lifecycle.phase == .operating(.start))
        h.colima.releaseOperation()
        #expect(await eventually { h.store.snapshot.lifecycle.observed == .running && h.store.snapshot.lifecycle.operation == nil })
        #expect(h.store.snapshot.progressMessage == nil)
    }

    @Test("A failed operation shows the error and notifies")
    func failedOperation() async throws {
        let h = await StoreHarness(instances: [Sample.instance(status: .stopped)]).started()
        h.colima.update { $0.operationError = .commandFailed(command: "colima start", exitCode: 1, message: "no space left") }
        h.store.requestVMOperation(.start)
        #expect(await eventually { h.store.snapshot.lifecycle.phase == .failed(.start, "no space left") })
        #expect(await eventually { h.notifier.posted.count == 1 })
        #expect(h.notifier.posted.first?.body == "no space left")
    }

    @Test("Disabled notifications are not posted")
    func notificationsDisabled() async throws {
        let h = await StoreHarness(settings: AppSettings(notificationsEnabled: false)).started()
        h.store.requestVMOperation(.restart)
        #expect(await eventually { h.colima.current.performed.count == 1 && h.store.snapshot.lifecycle.operation == nil })
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.notifier.posted.isEmpty)
    }

    @Test("Switching profiles persists the choice and resets profile state")
    func switchProfile() async throws {
        let h = await StoreHarness(
            instances: [Sample.instance(), Sample.instance("work", status: .stopped)],
            containers: [Sample.container("web")]
        ).started()
        #expect(await eventually { h.store.snapshot.containers.count == 1 })

        h.store.selectProfile(ProfileName("work"))
        #expect(h.store.snapshot.selectedProfile == ProfileName("work"))
        #expect(h.store.snapshot.containers.isEmpty)
        #expect(await eventually { h.store.snapshot.lifecycle.observed == .stopped })
        #expect(h.settingsStore.saved.selectedProfile == ProfileName("work"))
        #expect(h.watcher.watchedDirectories.last?.contains { $0.path(percentEncoded: false).hasSuffix("/_lima/colima-work/") } == true)
    }

    @Test("Results of a refresh that started before a profile switch are dropped")
    func staleResultsDropped() async throws {
        let h = await StoreHarness(instances: [Sample.instance(), Sample.instance("work", status: .stopped)]).started()
        let before = h.colima.current.listCalls
        h.colima.update { $0.holdList = true }
        let stale = Task { await h.store.refresh() }
        _ = await eventually { h.colima.current.listCalls == before + 1 }
        h.store.selectProfile(ProfileName("work"))
        h.colima.update {
            $0.holdList = false
            $0.instances[0].status = .broken
        }
        h.colima.releaseList()
        await stale.value
        await h.store.refresh()
        #expect(h.store.snapshot.selectedProfile == ProfileName("work"))
        #expect(h.store.snapshot.lifecycle.observed == .stopped)
    }

    @Test("Profile switching is blocked during a VM operation")
    func switchBlockedDuringOperation() async throws {
        let h = await StoreHarness(instances: [Sample.instance(), Sample.instance("work", status: .stopped)]).started()
        h.colima.update { $0.holdOperations = true }
        h.store.requestVMOperation(.stop)
        h.store.selectProfile(ProfileName("work"))
        #expect(h.store.snapshot.selectedProfile == .default)
        h.colima.releaseOperation()
    }

    @Test("Without a stored choice, the first profile is used when default does not exist")
    func firstProfileFallback() async throws {
        let h = await StoreHarness(instances: [Sample.instance("work")], details: [ProfileName("work"): Sample.details()]).started()
        #expect(await eventually { h.store.snapshot.selectedProfile == ProfileName("work") })
        #expect(await eventually { h.store.snapshot.docker == .reachable })
    }

    @Test("An unreachable Docker socket is reported")
    func dockerUnreachable() async throws {
        let h = StoreHarness()
        h.docker.update { $0.reachable = false }
        _ = await h.started()
        #expect(await eventually {
            if case .unreachable = h.store.snapshot.docker { return true }
            return false
        })
    }

    @Test("A containerd profile has no Docker section")
    func containerdRuntime() async throws {
        let h = await StoreHarness(details: [.default: Sample.details(runtime: "containerd")]).started()
        #expect(h.store.snapshot.details?.runtime == "containerd")
        #expect(h.store.snapshot.docker == .notApplicable)
        #expect(h.dockerSockets.withLock { $0 }.isEmpty)
    }

    @Test("File changes trigger a debounced refresh")
    func fileChangeRefresh() async throws {
        let h = await StoreHarness().started()
        let before = h.colima.current.listCalls
        h.watcher.emit()
        h.watcher.emit()
        // The second change cancels the first debounce and starts another; the new sleeper may not be
        // registered yet when the first one goes. Advance in debounce steps (far below the 30 s
        // heartbeat) until the refresh ran.
        for _ in 0..<8 where h.colima.current.listCalls == before {
            await h.clock.advance(by: AppStore.fileChangeDebounce)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(h.colima.current.listCalls == before + 1)
        // Debounced: the two changes made one refresh.
        await h.clock.advance(by: AppStore.fileChangeDebounce)
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.colima.current.listCalls == before + 1)
    }

    @Test("Docker events refresh the container list")
    func dockerEventRefresh() async throws {
        let h = await StoreHarness(containers: [Sample.container("web")]).started()
        #expect(await eventually { h.store.snapshot.containers.count == 1 })
        h.docker.update { $0.containers.append(Sample.container("db")) }
        let sleepers = h.clock.sleeperCount
        h.docker.emitEvent(DockerEvent(type: "container", action: "start", actorID: "db"))
        await h.clock.waitForSleepers(sleepers + 1)
        await h.clock.advance(by: .milliseconds(200))
        #expect(await eventually { h.store.snapshot.containers.count == 2 })
    }

    @Test("Opening the menu refreshes and keeps refreshing until closed")
    func liveRefresh() async throws {
        let h = await StoreHarness().started()
        let before = h.colima.current.listCalls
        let sleepers = h.clock.sleeperCount
        h.store.menuWillOpen()
        await h.clock.waitForSleepers(sleepers + 1)
        await h.clock.advance(by: .seconds(2))
        #expect(await eventually { h.colima.current.listCalls >= before + 1 })
        h.store.menuDidClose()
        let afterClose = h.colima.current.listCalls
        await h.clock.advance(by: .seconds(4))
        #expect(h.colima.current.listCalls == afterClose)
    }

    @Test("Opening the information submenu loads usage and engine facts")
    func information() async throws {
        let h = await StoreHarness().started()
        #expect(await eventually { h.store.snapshot.docker == .reachable })
        h.store.informationMenuWillOpen()
        #expect(await eventually { h.store.snapshot.usage != nil && h.store.snapshot.engine != nil && h.store.snapshot.diskUsage != nil })
        h.store.informationMenuDidClose()
    }

    @Test("Container actions run once and clear their pending state")
    func containerAction() async throws {
        let web = Sample.container("web")
        let h = await StoreHarness(containers: [web]).started()
        #expect(await eventually { h.store.snapshot.docker == .reachable })
        h.store.performContainerAction(.stop, containerID: web.id)
        #expect(h.store.snapshot.containerOperations[web.id] == .stop)
        h.store.performContainerAction(.stop, containerID: web.id)
        #expect(await eventually { h.store.snapshot.containerOperations.isEmpty })
        #expect(h.docker.current.actions.map(\.1) == [web.id])
    }

    @Test("A failed container action is shown and notified")
    func containerActionFailure() async throws {
        let web = Sample.container("web")
        let h = await StoreHarness(containers: [web]).started()
        #expect(await eventually { h.store.snapshot.docker == .reachable })
        h.docker.update { $0.actionError = .api(status: 500, message: "kill failed") }
        h.store.performContainerAction(.restart, containerID: web.id)
        #expect(await eventually { h.store.snapshot.containerActionError == "Could not restart web: kill failed" })
        #expect(await eventually { h.notifier.posted.count == 1 })
    }

    @Test("Deleting a stopped container removes it from the list")
    func deleteStopped() async throws {
        let db = Sample.container("db", state: .exited)
        let h = await StoreHarness(containers: [Sample.container("web"), db]).started()
        #expect(await eventually { h.store.snapshot.containers.count == 2 })
        h.store.performContainerAction(.remove, containerID: db.id)
        #expect(await eventually { h.store.snapshot.containers.map(\.name) == ["web"] })
        #expect(h.docker.current.actions.map(\.0) == [.remove])
        #expect(h.store.snapshot.containerOperations.isEmpty)
    }

    @Test("Deleting a running container is refused without calling Docker")
    func deleteRunningRefused() async throws {
        let web = Sample.container("web")
        let h = await StoreHarness(containers: [web]).started()
        #expect(await eventually { h.store.snapshot.containers.count == 1 })
        h.store.performContainerAction(.remove, containerID: web.id)
        #expect(h.store.snapshot.containerActionError == "Stop web before deleting it.")
        #expect(h.store.snapshot.containerOperations.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.docker.current.actions.isEmpty)
    }

    @Test("Changing colima paths rebuilds the client; other changes do not")
    func settingsUpdate() async throws {
        let h = await StoreHarness().started()
        #expect(h.colimaFactoryCalls.withLock { $0 } == 1)

        var settings = h.store.settings
        settings.logTailLines = 50
        h.store.updateSettings(settings)
        #expect(h.colimaFactoryCalls.withLock { $0 } == 1)
        #expect(h.settingsStore.saved.logTailLines == 50)

        settings.colimaExecutablePath = "/custom/colima"
        h.store.updateSettings(settings)
        #expect(h.colimaFactoryCalls.withLock { $0 } == 2)
        #expect(await eventually { h.store.snapshot.docker == .reachable })
    }
}

@MainActor
@Suite("SingleFlight")
struct SingleFlightTests {
    @Test("Calls during a run coalesce into one re-run")
    func coalesce() async {
        final class Counter { var runs = 0 }
        let flight = SingleFlight()
        let counter = Counter()
        let gate = AsyncStream.makeStream(of: Void.self)
        let first = Task { await flight.run { counter.runs += 1; for await _ in gate.stream { break } } }
        await ManualClock.settle()
        let second = Task { await flight.run { counter.runs += 1 } }
        let third = Task { await flight.run { counter.runs += 1 } }
        await ManualClock.settle()
        // Finish (not yield): the coalesced re-run executes the same closure again.
        gate.continuation.finish()
        await first.value
        await second.value
        await third.value
        #expect(counter.runs == 2)
    }
}

@MainActor
@Suite("Container run times")
struct ContainerRunTimeTests {
    private let started = Date(timeIntervalSince1970: 1_799_990_000)

    @Test("Start times come from inspect, once per container and state")
    func cached() async {
        let web = Sample.container("web")
        let harness = StoreHarness(containers: [web])
        harness.docker.update { $0.details[web.id] = Sample.containerDetails(web, startedAt: started) }
        _ = await harness.started()
        #expect(await eventually { harness.store.snapshot.containers.first?.startedAt == started })
        let calls = harness.docker.current.inspectCalls.count
        #expect(calls == 1)

        await harness.store.refresh()
        #expect(harness.docker.current.inspectCalls.count == calls)
    }

    @Test("A state change or an event for the container reads the times again")
    func invalidated() async {
        let web = Sample.container("web")
        let harness = StoreHarness(containers: [web])
        harness.docker.update { $0.details[web.id] = Sample.containerDetails(web, startedAt: started) }
        _ = await harness.started()
        #expect(await eventually { harness.store.snapshot.containers.first?.startedAt == started })

        let finished = started.addingTimeInterval(60)
        harness.docker.update {
            $0.containers[0].state = .exited
            $0.details[web.id] = Sample.containerDetails(web, state: .exited, startedAt: started, finishedAt: finished)
        }
        await harness.store.refresh()
        #expect(harness.store.snapshot.containers.first?.finishedAt == finished)
        #expect(harness.docker.current.inspectCalls.count == 2)

        let restarted = finished.addingTimeInterval(5)
        harness.docker.update { $0.details[web.id] = Sample.containerDetails(web, state: .exited, startedAt: restarted, finishedAt: finished) }
        harness.docker.emitEvent(DockerEvent(type: "container", action: "restart", actorID: web.id))
        // The heartbeat sleeps already; the event adds the debounce.
        _ = await harness.clock.waitForSleepers(2)
        await harness.clock.advance(by: AppStore.dockerEventDebounce)
        #expect(await eventually { harness.store.snapshot.containers.first?.startedAt == restarted })
    }
}

