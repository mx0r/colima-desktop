import AppKit
import ColimaDomain
import Testing
@testable import ColimaFeatures
@testable import ColimaUI

@MainActor
@Suite("MenuRenderer")
struct MenuRendererTests {
    private let target = MenuActionTarget { _ in }

    private func render(_ nodes: [MenuNode], into menu: NSMenu) {
        MenuRenderer(target: target, submenuDelegate: nil).render(nodes, into: menu)
    }

    @Test("Items are created in order with titles, state and actions")
    func initialRender() throws {
        let menu = NSMenu()
        render([
            MenuNode(id: "a", title: "Alpha", action: .startVM, keyEquivalent: "s"),
            .separator("sep"),
            .header("h", "Header"),
            MenuNode(id: "b", title: "Beta", isEnabled: false, isChecked: true),
        ], into: menu)
        #expect(menu.items.map { $0.identifier?.rawValue } == ["a", "sep", "h", "b"])
        #expect(menu.items[0].title == "Alpha")
        #expect(menu.items[0].keyEquivalent == "s")
        #expect(menu.items[0].action == #selector(MenuActionTarget.menuItemSelected(_:)))
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items[2].isSectionHeader)
        #expect(menu.items[3].state == .on)
        #expect(!menu.items[3].isEnabled)
        #expect(!menu.autoenablesItems)
    }

    @Test("Re-rendering keeps item and submenu identity, so open submenus survive")
    func identityPreserved() throws {
        let menu = NSMenu()
        let first = [MenuNode(id: "parent", title: "Parent", children: [MenuNode(id: "child", title: "One")])]
        render(first, into: menu)
        let item = try #require(menu.items.first)
        let submenu = try #require(item.submenu)
        let child = try #require(submenu.items.first)

        render([MenuNode(id: "parent", title: "Parent v2", children: [MenuNode(id: "child", title: "Two"), MenuNode(id: "new", title: "New")])], into: menu)
        #expect(menu.items.first === item)
        #expect(item.submenu === submenu)
        #expect(submenu.items.first === child)
        #expect(child.title == "Two")
        #expect(item.title == "Parent v2")
        #expect(submenu.items.map(\.title) == ["Two", "New"])
    }

    @Test("Items are moved, inserted and removed to match the new order")
    func reorder() throws {
        let menu = NSMenu()
        render(["a", "b", "c", "d"].map { MenuNode(id: $0, title: $0) }, into: menu)
        let b = menu.items[1]
        render(["c", "b", "e"].map { MenuNode(id: $0, title: $0) }, into: menu)
        #expect(menu.items.map(\.title) == ["c", "b", "e"])
        #expect(menu.items[1] === b)
    }

    @Test("A node changing kind replaces the item")
    func kindChange() throws {
        let menu = NSMenu()
        render([MenuNode(id: "x", title: "Item")], into: menu)
        render([.separator("x")], into: menu)
        #expect(menu.items.count == 1)
        #expect(menu.items[0].isSeparatorItem)
    }

    @Test("Dimmed items use a secondary attributed title; undimming restores the plain title")
    func dimmed() throws {
        let menu = NSMenu()
        render([MenuNode(id: "c", title: "db", isDimmed: true)], into: menu)
        let color = menu.items[0].attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == .secondaryLabelColor)
        render([MenuNode(id: "c", title: "db")], into: menu)
        #expect(menu.items[0].attributedTitle == nil || menu.items[0].attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
        #expect(menu.items[0].title == "db")
    }

    @Test("Clicking an item delivers its action")
    func actionDelivery() throws {
        var received: [MenuAction] = []
        let target = MenuActionTarget { received.append($0) }
        let menu = NSMenu()
        MenuRenderer(target: target, submenuDelegate: nil).render([MenuNode(id: "copy", title: "Copy", action: .copy("value"))], into: menu)
        // performActionForItem needs a running NSApplication; call the wired target and selector directly.
        let item = try #require(menu.items.first)
        let action = try #require(item.action)
        _ = (item.target as? NSObject)?.perform(action, with: item)
        #expect(received == [.copy("value")])
    }

    @Test("The status banner is a custom view with the title and subtitle")
    func banner() throws {
        let menu = NSMenu()
        render([MenuNode(id: "status", kind: .banner, title: "Colima is running", subtitle: "Profile: default", image: .dot(.green), isEnabled: false)], into: menu)
        let view = try #require(menu.items.first?.view)
        #expect(view.accessibilityLabel() == "Colima is running, Profile: default")
    }

    @Test("A full menu from the builder renders without unidentified items")
    func fullMenu() throws {
        var snapshot = AppSnapshot()
        snapshot.profiles = [ColimaInstance(profile: .default, status: .running, arch: "aarch64", cpus: 4, memoryBytes: 8 << 30, diskBytes: 100 << 30, runtime: "docker")]
        _ = snapshot.lifecycle.handle(.observed(.running))
        snapshot.docker = .reachable
        snapshot.containers = [
            Container(id: "abc123", name: "web", image: "nginx", state: .running, statusText: "Up", created: Date(), ports: [PublishedPort(privatePort: 80, publicPort: 8080, proto: "tcp")], labels: [Container.composeProjectLabel: "shop"]),
        ]
        let menu = NSMenu()
        render(MenuModelBuilder.build(snapshot), into: menu)
        render(MenuModelBuilder.build(snapshot), into: menu)
        func check(_ menu: NSMenu) {
            for item in menu.items {
                #expect(item.identifier != nil)
                if let submenu = item.submenu { check(submenu) }
            }
        }
        check(menu)
        #expect(menu.items.contains { $0.title == "web" })
    }

    @Test("Status icons are template images for every state")
    func statusIcons() {
        for state in [IconState.running, .stopped, .transitioning, .error, .unknown] {
            let image = StatusIconRenderer.image(for: state, style: .llamaCubes)
            #expect(image.isTemplate)
            #expect(image.accessibilityDescription?.isEmpty == false)
        }
    }

    @Test("Menu bar cubes show the state; the transition fills them one by one")
    func statusCubes() {
        #expect(StatusIconRenderer.filledCubes(for: .running, frame: 0) == [true, true, true])
        #expect(StatusIconRenderer.filledCubes(for: .stopped, frame: 0) == [false, false, false])
        #expect(StatusIconRenderer.filledCubes(for: .error, frame: 0) == [false, false, false])
        let counts = (0..<5).map { StatusIconRenderer.filledCubes(for: .transitioning, frame: $0).filter { $0 }.count }
        #expect(counts == [0, 1, 2, 3, 0])
    }

    @Test("Every style draws distinct running, changing, stopped and error icons", arguments: MenuBarIconStyle.allCases)
    func statusIconPixels(style: MenuBarIconStyle) throws {
        func pixels(_ state: IconState) throws -> Data {
            // The first frame shown for a state must already tell it apart.
            let frame = StatusIconRenderer.firstFrame(for: state, style: style)
            let image = StatusIconRenderer.image(for: state, style: style, frame: frame, appearance: NSAppearance(named: .aqua))
            var rect = NSRect(origin: .zero, size: image.size)
            let cgImage = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            return try #require(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
        }
        let states: [IconState] = [.running, .transitioning, .stopped, .error]
        let images = try states.map(pixels)
        #expect(Set(images).count == states.count)
    }

    @Test("Only the status light style uses colors; the others are template images")
    func templateStyles() {
        for style in MenuBarIconStyle.allCases {
            let image = StatusIconRenderer.image(for: .running, style: style)
            #expect(image.isTemplate == (style != .llamaDot))
            #expect(StatusIconRenderer.usesTemplate(style) == image.isTemplate)
        }
    }

    @Test("Status light colors: green running, amber changing, red stopped")
    func statusLightColors() {
        #expect(StatusIconRenderer.lightColor(for: .running) == .systemGreen)
        #expect(StatusIconRenderer.lightColor(for: .transitioning) == StatusIconRenderer.amber)
        #expect(StatusIconRenderer.lightColor(for: .stopped) == .systemRed)
        #expect(StatusIconRenderer.lightColor(for: .error) == .systemRed)
        #expect(StatusIconRenderer.lightColor(for: .unknown) == .systemGray)
    }

    @Test("Only transitions animate; frame counts depend on the style")
    func frameCounts() {
        #expect(StatusIconRenderer.frameCount(for: .transitioning, style: .container) == 5)
        #expect(StatusIconRenderer.frameCount(for: .transitioning, style: .llamaCubes) == 4)
        #expect(StatusIconRenderer.frameCount(for: .transitioning, style: .llamaDot) == 2)
        #expect(StatusIconRenderer.frameCount(for: .transitioning, style: .llamaSymbols) == 1)
        for style in MenuBarIconStyle.allCases {
            #expect(StatusIconRenderer.frameCount(for: .running, style: style) == 1)
        }
    }

    @Test("Confirmation texts name the profile or container")
    func confirmations() {
        #expect(ConfirmationPresenter.dialog(for: .stopVM, profile: ProfileName("work"))?.message == "Stop Colima “work”?")
        #expect(ConfirmationPresenter.dialog(for: .container(.restart, containerID: "1", name: "db"), profile: .default)?.confirmTitle == "Restart")
        #expect(ConfirmationPresenter.dialog(for: .startVM, profile: .default) == nil)
        let delete = ConfirmationPresenter.dialog(for: .container(.remove, containerID: "1", name: "db"), profile: .default)
        #expect(delete?.message == "Delete container “db”?")
        #expect(delete?.confirmTitle == "Delete")
    }
}
