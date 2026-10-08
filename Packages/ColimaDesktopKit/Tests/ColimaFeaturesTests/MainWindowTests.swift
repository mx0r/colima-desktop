import ColimaDomain
import ColimaTestSupport
import Foundation
import Testing
@testable import ColimaFeatures

/// Snapshot of a running VM with Docker reachable.
private func runningSnapshot(containers: [Container] = []) -> AppSnapshot {
    var snapshot = AppSnapshot()
    snapshot.profiles = [Sample.instance()]
    _ = snapshot.lifecycle.handle(.observed(.running))
    snapshot.details = Sample.details()
    snapshot.docker = .reachable
    snapshot.socketPath = "/tmp/docker.sock"
    snapshot.containers = containers
    return snapshot
}

@Suite("Shared menu and window content")
struct SharedContentTests {
    private let now = Date(timeIntervalSince1970: 1_791_003_600)

    @Test("The status summary is what the menu banner shows")
    func statusSummary() {
        let snapshot = runningSnapshot()
        let summary = StatusSummary.make(snapshot)
        let banner = MenuModelBuilder.build(snapshot, now: now)[0]
        #expect(summary.title == "Colima is running")
        #expect(banner.title == summary.title)
        #expect(banner.subtitle == summary.subtitle)
        #expect(banner.image == .dot(summary.color))
    }

    @Test("Information sections hold the Information submenu's rows, in order")
    func informationSections() throws {
        var snapshot = runningSnapshot()
        snapshot.colimaVersion = "0.10.3"
        let sections = InformationSections.build(snapshot)
        #expect(sections.map(\.title) == ["Colima", "VM usage", "Docker"])
        let colima = try #require(sections.first)
        #expect(colima.items.first == InfoItem(id: "info.profile", label: "Profile", value: "default"))
        #expect(sections[1].items == [InfoItem(id: "info.usage.loading", label: nil, value: "Loading…")])

        let menuRows = try #require(MenuModelBuilder.build(snapshot, now: now).first { $0.id == MenuNodeID.information }?.children)
        let valueRows = menuRows.filter { $0.kind == .item && $0.isEnabled }.map(\.title)
        let sectionRows = sections.flatMap(\.items).compactMap { item in item.label.map { "\($0): \(item.value)" } }
        #expect(valueRows == sectionRows)
    }

    @Test("Container facts are the container submenu's first rows")
    func containerFacts() throws {
        let web = Sample.container("web", project: "shop")
        let facts = ContainerFacts.rows(web, now: now)
        #expect(facts.map(\.label) == ["Image", "Status", "ID", "Created", "Service"])
        let children = try #require(MenuModelBuilder.containerNode(web, snapshot: runningSnapshot(containers: [web]), now: now).children)
        #expect(Array(children.prefix(facts.count)).map(\.title) == facts.map { "\($0.label ?? ""): \($0.value)" })
    }

    @Test("Commands follow the container's state and pending operation")
    func commands() {
        let running = Sample.container("web")
        let stopped = Sample.container("db", state: .exited)
        var snapshot = runningSnapshot(containers: [running, stopped])
        #expect(ContainerCommands.available(for: running, in: snapshot) == ContainerCommands(
            canStart: false, canStop: true, canRestart: true, canShowLogs: true, canOpenTerminal: true, canDelete: false, pending: nil
        ))
        #expect(ContainerCommands.available(for: stopped, in: snapshot) == ContainerCommands(
            canStart: true, canStop: false, canRestart: false, canShowLogs: true, canOpenTerminal: false, canDelete: true, pending: nil
        ))
        snapshot.containerOperations[running.id] = .stop
        let busy = ContainerCommands.available(for: running, in: snapshot)
        #expect(!busy.canStop && !busy.canRestart && busy.pending == .stop)
    }

    @Test("The list state gives the menu's texts")
    func listState() {
        var snapshot = runningSnapshot()
        #expect(ContainerListState.make(snapshot) == .ready)
        snapshot.docker = .unreachable("refused")
        #expect(ContainerListState.make(snapshot) == .unreachable("refused"))
        var stopped = AppSnapshot()
        _ = stopped.lifecycle.handle(.observed(.stopped))
        #expect(ContainerListState.make(stopped) == .vmNotRunning)
        #expect(ContainerListState.vmNotRunning.message == "Containers are available while Colima runs")
    }
}

