import Cocoa
import CoreImage

class AnnotationCanvas: NSView {
    var baseImage: NSImage? {
        didSet {
            baseCIImage = nil
            for a in annotations { a.cachedBlurImage = nil }
            needsDisplay = true
        }
    }
    var annotations: [Annotation] = []
    var currentTool: AnnotationToolType = .arrow {
        didSet {
            if currentTool != .select { deselectAll() }
        }
    }
    var currentColor: NSColor = .systemRed {
        didSet { updateSelected { $0.color = self.currentColor } }
    }
    var currentLineWidth: CGFloat = 3 {
        didSet {
            updateSelected { a in
                a.lineWidth = self.currentLineWidth
                if a.toolType == .text {
                    a.fontSize = Annotation.fontSize(forLineWidth: self.currentLineWidth)
                    a.rect = Annotation.textRect(for: a.text, origin: a.rect.origin, fontSize: a.fontSize, filled: a.isFilled)
                }
            }
        }
    }
    var currentFilled: Bool = false {
        didSet {
            updateSelected { a in
                a.isFilled = self.currentFilled
                if a.toolType == .text {
                    a.rect = Annotation.textRect(for: a.text, origin: a.rect.origin, fontSize: a.fontSize, filled: a.isFilled)
                }
            }
        }
    }
    var onAnnotationsChanged: (() -> Void)?
    var onCropApplied: ((NSRect) -> Void)?
    var onCanvasSizeChanged: (() -> Void)?
    /// A single-key shortcut changed the tool (the toolbar mirrors it)
    var onToolShortcut: ((AnnotationToolType) -> Void)?
    /// Return pressed while a crop is pending
    var onConfirmCrop: (() -> Void)?

    private struct UndoState {
        let image: NSImage?
        let annotations: [Annotation]
        let canvasSize: NSSize
    }

    private static let sharedCIContext = CIContext(options: [.cacheIntermediates: false])

    private var baseCIImage: CIImage?
    private var activeAnnotation: Annotation?
    private var dragStart: NSPoint?
    private var undoStack: [UndoState] = []
    private var redoStack: [UndoState] = []
    private var cropAnnotation: Annotation?
    private var activeTextField: NSTextField?

    // Selection / move / resize state
    private var movingAnnotation: Annotation?
    private var moveOffset: NSPoint = .zero
    private var resizingAnnotation: Annotation?
    private var resizeHandle: Int = 0
    private var resizeAnchor: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    private func updateSelected(_ change: (Annotation) -> Void) {
        let selected = annotations.filter { $0.isSelected }
        guard !selected.isEmpty else { return }
        selected.forEach(change)
        needsDisplay = true
        onAnnotationsChanged?()
    }

    private func deselectAll() {
        guard annotations.contains(where: { $0.isSelected }) else { return }
        for a in annotations { a.isSelected = false }
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if let image = baseImage {
            image.draw(in: bounds)
        }
        drawAnnotationLayers(in: context, includeActive: true)
    }

    /// Shared by on-screen drawing and final export, so both look identical.
    private func drawAnnotationLayers(in context: CGContext, includeActive: Bool) {
        let active = includeActive ? activeAnnotation : nil

        // 1. Pixel effects (blur / pixelate)
        for annotation in annotations where annotation.toolType.isImageEffect {
            drawEffect(annotation: annotation, in: context)
        }
        if let active = active, active.toolType.isImageEffect {
            drawEffect(annotation: active, in: context)
        }

        // 2. Spotlight dims everything outside its areas
        var spots = annotations.filter { $0.toolType == .spotlight }
        if let active = active, active.toolType == .spotlight { spots.append(active) }
        drawSpotlights(spots, in: context)

        // 3. Vector annotations
        for annotation in annotations where annotation.toolType != .crop {
            annotation.draw(in: context, viewBounds: bounds)
        }
        if let active = active, active.toolType != .crop {
            active.draw(in: context, viewBounds: bounds)
        }

        // 4. Crop overlay last (screen only)
        guard includeActive else { return }
        if let crop = cropAnnotation {
            crop.draw(in: context, viewBounds: bounds)
        } else if let active = activeAnnotation, active.toolType == .crop {
            active.draw(in: context, viewBounds: bounds)
        }
    }

