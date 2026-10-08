import Foundation

/// The app's version and build number.
public struct AppVersion: Codable, Hashable, Sendable {
    /// Marketing version, e.g. `0.8`.
    public var version: String
    /// Build number; release builds count commits, so a newer release has a higher build.
    public var build: Int

    /// Creates a version.
    public init(version: String, build: Int) {
        self.version = version
        self.build = build
    }
}

/// The notification that tells the user an update was installed. Updates install silently on quit,
/// so without it a new version would go unnoticed.
public enum UpdateNotice {
    /// A notification's text.
    public struct Message: Hashable, Sendable {
        public var title: String
        public var body: String
    }

    /// The notice for this launch, or nil when nothing was updated.
    ///
    /// - Parameters:
    ///   - previous: Version recorded at the last launch; nil when none was recorded.
    ///   - launchedBefore: Whether the app ran before. With no recorded version, an earlier run was a
    ///     version that did not record yet, so an older one.
    public static func message(previous: AppVersion?, current: AppVersion, launchedBefore: Bool) -> Message? {
        guard let previous else {
            return launchedBefore ? Message(title: "Colima Desktop updated", body: "Version \(current.version) is installed.") : nil
        }
        guard current.build > previous.build else { return nil }
        return Message(title: "Colima Desktop updated", body: "Version \(current.version) is installed (was \(previous.version)).")
    }
}
