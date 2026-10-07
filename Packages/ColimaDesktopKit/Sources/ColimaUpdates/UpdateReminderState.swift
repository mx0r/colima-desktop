import Foundation

/// What the menu shows for updates found by scheduled checks. Pure, so it is tested without Sparkle.
///
/// A menu bar app has no window to return to, so a scheduled check never opens Sparkle's window:
/// the found version becomes pending and the menu offers it as "Update to X…".
struct UpdateReminderState: Equatable {
    /// Version waiting for the user; nil when none.
    private(set) var pendingVersion: String?
    /// Version downloaded in the background and installed on quit or restart; nil when none.
    /// Kept until the app relaunches: Sparkle installs it then in any case.
    private(set) var readyVersion: String?

    /// Whether Sparkle may show a scheduled update itself. Never: `immediateFocus` is true right
    /// after launch (e.g. at login), which would pop a window nobody asked for.
    static func sparkleShowsScheduledUpdate(immediateFocus: Bool) -> Bool {
        false
    }

    /// Sparkle is about to show an update, or leaves showing it to us.
    mutating func willShowUpdate(version: String, handledBySparkle: Bool) {
        if !handledBySparkle { pendingVersion = version }
    }

    /// The user looked at the update (e.g. chose "Update to X…").
    mutating func userAttended() {
        pendingVersion = nil
    }

    /// The update session ended (installed, skipped or dismissed).
    mutating func sessionFinished() {
        pendingVersion = nil
    }

    /// An update finished downloading in the background and waits to be installed.
    mutating func updateReadyToInstall(version: String) {
        readyVersion = version
        pendingVersion = nil
    }
}
