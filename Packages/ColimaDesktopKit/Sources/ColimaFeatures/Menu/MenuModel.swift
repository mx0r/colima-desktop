import ColimaDomain
import Foundation

/// Toolkit-independent description of one menu item. Rendered into `NSMenu` by the UI layer.
public struct MenuNode: Identifiable, Hashable, Sendable {
    /// Item kind.
    public enum Kind: Hashable, Sendable {
        case item
        case separator
        /// Non-interactive section title.
        case header
        /// Non-interactive, full-color status row (title, subtitle, image).
        case banner
    }

    /// Stable ID; the renderer reuses `NSMenuItem`s by ID so open submenus survive updates.
    public var id: String
    public var kind: Kind
    public var title: String
    /// Secondary line under the title.
    public var subtitle: String?
    public var image: MenuImage?
    public var isEnabled: Bool
    /// Shown in a secondary color (e.g. stopped containers).
    public var isDimmed: Bool
    /// Shows a checkmark.
    public var isChecked: Bool
    /// Indentation level.
    public var indentation: Int
    /// Action on click.
    public var action: MenuAction?
    /// Submenu items; nil for a plain item.
    public var children: [MenuNode]?
    /// Key equivalent (with ⌘), e.g. "q".
    public var keyEquivalent: String?
    public var toolTip: String?

    /// Creates an item.
    public init(
        id: String,
        kind: Kind = .item,
        title: String = "",
        subtitle: String? = nil,
        image: MenuImage? = nil,
        isEnabled: Bool = true,
        isDimmed: Bool = false,
        isChecked: Bool = false,
        indentation: Int = 0,
        action: MenuAction? = nil,
        children: [MenuNode]? = nil,
        keyEquivalent: String? = nil,
        toolTip: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.image = image
        self.isEnabled = isEnabled
        self.isDimmed = isDimmed
        self.isChecked = isChecked
        self.indentation = indentation
        self.action = action
        self.children = children
        self.keyEquivalent = keyEquivalent
        self.toolTip = toolTip
    }

    /// A separator.
    public static func separator(_ id: String) -> MenuNode {
        MenuNode(id: id, kind: .separator, isEnabled: false)
    }

    /// A section header.
    public static func header(_ id: String, _ title: String) -> MenuNode {
        MenuNode(id: id, kind: .header, title: title, isEnabled: false)
    }

    /// A disabled informational row.
    public static func note(_ id: String, _ title: String, image: MenuImage? = nil) -> MenuNode {
        MenuNode(id: id, title: title, image: image, isEnabled: false)
    }

    /// A "Label: value" row that copies the value when clicked.
    public static func value(_ id: String, _ label: String, _ value: String, indentation: Int = 0) -> MenuNode {
        MenuNode(
            id: id,
            title: "\(label): \(value)",
            indentation: indentation,
            action: .copy(value),
            toolTip: "Click to copy"
        )
    }
}

/// The update entry of the menu.
public enum UpdatesMenuItem: Hashable, Sendable {
    /// No updater in this build (Debug builds).
    case hidden
    /// "Check for Updates…".
    case check
    /// "Update to X…" for a version found by a background check.
    case pending(String)
    /// "Restart to Update to X" for a version already downloaded in the background.
    case readyToInstall(String)

    /// The entry for an updater's current state.
    @MainActor
    public init(updater: (any UpdateControlling)?) {
        guard let updater else {
            self = .hidden
            return
        }
        if let ready = updater.readyToInstallVersion {
            self = .readyToInstall(ready)
        } else if let pending = updater.pendingUpdateVersion {
            self = .pending(pending)
        } else {
            self = .check
        }
    }
}

/// Well-known node IDs.
public enum MenuNodeID {
    /// The information submenu; the UI reports when it opens and closes.
    public static let information = "information"
}

/// Icon of a menu item.
public enum MenuImage: Hashable, Sendable {
    /// A colored dot.
    case dot(StatusColor)
    /// An SF Symbol, tinted like text.
    case symbol(String)
}

/// Semantic status colors.
public enum StatusColor: Hashable, Sendable {
    case green
    case yellow
    case orange
    case red
    case gray
}

/// Every command a menu item can trigger.
public enum MenuAction: Hashable, Sendable {
    case startVM
    case stopVM
    case restartVM
    case selectProfile(ProfileName)
    case copy(String)
    case showLogs(containerID: String, name: String)
    case openTerminal(containerID: String, name: String)
    case openURL(URL)
    case container(ContainerAction, containerID: String, name: String)
    /// Opens the New Container window.
    case newContainer
    case showSettings
    case showAbout
    /// Shows the updater: a check, or the update found in the background.
    case checkForUpdates
    /// Installs the update downloaded in the background and relaunches.
    case installUpdate
    case quit

    /// Whether the action needs confirmation before it runs.
    public var needsConfirmation: Bool {
        switch self {
        case .stopVM, .restartVM: true
        case .container(let action, _, _): action != .start
        default: false
        }
    }
}
