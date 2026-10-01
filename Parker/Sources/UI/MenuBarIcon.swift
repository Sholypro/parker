import Cocoa

/// Menu bar icon drawn from Parker/Support/MenuBarIcon.svg (256-unit artboard, y pointing down).
/// Vector + template: crisp at any scale, and macOS tints it for light / dark menu bars.
enum MenuBarIcon {
    static func make(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let s = rect.width / 256
            let transform = NSAffineTransform()
            transform.scale(by: s)
            transform.concat()
            NSColor.black.setStroke()

            func stroke(_ path: NSBezierPath, width: CGFloat) {
                // Never thinner than one device pixel once scaled down
                path.lineWidth = max(width, 1.0 / s)
                path.stroke()
            }

            // Outer rounded square
            stroke(NSBezierPath(roundedRect: NSRect(x: 6, y: 6, width: 244, height: 244), xRadius: 52, yRadius: 52), width: 12)

            // Lenses
            stroke(NSBezierPath(roundedRect: NSRect(x: 44, y: 72, width: 72, height: 65), xRadius: 17, yRadius: 17), width: 12)
            stroke(NSBezierPath(roundedRect: NSRect(x: 140, y: 72, width: 72, height: 65), xRadius: 17, yRadius: 17), width: 12)

            // Bridge
            let bridge = NSBezierPath()
            bridge.move(to: NSPoint(x: 116, y: 102.5))
            bridge.curve(to: NSPoint(x: 140, y: 102.5),
                         controlPoint1: NSPoint(x: 124, y: 97.8333),
                         controlPoint2: NSPoint(x: 132, y: 97.8333))
            stroke(bridge, width: 12)

            // Viewfinder corners inside the lenses
            let marks = NSBezierPath()
            marks.move(to: NSPoint(x: 63, y: 112))
            marks.line(to: NSPoint(x: 63, y: 91.5))
            marks.line(to: NSPoint(x: 84, y: 91.5))
            marks.move(to: NSPoint(x: 172, y: 117.5))
            marks.line(to: NSPoint(x: 193, y: 117.5))
            marks.line(to: NSPoint(x: 193, y: 97))
            stroke(marks, width: 9)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Parker"
        return image
    }
}
