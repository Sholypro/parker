import Cocoa
import AVFoundation

/// CleanShot-style "Quick Access Overlay": a stack of floating previews in a screen corner
/// (bottom-left by default). Newest capture at the bottom, older ones pushed up.
/// Hover: Copy / Annotate + corner actions. Click: annotate. Drag: drop the file anywhere.
/// Right-click: full menu. Horizontal trackpad swipe: dismiss.
final class FloatingThumbnailController {
    private final class Entry {
        let window: NSPanel
        let view: ThumbnailView
        let url: URL
        let height: CGFloat
        var timer: Timer?

        init(window: NSPanel, view: ThumbnailView, url: URL, height: CGFloat) {
            self.window = window
            self.view = view
            self.url = url
            self.height = height
        }
    }

    private var entries: [Entry] = []   // oldest first, newest last
    private(set) var currentURL: URL?
    var onEdit: ((URL) -> Void)?
    var onPin: ((URL) -> Void)?

    private let cardWidth: CGFloat = 232
    private let minCardHeight: CGFloat = 110
    private let maxCardHeight: CGFloat = 250
    private let padding: CGFloat = 18
    private let stackSpacing: CGFloat = 10
    private let maxEntries = 6

    private var isLeft: Bool { Defaults.shared.thumbnailPosition != "bottomRight" }

    // MARK: - Show

