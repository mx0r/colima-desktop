import AppKit

/// The llama with three cubes from the Colima logo (https://github.com/abiosoft/colima, MIT), redrawn as vectors.
///
/// Geometry is in logo pixels (the llama in `colima.png` is about 76×100), origin top-left.
/// Shared by the menu bar icon and `scripts/generate-app-icon.sh`, so keep it free of module dependencies.
enum ColimaLlama {
    /// Lime green of the logo's cubes.
    static let lime = NSColor(srgbRed: 0xA9 / 255.0, green: 0xCF / 255.0, blue: 0x37 / 255.0, alpha: 1)

    /// Bounds of the drawing in logo pixels, including the outline.
    static let bounds = NSRect(x: 3.8, y: 3, width: 67.8, height: 92)

    /// A cube on the llama's back.
    struct Cube {
        var center: NSPoint
        /// Rotation in degrees, clockwise on screen.
        var angle: CGFloat
        var side: CGFloat
    }

    /// Bottom-left, bottom-right, top: the order they fill in the transition animation.
    static let cubes = [
        Cube(center: NSPoint(x: 35.5, y: 45), angle: -2, side: 12.5),
        Cube(center: NSPoint(x: 51.5, y: 43), angle: -10, side: 12.5),
        Cube(center: NSPoint(x: 42.5, y: 28.5), angle: -10, side: 12.5),
    ]

    /// Center of the cube pyramid; cubes scale around it.
    static let pyramidCenter = NSPoint(x: 43, y: 40)

    /// Drawing options.
    struct Style {
        var outline: NSColor = .black
        /// Body fill; nil leaves it transparent.
        var bodyFill: NSColor? = .white
        /// Outline width in output points.
        var lineWidth: CGFloat
        /// Cube fill per cube (`cubes` order); nil draws a hollow cube.
        var cubeFills: [NSColor?] = [lime, lime, lime]
        var cubeLineWidth: CGFloat
        /// Door slits on the cubes (only legible at large sizes).
        var slits = true
        /// Enlarges the cube pyramid around its center; small sizes need bigger cubes.
        var cubeScale: CGFloat = 1
        /// Draws the saddle straps.
        var straps = true
        /// Clear gap around each cube in output points, so small filled cubes stay separate.
        var cubeGap: CGFloat = 0
        /// Draws the cubes; false leaves the llama's back free for another mark.
        var drawsCubes = true
    }

    /// Point in `rect` for a point in logo pixels, using the same fit as `draw(in:flipped:style:)`.
    static func point(_ logoPoint: NSPoint, fitting rect: NSRect, flipped: Bool) -> NSPoint {
        transform(fitting: rect, flipped: flipped).transform(logoPoint)
    }

    /// Output points per logo pixel for `rect`.
    static func scale(fitting rect: NSRect) -> CGFloat {
        min(rect.width / bounds.width, rect.height / bounds.height)
    }

    /// Transform from logo pixels into `rect` (aspect fit, centered). `flipped` is the target's `isFlipped`.
    static func transform(fitting rect: NSRect, flipped: Bool) -> AffineTransform {
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let width = bounds.width * scale
        let height = bounds.height * scale
        let originX = rect.minX + (rect.width - width) / 2
        let originY = rect.minY + (rect.height - height) / 2
        var transform = AffineTransform.identity
        if flipped {
            transform.translate(x: originX, y: originY)
            transform.scale(scale)
        } else {
            transform.translate(x: originX, y: originY + height)
            transform.scale(x: scale, y: -scale)
        }
        transform.translate(x: -bounds.minX, y: -bounds.minY)
        return transform
    }

