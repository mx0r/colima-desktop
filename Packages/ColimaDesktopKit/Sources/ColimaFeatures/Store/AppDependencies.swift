import ColimaDomain
import Foundation

/// Values detected on the host for the current settings (shown as placeholders in Settings).
public struct DetectedEnvironment: Hashable, Sendable {
    /// colima executable found (honoring the override), nil when missing.
    public var colimaExecutable: String?
    /// colima executable found without the override.
    public var autoColimaExecutable: String?
    /// Resolved directories.
    public var paths: ColimaPaths

    /// Creates a detected environment.
    public init(colimaExecutable: String?, autoColimaExecutable: String?, paths: ColimaPaths) {
        self.colimaExecutable = colimaExecutable
        self.autoColimaExecutable = autoColimaExecutable
        self.paths = paths
    }
}

/// Ports and factories the features need. Built by the composition root.
public struct AppDependencies: Sendable {
    /// Settings storage.
    public var settingsStore: any SettingsPersisting
    /// Detects executables and directories for settings.
    public var detectEnvironment: @Sendable (AppSettings) -> DetectedEnvironment
    /// Creates a colima client for settings.
    public var makeColima: @Sendable (AppSettings) -> any ColimaControlling
    /// Creates a Docker client for a socket path.
    public var makeDocker: @Sendable (String) -> any DockerEngine
    /// Directory change notifications.
    public var fileWatcher: any FileChangeObserving
    /// User notifications.
    public var notifier: any UserNotifying
    /// Clock for timers and debouncing.
    public var clock: any Clock<Duration>

    /// Creates dependencies.
    public init(
        settingsStore: any SettingsPersisting,
        detectEnvironment: @escaping @Sendable (AppSettings) -> DetectedEnvironment,
        makeColima: @escaping @Sendable (AppSettings) -> any ColimaControlling,
        makeDocker: @escaping @Sendable (String) -> any DockerEngine,
        fileWatcher: any FileChangeObserving,
        notifier: any UserNotifying,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.settingsStore = settingsStore
        self.detectEnvironment = detectEnvironment
        self.makeColima = makeColima
        self.makeDocker = makeDocker
        self.fileWatcher = fileWatcher
        self.notifier = notifier
        self.clock = clock
    }
}
