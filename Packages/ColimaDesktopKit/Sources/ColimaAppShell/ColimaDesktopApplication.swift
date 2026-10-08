import AppKit
import ColimaFeatures
import ColimaInfrastructure
import ColimaUI
import ColimaUpdates

/// Entry point of the app bundle.
public enum ColimaDesktopApplication {
    /// Starts the menu bar app. Does not return, except when another copy already runs: then this
    /// copy asks it to open its menu and returns at once, which ends the process.
    public static func run() {
        if SingleInstance.yieldToRunningCopy() { return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

/// Creates the object graph at launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: AppStore?
    private var statusItem: StatusItemController?
    private var router: ActionRouter?
    private var updater: SparkleUpdater?
    private var appearanceTask: Task<Void, Never>?
    private let windows = WindowManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        let store = AppStore(dependencies: LiveEnvironment.dependencies())
        // Debug builds do not update themselves: they would be offered the published release.
        let updater = SparkleUpdater.isEnabledForMainBundle
            ? SparkleUpdater(allowedChannels: { [weak store] in store?.settings.updateChannel.sparkleChannels ?? [] })
            : nil
        let router = ActionRouter(store: store, windows: windows, loginItem: SMAppServiceLoginItem(), updater: updater)
        statusItem = StatusItemController(store: store, updater: updater) { [weak router] action in
            router?.handle(action)
        }
        self.updater = updater
        self.store = store
        self.router = router
        MainMenu.router = router
        // Selector-based, so it is delivered from the run loop and not as a main-queue job.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(anotherCopyLaunched),
            name: SingleInstance.anotherCopyLaunched,
            object: nil
        )
        observeAppearance(of: store)
        store.start()
    }

    /// Keeps open windows in step with the appearance settings.
    private func observeAppearance(of store: AppStore) {
        let windows = windows
        windows.setAppearance(from: store.settings)
        appearanceTask = Task { [weak store] in
            guard let store else { return }
            let changes = Observations {
                (store.settings.interfaceAppearance, store.settings.terminalAppearance, store.settings.logsAppearance)
            }
            for await _ in changes {
                windows.setAppearance(from: store.settings)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Opening the app again (Finder, Spotlight) while no window is open shows the main window,
    /// which works even when the menu bar hides the status item.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { router?.showMainWindow() }
        return true
    }

    /// Another copy was started and quit; show this one's main window.
    @objc private func anotherCopyLaunched(_ notification: Notification) {
        router?.showMainWindow()
    }
}

/// Main menu. Invisible while the app is a pure menu bar app, but it provides the
/// standard key equivalents (copy, paste, close, …) for the windows.
enum MainMenu {
    /// Receives About and Settings from the app menu.
    static weak var router: ActionRouter?

    static func make() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(item("About Colima Desktop", #selector(MenuTarget.showAbout), target: MenuTarget.shared))
        if SparkleUpdater.isEnabledForMainBundle {
            appMenu.addItem(item("Check for Updates…", #selector(MenuTarget.checkForUpdates), target: MenuTarget.shared))
        }
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(MenuTarget.showSettings), key: ",", target: MenuTarget.shared))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide Colima Desktop", #selector(NSApplication.hide(_:)), key: "h"))
        appMenu.addItem(item("Quit Colima Desktop", #selector(NSApplication.terminate(_:)), key: "q"))
        main.addItem(submenu("Colima Desktop", appMenu))

        let colima = NSMenu(title: "Colima")
        colima.addItem(command("Start", .startVM))
        colima.addItem(command("Stop…", .stopVM))
        colima.addItem(command("Restart…", .restartVM))
        colima.addItem(.separator())
        colima.addItem(command("Refresh", .refresh))
        main.addItem(submenu("Colima", colima))

        let container = NSMenu(title: "Container")
        container.addItem(command("Start", .startContainer))
        container.addItem(command("Stop…", .stopContainer))
        container.addItem(command("Restart…", .restartContainer))
        container.addItem(.separator())
        container.addItem(command("Show Logs", .showLogs, key: "l"))
        container.addItem(command("Open Terminal", .openTerminal, key: "t"))
        container.addItem(.separator())
        container.addItem(command("Delete…", .deleteContainer))
        container.addItem(.separator())
        container.addItem(command("New Container…", .newContainer, key: "n"))
        main.addItem(submenu("Container", container))

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), key: "z"))
        edit.addItem(item("Redo", Selector(("redo:")), key: "Z"))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        main.addItem(submenu("Edit", edit))

        let window = NSMenu(title: "Window")
        window.addItem(item("Colima Desktop", #selector(MenuTarget.showMainWindow), key: "0", target: MenuTarget.shared))
        window.addItem(.separator())
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        window.addItem(item("Close", #selector(NSWindow.performClose(_:)), key: "w"))
        main.addItem(submenu("Window", window))
        NSApp.windowsMenu = window
        return main
    }

    private static func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    /// An item for a menu bar command; enabled from the current state (`MenuTarget.validateMenuItem`).
    private static func command(_ title: String, _ command: MainMenuCommand, key: String = "") -> NSMenuItem {
        let item = item(title, #selector(MenuTarget.runCommand(_:)), key: key, target: MenuTarget.shared)
        item.tag = MainMenuCommand.allCases.firstIndex(of: command) ?? -1
        return item
    }

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    /// Target for app menu items that need the router.
    final class MenuTarget: NSObject, NSMenuItemValidation {
        static let shared = MenuTarget()

        /// Runs a menu bar command (the item's tag indexes `MainMenuCommand.allCases`).
        @objc func runCommand(_ sender: NSMenuItem) {
            guard let action = action(for: sender) else { return }
            MainMenu.router?.handle(action)
        }

        @objc func showMainWindow() { MainMenu.router?.showMainWindow() }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            guard menuItem.action == #selector(runCommand(_:)) else { return true }
            return action(for: menuItem) != nil
        }

        private func action(for item: NSMenuItem) -> MenuAction? {
            guard let router = MainMenu.router, MainMenuCommand.allCases.indices.contains(item.tag) else { return nil }
            return router.menuBarAction(for: MainMenuCommand.allCases[item.tag])
        }

        @objc func showAbout() { MainMenu.router?.handle(.showAbout) }
        @objc func showSettings() { MainMenu.router?.handle(.showSettings) }
        @objc func checkForUpdates() { MainMenu.router?.handle(.checkForUpdates) }
    }
}
