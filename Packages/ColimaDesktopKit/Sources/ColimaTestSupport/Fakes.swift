import ColimaDomain
import ColimaFeatures
import Foundation
import Observation
import Synchronization

/// Scriptable colima.
public final class FakeColima: ColimaControlling {
    public struct State: Sendable {
        public var instances: [ColimaInstance] = []
        public var details: [ProfileName: ColimaInstanceDetails] = [:]
        public var listError: ColimaError?
        public var operationError: ColimaError?
        public var usage = VMUsage(
            loadAverage: LoadAverage(one: 0.1, five: 0.2, fifteen: 0.3),
            cpuCount: 4,
            memoryTotalBytes: 8 << 30,
            memoryAvailableBytes: 6 << 30,
            disks: [DiskUsage(mountPoint: "/", totalBytes: 100, usedBytes: 10, availableBytes: 90)]
        )
        public var version = "0.10.3"
        public var performed: [(VMOperation, ProfileName)] = []
        public var listCalls = 0
        public var progressLines: [String] = []
        /// When set, `perform` waits until `releaseOperation()`.
        public var holdOperations = false
        /// When set, `listInstances` waits until `releaseList()`.
        public var holdList = false
        /// Status set on the profile after a successful operation.
        public var applyOperationResult = true

        public init() {}
    }

    private let state: Mutex<State>
    private let operationGate = Gate()
    private let listGate = Gate()

    public init(_ state: State = State()) {
        self.state = Mutex(state)
    }

    /// Mutates the scripted state.
    public func update(_ change: (inout State) -> Void) {
        state.withLock { change(&$0) }
    }

    /// Reads the scripted state.
    public var current: State { state.withLock { $0 } }

    public func releaseOperation() { operationGate.open() }
    public func releaseList() { listGate.open() }

    public func listInstances() async throws -> [ColimaInstance] {
        let (hold, error) = state.withLock { state -> (Bool, ColimaError?) in
            state.listCalls += 1
            return (state.holdList, state.listError)
        }
        if hold { await listGate.wait() }
        if let error { throw error }
        return state.withLock { $0.instances }
    }

    public func details(of profile: ProfileName) async throws -> ColimaInstanceDetails? {
        state.withLock { state in
            guard state.instances.first(where: { $0.profile == profile })?.status == .running else { return nil }
            return state.details[profile]
        }
    }

    public func perform(_ operation: VMOperation, on profile: ProfileName, progress: @escaping @Sendable (String) -> Void) async throws {
        let (hold, lines) = state.withLock { state -> (Bool, [String]) in
            state.performed.append((operation, profile))
            return (state.holdOperations, state.progressLines)
        }
        lines.forEach(progress)
        if hold { await operationGate.wait() }
        try state.withLock { state in
            if let error = state.operationError { throw error }
            guard state.applyOperationResult, let index = state.instances.firstIndex(where: { $0.profile == profile }) else { return }
            state.instances[index].status = operation.targetStatus
        }
    }

    public func usage(of profile: ProfileName) async throws -> VMUsage {
        state.withLock { $0.usage }
    }

    public func version() async throws -> String {
        state.withLock { $0.version }
    }
}

