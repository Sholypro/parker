import Cocoa

enum AnnotationToolType: String, CaseIterable {
    case select = "Select"
    case arrow = "Arrow"
    case rectangle = "Rectangle"
    case ellipse = "Ellipse"
    case line = "Line"
    case text = "Text"
    case freehand = "Freehand"
    case highlight = "Highlight"
    case blur = "Blur"
    case pixelate = "Pixelate"
    case spotlight = "Spotlight"
    case numberedStep = "Step"
    case crop = "Crop"

    var iconName: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .line: return "line.diagonal"
        case .text: return "textformat"
        case .freehand: return "pencil.tip"
        case .highlight: return "highlighter"
        case .blur: return "drop.fill"
        case .pixelate: return "square.grid.3x3.fill"
        case .spotlight: return "flashlight.on.fill"
        case .numberedStep: return "1.circle"
        case .crop: return "crop"
        }
    }

    /// French label shown in tooltips
    var label: String {
        switch self {
        case .select: return "Sélection"
        case .arrow: return "Flèche"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Ligne"
        case .text: return "Texte"
        case .freehand: return "Crayon"
        case .highlight: return "Surligneur"
        case .blur: return "Flou"
        case .pixelate: return "Pixellisation"
        case .spotlight: return "Spotlight"
        case .numberedStep: return "Compteur"
        case .crop: return "Recadrer"
        }
    }

    /// Single-key shortcut (no modifier) in the editor
    var shortcut: Character {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .line: return "l"
        case .text: return "t"
        case .freehand: return "p"
        case .highlight: return "h"
        case .blur: return "b"
        case .pixelate: return "x"
        case .spotlight: return "s"
        case .numberedStep: return "n"
        case .crop: return "c"
        }
    }

    var tooltip: String { "\(label) (\(String(shortcut).uppercased()))" }

    /// Tools defined by a rectangle that can be resized by their corners
    var isRectBased: Bool {
        switch self {
        case .rectangle, .ellipse, .highlight, .blur, .pixelate, .spotlight: return true
        default: return false
        }
    }

    /// Tools that are rendered from the base image pixels
    var isImageEffect: Bool { self == .blur || self == .pixelate }
}

class Annotation {
    let id = UUID()
    var toolType: AnnotationToolType
    var color: NSColor
    var lineWidth: CGFloat
    var points: [NSPoint] = []
    var rect: NSRect = .zero
    var text: String = ""
    var fontSize: CGFloat = 16
    var stepNumber: Int = 1
    /// Shapes: filled. Text: drawn on a colored label background.
    var isFilled: Bool = false
    var isSelected: Bool = false

    // Effect cache: avoids recomputing the CIFilter pipeline every frame
    var cachedBlurImage: CGImage?
    var cachedBlurRect: NSRect = .zero

    static let textPadding: CGFloat = 8
    static let handleRadius: CGFloat = 5

    init(toolType: AnnotationToolType, color: NSColor = .systemRed, lineWidth: CGFloat = 3) {
        self.toolType = toolType
        self.color = color
        self.lineWidth = lineWidth
    }

    // MARK: - Sizing helpers

    static func fontSize(forLineWidth width: CGFloat) -> CGFloat { 12 + width * 2 }

    static func textFont(size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }

    static func textRect(for text: String, origin: NSPoint, fontSize: CGFloat, filled: Bool) -> NSRect {
        let size = (text as NSString).size(withAttributes: [.font: textFont(size: fontSize)])
        if filled {
            return NSRect(x: origin.x, y: origin.y,
                          width: ceil(size.width) + textPadding * 2,
                          height: ceil(size.height) + textPadding)
        }
        return NSRect(origin: origin, size: NSSize(width: ceil(size.width), height: ceil(size.height)))
    }

    var stepDiameter: CGFloat { 18 + lineWidth * 3 }

    var stepCircleRect: NSRect {
        let d = stepDiameter
        return NSRect(x: rect.origin.x - d / 2, y: rect.origin.y - d / 2, width: d, height: d)
    }

    /// Bounding box used for the selection outline
    var boundingRect: NSRect {
        switch toolType {
        case .arrow, .line, .freehand:
            guard let first = points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .numberedStep:
            return stepCircleRect
        default:
            return rect
        }
    }

    /// Resize handles: endpoints for lines/arrows, corners for rect-based shapes
    var handlePoints: [NSPoint] {
        if toolType == .arrow || toolType == .line {
            return points.count >= 2 ? [points[0], points[1]] : []
        }
        if toolType.isRectBased {
            return [
                NSPoint(x: rect.minX, y: rect.minY),
                NSPoint(x: rect.maxX, y: rect.minY),
                NSPoint(x: rect.minX, y: rect.maxY),
                NSPoint(x: rect.maxX, y: rect.maxY),
            ]
        }
        return []
    }

