import AppKit
import ColimaDomain
import SwiftUI

/// Opens and tracks app windows (logs, terminals, settings).
///
/// While any window is open the app gets a Dock icon and appears in ⌘-Tab; with no windows it is a pure menu bar app.
///
/// Appearance: the app-wide appearance stays at the macOS setting, so a window group set to System
/// follows macOS even while the other group is forced light or dark. Each window gets the appearance
/// of its role instead: console for logs and terminal windows and their sheets, interface for all
/// other windows, including those AppKit or Sparkle create (About, alerts, update dialogs).
public final class WindowManager: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private var roles: [String: WindowRole] = [:]
    private var closeHandlers: [String: () -> Void] = [:]
    private var interfaceAppearance = AppearanceMode.system
    private var consoleAppearance = AppearanceMode.system

    /// Creates a window manager.
    override public init() {
        super.init()
        // Windows this class does not create get the interface appearance when they become key,
        // which happens before their first display.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(anyWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    /// Sets the appearance of both window groups and applies it to every open window.
    public func setAppearance(interface: AppearanceMode, console: AppearanceMode) {
        interfaceAppearance = interface
        consoleAppearance = console
        for window in NSApp.windows where Self.isAppWindow(window) {
            applyAppearance(to: window)
        }
    }

    /// Role of a window: a sheet takes the role of the window it is attached to; windows not opened
    /// through this class are interface windows.
    public func role(of window: NSWindow) -> WindowRole {
        var owner = window
        while let parent = owner.sheetParent { owner = parent }
        guard let id = owner.identifier?.rawValue, windows[id] === owner else { return .interface }
        return roles[id] ?? .interface
    }

    /// Whether a window with this ID is open.
    public func isOpen(_ id: String) -> Bool { windows[id] != nil }

    /// Brings an open window to the front. Returns false if no window has this ID.
    @discardableResult
    public func focus(_ id: String) -> Bool {
        guard let window = windows[id] else { return false }
        bringToFront(window)
        return true
    }

    /// Shows the window with `id`, creating it with `content` if needed.
    ///
    /// - Parameters:
    ///   - autosaveName: Frame autosave name shared by windows of one kind.
    ///   - role: Which appearance setting the window follows.
    ///   - onClose: Called once when the window closes.
    public func show<Content: View>(
        id: String,
        title: String,
        size: NSSize,
        autosaveName: String,
        role: WindowRole = .interface,
        minSize: NSSize = NSSize(width: 360, height: 240),
        onClose: (() -> Void)? = nil,
        content: () -> Content
    ) {
        if let window = windows[id] {
            bringToFront(window)
            return
        }
        let controller = NSHostingController(rootView: content())
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = minSize
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.tabbingMode = .disallowed
        if !window.setFrameUsingName(autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(autosaveName)
        // Cascade windows of the same kind instead of stacking them exactly.
        if let previous = windows.values.first(where: { $0.frameAutosaveName == autosaveName }) {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
        }
        windows[id] = window
        roles[id] = role
        applyAppearance(to: window)
        if let onClose { closeHandlers[id] = onClose }
        updateActivationPolicy()
        bringToFront(window)
    }

    /// Closes a window.
    public func close(_ id: String) {
        windows[id]?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        roles[id] = nil
        closeHandlers.removeValue(forKey: id)?()
        // Defer so the closing window is gone before the policy changes.
        Task { @MainActor in self.updateActivationPolicy() }
    }

    @objc private func anyWindowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, Self.isAppWindow(window) else { return }
        applyAppearance(to: window)
    }

    private func applyAppearance(to window: NSWindow) {
        let mode = role(of: window) == .console ? consoleAppearance : interfaceAppearance
        let appearance = mode.nsAppearance
        guard window.appearance?.name != appearance?.name else { return }
        window.appearance = appearance
    }

    /// Windows the user works with. Leaves out the menu bar's own window, whose appearance follows
    /// the menu bar, and other system windows (menus, tooltips).
    private static func isAppWindow(_ window: NSWindow) -> Bool {
        (window.canBecomeKey || window.sheetParent != nil) && window.level < .statusBar
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func updateActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = windows.isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if policy == .regular { NSApp.activate() }
        }
    }
}
