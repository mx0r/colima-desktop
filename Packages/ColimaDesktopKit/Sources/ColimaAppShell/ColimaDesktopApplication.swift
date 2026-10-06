import AppKit
import ColimaFeatures
import ColimaInfrastructure
import ColimaUI

/// Entry point of the app bundle.
public enum ColimaDesktopApplication {
    /// Starts the menu bar app. Does not return.
    public static func run() {
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
    private let windows = WindowManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        let store = AppStore(dependencies: LiveEnvironment.dependencies())
        let router = ActionRouter(store: store, windows: windows, loginItem: SMAppServiceLoginItem())
        statusItem = StatusItemController(store: store) { [weak router] action in
            router?.handle(action)
        }
        self.store = store
        self.router = router
        MainMenu.router = router
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(MenuTarget.showSettings), key: ",", target: MenuTarget.shared))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide Colima Desktop", #selector(NSApplication.hide(_:)), key: "h"))
        appMenu.addItem(item("Quit Colima Desktop", #selector(NSApplication.terminate(_:)), key: "q"))
        main.addItem(submenu("Colima Desktop", appMenu))

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

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    /// Target for app menu items that need the router.
    final class MenuTarget: NSObject {
        static let shared = MenuTarget()

        @objc func showAbout() { MainMenu.router?.handle(.showAbout) }
        @objc func showSettings() { MainMenu.router?.handle(.showSettings) }
    }
}