/// Scriptable Docker engine.
public final class FakeDockerEngine: DockerEngine {
    public struct State: Sendable {
        public var containers: [Container] = []
        public var reachable = true
        public var actionError: DockerError?
        public var actions: [(ContainerAction, String)] = []
        public var summary = EngineSummary(
            serverVersion: "29.5.2", apiVersion: "1.54", operatingSystem: "Ubuntu", kernelVersion: "6.8",
            architecture: "aarch64", cpuCount: 4, memoryTotalBytes: 8 << 30, containersTotal: 1,
            containersRunning: 1, containersPaused: 0, containersStopped: 0, images: 1, storageDriver: "overlayfs"
        )
        public var execCommands: [[String]] = []
        public var logRequests: [LogOptions] = []
        /// Answer to every image search.
        public var searchResults: [ImageSearchResult] = []
        /// Fails image searches when set.
        public var searchError: DockerError?
        /// Search terms asked for, in order.
        public var searchTerms: [String] = []
        /// Messages every pull yields.
        public var pullMessages: [PullMessage] = []
        /// Fails pulls after their messages when set.
        public var pullError: DockerError?
        /// Keeps pulls open after their messages until the consumer cancels.
        public var pullHangs = false
        /// Images pulled, in order.
        public var pulls: [ImageReference] = []
        /// Answers to container creates, used in order; when empty, creates succeed with ID "new1".
        public var createResults: [Result<CreatedContainer, DockerError>] = []
        /// Specs of container creates, in order.
        public var createdSpecs: [ContainerSpec] = []

        public init() {}
    }

    private let state: Mutex<State>
    private let logContinuations = Mutex<[AsyncThrowingStream<[LogLine], Error>.Continuation]>([])
    private let eventContinuations = Mutex<[AsyncThrowingStream<DockerEvent, Error>.Continuation]>([])
    /// Session handed out by `exec`.
    public let execSession = FakeExecSession()

    public init(_ state: State = State()) {
        self.state = Mutex(state)
    }

    public func update(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }
    public var current: State { state.withLock { $0 } }

    /// Sends log lines to the most recent log stream.
    public func emitLogs(_ lines: [LogLine]) {
        _ = logContinuations.withLock { $0.last?.yield(lines) }
    }

    /// Ends the most recent log stream.
    public func endLogs(throwing error: Error? = nil) {
        logContinuations.withLock { $0.last?.finish(throwing: error) }
    }

    /// Sends an event to all event streams.
    public func emitEvent(_ event: DockerEvent) {
        eventContinuations.withLock { $0.forEach { $0.yield(event) } }
    }

    private func checkReachable() throws {
        if !state.withLock({ $0.reachable }) {
            throw DockerError.socketUnavailable(path: "/fake.sock", reason: "refused")
        }
    }

    public func verifyCompatibility() async throws { try checkReachable() }

    public func summary() async throws -> EngineSummary {
        try checkReachable()
        return state.withLock { $0.summary }
    }

    public func diskUsage() async throws -> DiskUsageSummary {
        try checkReachable()
        return DiskUsageSummary(images: .empty, containers: .empty, volumes: .empty, buildCache: .empty)
    }

    public func containers() async throws -> [Container] {
        try checkReachable()
        return state.withLock { $0.containers }
    }

    public func inspect(containerID: String) async throws -> ContainerDetails {
        throw DockerError.api(status: 404, message: "not scripted")
    }

    public func perform(_ action: ContainerAction, containerID: String) async throws {
        try state.withLock { state in
            state.actions.append((action, containerID))
            if let error = state.actionError { throw error }
            if action == .remove { state.containers.removeAll { $0.id == containerID } }
        }
    }

    public func logs(containerID: String, options: LogOptions) -> AsyncThrowingStream<[LogLine], Error> {
        state.withLock { $0.logRequests.append(options) }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [LogLine].self)
        logContinuations.withLock { $0.append(continuation) }
        return stream
    }

    public func events() -> AsyncThrowingStream<DockerEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DockerEvent.self)
        eventContinuations.withLock { $0.append(continuation) }
        return stream
    }

    public func exec(containerID: String, command: [String], size: TerminalSize) async throws -> any ExecSession {
        state.withLock { $0.execCommands.append(command) }
        return execSession
    }

    public func searchImages(term: String, limit: Int) async throws -> [ImageSearchResult] {
        try checkReachable()
        return try state.withLock { state in
            state.searchTerms.append(term)
            if let error = state.searchError { throw error }
            return state.searchResults
        }
    }

    public func pullImage(_ reference: ImageReference) -> AsyncThrowingStream<PullMessage, Error> {
        let (messages, error, hangs) = state.withLock { state in
            state.pulls.append(reference)
            return (state.pullMessages, state.pullError, state.pullHangs)
        }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PullMessage.self)
        for message in messages { continuation.yield(message) }
        if let error {
            continuation.finish(throwing: error)
        } else if !hangs {
            continuation.finish()
        }
        return stream
    }

    public func createContainer(_ spec: ContainerSpec) async throws -> CreatedContainer {
        try checkReachable()
        let result: Result<CreatedContainer, DockerError> = state.withLock { state in
            state.createdSpecs.append(spec)
            return state.createResults.isEmpty ? .success(CreatedContainer(id: "new1", warnings: [])) : state.createResults.removeFirst()
        }
        return try result.get()
    }
}

