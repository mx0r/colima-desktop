import AppKit
import ColimaFeatures

/// Boxes a `MenuAction` for `NSMenuItem.representedObject`.
final class MenuActionBox: NSObject {
    let action: MenuAction
    init(_ action: MenuAction) { self.action = action }
}

/// Receives menu item clicks and forwards the decoded action.
public final class MenuActionTarget: NSObject {
    private let handler: (MenuAction) -> Void

    /// Creates a target calling `handler` for each click.
    public init(handler: @escaping (MenuAction) -> Void) {
        self.handler = handler
    }

    @objc func menuItemSelected(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MenuActionBox else { return }
        handler(box.action)
    }
}

/// Reconciles `MenuNode` trees into `NSMenu`s in place.
///
/// Items are matched by node ID and updated, moved, inserted or removed. Existing submenus are kept,
/// so a submenu the user has open stays open while its content updates.
public final class MenuRenderer {
    private let target: MenuActionTarget
    private weak var submenuDelegate: NSMenuDelegate?

    /// Creates a renderer.
    ///
    /// - Parameters:
    ///   - target: Receives clicks.
    ///   - submenuDelegate: Set on every created submenu (to observe open/close).
    public init(target: MenuActionTarget, submenuDelegate: NSMenuDelegate?) {
        self.target = target
        self.submenuDelegate = submenuDelegate
    }

    /// Makes `menu` match `nodes`.
    public func render(_ nodes: [MenuNode], into menu: NSMenu) {
        menu.autoenablesItems = false
        var existing: [String: NSMenuItem] = [:]
        for item in menu.items {
            if let id = item.identifier?.rawValue { existing[id] = item } else { menu.removeItem(item) }
        }

        for (index, node) in nodes.enumerated() {
            var item: NSMenuItem
            if let found = existing.removeValue(forKey: node.id), Self.kind(of: found) == node.kind {
                item = found
            } else {
                if let stale = menu.items.first(where: { $0.identifier?.rawValue == node.id }) {
                    menu.removeItem(stale)
                }
                item = makeItem(for: node)
            }
            let currentIndex = menu.index(of: item)
            if currentIndex != index {
                if currentIndex >= 0 { menu.removeItem(item) }
                menu.insertItem(item, at: min(index, menu.numberOfItems))
            }
            update(&item, with: node)
        }
        for leftover in existing.values {
            menu.removeItem(leftover)
        }
    }

    // MARK: Items

    private static func kind(of item: NSMenuItem) -> MenuNode.Kind {
        if item.isSeparatorItem { return .separator }
        if item.isSectionHeader { return .header }
        if item.view is MenuBannerView { return .banner }
        return .item
    }

    private func makeItem(for node: MenuNode) -> NSMenuItem {
        let item: NSMenuItem
        switch node.kind {
        case .separator:
            item = .separator()
        case .header:
            item = .sectionHeader(title: node.title)
        case .banner:
            item = NSMenuItem()
            item.view = MenuBannerView()
        case .item:
            item = NSMenuItem()
        }
        item.identifier = NSUserInterfaceItemIdentifier(node.id)
        return item
    }

    private func update(_ item: inout NSMenuItem, with node: MenuNode) {
        switch node.kind {
        case .separator:
            return
        case .header:
            if item.title != node.title { item.title = node.title }
            return
        case .banner:
            (item.view as? MenuBannerView)?.configure(
                title: node.title,
                subtitle: node.subtitle,
                image: node.image.flatMap(MenuImages.image(for:))
            )
            item.isEnabled = false
            return
        case .item:
            break
        }

        if node.isDimmed {
            let attributed = NSAttributedString(string: node.title, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.menuFont(ofSize: 0),
            ])
            if item.attributedTitle != attributed { item.attributedTitle = attributed }
        } else {
            if item.attributedTitle != nil { item.attributedTitle = nil }
            if item.title != node.title { item.title = node.title }
        }
        if item.subtitle != node.subtitle { item.subtitle = node.subtitle }
        let image = node.image.flatMap(MenuImages.image(for:))
        if item.image !== image { item.image = image }
        if item.isEnabled != node.isEnabled { item.isEnabled = node.isEnabled }
        let state: NSControl.StateValue = node.isChecked ? .on : .off
        if item.state != state { item.state = state }
        if item.indentationLevel != node.indentation { item.indentationLevel = node.indentation }
        if item.toolTip != node.toolTip { item.toolTip = node.toolTip }
        let key = node.keyEquivalent ?? ""
        if item.keyEquivalent != key {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = key.isEmpty ? [] : .command
        }

        if let action = node.action {
            item.target = target
            item.action = #selector(MenuActionTarget.menuItemSelected(_:))
            if (item.representedObject as? MenuActionBox)?.action != action {
                item.representedObject = MenuActionBox(action)
            }
        } else {
            item.target = nil
            item.action = nil
            item.representedObject = nil
        }

        if let children = node.children {
            let submenu: NSMenu
            if let existing = item.submenu {
                submenu = existing
            } else {
                submenu = NSMenu(title: node.title)
                submenu.delegate = submenuDelegate
                item.submenu = submenu
            }
            render(children, into: submenu)
        } else if item.submenu != nil {
            item.submenu = nil
        }
    }
}

/// Non-interactive status row with a colored image, bold title and a secondary line.
final class MenuBannerView: NSView {
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 44))
        // NSMenu stretches custom item views to the menu width.
        autoresizingMask = [.width]
        titleLabel.font = .menuFont(ofSize: NSFont.systemFontSize).bold
        subtitleLabel.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.cell?.wraps = true
        subtitleLabel.preferredMaxLayoutWidth = 280

        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [imageView, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(title: String, subtitle: String?, image: NSImage?) {
        if titleLabel.stringValue != title { titleLabel.stringValue = title }
        let subtitleText = subtitle ?? ""
        if subtitleLabel.stringValue != subtitleText { subtitleLabel.stringValue = subtitleText }
        subtitleLabel.isHidden = subtitleText.isEmpty
        if imageView.image !== image { imageView.image = image }
        setAccessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: ", "))
        let size = fittingSize
        if frame.size != size { setFrameSize(size) }
    }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
