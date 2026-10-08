import AppKit
import ColimaDomain

/// Asks, when the app quits while Colima runs, whether to stop Colima too.
public enum QuitConfirmation {
    /// The user's answer.
    public struct Answer: Hashable, Sendable {
        public var choice: QuitChoice
        /// "Don't ask again" was ticked.
        public var remember: Bool
    }

    /// Shows the question; nil when the user cancels the quit. Call synchronously from a menu
    /// action, never from inside a Task.
    public static func ask(profile: ProfileName, appearance: AppearanceMode) -> Answer? {
        let alert = NSAlert()
        alert.messageText = "Quit Colima Desktop?"
        alert.informativeText = "Colima “\(profile)” and its containers keep running after Colima Desktop quits. You can stop Colima now as well."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Stop Colima and Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.window.appearance = appearance.nsAppearance
        NSApp.activate()
        let choice: QuitChoice
        switch alert.runModal() {
        case .alertFirstButtonReturn: choice = .leaveRunning
        case .alertSecondButtonReturn: choice = .stopColima
        default: return nil
        }
        return Answer(choice: choice, remember: alert.suppressionButton?.state == .on)
    }
}