/// Scriptable exec session.
public final class FakeExecSession: ExecSession {
    public let output: AsyncThrowingStream<[UInt8], Error>
    private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private let written = Mutex<[[UInt8]]>([])
    private let resizes = Mutex<[TerminalSize]>([])
    private let code = Mutex<Int?>(nil)

    public init() {
        (output, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self)
    }

    public var writes: [[UInt8]] { written.withLock { $0 } }
    public var sizes: [TerminalSize] { resizes.withLock { $0 } }

    /// Emits terminal output.
    public func emit(_ bytes: [UInt8]) { continuation.yield(bytes) }

    /// Ends the process with an exit code.
    public func exit(_ exitCode: Int) {
        code.withLock { $0 = exitCode }
        continuation.finish()
    }

    public func write(_ bytes: [UInt8]) async throws { written.withLock { $0.append(bytes) } }
    public func resize(_ size: TerminalSize) async throws { resizes.withLock { $0.append(size) } }
    public func exitCode() async throws -> Int? { code.withLock { $0 } }
    public func close() async { continuation.finish() }
}

/// File watcher whose changes are triggered by the test.
public final class FakeFileWatcher: FileChangeObserving {
    private let continuations = Mutex<[AsyncStream<Void>.Continuation]>([])
    private let watched = Mutex<[[URL]]>([])

    public init() {}

    /// Directory lists passed to `changes(in:)`, in call order.
    public var watchedDirectories: [[URL]] { watched.withLock { $0 } }

    /// Emits a change on all streams.
    public func emit() {
        continuations.withLock { $0.forEach { $0.yield() } }
    }

    public func changes(in directories: [URL]) -> AsyncStream<Void> {
        watched.withLock { $0.append(directories) }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        continuations.withLock { $0.append(continuation) }
        return stream
    }
}

/// Records notifications.
public final class RecordingNotifier: UserNotifying {
    private let posts = Mutex<[(title: String, body: String)]>([])

    public init() {}

    public var posted: [(title: String, body: String)] { posts.withLock { $0 } }

    public func post(title: String, body: String) async {
        posts.withLock { $0.append((title, body)) }
    }
}

/// Settings kept in memory.
public final class InMemorySettingsStore: SettingsPersisting {
    private let value: Mutex<AppSettings>

    public init(_ settings: AppSettings = .defaults) {
        value = Mutex(settings)
    }

    public var saved: AppSettings { value.withLock { $0 } }

    public func load() -> AppSettings { value.withLock { $0 } }
    public func save(_ settings: AppSettings) { value.withLock { $0 = settings } }
}

/// Updater stub.
@MainActor
@Observable
public final class FakeUpdater: UpdateControlling {
    public var automaticallyChecksForUpdates = true
    public var pendingUpdateVersion: String?
    public var automaticallyDownloadsUpdates = true
    public var allowsAutomaticUpdates = true
    public var readyToInstallVersion: String?
    public private(set) var checkCount = 0
    public private(set) var installCount = 0

    public init() {}

    public func checkForUpdates() { checkCount += 1 }
    public func installUpdateAndRelaunch() { installCount += 1 }
}

