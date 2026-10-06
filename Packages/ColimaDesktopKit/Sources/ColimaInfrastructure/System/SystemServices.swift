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

/// Launch at login through `SMAppService.mainApp` (macOS 13+).
@MainActor
public final class SMAppServiceLoginItem: LoginItemControlling {
    /// Creates the controller.
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
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
