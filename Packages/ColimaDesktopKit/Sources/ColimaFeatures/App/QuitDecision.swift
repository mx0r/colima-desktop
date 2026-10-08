import ColimaDomain
import Foundation

/// What happens when the user quits the app.
public enum QuitPlan: Hashable, Sendable {
    /// Quit at once: Colima does not run, or the user chose to leave it running.
    case quit
    /// Ask whether to stop Colima too.
    case ask
    /// Stop Colima, then quit (a remembered answer).
    case stopColimaThenQuit
}

/// Decides how a quit goes. Quitting the app leaves Colima and its containers running, so the user
/// is asked while Colima runs, unless they asked to remember their answer.
public enum QuitDecision {
    /// The plan for the current state and settings.
    public static func plan(snapshot: AppSnapshot, settings: AppSettings) -> QuitPlan {
        guard snapshot.lifecycle.observed == .running else { return .quit }
        switch settings.rememberedChoices.quit {
        case nil: return .ask
        case .leaveRunning: return .quit
        case .stopColima: return .stopColimaThenQuit
        }
    }
}
