import Foundation

/// Decides which copy of the app keeps running when several are started: the oldest one.
///
/// Each new copy checks once, at launch, and quits if an older copy runs. Comparing launch times
/// (instead of "quit if any other copy runs") makes two copies started at the same moment agree on
/// one survivor.
public enum SingleInstancePolicy {
    /// A running copy of the app.
    public struct Instance: Hashable, Sendable {
        public var processID: Int32
        /// Nil when macOS does not know it (a copy not started through Launch Services).
        public var launchDate: Date?

        /// Creates an instance.
        public init(processID: Int32, launchDate: Date?) {
            self.processID = processID
            self.launchDate = launchDate
        }
    }

    /// Whether `current` should quit because one of `others` is older.
    ///
    /// Another copy without a launch date counts as older (it already runs); this copy without one
    /// counts as starting `now`. Equal launch times go to the lower process ID.
    public static func shouldQuit(_ current: Instance, others: [Instance], now: Date = Date()) -> Bool {
        let mine = (current.launchDate ?? now, current.processID)
        return others.contains { other in
            let theirs = (other.launchDate ?? .distantPast, other.processID)
            return theirs < mine
        }
    }
}
