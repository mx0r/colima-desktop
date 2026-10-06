import AppKit
import SwiftUI

/// Opens and tracks app windows (logs, terminals, settings).
///
/// While any window is open the app gets a Dock icon and appears in ⌘-Tab; with no windows it is a pure menu bar app.
public final class WindowManager: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private var closeHandlers: [String: () -> Void] = [:]

    /// Creates a window manager.
    override public init() {
        super.init()
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
    ///   - onClose: Called once when the window closes.
    public func show<Content: View>(
        id: String,
        title: String,
        size: NSSize,
        autosaveName: String,
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
        closeHandlers.removeValue(forKey: id)?()
        // Defer so the closing window is gone before the policy changes.
        Task { @MainActor in self.updateActivationPolicy() }
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
