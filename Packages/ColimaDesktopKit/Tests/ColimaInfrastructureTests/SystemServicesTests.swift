import ColimaDomain
import Foundation
import Synchronization
import Testing
@testable import ColimaInfrastructure

@Suite("System adapters")
struct SystemServicesTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "colima-desktop-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Counts stream elements in the background.
    private final class EventCounter: Sendable {
        private let count = Mutex(0)
        private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

        init(_ stream: AsyncStream<Void>) {
            let task = Task { [self] in
                for await _ in stream { self.count.withLock { $0 += 1 } }
            }
            self.task.withLock { $0 = task }
        }

        var value: Int { count.withLock { $0 } }

        func cancel() { task.withLock { $0?.cancel() } }

        /// Polls until the count reaches `target` or the timeout passes.
        func waitFor(_ target: Int, timeout: Duration = .seconds(3)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if value >= target { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return value >= target
        }
    }

    @Test("Creating a file in a watched directory emits a change")
    func watchDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = EventCounter(DispatchFileWatcher().changes(in: [root]))
        defer { events.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        try Data("1".utf8).write(to: root.appending(path: "ha.pid"))
        #expect(await events.waitFor(1))
    }

    @Test("A missing directory is watched through its parent and picked up once created")
    func watchMissingDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appending(path: "work", directoryHint: .isDirectory)
        let events = EventCounter(DispatchFileWatcher().changes(in: [profile]))
        defer { events.cancel() }
        try await Task.sleep(for: .milliseconds(100))

        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        #expect(await events.waitFor(1))

        try await Task.sleep(for: .milliseconds(100))
        let before = events.value
        try Data().write(to: profile.appending(path: "docker.sock"))
        #expect(await events.waitFor(before + 1))
    }

    @Test("Settings round-trip through UserDefaults and fall back to defaults")
    func settingsStore() throws {
        let suite = "colima-desktop-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        #expect(store.load() == .defaults)

        let settings = AppSettings(colimaExecutablePath: "/x/colima", heartbeatSeconds: 5, selectedProfile: ProfileName("work"))
        store.save(settings)
        #expect(store.load() == settings)

        defaults.set(Data("garbage".utf8), forKey: "settings.v1")
        #expect(store.load() == .defaults)
    }
}
