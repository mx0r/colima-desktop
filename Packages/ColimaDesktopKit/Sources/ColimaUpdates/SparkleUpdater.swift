import AppKit
import ColimaDomain
import Observation
import Sparkle

/// Self-update through Sparkle. The feed URL and public EdDSA key come from Info.plist
/// (`SUFeedURL`, `SUPublicEDKey`); Sparkle persists the user's choices itself.
///
/// A menu bar app has no window to come back to, so scheduled checks use Sparkle's gentle
/// reminders: an update found in the background becomes `pendingUpdateVersion` (shown as
/// "Update to X…" in the menu) instead of a window stealing focus.
@Observable
public final class SparkleUpdater: NSObject, UpdateControlling, SPUStandardUserDriverDelegate {
    public private(set) var pendingUpdateVersion: String?

    public var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    /// Creates and starts the updater.
    override public init() {
        automaticallyChecksForUpdates = false
        super.init()
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
    }

    public func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders)

    public var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Let Sparkle show a scheduled update only when it would come up in focus anyway;
    /// otherwise the menu offers it.
    public func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    public func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate {
            pendingUpdateVersion = update.displayVersionString
        }
    }

    public func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingUpdateVersion = nil
    }

    public func standardUserDriverWillFinishUpdateSession() {
        pendingUpdateVersion = nil
    }
}
