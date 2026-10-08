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
    /// Set while Colima stops before quitting; a second quit then does nothing.
    private var isStoppingForQuit = false
    /// The open main window's model; the menu bar's Container commands act on its selection.
    private(set) var mainWindowModel: MainWindowModel?

    init(store: AppStore, windows: WindowManager, loginItem: any LoginItemControlling, updater: (any UpdateControlling)?) {
        self.store = store
        self.windows = windows
        self.loginItem = loginItem
        self.updater = updater
    }

    /// Handles a menu action. Confirmation runs synchronously, before any task starts.
    func handle(_ action: MenuAction) {
        let profile = store.snapshot.selectedProfile
        guard ConfirmationPresenter.confirm(action, profile: profile, appearance: store.settings.interfaceAppearance) else { return }
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
        case .newContainer:
            showNewContainer()
        case .openMainWindow:
            showMainWindow()
        case .refresh:
            Task { await store.refresh() }
        case .showSettings:
            showSettings()
        case .showAbout:
            AboutPanel.show(snapshot: store.snapshot)
        case .checkForUpdates:
            updater?.checkForUpdates()
        case .installUpdate:
            updater?.installUpdateAndRelaunch()
        case .quit:
            quit()
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
            role: .console(.logs),
            onClose: { model.stop() },
            content: { [store] in LogsWindowView(model: model, textStyle: { store.settings.logsText }) }
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
            role: .console(.terminal),
            onClose: { model.close() },
            content: { [store] in TerminalWindowView(model: model, textStyle: { store.settings.terminalText }) }
        )
    }

    /// Quits; while Colima runs, asks first whether to stop it too (unless the answer is remembered).
    private func quit() {
        guard !isStoppingForQuit else { return }
        switch QuitDecision.plan(snapshot: store.snapshot, settings: store.settings) {
        case .quit:
            NSApp.terminate(nil)
        case .stopColimaThenQuit:
            stopColimaThenQuit()
        case .ask:
            guard let answer = QuitConfirmation.ask(profile: store.snapshot.selectedProfile, appearance: store.settings.interfaceAppearance) else { return }
            if answer.remember {
                var settings = store.settings
                settings.rememberedChoices.quit = answer.choice
                store.updateSettings(settings)
            }
            if answer.choice == .stopColima { stopColimaThenQuit() } else { NSApp.terminate(nil) }
        }
    }

    /// Stops Colima, then quits; the menu bar icon shows the stop meanwhile.
    private func stopColimaThenQuit() {
        isStoppingForQuit = true
        Task {
            await store.stopVMAndWait()
            NSApp.terminate(nil)
        }
    }

    /// The action of a menu bar command now; container commands act on the main window's selection.
    func menuBarAction(for command: MainMenuCommand) -> MenuAction? {
        MainMenuState.action(for: command, snapshot: store.snapshot, selectedContainerID: mainWindowModel?.selectedContainerID)
    }

    /// Opens the main window, or brings it to the front.
    func showMainWindow() {
        guard !windows.focus("main") else { return }
        let model = MainWindowModel(store: store, onAction: { [weak self] action in self?.handle(action) })
        mainWindowModel = model
        model.appear()
        windows.show(
            id: "main",
            title: "Colima Desktop",
            size: NSSize(width: 1080, height: 680),
            autosaveName: "MainWindow",
            minSize: NSSize(width: 820, height: 480),
            onClose: { [weak self] in
                model.disappear()
                self?.mainWindowModel = nil
            },
            content: { MainWindowView(model: model) }
        )
    }

    private func showNewContainer() {
        guard let engine = store.dockerEngine else { return showDockerUnavailable() }
        guard !windows.focus("new-container") else { return }
        let catalogs: [any ImageCatalog] = store.settings.enabledImageSources.map { kind in
            switch kind {
            case .dockerHub: DockerHubCatalog(engine: engine)
            }
        }
        let model = NewContainerViewModel(
            engine: engine,
            catalogs: catalogs,
            vmArchitecture: store.snapshot.details?.arch ?? store.snapshot.selectedInstance?.arch,
            onAction: { [weak self] action in self?.handle(action) }
        )
        windows.show(
            id: "new-container",
            title: "New Container",
            size: NSSize(width: 980, height: 700),
            autosaveName: "NewContainerWindow",
            minSize: NSSize(width: 760, height: 520),
            onClose: { model.close() },
            content: { NewContainerWindowView(model: model) }
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
        alert.window.appearance = store.settings.interfaceAppearance.nsAppearance
        NSApp.activate()
        alert.runModal()
    }
}
