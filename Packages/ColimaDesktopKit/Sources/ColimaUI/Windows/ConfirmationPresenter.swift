import AppKit
import ColimaDomain
import ColimaFeatures

/// Asks before destructive actions.
public enum ConfirmationPresenter {
    /// Texts for a confirmation dialog.
    public struct Dialog: Hashable, Sendable {
        public var message: String
        public var information: String
        public var confirmTitle: String
    }

    /// Dialog texts for an action, or nil when the action needs no confirmation.
    public static func dialog(for action: MenuAction, profile: ProfileName) -> Dialog? {
        guard action.needsConfirmation else { return nil }
        switch action {
        case .stopVM:
            return Dialog(
                message: "Stop Colima “\(profile)”?",
                information: "All running containers in this profile will stop.",
                confirmTitle: "Stop"
            )
        case .restartVM:
            return Dialog(
                message: "Restart Colima “\(profile)”?",
                information: "Running containers will stop and start again with the VM, if their restart policy allows it.",
                confirmTitle: "Restart"
            )
        case .container(.stop, _, let name):
            return Dialog(message: "Stop container “\(name)”?", information: "The container's processes receive SIGTERM.", confirmTitle: "Stop")
        case .container(.restart, _, let name):
            return Dialog(message: "Restart container “\(name)”?", information: "The container stops and starts again.", confirmTitle: "Restart")
        case .container(.remove, _, let name):
            return Dialog(
                message: "Delete container “\(name)”?",
                information: "The container and its writable layer are removed. Its volumes and image are kept. You cannot undo this.",
                confirmTitle: "Delete"
            )
        default:
            return nil
        }
    }

    /// Shows a modal confirmation. Call synchronously from a menu action, never from inside a Task.
    ///
    /// - Parameter appearance: The interface appearance setting.
    public static func confirm(_ action: MenuAction, profile: ProfileName, appearance: AppearanceMode = .system) -> Bool {
        guard let dialog = dialog(for: action, profile: profile) else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = dialog.message
        alert.informativeText = dialog.information
        let confirm = alert.addButton(withTitle: dialog.confirmTitle)
        confirm.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.window.appearance = appearance.nsAppearance
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
