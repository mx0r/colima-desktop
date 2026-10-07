import AppKit
import ColimaFeatures

/// Keeps one copy of the app running per user: a second copy (another build, another folder,
/// or a launch at login next to a manual start) quits and the running copy opens its menu.
enum SingleInstance {
    /// Posted by a copy that quits in favour of the running one.
    static let anotherCopyLaunched = Notification.Name("com.enscope.macos.ColimaDesktop.anotherCopyLaunched")

    /// Whether this process must quit because an older copy runs. Tells that copy to show itself.
    static func yieldToRunningCopy() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let current = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != current.processIdentifier && !$0.isTerminated }
            .map { SingleInstancePolicy.Instance(processID: $0.processIdentifier, launchDate: $0.launchDate) }
        let me = SingleInstancePolicy.Instance(processID: current.processIdentifier, launchDate: current.launchDate)
        guard SingleInstancePolicy.shouldQuit(me, others: others) else { return false }
        DistributedNotificationCenter.default().postNotificationName(anotherCopyLaunched, object: nil, userInfo: nil, deliverImmediately: true)
        return true
    }
}
