// Draws Resources/AppIcon.png from the same RJ45 path the menu bar uses.
// Run via ./Tools/make_icns.sh, which compiles this alongside ConnectorShape.swift
// so the app icon and the menu bar glyph can never drift apart.
import AppKit

// Compiled with ConnectorShape.swift, so this is a library, not a script — the
// executable code has to live in a main entry point rather than at the top level.
@main
struct IconGenerator {
    static func main() {
        let size = CGFloat(1024)
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let tile = NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225)
        NSGradient(
            colors: [
                NSColor(srgbRed: 0.20, green: 0.47, blue: 0.90, alpha: 1),
                NSColor(srgbRed: 0.09, green: 0.28, blue: 0.66, alpha: 1),
            ]
        )?.draw(in: tile, angle: -90)

        let plugRect = NSRect(x: size * 0.17, y: size * 0.26, width: size * 0.66, height: size * 0.48)
        let lineWidth = size * 0.05

        // The plug is rendered into its own transparent layer and then composited. The
        // pins are knocked out of that layer, and destinationOut erases to transparent —
        // done directly on the tile it would take the gradient with it.
        let plug = NSImage(size: NSSize(width: size, height: size))
        plug.lockFocus()
        let (outline, pins) = ConnectorShape.path(in: plugRect, lineWidth: lineWidth)
        NSColor.white.set()
        outline.fill()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        pins.lineWidth = lineWidth * 0.62
        pins.lineCapStyle = .round
        pins.stroke()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        plug.unlockFocus()

        plug.draw(in: rect)

        image.unlockFocus()

        // lockFocus renders at the display's backing scale, so read the bitmap back at whatever
        // size it actually came out and let sips downsample from there.
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { fatalError("Could not render the icon.") }

        let url = URL(fileURLWithPath: "Resources/AppIcon.png")
        try! png.write(to: url)
        print("Wrote \(url.path) at \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
}