    private func drawSpotlights(_ spots: [Annotation], in context: CGContext) {
        let valid = spots.filter { $0.rect.width > 1 && $0.rect.height > 1 }
        guard !valid.isEmpty else { return }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        context.fill(bounds)
        context.setBlendMode(.clear)
        for spot in valid {
            let r = min(10, spot.rect.width / 2, spot.rect.height / 2)
            context.addPath(CGPath(roundedRect: spot.rect, cornerWidth: r, cornerHeight: r, transform: nil))
            context.fillPath()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func baseImageAsCI() -> CIImage? {
        if let cached = baseCIImage { return cached }
        guard let image = baseImage else { return nil }
        var proposed = NSRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            baseCIImage = CIImage(cgImage: cg)
        } else if let tiff = image.tiffRepresentation {
            baseCIImage = CIImage(data: tiff)
        }
        return baseCIImage
    }

    private func drawEffect(annotation: Annotation, in context: CGContext) {
        guard annotation.rect.width > 1, annotation.rect.height > 1 else { return }

        if let cached = annotation.cachedBlurImage, annotation.cachedBlurRect == annotation.rect {
            context.draw(cached, in: annotation.rect)
            return
        }

        guard let ciImage = baseImageAsCI() else { return }

        let scaleX = ciImage.extent.width / bounds.width
        let scaleY = ciImage.extent.height / bounds.height
        let ciRect = CGRect(
            x: annotation.rect.origin.x * scaleX,
            y: annotation.rect.origin.y * scaleY,
            width: annotation.rect.width * scaleX,
            height: annotation.rect.height * scaleY
        ).integral.intersection(ciImage.extent)
        guard !ciRect.isNull, ciRect.width > 0, ciRect.height > 0 else { return }

        let output: CIImage
        if annotation.toolType == .pixelate {
            guard let filter = CIFilter(name: "CIPixellate") else { return }
            filter.setValue(ciImage.clampedToExtent(), forKey: kCIInputImageKey)
            filter.setValue(max(8, max(ciRect.width, ciRect.height) / 14), forKey: kCIInputScaleKey)
            filter.setValue(CIVector(x: ciRect.minX, y: ciRect.minY), forKey: kCIInputCenterKey)
            guard let out = filter.outputImage else { return }
            output = out
        } else {
            let sigma = max(8, min(ciRect.width, ciRect.height) / 6)
            output = ciImage.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma))
        }

        guard let cgImage = Self.sharedCIContext.createCGImage(output.cropped(to: ciRect), from: ciRect) else { return }
        annotation.cachedBlurImage = cgImage
        annotation.cachedBlurRect = annotation.rect
        context.draw(cgImage, in: annotation.rect)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        commitActiveTextField()
        window?.makeFirstResponder(self)

        let point = convert(event.locationInWindow, from: nil)
        dragStart = point

        // Grab a handle of the selected annotation, whatever the tool
        if let selected = annotations.last(where: { $0.isSelected }), let handle = selected.handleIndex(at: point) {
            beginResize(selected, handle: handle)
            return
        }

        if currentTool == .select {
            handleSelectMouseDown(point: point, clickCount: event.clickCount)
            return
        }

        deselectAll()

        if currentTool == .text {
            handleInlineText(at: point)
            return
        }

        if currentTool == .numberedStep {
            pushUndo()
            let annotation = Annotation(toolType: .numberedStep, color: currentColor, lineWidth: currentLineWidth)
            annotation.rect = NSRect(origin: point, size: .zero)
            annotation.stepNumber = (annotations.filter { $0.toolType == .numberedStep }.map { $0.stepNumber }.max() ?? 0) + 1
            annotations.append(annotation)
            needsDisplay = true
            onAnnotationsChanged?()
            return
        }

        if currentTool == .crop {
            cropAnnotation = nil
            let annotation = Annotation(toolType: .crop, color: .white, lineWidth: 1)
            annotation.rect = NSRect(origin: point, size: .zero)
            activeAnnotation = annotation
            needsDisplay = true
            return
        }

        pushUndo()
        let annotation = Annotation(toolType: currentTool, color: currentColor, lineWidth: currentLineWidth)
        annotation.isFilled = currentFilled

