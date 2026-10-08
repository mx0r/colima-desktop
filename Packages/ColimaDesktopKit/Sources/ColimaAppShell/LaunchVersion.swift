import ColimaFeatures
import ColimaUpdates
import Foundation

/// Records the version each launch runs as, and tells whether an update was installed since the last one.
enum LaunchVersion {
    /// Defaults key of the version recorded at the last launch.
    static let recordedKey = "LastLaunchedVersion"
    /// Sparkle's own defaults key, set after its first launch.
    static let sparkleLaunchedBeforeKey = "SUHasLaunchedBefore"

    /// Records this launch's version and returns the update notice, if any. Debug builds neither record
    /// nor notify: switching between them and the installed app would look like updates.
    static func recordAndCheck(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> UpdateNotice.Message? {
        guard SparkleUpdater.isEnabledForMainBundle,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) else { return nil }
        let current = AppVersion(version: version, build: build)
        let previous = defaults.data(forKey: recordedKey).flatMap { try? JSONDecoder().decode(AppVersion.self, from: $0) }
        let launchedBefore = defaults.bool(forKey: sparkleLaunchedBeforeKey)
        if let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: recordedKey)
        }
        return UpdateNotice.message(previous: previous, current: current, launchedBefore: launchedBefore)
    }
}
