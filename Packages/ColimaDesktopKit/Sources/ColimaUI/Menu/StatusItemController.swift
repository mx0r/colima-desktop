import AppKit
import ColimaDomain
import ColimaFeatures
import Observation

/// Owns the menu bar item: renders the icon and the menu from the store and reports menu open/close.
public final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let store: AppStore
    private let updater: (any UpdateControlling)?
    private let actionTarget: MenuActionTarget
    private lazy var renderer = MenuRenderer(target: actionTarget, submenuDelegate: self)
    private var observationTask: Task<Void, Never>?
    private var animationTask: Task<Void, Never>?
    private var lastSnapshot: AppSnapshot?
    private var lastUpdates: UpdatesMenuItem?
    private var iconKey: IconKey?
    private var appearanceObservation: NSKeyValueObservation?
    private var menuAppearance: AppearanceMode?

    /// Everything the icon image depends on; the icon is redrawn only when it changes.
    private struct IconKey: Equatable {
        var state: IconState
        var style: MenuBarIconStyle
        /// Only set for colored styles, which are drawn for one appearance.
        var appearance: NSAppearance.Name?
    }

    /// Interval between frames of the transition animation.
    static let animationInterval = Duration.milliseconds(400)

    /// Creates the status item. `onAction` receives every menu command.
    public init(store: AppStore, updater: (any UpdateControlling)? = nil, onAction: @escaping (MenuAction) -> Void) {
        self.store = store
        self.updater = updater
        actionTarget = MenuActionTarget(handler: onAction)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        render(store.snapshot, style: store.settings.menuBarIconStyle, appearance: store.settings.interfaceAppearance)
        observe()
        // Colored icons are drawn for one appearance; redraw when the menu bar turns light or dark.
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    /// Opens the menu, for example when the app is launched a second time. Deferred to the run loop:
    /// opening a menu inside a main-queue job would stall MainActor tasks while it is open.
    public func showMenu() {
        perform(#selector(openMenuNow), with: nil, afterDelay: 0)
    }

    @objc private func openMenuNow() {
        statusItem.button?.performClick(nil)
    }

    private func observe() {
        observationTask = Task { [weak self, store, updater] in
            let changes = Observations {
                (store.snapshot, store.settings.menuBarIconStyle, updater?.pendingUpdateVersion, store.settings.interfaceAppearance)
            }
            for await (snapshot, style, _, appearance) in changes {
                guard let self else { return }
                self.render(snapshot, style: style, appearance: appearance)
            }
        }
    }

    private func render(_ snapshot: AppSnapshot, style: MenuBarIconStyle, appearance: AppearanceMode) {
        updateIcon(snapshot: snapshot, style: style)
        let updates = UpdatesMenuItem(updater: updater)
        guard snapshot != lastSnapshot || updates != lastUpdates || appearance != menuAppearance else { return }
        lastSnapshot = snapshot
        lastUpdates = updates
        menuAppearance = appearance
        renderer.render(MenuModelBuilder.build(snapshot, updates: updates), into: menu)
        Self.setAppearance(appearance.nsAppearance, on: menu)
    }

    /// The menu follows the interface appearance, not the menu bar's. Submenus get it too, including new ones.
    private static func setAppearance(_ appearance: NSAppearance?, on menu: NSMenu) {
        if menu.appearance?.name != appearance?.name { menu.appearance = appearance }
        for item in menu.items {
            if let submenu = item.submenu { setAppearance(appearance, on: submenu) }
        }
    }

    private func updateIcon(snapshot: AppSnapshot? = nil, style: MenuBarIconStyle? = nil) {
        guard let button = statusItem.button else { return }
        let snapshot = snapshot ?? store.snapshot
        let style = style ?? store.settings.menuBarIconStyle
        var state = snapshot.lifecycle.iconState
        if state == .running, case .unreachable = snapshot.docker { state = .error }
        let appearance = StatusIconRenderer.usesTemplate(style)
            ? nil
            : button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
        let key = IconKey(state: state, style: style, appearance: appearance)
        guard key != iconKey else { return }
        iconKey = key
        animationTask?.cancel()
        animationTask = nil

        let drawingAppearance = appearance.flatMap(NSAppearance.init(named:))
        let firstFrame = StatusIconRenderer.firstFrame(for: state, style: style)
        button.image = StatusIconRenderer.image(for: state, style: style, frame: firstFrame, appearance: drawingAppearance)
        // The status light already shows "stopped" in red; dimming would wash it out.
        button.appearsDisabled = state == .stopped && StatusIconRenderer.usesTemplate(style)
        button.toolTip = StatusIconRenderer.accessibilityText(for: state)
        button.setAccessibilityLabel(StatusIconRenderer.accessibilityText(for: state))

        let frames = StatusIconRenderer.frameCount(for: state, style: style)
        guard frames > 1 else { return }
        animationTask = Task { [weak button] in
            var frame = firstFrame
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.animationInterval)
                frame = (frame + 1) % frames
                button?.image = StatusIconRenderer.image(for: state, style: style, frame: frame, appearance: drawingAppearance)
            }
        }
    }

    // MARK: NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        // Synchronous and cheap: apply the latest snapshot; IO happens in menuWillOpen.
        render(store.snapshot, style: store.settings.menuBarIconStyle, appearance: store.settings.interfaceAppearance)
    }

    public func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu {
            store.menuWillOpen()
        } else if identifier(of: menu) == MenuNodeID.information {
            store.informationMenuWillOpen()
        }
    }

    public func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu {
            store.menuDidClose()
        } else if identifier(of: menu) == MenuNodeID.information {
            store.informationMenuDidClose()
        }
    }

    /// Node ID of the item that owns a submenu.
    private func identifier(of submenu: NSMenu) -> String? {
        submenu.supermenu?.items.first { $0.submenu === submenu }?.identifier?.rawValue
    }
}
