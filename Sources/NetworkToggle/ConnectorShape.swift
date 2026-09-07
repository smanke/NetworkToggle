import AppKit

/// The RJ45 socket seen head-on: the wide contact block across the top and the stepped
/// keyway that the plug's latch drops into below. Drawn as a path so it renders crisply
/// at 16pt in the menu bar and at 1024px for the app icon from one definition.
///
/// SF Symbols has no RJ45 glyph — `cable.connector` is a Thunderbolt-style oval — so
/// this is hand-drawn. The face-on socket is the recognisable Ethernet mark; a plug in
/// profile reads as a shopping basket unless it is carrying a lot of detail that a menu
/// bar cannot show.
public enum ConnectorShape {

    /// The socket's outline, its contact block, and the dividers between the eight
    /// contacts. Coordinates are proportions of `rect`, so one construction serves every
    /// size, and callers take only the pieces that stay legible at theirs.
    public static func path(
        in rect: NSRect,
        lineWidth: CGFloat
    ) -> (outline: NSBezierPath, contacts: NSBezierPath, dividers: NSBezierPath) {
        let inset = lineWidth / 2
        let inner = rect.insetBy(dx: inset, dy: inset)

        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: inner.minX + inner.width * x, y: inner.minY + inner.height * y)
        }

        // Traced clockwise from the bottom-left of the keyway tab: up the two steps, out
        // to the full width of the body, across the top, and back down the mirror image.
        let corners: [(NSPoint, CGFloat)] = [
            (point(0.31, 0.00), 0.03),
            (point(0.31, 0.15), 0.03),
            (point(0.16, 0.15), 0.03),
            (point(0.16, 0.32), 0.03),
            (point(0.00, 0.32), 0.06),
            (point(0.00, 1.00), 0.10),
            (point(1.00, 1.00), 0.10),
            (point(1.00, 0.32), 0.06),
            (point(0.84, 0.32), 0.03),
            (point(0.84, 0.15), 0.03),
            (point(0.69, 0.15), 0.03),
            (point(0.69, 0.00), 0.03),
        ]

        let outline = NSBezierPath()
        let radiusScale = min(inner.width, inner.height)
        outline.move(to: midpoint(corners[0].0, corners[1].0))
        for index in 1...corners.count {
            let current = corners[index % corners.count]
            let next = corners[(index + 1) % corners.count]
            outline.appendArc(from: current.0, to: next.0, radius: current.1 * radiusScale)
        }
        outline.close()

        // The contact block sits just inside the top edge.
        let blockLeft: CGFloat = 0.11
        let blockRight: CGFloat = 0.89
        let contacts = NSBezierPath(
            roundedRect: NSRect(
                x: point(blockLeft, 0).x,
                y: point(0, 0.63).y,
                width: (blockRight - blockLeft) * inner.width,
                height: 0.25 * inner.height
            ),
            xRadius: 0.02 * radiusScale,
            yRadius: 0.02 * radiusScale
        )

        // Seven dividers make the eight contacts of an 8P8C jack.
        let dividers = NSBezierPath()
        let step = (blockRight - blockLeft) / 8
        for index in 1..<8 {
            let x = blockLeft + step * CGFloat(index)
            dividers.move(to: point(x, 0.63))
            dividers.line(to: point(x, 0.88))
        }

        return (outline, contacts, dividers)
    }

    private static func midpoint(_ a: NSPoint, _ b: NSPoint) -> NSPoint {
        NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// A menu bar image. Template images let macOS handle light, dark and the inverted
    /// look while a menu is open, so no colours are chosen here.
    ///
    /// The eight contact dividers are dropped at this size — at 18x16 they are under a
    /// pixel apart and turn the block into a grey smear. The socket silhouette plus a
    /// solid contact bar keeps the mark readable.
    ///
    /// - Parameters:
    ///   - filled: solid when a wired connection is carrying traffic, outlined when it
    ///     is not. Weight is readable at a glance; two similar glyphs are not.
    ///   - badged: the attention dot shown when a wired link is sitting idle. Placed
    ///     bottom-right, clear of the keyway.
    ///   - slashed: struck through when nothing is connected.
    public static func menuBarImage(filled: Bool, badged: Bool = false, slashed: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { bounds in
            let lineWidth: CGFloat = 1.3
            let socketRect = NSRect(x: 2, y: 2, width: 14, height: 12)
            let (outline, contacts, _) = path(in: socketRect, lineWidth: lineWidth)

            NSColor.black.set()

            if filled {
                outline.fill()
                // Knock the contact block back out of the solid body.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                contacts.fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else {
                outline.lineWidth = lineWidth
                outline.lineJoinStyle = .round
                outline.stroke()
                contacts.fill()
            }

            if badged {
                // Clear a ring first so the dot stays distinct from the socket beneath.
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