        switch currentTool {
        case .arrow, .line:
            annotation.points = [point, point]
        case .freehand:
            annotation.points = [point]
        default:
            annotation.rect = NSRect(origin: point, size: .zero)
        }

        activeAnnotation = annotation
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)

        if let resizing = resizingAnnotation {
            applyResize(resizing, to: point, shift: shift)
            needsDisplay = true
            return
        }

        if currentTool == .select, let moving = movingAnnotation {
            let dx = point.x - moveOffset.x
            let dy = point.y - moveOffset.y
            moveOffset = point
            moveAnnotation(moving, dx: dx, dy: dy)
            needsDisplay = true
            return
        }

        guard let annotation = activeAnnotation, let start = dragStart else { return }

        switch annotation.toolType {
        case .arrow, .line:
            if annotation.points.count >= 2 {
                annotation.points[1] = shift ? constrainToAngles(from: annotation.points[0], to: point) : point
            }
        case .freehand:
            annotation.points.append(point)
        default:
            annotation.rect = rectFrom(start, to: point, square: shift)
            annotation.cachedBlurImage = nil
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if resizingAnnotation != nil {
            resizingAnnotation = nil
            onAnnotationsChanged?()
            return
        }

        if currentTool == .select, movingAnnotation != nil {
            movingAnnotation = nil
            onAnnotationsChanged?()
            return
        }

        guard let annotation = activeAnnotation else { return }
        activeAnnotation = nil

        if annotation.toolType == .crop {
            if annotation.rect.width > 5, annotation.rect.height > 5 {
                cropAnnotation = annotation
                onCropApplied?(annotation.rect)
            }
            needsDisplay = true
            return
        }

        // Ignore accidental clicks that would create invisible shapes
        let tooSmall: Bool
        switch annotation.toolType {
        case .arrow, .line:
            tooSmall = annotation.points.count < 2 || hypot(annotation.points[1].x - annotation.points[0].x,
                                                             annotation.points[1].y - annotation.points[0].y) < 3
        case .freehand:
            tooSmall = annotation.points.count < 2
        default:
            tooSmall = annotation.rect.width < 3 || annotation.rect.height < 3
        }
        if tooSmall {
            if !undoStack.isEmpty { undoStack.removeLast() }
            needsDisplay = true
            return
        }

        annotations.append(annotation)
        redoStack.removeAll()
        needsDisplay = true
        onAnnotationsChanged?()
    }

    private func rectFrom(_ start: NSPoint, to point: NSPoint, square: Bool) -> NSRect {
        var w = abs(point.x - start.x)
        var h = abs(point.y - start.y)
        if square {
            let side = max(w, h)
            w = side
            h = side
        }
        let x = point.x >= start.x ? start.x : start.x - w
        let y = point.y >= start.y ? start.y : start.y - h
        return NSRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Select, Move, Resize

    private func handleSelectMouseDown(point: NSPoint, clickCount: Int) {
        let hit = annotations.reversed().first(where: { $0.hitTest(point: point) })

        for a in annotations { a.isSelected = false }

        if let hit = hit {
            hit.isSelected = true
            // Double-click on a text annotation: edit it
            if clickCount >= 2, hit.toolType == .text {
                editText(hit)
                return
            }
            pushUndo()
            movingAnnotation = hit
            moveOffset = point
        } else {
            movingAnnotation = nil
        }
        needsDisplay = true
    }

    private func beginResize(_ annotation: Annotation, handle: Int) {
        pushUndo()
        resizingAnnotation = annotation
        resizeHandle = handle
        if annotation.toolType.isRectBased {
            // Anchor = opposite corner (handles: 0 BL, 1 BR, 2 TL, 3 TR)
            let r = annotation.rect
            switch handle {
            case 0: resizeAnchor = NSPoint(x: r.maxX, y: r.maxY)
            case 1: resizeAnchor = NSPoint(x: r.minX, y: r.maxY)
            case 2: resizeAnchor = NSPoint(x: r.maxX, y: r.minY)
            default: resizeAnchor = NSPoint(x: r.minX, y: r.minY)
            }
        }
    }

    private func applyResize(_ annotation: Annotation, to point: NSPoint, shift: Bool) {
        switch annotation.toolType {
        case .arrow, .line:
            guard annotation.points.count >= 2, resizeHandle < 2 else { return }
            let other = annotation.points[resizeHandle == 0 ? 1 : 0]
            annotation.points[resizeHandle] = shift ? constrainToAngles(from: other, to: point) : point
        default:
            annotation.rect = rectFrom(resizeAnchor, to: point, square: shift)
            annotation.cachedBlurImage = nil
        }
    }

    private func moveAnnotation(_ annotation: Annotation, dx: CGFloat, dy: CGFloat) {
        switch annotation.toolType {
        case .arrow, .line, .freehand:
            for i in 0..<annotation.points.count {
                annotation.points[i].x += dx
                annotation.points[i].y += dy
            }
        default:
            annotation.rect.origin.x += dx
            annotation.rect.origin.y += dy
        }
        if annotation.toolType.isImageEffect {
            annotation.cachedBlurImage = nil
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if flags.contains(.command) {
            switch chars {
            case "z":
                if flags.contains(.shift) { performRedo() } else { performUndo() }
                return
            case "c":
                copyToClipboard()
                return
            case "a":
                for a in annotations { a.isSelected = true }
                needsDisplay = true
                return
            case "d":
                duplicateSelection()
                return
            default:
                super.keyDown(with: event)
                return
            }
        }

        switch event.keyCode {
        case 53: // Escape
            if cropAnnotation != nil {
                cropAnnotation = nil
                needsDisplay = true
            } else {
                deselectAll()
            }
            return
        case 36, 76: // Return / Enter
            if cropAnnotation != nil { onConfirmCrop?() }
            return
        case 51, 117: // Backspace / Delete
            let selected = annotations.filter { $0.isSelected }
            if !selected.isEmpty {
                pushUndo()
                let ids = Set(selected.map { $0.id })
                annotations.removeAll { ids.contains($0.id) }
                needsDisplay = true
                onAnnotationsChanged?()
            }
            return
        case 123, 124, 125, 126: // Arrow keys nudge the selection
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let selected = annotations.filter { $0.isSelected }
            guard !selected.isEmpty else { return }
            let dx: CGFloat = event.keyCode == 123 ? -step : (event.keyCode == 124 ? step : 0)
            let dy: CGFloat = event.keyCode == 125 ? -step : (event.keyCode == 126 ? step : 0)
            selected.forEach { moveAnnotation($0, dx: dx, dy: dy) }
            needsDisplay = true
            return
        default:
            break
        }

        // Single-key tool shortcuts
        if flags.subtracting([.shift, .capsLock]).isEmpty, let ch = chars.first,
           let tool = AnnotationToolType.allCases.first(where: { $0.shortcut == ch }) {
            currentTool = tool
            onToolShortcut?(tool)
            return
        }

        super.keyDown(with: event)
    }

    private func duplicateSelection() {
        let selected = annotations.filter { $0.isSelected }
        guard !selected.isEmpty else { return }
        pushUndo()
        for a in selected {
            a.isSelected = false
            let copy = copyAnnotation(a)
            moveAnnotation(copy, dx: 12, dy: -12)
            if copy.toolType == .numberedStep {
                copy.stepNumber = (annotations.filter { $0.toolType == .numberedStep }.map { $0.stepNumber }.max() ?? 0) + 1
            }
            copy.isSelected = true
            annotations.append(copy)
        }
        needsDisplay = true
        onAnnotationsChanged?()
    }

    private func copyToClipboard() {
        guard let image = renderFinalImage() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        Toast.show(message: "Copié dans le presse-papiers")
    }

    // MARK: - Inline Text

    private var editingTextAnnotation: Annotation?

    private func handleInlineText(at point: NSPoint, initialText: String = "", color: NSColor? = nil, fontSize: CGFloat? = nil) {
        let size = fontSize ?? Annotation.fontSize(forLineWidth: currentLineWidth)
        let font = Annotation.textFont(size: size)
        let height = ceil(font.ascender - font.descender + font.leading) + 6

        let textField = NSTextField(frame: NSRect(x: point.x, y: point.y - height / 2, width: max(220, bounds.width - point.x - 8), height: height))
        textField.isBordered = false
        textField.drawsBackground = false
        textField.font = font
        textField.textColor = color ?? currentColor
        textField.focusRingType = .none
        textField.placeholderString = "Tape ton texte…"
        textField.stringValue = initialText
        textField.target = self
        textField.action = #selector(textFieldCommitted(_:))
        textField.delegate = self

        addSubview(textField)
        window?.makeFirstResponder(textField)
        activeTextField = textField
    }

    private func editText(_ annotation: Annotation) {
        pushUndo()
        annotations.removeAll { $0.id == annotation.id }
        editingTextAnnotation = annotation
        needsDisplay = true
        let origin = annotation.isFilled
            ? NSPoint(x: annotation.rect.minX + Annotation.textPadding, y: annotation.rect.minY + Annotation.textPadding / 2)
            : annotation.rect.origin
        let font = Annotation.textFont(size: annotation.fontSize)
        let height = ceil(font.ascender - font.descender + font.leading) + 6
        let textHeight = Annotation.textRect(for: annotation.text, origin: .zero, fontSize: annotation.fontSize, filled: false).height
        // Inverse of the placement done in commitActiveTextField, so editing never shifts the text
        handleInlineText(at: NSPoint(x: origin.x, y: origin.y + height / 2 - (height - textHeight) / 2),
                         initialText: annotation.text,
                         color: annotation.isFilled ? .labelColor : annotation.color,
                         fontSize: annotation.fontSize)
    }

    @objc private func textFieldCommitted(_ sender: NSTextField) {
        commitActiveTextField()
    }

    private func commitActiveTextField() {
        guard let tf = activeTextField else { return }
        let text = tf.stringValue
        let fieldOrigin = tf.frame.origin
        let fieldHeight = tf.frame.height
        let template = editingTextAnnotation

        // Clear state first: removing the field ends editing and re-enters this method
        activeTextField = nil
        editingTextAnnotation = nil
        tf.removeFromSuperview()

        guard !text.isEmpty else {
            needsDisplay = true
            onAnnotationsChanged?()
            return
        }
        if template == nil { pushUndo() }

        let annotation = Annotation(
            toolType: .text,
            color: template?.color ?? currentColor,
            lineWidth: template?.lineWidth ?? currentLineWidth
        )
        annotation.text = text
        annotation.isFilled = template?.isFilled ?? currentFilled
        annotation.fontSize = template?.fontSize ?? Annotation.fontSize(forLineWidth: currentLineWidth)

        let textHeight = Annotation.textRect(for: text, origin: .zero, fontSize: annotation.fontSize, filled: false).height
        var origin = NSPoint(x: fieldOrigin.x, y: fieldOrigin.y + (fieldHeight - textHeight) / 2)
        if annotation.isFilled {
            origin.x -= Annotation.textPadding
            origin.y -= Annotation.textPadding / 2
        }
        annotation.rect = Annotation.textRect(for: text, origin: origin, fontSize: annotation.fontSize, filled: annotation.isFilled)

        annotations.append(annotation)
        redoStack.removeAll()
        needsDisplay = true
        onAnnotationsChanged?()
    }

    // MARK: - Crop

    func applyCrop() {
        guard let crop = cropAnnotation, let image = baseImage else { return }

        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return }

        // Work in pixels: the base image may be larger than its point size (Retina)
        let scaleX = CGFloat(cgImage.width) / bounds.width
        let scaleY = CGFloat(cgImage.height) / bounds.height
        let pixelRect = CGRect(
            x: crop.rect.origin.x * scaleX,
            y: CGFloat(cgImage.height) - (crop.rect.origin.y + crop.rect.height) * scaleY,
            width: crop.rect.width * scaleX,
            height: crop.rect.height * scaleY
        ).integral

        guard let croppedCG = cgImage.cropping(to: pixelRect) else { return }

        let pointScale = image.size.width / CGFloat(cgImage.width)
        let croppedImage = NSImage(cgImage: croppedCG, size: NSSize(width: CGFloat(croppedCG.width) * pointScale,
                                                                     height: CGFloat(croppedCG.height) * pointScale))

        pushUndo()
        annotations.removeAll()
        cropAnnotation = nil
        baseImage = croppedImage

        let newSize = AnnotationCanvas.fittedCanvasSize(for: croppedImage.size)
        frame = NSRect(origin: frame.origin, size: newSize)

        needsDisplay = true
        onAnnotationsChanged?()
        onCanvasSizeChanged?()
    }

    func cancelCrop() {
        cropAnnotation = nil
        needsDisplay = true
    }

    var hasPendingCrop: Bool { cropAnnotation != nil }

    /// Canvas size used on screen. Tall captures (scrolling shots) are fitted to the width
    /// and scrolled, instead of being shrunk until unreadable.
    static func fittedCanvasSize(for imageSize: NSSize) -> NSSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return NSSize(width: 400, height: 300) }
        let maxWidth: CGFloat = 1200
        let maxHeight: CGFloat = 800
        let maxScrollableHeight: CGFloat = 7000
        let isTall = imageSize.height / imageSize.width > 1.8
        let scale: CGFloat
        if isTall {
            scale = min(maxWidth / imageSize.width, maxScrollableHeight / imageSize.height, 1.0)
        } else {
            scale = min(maxWidth / imageSize.width, maxHeight / imageSize.height, 1.0)
        }
        return NSSize(width: (imageSize.width * scale).rounded(), height: (imageSize.height * scale).rounded())
    }

    // MARK: - Undo/Redo

    func pushUndo() {
        undoStack.append(UndoState(image: baseImage, annotations: annotations.map { copyAnnotation($0) }, canvasSize: frame.size))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func performUndo() {
        commitActiveTextField()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(UndoState(image: baseImage, annotations: annotations.map { copyAnnotation($0) }, canvasSize: frame.size))
        restore(previous)
    }

    func performRedo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(UndoState(image: baseImage, annotations: annotations.map { copyAnnotation($0) }, canvasSize: frame.size))
        restore(next)
    }

    private func restore(_ state: UndoState) {
        if state.image !== baseImage {
            baseImage = state.image
        }
        annotations = state.annotations
        cropAnnotation = nil
        movingAnnotation = nil
        resizingAnnotation = nil

        if state.canvasSize != frame.size {
            frame = NSRect(origin: frame.origin, size: state.canvasSize)
            onCanvasSizeChanged?()
        }

        needsDisplay = true
        onAnnotationsChanged?()
    }

    private func copyAnnotation(_ a: Annotation) -> Annotation {
        let copy = Annotation(toolType: a.toolType, color: a.color, lineWidth: a.lineWidth)
        copy.points = a.points
        copy.rect = a.rect
        copy.text = a.text
        copy.fontSize = a.fontSize
        copy.stepNumber = a.stepNumber
        copy.isFilled = a.isFilled
        copy.cachedBlurImage = a.cachedBlurImage
        copy.cachedBlurRect = a.cachedBlurRect
        return copy
    }

    // MARK: - Helpers

    private func constrainToAngles(from start: NSPoint, to end: NSPoint) -> NSPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let angle = atan2(dy, dx)
        let distance = hypot(dx, dy)
        let snapped = round(angle / (.pi / 4)) * (.pi / 4)
        return NSPoint(x: start.x + distance * cos(snapped), y: start.y + distance * sin(snapped))
    }

    // MARK: - Export

    func renderFinalImage() -> NSImage? {
        commitActiveTextField()
        guard let image = baseImage else { return nil }
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cgBase = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }

        // Render at full pixel resolution (keeps Retina sharpness)
        let pixelW = cgBase.width
        let pixelH = cgBase.height
        guard let ctx = CGContext(
            data: nil, width: pixelW, height: pixelH, bitsPerComponent: 8, bytesPerRow: 0,
            space: cgBase.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) ?? CGContext(
            data: nil, width: pixelW, height: pixelH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.draw(cgBase, in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        // Hide selection chrome during export
        let selected = annotations.filter { $0.isSelected }
        selected.forEach { $0.isSelected = false }

        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.scaleBy(x: CGFloat(pixelW) / bounds.width, y: CGFloat(pixelH) / bounds.height)
        drawAnnotationLayers(in: ctx, includeActive: false)
        NSGraphicsContext.current = previousContext

        selected.forEach { $0.isSelected = true }

        guard let output = ctx.makeImage() else { return nil }
        return NSImage(cgImage: output, size: image.size)
    }
}

// MARK: - NSTextFieldDelegate

extension AnnotationCanvas: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        commitActiveTextField()
    }
}
