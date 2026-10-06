import AppKit
import ColimaDomain

/// Draws the menu bar icon in one of the `MenuBarIconStyle`s.
///
/// | Style | running | transitioning | stopped | error | unknown |
/// |---|---|---|---|---|---|
/// | container | filled | ribs fill up | outline | badge | faded |
/// | llamaCubes | cubes filled | cubes fill up | cubes hollow | badge | faded |
/// | llamaDot | green light | amber light, pulsing | red light | red light with "!" | grey light |
/// | llamaSymbols | play | pause | stop | badge | faded |
///
/// All styles except `llamaDot` are template images, so the system tints them for the menu bar.
/// `llamaDot` keeps its colors and is drawn for a given appearance.
public enum StatusIconRenderer {
    /// Amber of the status light.
    public static let amber = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.0, alpha: 1)

    /// Icon for a state.
    ///
    /// - Parameters:
    ///   - frame: Step of the transition animation (see `frameCount(for:style:)`).
    ///   - appearance: Appearance for colored styles; nil uses the appearance current at draw time.
    public static func image(
        for state: IconState,
        style: MenuBarIconStyle = .llamaCubes,
        frame: Int = 0,
        appearance: NSAppearance? = nil
    ) -> NSImage {
        let image: NSImage
        switch style {
        case .container:
            image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
                drawContainer(state, frame: frame)
                return true
            }
        case .llamaCubes:
            image = NSImage(size: llamaSize, flipped: true) { _ in
                drawLlamaCubes(state, frame: frame)
                return true
            }
        case .llamaDot:
            image = NSImage(size: llamaSize, flipped: true) { _ in
                let target = appearance ?? NSAppearance.currentDrawing()
                target.performAsCurrentDrawingAppearance {
                    drawLlamaDot(state, frame: frame)
                }
                return true
            }
        case .llamaSymbols:
            image = NSImage(size: llamaSize, flipped: true) { _ in
                drawLlamaSymbol(state)
                return true
            }
        }
        image.isTemplate = usesTemplate(style)
        image.accessibilityDescription = accessibilityText(for: state)
        return image
    }

    /// Whether the style is a template image (tinted by the system).
    public static func usesTemplate(_ style: MenuBarIconStyle) -> Bool {
        style != .llamaDot
    }

    /// Frames of the animation for a state; 1 means static.
    public static func frameCount(for state: IconState, style: MenuBarIconStyle) -> Int {
        guard state == .transitioning else { return 1 }
        switch style {
        case .container: return ribCount + 1
        case .llamaCubes: return ColimaLlama.cubes.count + 1
        case .llamaDot: return 2
        case .llamaSymbols: return 1
        }
    }

    /// Frame to show first. Fill animations start with one element filled, so a transition never looks like "stopped".
    public static func firstFrame(for state: IconState, style: MenuBarIconStyle) -> Int {
        frameCount(for: state, style: style) > 2 ? 1 : 0
    }

    /// VoiceOver text and tooltip for a state.
    public static func accessibilityText(for state: IconState) -> String {
        switch state {
        case .running: "Colima running"
        case .stopped: "Colima stopped"
        case .transitioning: "Colima changing state"
        case .error: "Colima error"
        case .unknown: "Colima status unknown"
        }
    }

    /// Color of the status light.
    static func lightColor(for state: IconState) -> NSColor {
        switch state {
        case .running: .systemGreen
        case .transitioning: amber
        case .stopped, .error: .systemRed
        case .unknown: .systemGray
        }
    }

    /// Which cubes are filled (bottom-left, bottom-right, top).
    static func filledCubes(for state: IconState, frame: Int) -> [Bool] {
        switch state {
        case .running:
            return [true, true, true]
        case .transitioning:
            let count = frame % frameCount(for: .transitioning, style: .llamaCubes)
            return (0..<ColimaLlama.cubes.count).map { $0 < count }
        case .stopped, .error, .unknown:
            return [false, false, false]
        }
    }

    // MARK: Llama styles

    private static let llamaSize = NSSize(width: 17, height: 18)
    private static let llamaRect = NSRect(x: 0.3, y: 0.5, width: 13, height: 17)
    private static let lineWidth: CGFloat = 1.2
    /// Where the cubes sit; the status light goes here too.
    private static var lightCenter: NSPoint {
        ColimaLlama.point(NSPoint(x: 48, y: 37), fitting: llamaRect, flipped: true)
    }

    /// Symbols sit a bit further right than the light, clear of the neck line.
    private static var symbolCenter: NSPoint {
        ColimaLlama.point(NSPoint(x: 51, y: 37), fitting: llamaRect, flipped: true)
    }

    private static func llamaStyle(color: NSColor) -> ColimaLlama.Style {
        ColimaLlama.Style(
            outline: color,
            bodyFill: nil,
            lineWidth: lineWidth,
            cubeLineWidth: lineWidth * 0.85,
            slits: false,
            cubeScale: 1.25,
            straps: false,
            cubeGap: 0.6
        )
    }

    private static func drawLlamaCubes(_ state: IconState, frame: Int) {
        let color = NSColor.black.withAlphaComponent(state == .unknown ? 0.45 : 1)
        var style = llamaStyle(color: color)
        style.cubeFills = filledCubes(for: state, frame: frame).map { $0 ? color : nil }
        ColimaLlama.draw(in: llamaRect, flipped: true, style: style)
        if state == .error {
            drawBadge(center: NSPoint(x: 13.7, y: 4.2), radius: 3.1, color: .black)
        }
    }

    private static func drawLlamaDot(_ state: IconState, frame: Int) {
        var style = llamaStyle(color: .labelColor)
        style.drawsCubes = false
        ColimaLlama.draw(in: llamaRect, flipped: true, style: style)
        // Pulse while changing state.
        let alpha: CGFloat = state == .transitioning && frame % 2 == 1 ? 0.45 : 1
        let color = lightColor(for: state).withAlphaComponent(alpha)
        if state == .error {
            drawBadge(center: lightCenter, radius: 3.1, color: color)
        } else {
            clearHalo(center: lightCenter, radius: 2.8 + 0.7)
            color.setFill()
            circle(center: lightCenter, radius: 2.8).fill()
        }
    }

    private static func drawLlamaSymbol(_ state: IconState) {
        let color = NSColor.black.withAlphaComponent(state == .unknown ? 0.45 : 1)
        var style = llamaStyle(color: color)
        style.drawsCubes = false
        ColimaLlama.draw(in: llamaRect, flipped: true, style: style)
        let center = symbolCenter
        color.setFill()
        switch state {
        case .running:
            // Play: triangle pointing right, optically centered.
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: center.x - 1.7, y: center.y - 2.7))
            triangle.line(to: NSPoint(x: center.x + 2.8, y: center.y))
            triangle.line(to: NSPoint(x: center.x - 1.7, y: center.y + 2.7))
            triangle.close()
            triangle.lineJoinStyle = .round
            clearHalo(path: triangle, width: 2)
            color.setFill()
            triangle.fill()
        case .transitioning:
            // Pause: two bars.
            let bars = NSBezierPath()
            for dx: CGFloat in [-1.35, 1.35] {
                bars.append(NSBezierPath(roundedRect: NSRect(x: center.x + dx - 0.75, y: center.y - 2.5, width: 1.5, height: 5), xRadius: 0.4, yRadius: 0.4))
            }
            clearHalo(path: bars, width: 2)
            color.setFill()
            bars.fill()
        case .stopped:
            // Stop: square.
            let square = NSBezierPath(roundedRect: NSRect(x: center.x - 2.2, y: center.y - 2.2, width: 4.4, height: 4.4), xRadius: 0.6, yRadius: 0.6)
            clearHalo(path: square, width: 2)
            color.setFill()
            square.fill()
        case .error:
            drawBadge(center: center, radius: 3.1, color: color)
        case .unknown:
            break
        }
    }

    // MARK: Container style

    private static let ribCount = 4

    private static func drawContainer(_ state: IconState, frame: Int) {
        let color = NSColor.black.withAlphaComponent(state == .unknown ? 0.45 : 1)
        let body = NSRect(x: 1.5, y: 2.5, width: 17, height: 11)
        let outline = NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2)
        outline.lineWidth = 1.5
        color.set()

        switch state {
        case .running:
            outline.fill()
            // Ribs cut out of the filled body.
            NSGraphicsContext.current?.compositingOperation = .clear
            ribs(in: body, width: 1.2).forEach { $0.fill() }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        case .stopped, .unknown:
            outline.stroke()
            ribs(in: body, width: 1).forEach { $0.fill() }
        case .transitioning:
            outline.stroke()
            // Ribs thicken one by one, like a progress indicator.
            let filled = frame % frameCount(for: .transitioning, style: .container)
            for (index, rib) in ribs(in: body, width: 1).enumerated() where index >= filled {
                rib.fill()
            }
            for rib in ribs(in: body, width: 2).prefix(filled) {
                rib.fill()
            }
        case .error:
            outline.stroke()
            ribs(in: body, width: 1).forEach { $0.fill() }
            // Flipped badge geometry, mirrored for this non-flipped canvas.
            drawBadge(center: NSPoint(x: 15.5, y: 4.5), radius: 4.5, color: color, flipped: false)
        }
    }

    private static func ribs(in body: NSRect, width: CGFloat) -> [NSBezierPath] {
        let spacing = body.width / CGFloat(ribCount + 1)
        return (1...ribCount).map { index in
            let x = body.minX + spacing * CGFloat(index) - width / 2
            return NSBezierPath(rect: NSRect(x: x, y: body.minY + 2.5, width: width, height: body.height - 5))
        }
    }

    // MARK: Shared shapes

    private static func circle(center: NSPoint, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// Clears a disc so a mark separates from the lines below it.
    private static func clearHalo(center: NSPoint, radius: CGFloat) {
        NSGraphicsContext.current?.compositingOperation = .clear
        circle(center: center, radius: radius).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    /// Clears an outline of `width` around a shape.
    private static func clearHalo(path: NSBezierPath, width: CGFloat) {
        NSGraphicsContext.current?.compositingOperation = .clear
        path.fill()
        path.lineWidth = width
        path.lineJoinStyle = .round
        path.stroke()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    /// Filled circle with a cut-out exclamation mark and a clear halo.
    private static func drawBadge(center: NSPoint, radius: CGFloat, color: NSColor, flipped: Bool = true) {
        clearHalo(center: center, radius: radius + 0.9)
        color.setFill()
        circle(center: center, radius: radius).fill()
        NSGraphicsContext.current?.compositingOperation = .clear
        let unit = radius / 3.1
        // In a flipped canvas y grows downwards: the bar is above the dot.
        let direction: CGFloat = flipped ? 1 : -1
        let barTop = center.y - 2.1 * unit * direction
        let barBottom = center.y + 0.5 * unit * direction
        NSBezierPath(
            roundedRect: NSRect(x: center.x - 0.55 * unit, y: min(barTop, barBottom), width: 1.1 * unit, height: 2.6 * unit),
            xRadius: 0.55 * unit,
            yRadius: 0.55 * unit
        ).fill()
        let dotCenter = NSPoint(x: center.x, y: center.y + 1.6 * unit * direction)
        circle(center: dotCenter, radius: 0.6 * unit).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }
}
