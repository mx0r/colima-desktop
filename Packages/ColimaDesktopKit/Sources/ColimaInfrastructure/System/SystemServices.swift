import ColimaDomain
import Foundation
import ServiceManagement
import Synchronization
import UserNotifications

/// Stores settings as JSON in `UserDefaults`.
///
/// `@unchecked Sendable`: `UserDefaults` is documented as thread-safe but not annotated.
public final class UserDefaultsSettingsStore: SettingsPersisting, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// Creates a store.
    public init(defaults: UserDefaults = .standard, key: String = "settings.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .defaults
        }
        return settings
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

/// The parts of `SMAppService` the login item uses; a seam for tests.
@MainActor
public protocol AppServiceControlling: AnyObject {
    /// Registration state; each read asks the system's login item service.
    var status: SMAppService.Status { get }
    /// Registers the service; throws when it is already registered or macOS refuses.
    func register() throws
    /// Unregisters the service; throws when it is not registered.
    func unregister() throws
}

extension SMAppService: AppServiceControlling {}

/// Launch at login through `SMAppService.mainApp` (macOS 13+).
@MainActor
public final class SMAppServiceLoginItem: LoginItemControlling {
    private let service: any AppServiceControlling

    /// Creates the controller for the app itself.
    public convenience init() {
        self.init(service: SMAppService.mainApp)
    }

    /// Creates the controller for any service (tests).
    public init(service: any AppServiceControlling) {
        self.service = service
    }

    public var status: LoginItemStatus { Self.map(service.status) }

    /// Maps the framework status. `.notFound` is what a never-registered app reports
    /// (measured with an ad-hoc signed bundle), so it means "off", not "unsupported".
    static func map(_ status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered, .notFound: .disabled
        @unknown default: .disabled
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        // One read: each one queries the system, and two could disagree.
        let status = service.status
        if enabled {
            // Registering what is already enabled throws.
            if status != .enabled { try service.register() }
        } else if status == .enabled || status == .requiresApproval {
            try service.unregister()
        }
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Posts notifications through `UNUserNotificationCenter`. Requires an app bundle.
public final class UNUserNotifier: NSObject, UserNotifying, UNUserNotificationCenterDelegate {
    private let authorizationRequested = Mutex(false)

    /// Creates the notifier and makes it the notification center delegate,
    /// so banners also show while the menu bar app is active.
    public override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    public func post(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let shouldAsk = authorizationRequested.withLock { requested in
            defer { requested = true }
            return !requested
        }
        if shouldAsk {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