    /// Draws into the current graphics context, aspect-fitted into `rect`.
    static func draw(in rect: NSRect, flipped: Bool, style: Style) {
        let transform = transform(fitting: rect, flipped: flipped)

        let body = bodyPath()
        body.transform(using: transform)
        body.lineWidth = style.lineWidth
        body.lineJoinStyle = .round
        body.lineCapStyle = .round
        if let fill = style.bodyFill {
            fill.setFill()
            body.fill()
        }
        style.outline.setStroke()
        body.stroke()

        if style.straps {
            for strap in strapPaths() {
                strap.transform(using: transform)
                strap.lineWidth = style.lineWidth
                strap.lineCapStyle = .round
                strap.stroke()
            }
        }

        for (index, cube) in cubes.enumerated() where style.drawsCubes {
            let scaled = Cube(
                center: NSPoint(
                    x: pyramidCenter.x + (cube.center.x - pyramidCenter.x) * style.cubeScale,
                    y: pyramidCenter.y + (cube.center.y - pyramidCenter.y) * style.cubeScale
                ),
                angle: cube.angle,
                side: cube.side * style.cubeScale
            )
            let (box, slits) = paths(for: scaled)
            box.transform(using: transform)
            box.lineJoinStyle = .round
            if style.cubeGap > 0 {
                NSGraphicsContext.current?.compositingOperation = .clear
                box.lineWidth = style.cubeLineWidth + style.cubeGap * 2
                box.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            box.lineWidth = style.cubeLineWidth
            // Knock out the body behind the cube so hollow cubes stay readable.
            if let fill = style.cubeFills.indices.contains(index) ? style.cubeFills[index] : nil {
                fill.setFill()
                box.fill()
            } else if let bodyFill = style.bodyFill {
                bodyFill.setFill()
                box.fill()
            } else {
                NSGraphicsContext.current?.compositingOperation = .clear
                box.fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            style.outline.setStroke()
            box.stroke()
            guard style.slits else { continue }
            for slit in slits {
                slit.transform(using: transform)
                slit.lineWidth = style.cubeLineWidth * 0.6
                slit.lineCapStyle = .round
                slit.stroke()
            }
        }
    }

    // MARK: Paths (logo pixels, top-left origin)

    private static func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

    /// Outline of the llama: front leg, neck, head, ear, back, tail, back leg, belly.
    static func bodyPath() -> NSBezierPath {
        let b = NSBezierPath()
        b.move(to: p(19.5, 93.5))
        b.line(to: p(19.5, 80))
        b.curve(to: p(13, 70), controlPoint1: p(19.5, 75), controlPoint2: p(15, 73))
        b.curve(to: p(9, 56), controlPoint1: p(10, 66), controlPoint2: p(9, 61))
        b.curve(to: p(14, 36), controlPoint1: p(9, 48), controlPoint2: p(13, 42))
        b.curve(to: p(15.5, 27.5), controlPoint1: p(15, 32), controlPoint2: p(15.5, 30))
        b.line(to: p(7.5, 27.5))
        b.curve(to: p(5.5, 22), controlPoint1: p(5, 27.5), controlPoint2: p(4.5, 24))
        b.curve(to: p(13, 18.5), controlPoint1: p(7, 20), controlPoint2: p(10, 19.5))
        b.curve(to: p(19, 14), controlPoint1: p(16, 17.5), controlPoint2: p(18.5, 16.5))
        b.curve(to: p(22, 4.5), controlPoint1: p(19.5, 10), controlPoint2: p(20, 5.5))
        b.curve(to: p(28, 14), controlPoint1: p(24.5, 4), controlPoint2: p(27.5, 9))
        b.curve(to: p(29, 34), controlPoint1: p(29, 20), controlPoint2: p(29.5, 28))
        b.curve(to: p(26, 47), controlPoint1: p(28.5, 40), controlPoint2: p(27, 44))
        b.curve(to: p(55, 52), controlPoint1: p(32, 52), controlPoint2: p(48, 52))
        b.curve(to: p(64, 57.5), controlPoint1: p(59, 52), controlPoint2: p(62, 54))
        b.curve(to: p(70, 65), controlPoint1: p(66, 60), controlPoint2: p(69, 63))
        b.curve(to: p(61.5, 62), controlPoint1: p(66.5, 64.5), controlPoint2: p(63.5, 62))
        b.curve(to: p(59.5, 80), controlPoint1: p(61, 68), controlPoint2: p(59.5, 75))
        b.line(to: p(58.5, 93.5))
        b.line(to: p(54, 93.5))
        b.line(to: p(54.5, 84))
        b.curve(to: p(51, 76.5), controlPoint1: p(54.5, 80), controlPoint2: p(53.5, 77.5))
        b.curve(to: p(40, 76.5), controlPoint1: p(47, 75.5), controlPoint2: p(44, 76.5))
        b.curve(to: p(25, 75), controlPoint1: p(35, 76.5), controlPoint2: p(29, 74))
        b.curve(to: p(24, 80), controlPoint1: p(24, 76), controlPoint2: p(24, 78))
        b.line(to: p(23.5, 93.5))
        b.close()
        return b
    }

    /// The two saddle straps under the cubes.
    static func strapPaths() -> [NSBezierPath] {
        let outer = NSBezierPath()
        outer.move(to: p(25.5, 49))
        outer.curve(to: p(40, 65.5), controlPoint1: p(26, 58), controlPoint2: p(31, 65.5))
        outer.curve(to: p(56, 53), controlPoint1: p(49, 65.5), controlPoint2: p(55, 60))
        let inner = NSBezierPath()
        inner.move(to: p(29, 52.5))
        inner.curve(to: p(40, 60), controlPoint1: p(30.5, 57.5), controlPoint2: p(34, 60))
        inner.curve(to: p(52, 52.5), controlPoint1: p(46, 60), controlPoint2: p(50.5, 57))
        return [outer, inner]
    }

    /// A rounded cube face and its two door slits.
    static func paths(for cube: Cube) -> (box: NSBezierPath, slits: [NSBezierPath]) {
        var transform = AffineTransform(translationByX: cube.center.x, byY: cube.center.y)
        transform.rotate(byDegrees: cube.angle)
        let half = cube.side / 2
        let box = NSBezierPath(roundedRect: NSRect(x: -half, y: -half, width: cube.side, height: cube.side), xRadius: cube.side * 0.1, yRadius: cube.side * 0.1)
        box.transform(using: transform)
        let slitOffset = cube.side * 0.15
        let slitHalfLength = cube.side * 0.24
        let slits = [-slitOffset, slitOffset].map { dx -> NSBezierPath in
            let slit = NSBezierPath()
            slit.move(to: NSPoint(x: dx, y: -slitHalfLength))
            slit.line(to: NSPoint(x: dx, y: slitHalfLength))
            slit.transform(using: transform)
            return slit
        }
        return (box, slits)
    }
}
