import AppKit

/// The RJ45 plug on the end of an Ethernet cable, drawn as a path so it renders crisply
/// at 16pt in the menu bar and at 1024px for the app icon from one definition.
///
/// SF Symbols has no RJ45 glyph — `cable.connector` is a Thunderbolt-style oval — so
/// this is hand-drawn. The silhouette is traced as a single outline rather than as a
/// body plus a separate latch: two overlapping subpaths leave a seam across the join
/// when stroked, and the latch then reads as a handle sitting on a basket.
public enum ConnectorShape {

    /// The plug's outline and its contact pins, sized to `rect`. Coordinates are
    /// proportions of the rect, so one construction serves every size.
    public static func path(in rect: NSRect, lineWidth: CGFloat) -> (outline: NSBezierPath, pins: NSBezierPath) {
        let inset = lineWidth / 2
        let inner = rect.insetBy(dx: inset, dy: inset)

        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: inner.minX + inner.width * x, y: inner.minY + inner.height * y)
        }

        // Traced as one closed outline: the cable stub at the bottom, out to the body,
        // around the latch that clicks into the socket, and back down. The stub matters —
        // without it a body-plus-latch silhouette reads as a shopping basket.
        let corners: [(NSPoint, CGFloat)] = [
            (point(0.43, 0.00), 0.03),   // cable, bottom-left
            (point(0.43, 0.22), 0.03),   // cable meets the body
            (point(0.00, 0.22), 0.08),   // body, bottom-left
            (point(0.00, 0.70), 0.08),   // body, top-left
            (point(0.34, 0.70), 0.04),   // latch shoulder, left
            (point(0.39, 1.00), 0.04),   // latch tip, left
            (point(0.61, 1.00), 0.04),   // latch tip, right
            (point(0.66, 0.70), 0.04),   // latch shoulder, right
            (point(1.00, 0.70), 0.08),   // body, top-right
            (point(1.00, 0.22), 0.08),   // body, bottom-right
            (point(0.57, 0.22), 0.03),   // cable meets the body
            (point(0.57, 0.00), 0.03),   // cable, bottom-right
        ]

        let outline = NSBezierPath()
        let radiusScale = min(inner.width, inner.height)
        outline.move(to: midpoint(corners[0].0, corners[1].0))
        for index in 1...corners.count {
            let current = corners[index % corners.count]
            let next = corners[(index + 1) % corners.count]
            outline.appendArc(
                from: current.0,
                to: next.0,
                radius: current.1 * radiusScale
            )
        }
        outline.close()

        // Four contacts as short stubs below the top edge of the face. Running them the
        // full height of the body turns the plug into a basket; eight would be accurate
        // and illegible at menu bar size.
        let pins = NSBezierPath()
        for x in [CGFloat(0.18), 0.39, 0.61, 0.82] {
            pins.move(to: point(x, 0.61))
            pins.line(to: point(x, 0.47))
        }

        return (outline, pins)
    }

    private static func midpoint(_ a: NSPoint, _ b: NSPoint) -> NSPoint {
        NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// A menu bar image. Template images let macOS handle light, dark and the inverted
    /// look while a menu is open, so no colours are chosen here.
    ///
    /// The contact pins are deliberately omitted at this size: at 18x16 they collide
    /// with the outline and the glyph turns to mush. The silhouette — latch, wide body,
    /// cable stub — is distinctive on its own.
    ///
    /// - Parameters:
    ///   - filled: solid when a wired connection is carrying traffic, outlined when it
    ///     is not. Weight is readable at a glance; two similar glyphs are not.
    ///   - badged: the attention dot shown when a wired link is sitting idle. Placed
    ///     bottom-right, clear of the latch.
    ///   - slashed: struck through when nothing is connected.
    public static func menuBarImage(filled: Bool, badged: Bool = false, slashed: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { bounds in
            let lineWidth: CGFloat = 1.5
            let plugRect = NSRect(x: 1, y: 2, width: 16, height: 12)
            let (outline, _) = path(in: plugRect, lineWidth: lineWidth)

            NSColor.black.set()

            if filled {
                outline.fill()
            } else {
                outline.lineWidth = lineWidth
                outline.lineJoinStyle = .round
                outline.stroke()
            }

            if badged {
                // Clear a ring first so the dot stays distinct from the plug beneath it.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 7.5, y: bounds.minY - 0.5, width: 8, height: 8)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 6, y: bounds.minY + 1, width: 5, height: 5)).fill()
            }

            if slashed {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: bounds.minX + 1, y: bounds.minY + 2))
                slash.line(to: NSPoint(x: bounds.maxX - 1, y: bounds.maxY - 2))
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                slash.lineWidth = lineWidth + 2.5
                slash.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                slash.lineWidth = lineWidth
                slash.lineCapStyle = .round
                slash.stroke()
            }

            return true
        }
        image.isTemplate = true
        return image
    }
}