    func show(for url: URL) {
        guard Defaults.shared.showThumbnail else { return }
        let isVideo = ["mp4", "mov", "m4v", "gif"].contains(url.pathExtension.lowercased())

        guard let source = Self.loadImage(url: url, isVideo: isVideo) else { return }
        let aspect = CGFloat(source.height) / CGFloat(max(source.width, 1))
        let cardHeight = min(max(cardWidth * aspect, minCardHeight), maxCardHeight)
        let thumb = Self.makeThumbnail(from: source, cardSize: NSSize(width: cardWidth, height: cardHeight))

        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        let finalX = isLeft ? visible.minX + padding : visible.maxX - cardWidth - padding
        let startX = isLeft ? visible.minX - cardWidth - 20 : visible.maxX + 20
        let y = visible.minY + padding

        let panel = ThumbnailPanel(
            contentRect: NSRect(x: startX, y: y, width: cardWidth, height: cardHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let view = ThumbnailView(
            frame: NSRect(origin: .zero, size: NSSize(width: cardWidth, height: cardHeight)),
            image: thumb,
            fileURL: url,
            isVideo: isVideo
        )
        let entry = Entry(window: panel, view: view, url: url, height: cardHeight)
        wire(entry)

        panel.contentView = view
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        entries.append(entry)
        currentURL = url
        scheduleAutoDismiss(entry)

        // Slide in, and push the older ones up
        layout(on: screen, animated: true, newest: entry, newestStartX: startX, finalX: finalX)

        // Keep the stack inside the screen and capped
        while entries.count > maxEntries { dismiss(entries[0], animated: true) }
    }

    func dismiss() {
        for entry in entries {
            entry.timer?.invalidate()
            entry.window.orderOut(nil)
        }
        entries.removeAll()
        currentURL = nil
    }

    // MARK: - Wiring

    private func wire(_ entry: Entry) {
        let url = entry.url
        let view = entry.view

        view.onEdit = { [weak self, weak entry] in
            guard let self = self, let entry = entry else { return }
            self.dismiss(entry, animated: false)
            self.onEdit?(url)
        }
        view.onOpen = {
            NSWorkspace.shared.open(url)
        }
        view.onPin = { [weak self, weak entry] in
            guard let self = self, let entry = entry else { return }
            self.dismiss(entry, animated: true)
            self.onPin?(url)
        }
        view.onCopy = { [weak self, weak entry] in
            FloatingThumbnailController.copy(url: url)
            if let self = self, let entry = entry { self.dismiss(entry, animated: true) }
        }
        view.onSaveAs = {
            FloatingThumbnailController.saveAs(url: url)
        }
        view.onReveal = {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        view.onSaveAsGIF = {
            Toast.show(message: "Conversion en GIF…", style: .info)
            GIFExporter.exportToGIF(videoURL: url) { result in
                switch result {
                case .success(let gifURL):
                    Defaults.shared.addRecentCapture(gifURL)
                    Toast.show(message: "GIF enregistré : \(gifURL.lastPathComponent)")
                case .failure:
                    Toast.show(message: "Échec de l'export GIF", style: .error)
                }
            }
        }
        view.onTrash = { [weak self, weak entry] in
            guard let self = self, let entry = entry else { return }
            NSWorkspace.shared.recycle([url]) { _, error in
                DispatchQueue.main.async {
                    if error == nil {
                        Toast.show(message: "Capture placée dans la corbeille", style: .info)
                    } else {
                        Toast.show(message: "Impossible de supprimer le fichier", style: .error)
                    }
                }
            }
            self.dismiss(entry, animated: true)
        }
        view.onClose = { [weak self, weak entry] in
            guard let self = self, let entry = entry else { return }
            self.dismiss(entry, animated: true)
        }
        view.onCloseAll = { [weak self] in
            guard let self = self else { return }
            for entry in self.entries { self.dismiss(entry, animated: true) }
        }
        view.onDraggedOut = { [weak self, weak entry] in
            guard let self = self, let entry = entry else { return }
            self.dismiss(entry, animated: false)
        }
        view.onHoverChanged = { [weak self, weak entry] hovering in
            guard let self = self, let entry = entry else { return }
            if hovering {
                entry.timer?.invalidate()
                entry.timer = nil
            } else {
                self.scheduleAutoDismiss(entry)
            }
        }
    }

    private func scheduleAutoDismiss(_ entry: Entry) {
        entry.timer?.invalidate()
        entry.timer = nil
        let duration = Defaults.shared.thumbnailDuration
        guard duration > 0, duration < 3600 else { return }  // very long = keep until closed
        entry.timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self, weak entry] _ in
            guard let self = self, let entry = entry else { return }
            self.dismiss(entry, animated: true)
        }
    }

    // MARK: - Layout

    private func referenceScreen() -> NSScreen? {
        if let last = entries.last {
            let center = NSPoint(x: last.window.frame.midX, y: last.window.frame.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return screen }
            // The newest one may still be off-screen (sliding in): use its vertical position
            let probe = NSPoint(x: NSEvent.mouseLocation.x, y: center.y)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) { return screen }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }

    private func layout(on screen: NSScreen?, animated: Bool,
                        newest: Entry? = nil, newestStartX: CGFloat = 0, finalX: CGFloat? = nil) {
        guard let screen = screen ?? referenceScreen() else { return }
        let visible = screen.visibleFrame
        let x = finalX ?? (isLeft ? visible.minX + padding : visible.maxX - cardWidth - padding)

        // Newest at the bottom, stacking upwards
        var y = visible.minY + padding
        var targets: [(Entry, NSRect)] = []
        var overflow: [Entry] = []
        for entry in entries.reversed() {
            let frame = NSRect(x: x, y: y, width: cardWidth, height: entry.height)
            if frame.maxY > visible.maxY - padding && !targets.isEmpty {
                overflow.append(entry)
                continue
            }
            targets.append((entry, frame))
            y += entry.height + stackSpacing
        }

        if let newest = newest, let target = targets.first(where: { $0.0 === newest })?.1 {
            newest.window.setFrame(NSRect(x: newestStartX, y: target.minY, width: cardWidth, height: newest.height), display: false)
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
                for (entry, frame) in targets {
                    entry.window.animator().setFrame(frame, display: true)
                    entry.window.animator().alphaValue = 1
                }
            }
        } else {
            for (entry, frame) in targets {
                entry.window.setFrame(frame, display: true)
                entry.window.alphaValue = 1
            }
        }

        for entry in overflow { dismiss(entry, animated: true) }
    }

