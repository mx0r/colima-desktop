import AppKit
import ColimaDomain
import Observation
import Sparkle

/// Self-update through Sparkle. The feed URL and public EdDSA key come from Info.plist
/// (`SUFeedURL`, `SUPublicEDKey`); Sparkle persists the user's choices itself.
///
/// Scheduled checks use Sparkle's gentle reminders (`UpdateReminderState`): an update found in the
/// background becomes `pendingUpdateVersion` for the menu instead of a window stealing focus.
/// With automatic downloads on, Sparkle downloads the update silently and installs it on quit;
/// `readyToInstallVersion` lets the menu offer "Restart to Update" before that.
@Observable
public final class SparkleUpdater: NSObject, UpdateControlling, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// Info.plist key telling whether this build updates itself (off for Debug builds).
    public static let enabledInfoKey = "ColimaDesktopUpdates"

    /// Whether a build enables updates, from the Info.plist value of `enabledInfoKey`.
    /// Build-setting substitution yields "YES"/"NO" strings; a literal plist value is a Bool.
    public static func isEnabled(infoValue: Any?) -> Bool {
        if let flag = infoValue as? Bool { return flag }
        if let text = infoValue as? String { return text.caseInsensitiveCompare("YES") == .orderedSame }
        return false
    }

    /// Whether the running app enables updates.
    public static var isEnabledForMainBundle: Bool {
        isEnabled(infoValue: Bundle.main.object(forInfoDictionaryKey: enabledInfoKey))
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    /// Installs the downloaded update and relaunches; handed over by Sparkle.
    @ObservationIgnored private var installNow: (() -> Void)?
    /// Sparkle channels the user opted into, asked at every check.
    @ObservationIgnored private let allowedChannels: () -> Set<String>
    private var reminders = UpdateReminderState()

    /// Creates and starts the updater.
    ///
    /// - Parameter allowedChannels: Channels besides the default one (e.g. `["beta"]`), read at
    ///   every check so a changed setting applies to the next check.
    public init(allowedChannels: @escaping () -> Set<String> = { [] }) {
        self.allowedChannels = allowedChannels
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    /// Version found by a background check and not yet shown to the user; nil when none.
    public var pendingUpdateVersion: String? { reminders.pendingVersion }

    /// Version downloaded in the background and ready to install; nil when none.
    public var readyToInstallVersion: String? { reminders.readyVersion }

    /// Background download and install, read from and written to Sparkle directly (it persists
    /// the choice; `SUAutomaticallyUpdate` in Info.plist sets the default).
    public var automaticallyDownloadsUpdates: Bool {
        get {
            access(keyPath: \.automaticallyDownloadsUpdates)
            return controller.updater.automaticallyDownloadsUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyDownloadsUpdates) {
                controller.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    /// Whether automatic downloads can be switched on. Sparkle derives it from the automatic-check
    /// setting, so it is re-read whenever that changes.
    public var allowsAutomaticUpdates: Bool {
        access(keyPath: \.automaticallyChecksForUpdates)
        return controller.updater.allowsAutomaticUpdates
    }

    /// Background checks, read from and written to Sparkle directly. No mirror: writing
    /// Sparkle's setting persists it as a user choice and resets its schedule, so it is written
    /// only when the user changes it.
    public var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    /// Shows Sparkle's window for a user-initiated check, or for the pending update.
    public func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// Installs the downloaded update and relaunches. Without one, falls back to a check.
    public func installUpdateAndRelaunch() {
        guard let installNow else { return checkForUpdates() }
        installNow()
    }

    // MARK: SPUUpdaterDelegate

    /// Channels to look in besides the default one; empty for stable only.
    public func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        allowedChannels()
    }

    /// A silently downloaded update waits for the app to quit. Taking the handler lets the menu
    /// offer "Restart to Update" now; Sparkle still installs on quit if the user never chooses it.
    public func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        installNow = immediateInstallHandler
        reminders.updateReadyToInstall(version: item.displayVersionString)
        return true
    }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders)

    /// Opts into gentle reminders; required for apps without a regular window.
    public var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Never lets Sparkle show a scheduled update itself; the menu offers it instead.
    public func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        UpdateReminderState.sparkleShowsScheduledUpdate(immediateFocus: immediateFocus)
    }

    /// Records an update Sparkle leaves to us, so the menu can offer it.
    public func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        reminders.willShowUpdate(version: update.displayVersionString, handledBySparkle: handleShowingUpdate)
    }

    /// The user looked at the update; the menu goes back to "Check for Updates…".
    public func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        reminders.userAttended()
    }

    /// The update session ended (installed, skipped or dismissed).
    public func standardUserDriverWillFinishUpdateSession() {
        reminders.sessionFinished()
    }
}