    private var contrastingTextColor: NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.65 ? .black : .white
    }

    // MARK: - Drawing

    func draw(in context: CGContext, viewBounds: NSRect) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch toolType {
        case .select:
            break
        case .arrow:
            drawArrow(in: context)
        case .rectangle:
            drawRectangle(in: context)
        case .ellipse:
            drawEllipse(in: context)
        case .line:
            drawLine(in: context)
        case .text:
            drawText(in: context)
        case .freehand:
            drawFreehand(in: context)
        case .highlight:
            drawHighlight(in: context)
        case .blur, .pixelate, .spotlight:
            break // rendered by the canvas (needs the base image / whole canvas)
        case .numberedStep:
            drawNumberedStep(in: context)
        case .crop:
            drawCropOverlay(in: context, viewBounds: viewBounds)
        }

        context.restoreGState()

        if isSelected {
            drawSelection(in: context)
        }
    }

    private func drawSelection(in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(boundingRect.insetBy(dx: -5, dy: -5))
        context.setLineDash(phase: 0, lengths: [])

        let r = Annotation.handleRadius
        for p in handlePoints {
            let handle = NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: handle)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: handle)
        }
        context.restoreGState()
    }

    private func drawArrow(in context: CGContext) {
        guard points.count >= 2 else { return }
        let start = points[0]
        let end = points[1]
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 1 else { return }

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = min(max(14, lineWidth * 4.5), length * 0.6)
        let headAngle: CGFloat = .pi / 7

        let p1 = NSPoint(x: end.x - headLength * cos(angle - headAngle),
                         y: end.y - headLength * sin(angle - headAngle))
        let p2 = NSPoint(x: end.x - headLength * cos(angle + headAngle),
                         y: end.y - headLength * sin(angle + headAngle))
        let base = NSPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)

        // Tapered shaft: thin at the tail, full width at the head
        let perp = angle + .pi / 2
        let tailHalf = max(1, lineWidth * 0.25)
        let headHalf = lineWidth * 0.75
        context.beginPath()
        context.move(to: NSPoint(x: start.x + tailHalf * cos(perp), y: start.y + tailHalf * sin(perp)))
        context.addLine(to: NSPoint(x: base.x + headHalf * cos(perp), y: base.y + headHalf * sin(perp)))
        context.addLine(to: NSPoint(x: base.x - headHalf * cos(perp), y: base.y - headHalf * sin(perp)))
        context.addLine(to: NSPoint(x: start.x - tailHalf * cos(perp), y: start.y - tailHalf * sin(perp)))
        context.closePath()
        context.setFillColor(color.cgColor)
        context.fillPath()

        context.beginPath()
        context.move(to: end)
        context.addLine(to: p1)
        context.addLine(to: p2)
        context.closePath()
        context.setFillColor(color.cgColor)
        context.setLineJoin(.round)
        context.setLineWidth(max(1, lineWidth * 0.5))
        context.drawPath(using: .fillStroke)
    }

    private func drawRectangle(in context: CGContext) {
        let radius = min(4, rect.width / 2, rect.height / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if isFilled {
            context.setFillColor(color.withAlphaComponent(0.3).cgColor)
            context.addPath(path)
            context.fillPath()
        }
        context.addPath(path)
        context.strokePath()
    }

    private func drawEllipse(in context: CGContext) {
        if isFilled {
            context.setFillColor(color.withAlphaComponent(0.3).cgColor)
            context.fillEllipse(in: rect)
        }
        context.strokeEllipse(in: rect)
    }

    private func drawLine(in context: CGContext) {
        guard points.count >= 2 else { return }
        context.move(to: points[0])
        context.addLine(to: points[1])
        context.strokePath()
    }

    private func drawText(in context: CGContext) {
        let font = Annotation.textFont(size: fontSize)
        var attrs: [NSAttributedString.Key: Any] = [.font: font]

        if isFilled {
            attrs[.foregroundColor] = contrastingTextColor
            let background = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            color.setFill()
            background.fill()
            (text as NSString).draw(
                at: NSPoint(x: rect.minX + Annotation.textPadding, y: rect.minY + Annotation.textPadding / 2),
                withAttributes: attrs
            )
        } else {
            attrs[.foregroundColor] = color
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            attrs[.shadow] = shadow
            (text as NSString).draw(at: rect.origin, withAttributes: attrs)
        }
    }

    private func drawFreehand(in context: CGContext) {
        guard points.count >= 2 else { return }

        if points.count <= 3 {
            context.move(to: points[0])
            for i in 1..<points.count {
                context.addLine(to: points[i])
            }
            context.strokePath()
            return
        }

        // Smooth Catmull-Rom spline for natural pencil feel
        context.move(to: points[0])
        for i in 0..<points.count - 1 {
            let p0 = points[max(0, i - 1)]
            let p1 = points[i]
            let p2 = points[min(points.count - 1, i + 1)]
            let p3 = points[min(points.count - 1, i + 2)]

            let cp1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let cp2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            context.addCurve(to: p2, control1: cp1, control2: cp2)
        }
        context.strokePath()
    }

    private func drawHighlight(in context: CGContext) {
        context.setBlendMode(.multiply)
        context.setFillColor(color.withAlphaComponent(0.4).cgColor)
        context.fill(rect)
    }

    private func drawNumberedStep(in context: CGContext) {
        let circleRect = stepCircleRect

        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: circleRect)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(max(1.5, stepDiameter * 0.06))
        context.strokeEllipse(in: circleRect.insetBy(dx: 1, dy: 1))

        let text = "\(stepNumber)"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: contrastingTextColor,
            .font: NSFont.systemFont(ofSize: stepDiameter * 0.5, weight: .bold)
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: NSPoint(x: circleRect.midX - textSize.width / 2, y: circleRect.midY - textSize.height / 2),
            withAttributes: attrs
        )
    }

    private func drawCropOverlay(in context: CGContext, viewBounds: NSRect) {
        guard rect.width > 0, rect.height > 0 else { return }

        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.fill(NSRect(x: 0, y: rect.maxY, width: viewBounds.width, height: viewBounds.height - rect.maxY))
        context.fill(NSRect(x: 0, y: 0, width: viewBounds.width, height: rect.origin.y))
        context.fill(NSRect(x: 0, y: rect.origin.y, width: rect.origin.x, height: rect.height))
        context.fill(NSRect(x: rect.maxX, y: rect.origin.y, width: viewBounds.width - rect.maxX, height: rect.height))
        context.restoreGState()

        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.stroke(rect)

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
        context.setLineWidth(0.5)
        let thirdW = rect.width / 3
        let thirdH = rect.height / 3
        for i in 1...2 {
            let x = rect.origin.x + thirdW * CGFloat(i)
            context.move(to: CGPoint(x: x, y: rect.origin.y))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.strokePath()

            let y = rect.origin.y + thirdH * CGFloat(i)
            context.move(to: CGPoint(x: rect.origin.x, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.strokePath()
        }

        let handleSize: CGFloat = 8
        context.setFillColor(NSColor.white.cgColor)
        for corner in [
            NSPoint(x: rect.minX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY),
            NSPoint(x: rect.maxX, y: rect.maxY),
        ] {
            context.fill(NSRect(x: corner.x - handleSize / 2, y: corner.y - handleSize / 2, width: handleSize, height: handleSize))
        }

        // Size label
        let label = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attrs)
        let labelRect = NSRect(x: rect.minX, y: rect.maxY + 6, width: size.width + 12, height: size.height + 4)
        context.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        context.addPath(CGPath(roundedRect: labelRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.fillPath()
        label.draw(at: NSPoint(x: labelRect.minX + 6, y: labelRect.minY + 2), withAttributes: attrs)
    }

    // MARK: - Hit testing

    func hitTest(point: NSPoint) -> Bool {
        switch toolType {
        case .arrow, .line:
            guard points.count >= 2 else { return false }
            return distanceFromPointToLine(point: point, lineStart: points[0], lineEnd: points[1]) < max(8, lineWidth)
        case .text:
            return rect.insetBy(dx: -4, dy: -4).contains(point)
        case .numberedStep:
            return stepCircleRect.insetBy(dx: -2, dy: -2).contains(point)
        case .freehand:
            guard points.count >= 2 else { return false }
            for i in 1..<points.count where distanceFromPointToLine(point: point, lineStart: points[i - 1], lineEnd: points[i]) < max(8, lineWidth) {
                return true
            }
            return false
        case .rectangle, .ellipse:
            if isFilled { return rect.insetBy(dx: -4, dy: -4).contains(point) }
            // Outline shapes: only the border is clickable, so things inside stay selectable
            let outer = rect.insetBy(dx: -max(6, lineWidth), dy: -max(6, lineWidth))
            let inner = rect.insetBy(dx: max(6, lineWidth), dy: max(6, lineWidth))
            return outer.contains(point) && (inner.width <= 0 || inner.height <= 0 || !inner.contains(point))
        default:
            return rect.insetBy(dx: -4, dy: -4).contains(point)
        }
    }

    /// Index of the resize handle under `point`, if any
    func handleIndex(at point: NSPoint) -> Int? {
        let tolerance = Annotation.handleRadius + 4
        for (i, p) in handlePoints.enumerated() where hypot(p.x - point.x, p.y - point.y) <= tolerance {
            return i
        }
        return nil
    }

    private func distanceFromPointToLine(point: NSPoint, lineStart: NSPoint, lineEnd: NSPoint) -> CGFloat {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return hypot(point.x - lineStart.x, point.y - lineStart.y) }

        var t = ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / lenSq
        t = max(0, min(1, t))

        let proj = NSPoint(x: lineStart.x + t * dx, y: lineStart.y + t * dy)
        return hypot(point.x - proj.x, point.y - proj.y)
    }
}