@Suite("Menu bar commands")
struct MainMenuStateTests {
    @Test("VM commands follow the lifecycle; container commands need a selection")
    func actions() {
        let web = Sample.container("web")
        let snapshot = runningSnapshot(containers: [web])
        #expect(MainMenuState.action(for: .startVM, snapshot: snapshot, selectedContainerID: nil) == nil)
        #expect(MainMenuState.action(for: .stopVM, snapshot: snapshot, selectedContainerID: nil) == .stopVM)
        #expect(MainMenuState.action(for: .refresh, snapshot: snapshot, selectedContainerID: nil) == .refresh)
        #expect(MainMenuState.action(for: .newContainer, snapshot: snapshot, selectedContainerID: nil) == .newContainer)
        #expect(MainMenuState.action(for: .stopContainer, snapshot: snapshot, selectedContainerID: nil) == nil)
        #expect(MainMenuState.action(for: .stopContainer, snapshot: snapshot, selectedContainerID: web.id) == .container(.stop, containerID: web.id, name: "web"))
        #expect(MainMenuState.action(for: .startContainer, snapshot: snapshot, selectedContainerID: web.id) == nil)
        #expect(MainMenuState.action(for: .openTerminal, snapshot: snapshot, selectedContainerID: web.id) == .openTerminal(containerID: web.id, name: "web"))
        #expect(MainMenuState.action(for: .deleteContainer, snapshot: snapshot, selectedContainerID: web.id) == nil)
        #expect(MainMenuState.action(for: .stopContainer, snapshot: snapshot, selectedContainerID: "gone") == nil)
    }

    @Test("New Container needs Docker")
    func newContainerNeedsDocker() {
        var snapshot = runningSnapshot()
        snapshot.docker = .unreachable("refused")
        #expect(MainMenuState.action(for: .newContainer, snapshot: snapshot, selectedContainerID: nil) == nil)
    }
}

@MainActor
@Suite("MainWindowModel")
struct MainWindowModelTests {
    private func model(_ harness: StoreHarness, actions: Locked<[MenuAction]> = Locked([])) -> MainWindowModel {
        MainWindowModel(store: harness.store, onAction: { action in actions.withLock { $0.append(action) } })
    }

    @Test("The filter matches name, image and Compose project")
    func filter() async {
        let containers = [
            Sample.container("web", project: "shop"),
            Sample.container("db", project: "shop"),
            Sample.container("cache"),
        ]
        let h = await StoreHarness(containers: containers).started()
        #expect(await eventually { h.store.snapshot.containers.count == 3 })
        let sut = model(h)
        #expect(sut.groups.flatMap(\.containers).count == 3)
        sut.filter = "SHOP"
        #expect(sut.groups.flatMap(\.containers).map(\.name).sorted() == ["db", "web"])
        sut.filter = "cache:latest"
        #expect(sut.groups.flatMap(\.containers).map(\.name) == ["cache"])
        sut.filter = "  "
        #expect(sut.groups.flatMap(\.containers).count == 3)
    }

