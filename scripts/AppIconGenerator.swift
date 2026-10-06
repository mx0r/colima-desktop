// Renders the app icon PNGs from the vector llama in ColimaLlama.swift.
// Run through scripts/generate-app-icon.sh, which compiles both files together.

import AppKit

@main
struct AppIconGenerator {
    /// Draws the icon on a square canvas following the macOS grid (824 pt body on 1024 pt).
    static func drawIcon(size: CGFloat) {
        let scale = size / 1024
        let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
        let shape = NSBezierPath(roundedRect: body, xRadius: 185 * scale, yRadius: 185 * scale)

        // Soft drop shadow under the body.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 18 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -6 * scale)
        shadow.set()
        NSColor.white.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Light background, as in the logo.
        NSGradient(colors: [
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            NSColor(srgbRed: 0.90, green: 0.92, blue: 0.87, alpha: 1),
        ])?.draw(in: shape, angle: -90)

        // Small sizes get thicker lines and no fine details.
        let small = size <= 64
        let art = small
            ? NSRect(x: 190 * scale, y: 160 * scale, width: 644 * scale, height: 700 * scale)
            : NSRect(x: 220 * scale, y: 175 * scale, width: 584 * scale, height: 670 * scale)
        ColimaLlama.draw(in: art, flipped: false, style: ColimaLlama.Style(
            outline: .black,
            bodyFill: .white,
            lineWidth: (small ? 38 : 18) * scale,
            cubeLineWidth: (small ? 30 : 16) * scale,
            slits: !small,
            cubeScale: small ? 1.2 : 1,
            straps: !small,
            cubeGap: small ? 10 * scale : 0
        ))
    }

    static func png(pixels: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        drawIcon(size: CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func main() throws {
        let output = URL(filePath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/Assets.xcassets/AppIcon.appiconset")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var images: [String] = []
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try png(pixels: points * scale).write(to: output.appending(path: filename))
                images.append(#"    { "filename" : "\#(filename)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(points)x\#(points)" }"#)
            }
        }
        let contents = "{\n  \"images\" : [\n\(images.joined(separator: ",\n"))\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
        try contents.write(to: output.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
        print("Wrote \(images.count) icons to \(output.path(percentEncoded: false))")
    }
}
