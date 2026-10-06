import AppKit
import ColimaDomain
import ColimaFeatures

/// Images for menu items and the status bar.
public enum MenuImages {
    private static var cache: [MenuImage: NSImage] = [:]

    /// Image for a menu node image token.
    public static func image(for token: MenuImage) -> NSImage? {
        if let cached = cache[token] { return cached }
        let image: NSImage?
        switch token {
        case .dot(let color):
            image = dot(nsColor(color))
        case .symbol(let name):
            image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
        cache[token] = image
        return image
    }

    /// AppKit color for a semantic status color.
    public static func nsColor(_ color: StatusColor) -> NSColor {
        switch color {
        case .green: .systemGreen
        case .yellow: .systemYellow
        case .orange: .systemOrange
        case .red: .systemRed
        case .gray: .systemGray
        }
    }

    /// A colored dot; not a template, so AppKit keeps its color.
    static func dot(_ color: NSColor, diameter: CGFloat = 10) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let dotRect = NSRect(
                x: (rect.width - diameter) / 2,
                y: (rect.height - diameter) / 2,
                width: diameter,
                height: diameter
            )
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            NSColor.black.withAlphaComponent(0.15).setStroke()
            let outline = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.25, dy: 0.25))
            outline.lineWidth = 0.5
            outline.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
