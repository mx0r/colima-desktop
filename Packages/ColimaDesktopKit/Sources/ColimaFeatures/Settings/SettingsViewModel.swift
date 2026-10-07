import ColimaDomain
import Foundation
import Observation

/// Editable settings. Changes are applied to the store after a short pause in typing.
@MainActor
@Observable
public final class SettingsViewModel {
    /// Settings being edited.
    public var draft: AppSettings {
        didSet {
            guard draft != oldValue else { return }
            scheduleApply()
        }
    }

    /// Launch-at-login state, read live.
    public private(set) var loginItemStatus: LoginItemStatus
    /// Last login item error.
    public private(set) var loginItemError: String?

    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private let loginItem: any LoginItemControlling
    @ObservationIgnored private let updater: (any UpdateControlling)?
    @ObservationIgnored private let appURL: URL
    @ObservationIgnored private let applicationDirectories: [URL]
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var applyTask: Task<Void, Never>?

    /// Delay between the last edit and applying it.
    static let applyDelay = Duration.milliseconds(700)

    /// Creates a view model for the store's current settings.
    ///
    /// - Parameters:
    ///   - appURL: Location of the running app (tests inject one).
    ///   - applicationDirectories: The Applications folders, `/Applications` and `~/Applications`.
    public init(
        store: AppStore,
        loginItem: any LoginItemControlling,
        updater: (any UpdateControlling)? = nil,
        appURL: URL = Bundle.main.bundleURL,
        applicationDirectories: [URL] = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask]),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.store = store
        self.loginItem = loginItem
        self.updater = updater
        self.appURL = appURL
        self.applicationDirectories = applicationDirectories
        self.clock = clock
        draft = store.settings
        loginItemStatus = loginItem.status
    }

    /// Values detected for the draft (placeholders and validation).
    public var detected: DetectedEnvironment {
        store.detectEnvironment(for: draft)
    }

    /// Profiles known to the store, for per-profile socket overrides.
    public var profiles: [ProfileName] {
        let names = store.snapshot.profiles.map(\.profile)
        return names.isEmpty ? [store.snapshot.selectedProfile] : names
    }

    /// Socket path colima reports for a profile, or the default path.
    public func detectedSocket(for profile: ProfileName) -> String {
        if profile == store.snapshot.selectedProfile, let path = store.snapshot.details?.dockerSocketPath {
            return path
        }
        return detected.paths.defaultDockerSocket(profile).path(percentEncoded: false)
    }

    /// Warning for the colima path override, if it is set but not executable.
    public var colimaPathWarning: String? {
        guard let override = draft.colimaExecutablePath?.trimmingCharacters(in: .whitespaces), !override.isEmpty else {
            return detected.autoColimaExecutable == nil ? "colima was not found in PATH or Homebrew locations." : nil
        }
        return detected.colimaExecutable == nil ? "Not found or not executable." : nil
    }

    /// Binding helper for optional string settings: empty text means auto.
    public func setOptional(_ keyPath: WritableKeyPath<AppSettings, String?>, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        draft[keyPath: keyPath] = trimmed.isEmpty ? nil : text
    }

    /// Switches the menu bar icon style. Applied at once so the menu bar updates while the user compares styles.
    public func selectMenuBarIconStyle(_ style: MenuBarIconStyle) {
        draft.menuBarIconStyle = style
        applyNow()
    }

    /// Sets the appearance of interface, terminal or logs windows. Applied at once so open windows switch while the user compares.
    public func selectAppearance(_ mode: AppearanceMode, for role: WindowRole) {
        switch role {
        case .interface: draft.interfaceAppearance = mode
        case .console(.terminal): draft.terminalAppearance = mode
        case .console(.logs): draft.logsAppearance = mode
        }
        applyNow()
    }

    /// Sets the font and spacing of the terminal or the logs. Applied at once so open windows follow while the user adjusts it.
    public func setTextStyle(_ style: ConsoleTextStyle, for console: ConsoleKind) {
        draft.setTextStyle(style, for: console)
        applyNow()
    }

    /// Sets or clears the socket override for a profile.
    public func setSocketOverride(_ text: String, for profile: ProfileName) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            draft.dockerSocketOverrides[profile.rawValue] = nil
        } else {
            draft.dockerSocketOverrides[profile.rawValue] = text
        }
    }

    /// Applies pending edits immediately (e.g. when the window closes).
    public func applyNow() {
        applyTask?.cancel()
        applyTask = nil
        store.updateSettings(draft)
    }

    /// Restores defaults (keeps the selected profile).
    public func resetToDefaults() {
        var defaults = AppSettings.defaults
        defaults.selectedProfile = draft.selectedProfile
        draft = defaults
    }

    /// Turns launch at login on or off.
    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        loginItemStatus = loginItem.status
    }

    /// Re-reads the login item state (e.g. after returning from System Settings).
    public func refreshLoginItemStatus() {
        loginItemStatus = loginItem.status
    }

    /// Whether this copy runs from outside `/Applications` and `~/Applications`. macOS registers
    /// the login item for this copy's path, so the user should turn it on from an installed copy.
    public var isOutsideApplicationsFolder: Bool {
        let appPath = appURL.standardizedFileURL.path(percentEncoded: false)
        return !applicationDirectories.contains { directory in
            var folder = directory.standardizedFileURL.path(percentEncoded: false)
            if !folder.hasSuffix("/") { folder += "/" }
            return appPath.hasPrefix(folder)
        }
    }

    /// Whether the app can update itself (false in builds without an updater).
    public var hasUpdater: Bool { updater != nil }

    /// Background update checks. Persisted by the updater itself.
    public var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    /// Background download and install of updates. Persisted by the updater itself.
    public var automaticallyDownloadsUpdates: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    /// Whether the automatic-download switch can be used (it needs automatic checks).
    public var canChangeAutomaticDownloads: Bool {
        updater?.allowsAutomaticUpdates ?? false
    }

    /// Checks for updates now.
    public func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// Opens System Settings → Login Items.
    public func openLoginItemSettings() {
        loginItem.openSystemSettings()
    }

    private func scheduleApply() {
        applyTask?.cancel()
        let clock = clock
        applyTask = Task { [weak self] in
            do { try await clock.sleep(for: Self.applyDelay) } catch { return }
            self?.applyNow()
        }
    }
}
