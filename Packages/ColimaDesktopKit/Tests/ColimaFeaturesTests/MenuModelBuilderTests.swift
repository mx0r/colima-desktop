import ColimaDomain
import ColimaTestSupport
import Foundation
import Testing
@testable import ColimaFeatures

@Suite("MenuModelBuilder")
struct MenuModelBuilderTests {
    private let now = Date(timeIntervalSince1970: 1_791_003_600)

    private func snapshot(
        status: VMStatus? = .running,
        containers: [Container] = [],
        docker: DockerReachability = .reachable
    ) -> AppSnapshot {
        var snapshot = AppSnapshot()
        if let status {
            snapshot.profiles = [Sample.instance(status: status)]
            _ = snapshot.lifecycle.handle(.observed(status))
        }
        if status == .running {
            snapshot.details = Sample.details()
            snapshot.docker = docker
            snapshot.socketPath = "/tmp/docker.sock"
        }
        snapshot.containers = containers
        return snapshot
    }

    private func node(_ id: String, in nodes: [MenuNode]) -> MenuNode? {
        for node in nodes {
            if node.id == id { return node }
            if let found = self.node(id, in: node.children ?? []) { return found }
        }
        return nil
    }

    @Test("Top-level order follows the spec: status, info, VM actions, containers, app items, quit")
    func topLevelOrder() {
        let ids = MenuModelBuilder.build(snapshot(), updates: .check, now: now).map(\.id)
        #expect(ids == [
            "status", MenuNodeID.information, "profiles", "sep.vm",
            "vm.start", "vm.stop", "vm.restart", "sep.containers",
            "containers.empty", "sep.app", "settings", "about", "updates", "sep.quit", "quit",
        ])
    }

    @Test("Check for Updates, the pending update found in the background, or nothing without an updater")
    func updates() throws {
        #expect(node("updates", in: MenuModelBuilder.build(snapshot(), now: now)) == nil)

        let idle = try #require(node("updates", in: MenuModelBuilder.build(snapshot(), updates: .check, now: now)))
        #expect(idle.title == "Check for Updates…")
        #expect(idle.action == .checkForUpdates)

        let pending = try #require(node("updates", in: MenuModelBuilder.build(snapshot(), updates: .pending("0.6"), now: now)))
        #expect(pending.title == "Update to 0.6…")
        #expect(pending.action == .checkForUpdates)
        #expect(pending.image == .symbol("arrow.down.circle.fill"))
    }

    @MainActor
    @Test("The menu item follows the updater")
    func updatesItemFromUpdater() {
        let updater = FakeUpdater()
        #expect(UpdatesMenuItem(updater: nil) == .hidden)
        #expect(UpdatesMenuItem(updater: updater) == .check)
        updater.pendingUpdateVersion = "0.7"
        #expect(UpdatesMenuItem(updater: updater) == .pending("0.7"))
    }

    @Test("Running VM: stop and restart enabled, start disabled")
    func runningActions() {
        let nodes = MenuModelBuilder.build(snapshot(), now: now)
        #expect(node("vm.start", in: nodes)?.isEnabled == false)
        #expect(node("vm.stop", in: nodes)?.isEnabled == true)
        #expect(node("vm.restart", in: nodes)?.isEnabled == true)
        #expect(node("status", in: nodes)?.title == "Colima is running")
        #expect(node("status", in: nodes)?.image == .dot(.green))
    }

    @Test("Stopped VM: only start enabled, containers explained")
    func stoppedActions() {
        let nodes = MenuModelBuilder.build(snapshot(status: .stopped), now: now)
        #expect(node("vm.start", in: nodes)?.isEnabled == true)
        #expect(node("vm.stop", in: nodes)?.isEnabled == false)
        #expect(node("vm.restart", in: nodes)?.isEnabled == false)
        #expect(node("containers.none", in: nodes) != nil)
    }

    @Test("During an operation all VM actions are disabled and progress is shown")
    func transitioning() {
        var state = snapshot(status: .stopped)
        _ = state.lifecycle.handle(.requested(.start))
        state.progressMessage = "downloading image"
        let nodes = MenuModelBuilder.build(state, now: now)
        #expect(["vm.start", "vm.stop", "vm.restart"].allSatisfy { node($0, in: nodes)?.isEnabled == false })
        #expect(node("status", in: nodes)?.title == "Colima is starting…")
        #expect(node("status", in: nodes)?.subtitle == "downloading image")
        #expect(node("profiles", in: nodes)?.children?.allSatisfy { !$0.isEnabled } == true)
    }

    @Test("Missing colima is explained")
    func colimaMissing() {
        var state = AppSnapshot()
        _ = state.lifecycle.handle(.colimaMissing)
        let status = MenuModelBuilder.statusNode(state)
        #expect(status.title == "Colima not found")
        #expect(status.image == .dot(.red))
    }

    @Test("Unreachable Docker shows the reason")
    func dockerUnreachable() {
        let nodes = MenuModelBuilder.build(snapshot(docker: .unreachable("refused")), now: now)
        #expect(node("containers.unreachable", in: nodes)?.subtitle == "refused")
    }

    @Test("Containers are grouped by project with headers, stopped ones dimmed")
    func containerGroups() throws {
        let containers = [
            Sample.container("web", project: "shop", ports: [PublishedPort(privatePort: 80, publicPort: 8080, proto: "tcp")]),
            Sample.container("db", state: .exited, project: "shop"),
            Sample.container("solo"),
        ]
        let nodes = MenuModelBuilder.build(snapshot(containers: containers), now: now)
        let section = nodes.drop { $0.id != "sep.containers" }.dropFirst().prefix { $0.id != "sep.app" }
        #expect(section.map(\.id) == [
            "containers.header", "group.project:shop", containers[0].prefixID, containers[1].prefixID,
            "group.standalone", containers[2].prefixID,
        ])
        #expect(section.first?.title == "Containers (2 of 3 running)")

        let db = try #require(node(containers[1].prefixID, in: nodes))
        #expect(db.isDimmed)
        #expect(node("\(containers[1].prefixID).terminal", in: nodes)?.isEnabled == false)
        #expect(node("\(containers[1].prefixID).start", in: nodes) != nil)
        #expect(node("\(containers[1].prefixID).stop", in: nodes) == nil)

        let open = try #require(node("\(containers[0].prefixID).open.8080", in: nodes))
        #expect(open.action == .openURL(URL(string: "http://localhost:8080")!))
        #expect(node("\(containers[0].prefixID).stop", in: nodes)?.action == .container(.stop, containerID: containers[0].id, name: "web"))
        #expect(node("\(containers[0].prefixID).logs", in: nodes)?.action == .showLogs(containerID: containers[0].id, name: "web"))
    }

    @Test("Delete is enabled only for stopped containers")
    func deleteOnlyWhenStopped() throws {
        let web = Sample.container("web")
        let db = Sample.container("db", state: .exited)
        let created = Sample.container("job", state: .created)
        let nodes = MenuModelBuilder.build(snapshot(containers: [web, db, created]), now: now)

        let deleteDB = try #require(node("\(db.prefixID).delete", in: nodes))
        #expect(deleteDB.title == "Delete…")
        #expect(deleteDB.isEnabled)
        #expect(deleteDB.action == .container(.remove, containerID: db.id, name: "db"))
        #expect(node("\(created.prefixID).delete", in: nodes)?.isEnabled == true)

        let deleteWeb = try #require(node("\(web.prefixID).delete", in: nodes))
        #expect(!deleteWeb.isEnabled)
        #expect(deleteWeb.toolTip == "Stop the container first")
    }

    @Test("A pending container action disables its actions and shows progress")
    func pendingContainerAction() {
        let web = Sample.container("web")
        var state = snapshot(containers: [web])
        state.containerOperations[web.id] = .restart
        let nodes = MenuModelBuilder.build(state, now: now)
        #expect(node(web.prefixID, in: nodes)?.subtitle == "Restarting…")
        #expect(node("\(web.prefixID).stop", in: nodes)?.isEnabled == false)
    }

    @Test("Information shows loading rows until usage arrives, then values that copy")
    func information() throws {
        var state = snapshot()
        var info = MenuModelBuilder.informationNode(state)
        #expect(node("info.usage.loading", in: [info]) != nil)

        state.usage = VMUsage(
            loadAverage: LoadAverage(one: 0.5, five: 0.25, fifteen: 0),
            cpuCount: 4,
            memoryTotalBytes: 8 << 30,
            memoryAvailableBytes: 6 << 30,
            disks: [DiskUsage(mountPoint: "/var/lib/docker", totalBytes: 100, usedBytes: 25, availableBytes: 75)]
        )
        info = MenuModelBuilder.informationNode(state)
        let load = try #require(node("info.load", in: [info]))
        #expect(load.title == "Load average: 0.50  0.25  0.00")
        #expect(load.action == .copy("0.50  0.25  0.00"))
        #expect(node("info.disk./var/lib/docker", in: [info])?.title.contains("(25%)") == true)
        #expect(node("info.socket", in: [info])?.action == .copy("/tmp/docker.sock"))
    }

    @Test("Profile submenu checks the selected profile and lists unknown selections")
    func profiles() throws {
        var state = snapshot()
        state.profiles.append(Sample.instance("work", status: .stopped))
        state.selectedProfile = ProfileName("work")
        let profiles = try #require(MenuModelBuilder.profileNode(state).children)
        #expect(profiles.map(\.title) == ["default", "work"])
        #expect(profiles.map(\.isChecked) == [false, true])

        state.selectedProfile = ProfileName("new")
        let withNew = try #require(MenuModelBuilder.profileNode(state).children)
        #expect(withNew.map(\.title) == ["default", "new", "work"])
        #expect(withNew[1].subtitle == "Not created")
    }

    @Test("Destructive actions need confirmation")
    func confirmation() {
        #expect(MenuAction.stopVM.needsConfirmation)
        #expect(MenuAction.restartVM.needsConfirmation)
        #expect(!MenuAction.startVM.needsConfirmation)
        #expect(MenuAction.container(.stop, containerID: "a", name: "a").needsConfirmation)
        #expect(!MenuAction.container(.start, containerID: "a", name: "a").needsConfirmation)
        #expect(MenuAction.container(.remove, containerID: "a", name: "a").needsConfirmation)
    }
}

private extension Container {
    var prefixID: String { "container.\(id)" }
}