/// Login item stub.
@MainActor
public final class FakeLoginItem: LoginItemControlling {
    public var status: LoginItemStatus = .disabled
    public var error: Error?

    public init() {}

    public func setEnabled(_ enabled: Bool) throws {
        if let error { throw error }
        status = enabled ? .enabled : .disabled
    }

    public func openSystemSettings() {}
}

/// One-shot gate tasks can wait on.
final class Gate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { state -> Bool in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// Sample values for tests.
public enum Sample {
    public static func instance(_ name: String = "default", status: VMStatus = .running) -> ColimaInstance {
        ColimaInstance(profile: ProfileName(name), status: status, arch: "aarch64", cpus: 4, memoryBytes: 8 << 30, diskBytes: 100 << 30, runtime: "docker")
    }

    public static func details(socket: String = "/tmp/docker.sock", runtime: String = "docker") -> ColimaInstanceDetails {
        ColimaInstanceDetails(
            displayName: "colima", driver: "vz", arch: "aarch64", runtime: runtime, mountType: "virtiofs",
            dockerSocketPath: runtime == "docker" ? socket : nil, containerdSocketPath: nil, kubernetes: false,
            cpus: 4, memoryBytes: 8 << 30, diskBytes: 100 << 30
        )
    }

    public static func container(
        _ name: String,
        state: ContainerState = .running,
        project: String? = nil,
        ports: [PublishedPort] = []
    ) -> Container {
        Container(
            id: "\(name)-0123456789abcdef",
            name: name,
            image: "\(name):latest",
            state: state,
            statusText: state == .running ? "Up 5 minutes" : "Exited (0) 1 hour ago",
            created: Date(timeIntervalSince1970: 1_791_000_000),
            ports: ports,
            labels: project.map { [Container.composeProjectLabel: $0, Container.composeServiceLabel: name] } ?? [:]
        )
    }

    public static func paths() -> ColimaPaths {
        ColimaPaths(colimaHome: URL(filePath: "/tmp/colima/", directoryHint: .isDirectory), limaHome: URL(filePath: "/tmp/colima/_lima/", directoryHint: .isDirectory))
    }
}

/// A thread-safe, copyable reference to a value.
public final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    public init(_ value: Value) {
        mutex = Mutex(value)
    }

    public var value: Value { mutex.withLock { $0 } }

    @discardableResult
    public func withLock<R: Sendable>(_ body: (inout Value) -> R) -> R {
        mutex.withLock { body(&$0) }
    }
}

/// Scriptable image catalog.
public final class FakeImageCatalog: ImageCatalog {
    public struct State: Sendable {
        /// Answer to every search.
        public var results: [ImageSearchResult] = []
        /// Fails searches when set.
        public var searchError: ImageCatalogError?
        /// Tags by repository; references without an entry belong to another registry (nil).
        public var tags: [String: [ImageTag]] = [:]
        /// Fails tag loads when set.
        public var tagsError: ImageCatalogError?
        /// Search terms asked for, in order.
        public var searches: [String] = []
        /// Repositories whose tags were asked for, in order.
        public var tagRequests: [String] = []

        public init() {}
    }

    public let name: String
    private let state: Mutex<State>

    public init(name: String = "Docker Hub", _ state: State = State()) {
        self.name = name
        self.state = Mutex(state)
    }

    public func update(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }
    public var current: State { state.withLock { $0 } }

    public func search(_ term: String, limit: Int) async throws -> [ImageSearchResult] {
        try state.withLock { state in
            state.searches.append(term)
            if let error = state.searchError { throw error }
            return state.results
        }
    }

    public func tags(of reference: ImageReference) async throws -> [ImageTag]? {
        try state.withLock { state in
            state.tagRequests.append(reference.repository)
            if let error = state.tagsError { throw error }
            return state.tags[reference.repository]
        }
    }
}
