import ColimaDomain
import ColimaFeatures
import Foundation
import Testing
@testable import ColimaInfrastructure

/// Runs against the colima and Docker on this machine. Enable with `COLIMA_DESKTOP_IT=1`.
/// Requires the default profile to be running with the Docker runtime. Read-only except for a short
/// exec and a throwaway hello-world container (pulled if missing, removed at the end).
private let enabled = ProcessInfo.processInfo.environment["COLIMA_DESKTOP_IT"] == "1"

@Suite("Live colima and Docker", .enabled(if: enabled), .serialized)
struct LiveColimaTests {
    private let environment = ProcessInfo.processInfo.environment

    private func colima() throws -> ColimaCLIClient {
        let locator = ExecutableLocator(pathVariable: "/usr/bin:/bin")
        let executable = try #require(locator.locateColima(override: nil), "colima not found")
        return ColimaCLIClient(
            executable: executable,
            environment: ChildEnvironment.make(base: ["HOME": NSHomeDirectory()], executable: executable, colimaHome: nil, limaHome: nil),
            runner: FoundationProcessRunner()
        )
    }

    private func docker() async throws -> DockerEngineClient {
        let details = try #require(try await colima().details(of: .default), "default profile is not running")
        let socket = try #require(details.dockerSocketPath, "no Docker socket")
        return DockerEngineClient(socketPath: socket)
    }

    @Test("colima list, status, version and usage work with a minimal PATH")
    func colimaQueries() async throws {
        let client = try colima()
        let instances = try await client.listInstances()
        #expect(instances.contains { $0.profile == .default })
        let details = try await client.details(of: .default)
        #expect(details?.dockerSocketPath != nil)
        #expect(try await client.version().isEmpty == false)
        let usage = try await client.usage(of: .default)
        #expect(usage.memoryTotalBytes > 0)
        #expect(!usage.disks.isEmpty)
    }

    @Test("Docker queries over the unix socket")
    func dockerQueries() async throws {
        let engine = try await docker()
        try await engine.verifyCompatibility()
        let containers = try await engine.containers()
        let summary = try await engine.summary()
        #expect(summary.containersTotal == containers.count)
        _ = try await engine.diskUsage()
        if let first = containers.first {
            let details = try await engine.inspect(containerID: first.id)
            #expect(details.id == first.id)
        }
    }

    @Test("Logs of a running container (no follow)")
    func logs() async throws {
        let engine = try await docker()
        let running = try #require(try await engine.containers().first { $0.state == .running }, "no running container")
        var count = 0
        for try await batch in engine.logs(containerID: running.id, options: LogOptions(follow: false, tail: 20)) {
            count += batch.count
        }
        #expect(count <= 20)
    }

    @Test("Exec through the hijacked connection")
    func exec() async throws {
        let engine = try await docker()
        let running = try #require(try await engine.containers().first { $0.state == .running }, "no running container")
        let session = try await engine.exec(
            containerID: running.id,
            command: ["/bin/sh", "-c", "echo colima-desktop-$((40+2))"],
            size: TerminalSize(columns: 80, rows: 24)
        )
        var output: [UInt8] = []
        for try await bytes in session.output { output += bytes }
        #expect(String(decoding: output, as: UTF8.self).contains("colima-desktop-42"))
        #expect(try await session.exitCode() == 0)
    }

    @Test("Events stream connects and can be cancelled")
    func events() async throws {
        let engine = try await docker()
        let task = Task {
            for try await _ in engine.events() {}
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = await task.result
    }

    @Test("The menu built from live data lists every container")
    @MainActor
    func liveMenu() async throws {
        let client = try colima()
        let engine = try await docker()
        var snapshot = AppSnapshot()
        snapshot.profiles = try await client.listInstances()
        _ = snapshot.lifecycle.handle(.observed(snapshot.selectedInstance?.status ?? .uninitialized))
        snapshot.details = try await client.details(of: .default)
        snapshot.docker = .reachable
        snapshot.containers = try await engine.containers()
        snapshot.usage = try await client.usage(of: .default)
        snapshot.engine = try await engine.summary()

        let nodes = MenuModelBuilder.build(snapshot)
        func dump(_ nodes: [MenuNode], depth: Int = 0) -> [String] {
            nodes.flatMap { node -> [String] in
                let indent = String(repeating: "  ", count: depth)
                let line: String = switch node.kind {
                case .separator: "\(indent)────"
                case .header: "\(indent)[\(node.title)]"
                default: "\(indent)\(node.title)\(node.subtitle.map { " — \($0)" } ?? "")\(node.isEnabled ? "" : " (disabled)")"
                }
                return [line] + dump(node.children ?? [], depth: depth + 1)
            }
        }
        let text = dump(nodes).joined(separator: "\n")
        print(text)
        for container in snapshot.containers {
            #expect(text.contains(container.name))
        }
    }

    @Test("Search, Docker Hub tags, pull, create, start and remove a hello-world container")
    func newContainer() async throws {
        let engine = try await docker()
        try await engine.verifyCompatibility()
        let catalog = DockerHubCatalog(engine: engine)
        let results = try await catalog.search("hello-world", limit: 5)
        #expect(results.first?.name == "hello-world")
        let reference = try #require(ImageReference("hello-world"))
        let tags = try #require(try await catalog.tags(of: reference))
        #expect(tags.contains { $0.name == "latest" })

        var progress = PullProgress()
        for try await message in engine.pullImage(reference) { progress.apply(message) }
        #expect(progress.error == nil)
        #expect(progress.status?.hasPrefix("Status:") == true)

        let name = "colima-desktop-it-\(UUID().uuidString.prefix(8).lowercased())"
        let created = try await engine.createContainer(ContainerSpec(image: reference, name: name, environment: [EnvironmentVariable(name: "IT", value: "1")]))
        do {
            #expect(try await engine.inspect(containerID: created.id).name == name)
            try await engine.perform(.start, containerID: created.id)
            // hello-world prints and exits; wait for that before removing it.
            for _ in 0..<40 where try await engine.inspect(containerID: created.id).state.isAlive {
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch {
            try? await engine.perform(.stop, containerID: created.id)
            try? await engine.perform(.remove, containerID: created.id)
            throw error
        }
        try await engine.perform(.remove, containerID: created.id)
    }

    @Test("Real status texts get exact durations from inspect times")
    func statusDurations() async throws {
        let engine = try await docker()
        for var container in try await engine.containers() {
            let details = try await engine.inspect(containerID: container.id)
            container.startedAt = details.startedAt
            container.finishedAt = details.finishedAt
            let text = Format.status(of: container)
            if container.statusText.hasPrefix("Up ") || container.statusText.hasPrefix("Exited (") {
                #expect(text.wholeMatch(of: #/(Up|Exited \(-?\d+\)) \d+[dhms]( \d+[hms])?( ago)?( \(.+\))?/#) != nil, "\(container.statusText) → \(text)")
            }
            print("status: \(container.statusText) → \(text)")
        }
    }
}

