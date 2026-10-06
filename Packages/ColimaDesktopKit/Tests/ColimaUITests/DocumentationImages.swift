import AppKit
import ColimaDomain
import Foundation
import Testing
@testable import ColimaUI

/// Renders the README and site images with the app's own drawing code.
/// Runs only with `COLIMA_DESKTOP_RENDER_DOCS=<repo root>` (see `make docs-images`).
private let outputRoot = ProcessInfo.processInfo.environment["COLIMA_DESKTOP_RENDER_DOCS"]

@MainActor
@Suite("DocumentationImages", .enabled(if: outputRoot != nil))
struct DocumentationImages {
    private var root: URL { URL(filePath: outputRoot ?? "/nonexistent", directoryHint: .isDirectory) }
    private var targets: [URL] { [root.appending(path: "docs"), root.appending(path: "site/assets")] }

    @Test("Menu bar icon styles, light and dark")
    func menuBarIcons() throws {
        let states: [IconState] = [.running, .transitioning, .stopped, .error]
        let cell = NSSize(width: 34, height: 26)
        let barPadding: CGFloat = 10
        let barWidth = cell.width * CGFloat(states.count) + barPadding * 2
        let gap: CGFloat = 16
        let size = NSSize(width: barWidth * 2 + gap, height: cell.height * CGFloat(MenuBarIconStyle.allCases.count) + 12)

        let image = NSImage(size: size, flipped: true) { _ in
            for (column, (background, foreground, appearance)) in [
                (NSColor(white: 0.96, alpha: 1), NSColor(white: 0.1, alpha: 1), NSAppearance.Name.aqua),
                (NSColor(white: 0.16, alpha: 1), NSColor.white, NSAppearance.Name.darkAqua),
            ].enumerated() {
                let barRect = NSRect(x: CGFloat(column) * (barWidth + gap), y: 0, width: barWidth, height: size.height)
                background.setFill()
                NSBezierPath(roundedRect: barRect, xRadius: 10, yRadius: 10).fill()
                for (row, style) in MenuBarIconStyle.allCases.enumerated() {
                    for (index, state) in states.enumerated() {
                        let frame = StatusIconRenderer.firstFrame(for: state, style: style)
                        let icon = StatusIconRenderer.image(for: state, style: style, frame: frame, appearance: NSAppearance(named: appearance))
                        let origin = NSPoint(
                            x: barRect.minX + barPadding + CGFloat(index) * cell.width + (cell.width - icon.size.width) / 2,
                            y: 6 + CGFloat(row) * cell.height + (cell.height - icon.size.height) / 2
                        )
                        draw(icon, at: origin, tint: icon.isTemplate ? foreground : nil)
                    }
                }
            }
            return true
        }
        try write(image, scale: 3, name: "menu-bar-icons.png")
    }

    @Test("App icon")
    func appIcon() throws {
        let source = root.appending(path: "App/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png")
        for directory in targets {
            let destination = directory.appending(path: "icon.png")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    @Test("Llama glyph as SVG for the site's menu bar")
    func llamaSVG() throws {
        // The menu bar glyph: outline llama, filled cubes, white for the site's dark strip.
        let viewBox = ColimaLlama.bounds
        var body = svgPath(ColimaLlama.bodyPath())
        body = "<path d=\"\(body)\" fill=\"none\" stroke=\"#fff\" stroke-width=\"6.4\" stroke-linejoin=\"round\" stroke-linecap=\"round\"/>"
        var cubes = ""
        for cube in ColimaLlama.cubes {
            let scaled = ColimaLlama.Cube(
                center: NSPoint(
                    x: ColimaLlama.pyramidCenter.x + (cube.center.x - ColimaLlama.pyramidCenter.x) * 1.25,
                    y: ColimaLlama.pyramidCenter.y + (cube.center.y - ColimaLlama.pyramidCenter.y) * 1.25
                ),
                angle: cube.angle,
                side: cube.side * 1.25
            )
            let d = svgPath(ColimaLlama.paths(for: scaled).box)
            // A dark halo separates the cubes from each other and from the neck, as in the app.
            cubes += "<path d=\"\(d)\" fill=\"#fff\" stroke=\"#1c1d22\" stroke-width=\"3.4\" stroke-linejoin=\"round\" paint-order=\"stroke\"/>"
        }
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="\(viewBox.minX) \(viewBox.minY) \(viewBox.width) \(viewBox.height)">\(body)\(cubes)</svg>

        """
        try svg.write(to: root.appending(path: "site/assets/llama-glyph.svg"), atomically: true, encoding: .utf8)
    }

    // MARK: Helpers

    private func draw(_ icon: NSImage, at origin: NSPoint, tint: NSColor?) {
        let rect = NSRect(origin: origin, size: icon.size)
        guard let tint else {
            icon.draw(in: rect)
            return
        }
        let tinted = NSImage(size: icon.size, flipped: false) { bounds in
            icon.draw(in: bounds)
            tint.set()
            bounds.fill(using: .sourceIn)
            return true
        }
        tinted.draw(in: rect)
    }

    private func write(_ image: NSImage, scale: CGFloat, name: String) throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width * scale),
            pixelsHigh: Int(image.size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(rep.representation(using: .png, properties: [:]))
        for directory in targets {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appending(path: name))
        }
    }

    /// SVG path data for a bezier path (same coordinate space).
    private func svgPath(_ path: NSBezierPath) -> String {
        var parts: [String] = []
        func number(_ value: CGFloat) -> String { String(format: "%.2f", value) }
        path.cgPath.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                parts.append("M\(number(points[0].x)) \(number(points[0].y))")
            case .addLineToPoint:
                parts.append("L\(number(points[0].x)) \(number(points[0].y))")
            case .addQuadCurveToPoint:
                parts.append("Q\(number(points[0].x)) \(number(points[0].y)) \(number(points[1].x)) \(number(points[1].y))")
            case .addCurveToPoint:
                parts.append("C\(number(points[0].x)) \(number(points[0].y)) \(number(points[1].x)) \(number(points[1].y)) \(number(points[2].x)) \(number(points[2].y))")
            case .closeSubpath:
                parts.append("Z")
            @unknown default:
                break
            }
        }
        return parts.joined(separator: " ")
    }
}
