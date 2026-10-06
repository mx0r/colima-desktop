import AppKit
import ColimaDomain
import ColimaFeatures
import ColimaInfrastructure
import ColimaTerminal
import ColimaUI
import SwiftUI

/// Executes menu actions: confirms destructive ones, then calls the store or opens windows.
final class ActionRouter {
    private let store: AppStore
    private let windows: WindowManager
    private let loginItem: any LoginItemControlling
    private let updater: (any UpdateControlling)?

    init(store: AppStore, windows: WindowManager, loginItem: any LoginItemControlling, updater: (any UpdateControlling)?) {
        self.store = store
        self.windows = windows
        self.loginItem = loginItem
        self.updater = updater
    }

    /// Handles a menu action. Confirmation runs synchronously, before any task starts.
    func handle(_ action: MenuAction) {
        guard ConfirmationPresenter.confirm(action, profile: store.snapshot.selectedProfile) else { return }
        switch action {
        case .startVM:
            store.requestVMOperation(.start)
        case .stopVM:
            store.requestVMOperation(.stop)
        case .restartVM:
            store.requestVMOperation(.restart)
        case .selectProfile(let profile):
            store.selectProfile(profile)
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .showLogs(let containerID, let name):
            showLogs(containerID: containerID, name: name)
        case .openTerminal(let containerID, let name):
            openTerminal(containerID: containerID, name: name)
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .container(let containerAction, let containerID, _):
            store.performContainerAction(containerAction, containerID: containerID)
        case .showSettings:
            showSettings()
        case .showAbout:
            AboutPanel.show(snapshot: store.snapshot)
        case .checkForUpdates:
            updater?.checkForUpdates()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    private func showLogs(containerID: String, name: String) {
        guard let engine = store.dockerEngine else { return showDockerUnavailable() }
        let id = "logs.\(containerID)"
        guard !windows.focus(id) else { return }
        let model = LogsViewModel(
            containerID: containerID,
            containerName: name,
            engine: engine,
            tailLines: store.settings.logTailLines,
            capacity: store.settings.logBufferCapacity
        )
        windows.show(
            id: id,
            title: "Logs — \(name)",
            size: NSSize(width: 900, height: 560),
            autosaveName: "LogsWindow",
            onClose: { model.stop() },
            content: { LogsWindowView(model: model) }
        )
    }

    private func openTerminal(containerID: String, name: String) {
        guard let engine = store.dockerEngine else { return showDockerUnavailable() }
        let model = TerminalSessionModel(
            containerID: containerID,
            containerName: name,
            engine: engine,
            command: store.settings.terminalShell.command
        )
        // Every click opens a new shell, like a new terminal tab.
        windows.show(
            id: "terminal.\(containerID).\(UUID().uuidString)",
            title: "Terminal — \(name)",
            size: NSSize(width: 820, height: 520),
            autosaveName: "TerminalWindow",
            onClose: { model.close() },
            content: { TerminalWindowView(model: model) }
        )
    }

    private func showSettings() {
        guard !windows.focus("settings") else { return }
        let model = SettingsViewModel(store: store, loginItem: loginItem, updater: updater)
        windows.show(
            id: "settings",
            title: "Colima Desktop Settings",
            size: NSSize(width: 560, height: 640),
            autosaveName: "SettingsWindow",
            onClose: { model.applyNow() },
            content: { SettingsView(model: model) }
        )
    }

    private func showDockerUnavailable() {
        let alert = NSAlert()
        alert.messageText = "Docker is not connected"
        alert.informativeText = "Wait until Colima is running and Docker is reachable, then try again."
        NSApp.activate()
        alert.runModal()
    }
}
