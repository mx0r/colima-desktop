import Foundation

/// Controls Colima VMs. Implemented by the colima CLI adapter.
public protocol ColimaControlling: Sendable {
    /// Lists all profiles.
    func listInstances() async throws -> [ColimaInstance]

    /// Details of a running profile; nil when the profile is not running.
    func details(of profile: ProfileName) async throws -> ColimaInstanceDetails?

    /// Runs start, stop or restart. `progress` receives status lines while the command runs.
    func perform(
        _ operation: VMOperation,
        on profile: ProfileName,
        progress: @escaping @Sendable (String) -> Void
    ) async throws

    /// Measures live resource usage inside the VM.
    func usage(of profile: ProfileName) async throws -> VMUsage

    /// Colima version string, e.g. `0.10.3`.
    func version() async throws -> String
}

/// A container action the user can trigger.
public enum ContainerAction: Hashable, Sendable {
    case start
    case stop
    case restart
    /// Deletes a stopped container (no force, volumes are kept).
    case remove
}

/// Terminal grid size.
public struct TerminalSize: Hashable, Sendable {
    public var columns: Int
    public var rows: Int

    /// Creates a size.
    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

/// Image search on Docker Hub through an engine.
public protocol ImageSearching: Sendable {
    /// Repositories on Docker Hub matching a term, in the engine's order.
    func searchImages(term: String, limit: Int) async throws -> [ImageSearchResult]
}

/// Docker Engine API access for one engine (one socket).
public protocol DockerEngine: ImageSearching {
    /// Checks that the engine is reachable and speaks a supported API version.
    func verifyCompatibility() async throws

    /// Engine facts from `/version` and `/info`.
    func summary() async throws -> EngineSummary

    /// Disk usage from `/system/df`.
    func diskUsage() async throws -> DiskUsageSummary

    /// All containers, including stopped ones.
    func containers() async throws -> [Container]

    /// Inspects one container.
    func inspect(containerID: String) async throws -> ContainerDetails

    /// Starts, stops, restarts or deletes a container.
    func perform(_ action: ContainerAction, containerID: String) async throws

    /// Streams decoded log lines in batches. Cancel the consuming task to stop.
    func logs(containerID: String, options: LogOptions) -> AsyncThrowingStream<[LogLine], Error>

    /// Streams container events. Cancel the consuming task to stop.
    func events() -> AsyncThrowingStream<DockerEvent, Error>

    /// Starts an interactive TTY process in a container.
    func exec(containerID: String, command: [String], size: TerminalSize) async throws -> any ExecSession

    /// Pulls an image, streaming Docker's progress messages. Fails with `DockerError.pullFailed`
    /// when the engine reports an error mid-stream. Cancel the consuming task to stop the pull.
    func pullImage(_ reference: ImageReference) -> AsyncThrowingStream<PullMessage, Error>

    /// Creates (does not start) a container. A missing image fails with HTTP 404.
    func createContainer(_ spec: ContainerSpec) async throws -> CreatedContainer
}

/// An interactive process inside a container.
public protocol ExecSession: Sendable {
    /// Raw terminal output. Finishes when the process exits or the connection closes.
    var output: AsyncThrowingStream<[UInt8], Error> { get }

    /// Sends keyboard input.
    func write(_ bytes: [UInt8]) async throws

    /// Resizes the pseudo terminal.
    func resize(_ size: TerminalSize) async throws

    /// Exit code once the process has ended; nil while it runs.
    func exitCode() async throws -> Int?

    /// Closes the connection. The process may keep running if it ignores SIGHUP.
    func close() async
}

/// Watches directories for entry changes (files created, deleted or renamed).
public protocol FileChangeObserving: Sendable {
    /// Emits whenever an entry in one of the directories changes.
    /// A missing directory is watched through its nearest existing parent.
    func changes(in directories: [URL]) -> AsyncStream<Void>
}

/// Loads and stores settings.
public protocol SettingsPersisting: Sendable {
    /// Loads settings, falling back to defaults.
    func load() -> AppSettings
    /// Stores settings.
    func save(_ settings: AppSettings)
}

/// Posts user notifications.
public protocol UserNotifying: Sendable {
    /// Posts a notification. Asks for permission on first use.
    func post(title: String, body: String) async
}

/// State of the launch-at-login registration.
public enum LoginItemStatus: Hashable, Sendable {
    case enabled
    case disabled
    /// Registered, but the user must allow it in System Settings.
    case requiresApproval
}

/// Registers the app as a login item.
@MainActor
public protocol LoginItemControlling: AnyObject {
    /// Current registration state. Read live; never cache it.
    var status: LoginItemStatus { get }
    /// Registers or unregisters the app.
    func setEnabled(_ enabled: Bool) throws
    /// Opens System Settings → Login Items.
    func openSystemSettings()
}

/// Checks for and installs new versions of the app.
@MainActor
public protocol UpdateControlling: AnyObject {
    /// Whether updates are checked in the background on a schedule.
    var automaticallyChecksForUpdates: Bool { get set }
    /// Version found by a background check and not yet shown to the user; nil when none.
    var pendingUpdateVersion: String? { get }
    /// Download updates in the background and install them when the app quits (or on request).
    var automaticallyDownloadsUpdates: Bool { get set }
    /// Whether automatic downloads can be switched on; false while automatic checks are off.
    var allowsAutomaticUpdates: Bool { get }
    /// Version downloaded in the background and ready to install; nil when none.
    var readyToInstallVersion: String? { get }
    /// Starts a user-initiated check, with progress and result shown by the updater.
    func checkForUpdates()
    /// Installs the downloaded update now and relaunches the app.
    func installUpdateAndRelaunch()
}

/// Finds executables on the host.
public protocol ExecutableLocating: Sendable {
    /// Path of the colima executable: the override when executable, otherwise a search result; nil if not found.
    func locateColima(override: String?) -> URL?
}