    @Test("Expanding loads details once; a state change loads them again")
    func details() async {
        let web = Sample.container("web")
        let harness = StoreHarness(containers: [web])
        harness.docker.update { $0.details[web.id] = Sample.containerDetails(web, startedAt: Date(timeIntervalSince1970: 1_000)) }
        let h = await harness.started()
        #expect(await eventually { h.store.snapshot.containers.first?.startedAt != nil })
        let sut = model(h)
        let calls = h.docker.current.inspectCalls.count

        sut.toggleExpanded(web.id)
        #expect(sut.isExpanded(web.id))
        #expect(await eventually { if case .loaded = sut.details[web.id] { true } else { false } })
        #expect(h.docker.current.inspectCalls.count == calls + 1)
        sut.syncDetails()
        #expect(h.docker.current.inspectCalls.count == calls + 1)

        h.docker.update {
            $0.containers[0].state = .exited
            $0.details[web.id] = Sample.containerDetails(web, state: .exited, startedAt: Date(timeIntervalSince1970: 1_000))
        }
        await h.store.refresh()
        sut.syncDetails()
        #expect(await eventually { if case .loaded(let details) = sut.details[web.id] { details.state == .exited } else { false } })

        sut.toggleExpanded(web.id)
        #expect(!sut.isExpanded(web.id))
    }

    @Test("Actions go to the router; the window is a live viewer while shown")
    func actionsAndViewing() async {
        let actions = Locked<[MenuAction]>([])
        let h = await StoreHarness().started()
        let sut = model(h, actions: actions)
        sut.perform(.startVM)
        sut.selectProfile(ProfileName("work"))
        #expect(actions.withLock { $0 } == [.startVM, .selectProfile(ProfileName("work"))])

        sut.appear()
        #expect(await eventually { h.store.snapshot.usage != nil })
        sut.disappear()
    }
}

@MainActor
@Suite("Live viewers")
struct LiveViewerTests {
    /// Advances the clock in steps until `condition` holds; false after a few steps.
    private func advance(_ h: StoreHarness, by step: Duration, until condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<6 {
            if condition() { return true }
            await h.clock.advance(by: step)
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("The window keeps the live refresh going after the menu closes")
    func windowKeepsRefreshing() async throws {
        let h = await StoreHarness().started()
        h.store.beginLiveUpdates(.mainWindow)
        h.store.menuWillOpen()
        h.store.menuDidClose()
        let before = h.colima.current.listCalls
        #expect(await advance(h, by: AppStore.liveInterval) { h.colima.current.listCalls > before })

        h.store.endLiveUpdates(.mainWindow)
        try await Task.sleep(for: .milliseconds(20))
        let after = h.colima.current.listCalls
        await h.clock.advance(by: AppStore.liveInterval * 2)
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.colima.current.listCalls == after)
    }

    @Test("Information keeps loading for the window after the submenu closes")
    func windowKeepsInformation() async throws {
        let h = await StoreHarness().started()
        #expect(await eventually { h.store.snapshot.docker == .reachable })
        h.store.beginInformationUpdates(.mainWindow)
        #expect(await eventually { h.store.snapshot.usage != nil })
        h.store.informationMenuWillOpen()
        h.store.informationMenuDidClose()

        h.colima.update { $0.usage.cpuCount = 9 }
        #expect(await advance(h, by: AppStore.informationInterval) { h.store.snapshot.usage?.cpuCount == 9 })

        h.store.endInformationUpdates(.mainWindow)
        h.colima.update { $0.usage.cpuCount = 7 }
        await h.clock.advance(by: AppStore.informationInterval * 2)
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.store.snapshot.usage?.cpuCount == 9)
    }
}

@Suite("Open Colima Desktop item")
struct OpenWindowItemTests {
    @Test("Sits between two separators above Start")
    func position() throws {
        let nodes = MenuModelBuilder.build(runningSnapshot())
        let index = try #require(nodes.firstIndex { $0.id == "open" })
        #expect(nodes[index].title == "Open Colima Desktop")
        #expect(nodes[index].action == .openMainWindow)
        #expect(nodes[index - 1].kind == .separator)
        #expect(nodes[index + 1].kind == .separator)
        #expect(nodes[index + 2].id == "vm.start")
    }
}