    private func dismiss(_ entry: Entry, animated: Bool) {
        guard let index = entries.firstIndex(where: { $0 === entry }) else { return }
        entry.timer?.invalidate()
        entry.timer = nil
        entries.remove(at: index)
        currentURL = entries.last?.url

        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: entry.window.frame.midX, y: entry.window.frame.midY)) })
            ?? referenceScreen()

        guard animated, let visible = screen?.visibleFrame else {
            entry.window.orderOut(nil)
            layout(on: screen, animated: true)
            return
        }

        let offX = isLeft ? visible.minX - cardWidth - 20 : visible.maxX + 20
        var frame = entry.window.frame
        frame.origin.x = offX
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            entry.window.animator().setFrame(frame, display: true)
            entry.window.animator().alphaValue = 0
        }, completionHandler: {
            entry.window.orderOut(nil)
        })
        layout(on: screen, animated: true)
    }

    // MARK: - Actions

    private static func copy(url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let image = NSImage(contentsOf: url), !["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
            pasteboard.writeObjects([image, url as NSURL])
        } else {
            pasteboard.writeObjects([url as NSURL])
        }
        Toast.show(message: "Copié dans le presse-papiers")
    }

    private static func saveAs(url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            Toast.show(message: "Enregistré : \(destination.lastPathComponent)")
        } catch {
            Toast.show(message: "Échec de l'enregistrement", style: .error)
        }
    }

    // MARK: - Image helpers

    private static func loadImage(url: URL, isVideo: Bool) -> CGImage? {
        if isVideo && url.pathExtension.lowercased() != "gif" {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 800, height: 800)
            if let cg = try? generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil) {
                return cg
            }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Aspect-fill crop: tall captures (scrolling shots) show their top part.
    private static func makeThumbnail(from image: CGImage, cardSize: NSSize) -> CGImage {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let target = cardSize.height / cardSize.width
        var crop = CGRect(x: 0, y: 0, width: w, height: h)
        if h / w > target {
            crop.size.height = (w * target).rounded()            // keep the top
        } else if h / w < target {
            crop.size.width = (h / target).rounded()
            crop.origin.x = ((w - crop.width) / 2).rounded()   // keep the center
        }
        let cropped = image.cropping(to: crop) ?? image

        let outW = Int(cardSize.width * 2)
        let outH = Int(cardSize.height * 2)
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return cropped }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage() ?? cropped
    }
}

// MARK: - Panel

private final class ThumbnailPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class OverlayButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Container that lets clicks fall through to the card except on its buttons.
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

// MARK: - Thumbnail card

class ThumbnailView: NSView, NSDraggingSource {
    var onEdit: (() -> Void)?
    var onOpen: (() -> Void)?
    var onPin: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onReveal: (() -> Void)?
    var onTrash: (() -> Void)?
    var onSaveAsGIF: (() -> Void)?
    var onClose: (() -> Void)?
    var onCloseAll: (() -> Void)?
    var onDraggedOut: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private let fileURL: URL
    private let isVideo: Bool
    private let image: CGImage
    private let imageLayer = CALayer()
    private let overlay = PassThroughView()
    private var mouseDownPoint: NSPoint?
    private var swipeAccumulator: CGFloat = 0

    init(frame: NSRect, image: CGImage, fileURL: URL, isVideo: Bool) {
        self.image = image
        self.fileURL = fileURL
        self.isVideo = isVideo
        super.init(frame: frame)

        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        imageLayer.frame = bounds
        imageLayer.contents = image
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)

        setupOverlay()
        setupTracking()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Overlay

    private func setupOverlay() {
        overlay.frame = bounds
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
        overlay.alphaValue = 0
        addSubview(overlay)

        // Center: two pill buttons
        let pillW: CGFloat = 112
        let pillH: CGFloat = 28
        let gap: CGFloat = 8
        let centerY = bounds.midY
        let firstTitle = "Copier"
        let secondTitle = isVideo ? "Ouvrir" : "Annoter"

        let compact = bounds.height < 130
        if compact {
            // Side by side when the card is short
            let w: CGFloat = 92
            let left = makePill(title: firstTitle, action: #selector(copyClicked))
            left.frame = NSRect(x: bounds.midX - w - gap / 2, y: centerY - pillH / 2, width: w, height: pillH)
            let right = makePill(title: secondTitle, action: isVideo ? #selector(openClicked) : #selector(editClicked))
            right.frame = NSRect(x: bounds.midX + gap / 2, y: centerY - pillH / 2, width: w, height: pillH)
            overlay.addSubview(left)
            overlay.addSubview(right)
        } else {
            let top = makePill(title: firstTitle, action: #selector(copyClicked))
            top.frame = NSRect(x: bounds.midX - pillW / 2, y: centerY + gap / 2, width: pillW, height: pillH)
            let bottom = makePill(title: secondTitle, action: isVideo ? #selector(openClicked) : #selector(editClicked))
            bottom.frame = NSRect(x: bounds.midX - pillW / 2, y: centerY - gap / 2 - pillH, width: pillW, height: pillH)
            overlay.addSubview(top)
            overlay.addSubview(bottom)
        }

        // Corners
        let s: CGFloat = 24
        let m: CGFloat = 7
        addCorner(symbol: "xmark", tip: "Fermer", action: #selector(closeClicked),
                  frame: NSRect(x: m, y: bounds.height - s - m, width: s, height: s))
        if isVideo {
            if fileURL.pathExtension.lowercased() != "gif" {
                addCorner(symbol: "photo.stack", tip: "Exporter en GIF", action: #selector(gifClicked),
                          frame: NSRect(x: bounds.width - s - m, y: bounds.height - s - m, width: s, height: s))
            }
        } else {
            addCorner(symbol: "pin.fill", tip: "Épingler à l'écran", action: #selector(pinClicked),
                      frame: NSRect(x: bounds.width - s - m, y: bounds.height - s - m, width: s, height: s))
        }
        addCorner(symbol: "folder", tip: "Afficher dans le Finder", action: #selector(revealClicked),
                  frame: NSRect(x: m, y: m, width: s, height: s))
        addCorner(symbol: "trash", tip: "Supprimer", action: #selector(trashClicked),
                  frame: NSRect(x: bounds.width - s - m, y: m, width: s, height: s))
    }

    private func makePill(title: String, action: Selector) -> NSButton {
        let button = OverlayButton(title: title, target: self, action: action)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 14
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.black,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ])
        return button
    }

    private func addCorner(symbol: String, tip: String, action: Selector, frame: NSRect) {
        let button = OverlayButton(frame: frame)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = frame.width / 2
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config)
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.toolTip = tip
        button.target = self
        button.action = action
        overlay.addSubview(button)
    }

    private func setupTracking() {
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            overlay.animator().alphaValue = 1
        }
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            overlay.animator().alphaValue = 0
        }
        onHoverChanged?(false)
    }

    // MARK: Click / drag

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        mouseDownPoint = nil

        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        let preview = NSImage(cgImage: image, size: bounds.size)
        item.setDraggingFrame(bounds, contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownPoint != nil else { return }
        mouseDownPoint = nil
        if event.clickCount >= 1 {
            if isVideo { onOpen?() } else { onEdit?() }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        if !isVideo {
            menu.addItem(withTitle: "Annoter", action: #selector(editClicked), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Ouvrir", action: #selector(openClicked), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Copier", action: #selector(copyClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Enregistrer sous…", action: #selector(saveAsClicked), keyEquivalent: "").target = self
        if !isVideo {
            menu.addItem(withTitle: "Épingler à l'écran", action: #selector(pinClicked), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Afficher dans le Finder", action: #selector(revealClicked), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Supprimer", action: #selector(trashClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Fermer", action: #selector(closeClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Tout fermer", action: #selector(closeAllClicked), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Two-finger horizontal swipe dismisses the card (like CleanShot / notifications).
    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began { swipeAccumulator = 0 }
        guard event.hasPreciseScrollingDeltas else { return }
        swipeAccumulator += event.scrollingDeltaX
        if abs(swipeAccumulator) > 70 && abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) {
            swipeAccumulator = 0
            onClose?()
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { onDraggedOut?() }
    }

    // MARK: Actions

    @objc private func editClicked() { onEdit?() }
    @objc private func openClicked() { onOpen?() }
    @objc private func copyClicked() { onCopy?() }
    @objc private func pinClicked() { onPin?() }
    @objc private func saveAsClicked() { onSaveAs?() }
    @objc private func revealClicked() { onReveal?() }
    @objc private func trashClicked() { onTrash?() }
    @objc private func gifClicked() { onSaveAsGIF?() }
    @objc private func closeClicked() { onClose?() }
    @objc private func closeAllClicked() { onCloseAll?() }
}
