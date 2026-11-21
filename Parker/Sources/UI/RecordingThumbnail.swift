import Cocoa
import AVFoundation

/// Card shown at the end of a screen recording: a muted looping preview, the duration,
/// "Copier" (the finished video) and "Modifier" (opens the editing window).
/// The finished video is written in the background as soon as the card appears.
final class RecordingThumbnailController: NSObject {
    private static var live: [RecordingThumbnailController] = []

    /// Called each time the finished video is written, with the previous URL when it was renamed.
    private let onRendered: (URL, URL?) -> Void
    private var project: RecordingProject
    private var panel: NSPanel?
    private var card: RecordingCardView?
    private let player = AVPlayer()
    private var loopObserver: NSObjectProtocol?

    private var renderer: RecordingRenderer?
    private var rendered = false
    private var failed = false
    private var pendingCopy = false
    private var progressTimer: Timer?

    private init(project: RecordingProject, onRendered: @escaping (URL, URL?) -> Void) {
        self.project = project
        self.onRendered = onRendered
        super.init()
    }

    static func show(_ project: RecordingProject, onRendered: @escaping (URL, URL?) -> Void) {
        // One recording card at a time: the previous one keeps writing its video if needed
        live.forEach { $0.closePanel() }
        let controller = RecordingThumbnailController(project: project, onRendered: onRendered)
        live.append(controller)
        controller.present()
        controller.startRender()
    }

    // MARK: - Panel

    private func present() {
        let size = RecordingCardView.size
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let left = Defaults.shared.thumbnailPosition.lowercased().contains("left")
        let x = left ? visible.minX + 20 : visible.maxX - size.width - 20
        let target = NSRect(x: x, y: visible.minY + 20, width: size.width, height: size.height)

        let panel = CardPanel(contentRect: target, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let card = RecordingCardView(frame: NSRect(origin: .zero, size: size), player: player)
        card.fileURL = project.outputURL
        card.onCopy = { [weak self] in self?.copyClicked() }
        card.onEdit = { [weak self] in self?.editClicked() }
        card.onClose = { [weak self] in self?.closePanel() }
        card.canDrag = { [weak self] in self?.rendered ?? false }
        panel.contentView = card
        self.card = card
        self.panel = panel

        // Slide in from the side
        panel.setFrame(target.offsetBy(dx: left ? -(size.width + 40) : size.width + 40, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }

        Task { await loadPreview() }
    }

    /// The preview shows the camera bubble too, drawn live like in the editor.
    private func loadPreview() async {
        let asset = AVURLAsset(url: project.screenURL)
        if let duration = try? await asset.load(.duration).seconds {
            await MainActor.run { self.card?.duration = duration }
        }
        guard let built = try? await RecordingComposer.build(project) else { return }
        await MainActor.run {
            let item = AVPlayerItem(asset: built.asset)
            item.videoComposition = built.videoComposition.map {
                RecordingComposer.videoComposition($0, with: self.project.layout)
            }
            self.player.isMuted = true
            self.player.replaceCurrentItem(with: item)
            self.loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                self?.player.seek(to: .zero)
                self?.player.play()
            }
            self.player.play()
        }
    }

    // MARK: - Rendering

    private func startRender() {
        let renderer = RecordingRenderer()
        self.renderer = renderer
        project.save()
        let snapshot = project
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateCopyButton()
        }
        updateCopyButton()
        Task { [self] in
            do {
                try await renderer.render(snapshot)
                await MainActor.run {
                    guard self.renderer === renderer else { return }
                    self.renderer = nil
                    self.rendered = true
                    self.progressTimer?.invalidate()
                    self.onRendered(snapshot.outputURL, nil)
                    if self.pendingCopy { self.pendingCopy = false; self.copyNow() }
                    self.updateCopyButton()
                    self.releaseIfDone()
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    guard self.renderer === renderer else { return }
                    self.renderer = nil
                    self.failed = true
                    self.pendingCopy = false
                    self.progressTimer?.invalidate()
                    self.updateCopyButton()
                    Toast.show(message: "Impossible de préparer la vidéo : ouvre « Modifier » pour réessayer", style: .error)
                    self.releaseIfDone()
                }
            }
        }
    }

    private func updateCopyButton() {
        guard let card else { return }
        if let renderer, pendingCopy {
            card.setCopyTitle("Préparation \(Int((renderer.progress * 100).rounded())) %", symbol: "hourglass")
        } else if pendingCopy {
            card.setCopyTitle("Préparation…", symbol: "hourglass")
        } else {
            card.setCopyTitle("Copier", symbol: "doc.on.doc")
        }
        card.setCopyEnabled(!failed)
    }

    // MARK: - Actions

    private func copyClicked() {
        if rendered {
            copyNow()
        } else if renderer != nil {
            pendingCopy = true
            updateCopyButton()
        }
    }

    private func copyNow() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([project.outputURL as NSURL])
        Toast.show(message: "Vidéo copiée")
    }

    private func editClicked() {
        // The editor writes the video itself from now on
        let wasRendered = rendered
        renderer?.cancel()
        renderer = nil
        progressTimer?.invalidate()
        pendingCopy = false
        let onRendered = self.onRendered
        RecordingEditorController.present(project, rendered: wasRendered, onRendered: onRendered)
        closePanel()
    }

    private func closePanel() {
        guard let panel else { return }
        self.panel = nil
        player.pause()
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            self.player.replaceCurrentItem(with: nil)
            self.card = nil
            self.releaseIfDone()
        })
    }

    /// The controller lives until its card is closed and its video is written.
    private func releaseIfDone() {
        guard panel == nil, renderer == nil else { return }
        Self.live.removeAll { $0 === self }
    }
}

private final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Card view

private final class RecordingCardView: NSView, NSDraggingSource {
    static let size = NSSize(width: 322, height: 234)
    private static let previewRect = NSRect(x: 11, y: 54, width: 300, height: 169)

    var onCopy: (() -> Void)?
    var onEdit: (() -> Void)?
    var onClose: (() -> Void)?
    var canDrag: (() -> Bool)?
    var fileURL: URL?
    var duration: Double = 0 {
        didSet {
            chip.stringValue = RecordingEditorController.format(duration)
            chipBox.isHidden = duration <= 0
            layoutChip()
        }
    }

    private let previewLayer = AVPlayerLayer()
    private let copyButton: MontageButton
    private let editButton: MontageButton
    private let closeButton = NSButton()
    private let chipBox = NSView()
    private let chip = NSTextField(labelWithString: "")
    private var dragStart: NSPoint?

    init(frame: NSRect, player: AVPlayer) {
        copyButton = MontageButton("Copier", symbol: "doc.on.doc", kind: .primary, target: nil, action: nil)
        editButton = MontageButton("Modifier", symbol: "pencil", kind: .secondary, target: nil, action: nil)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = MontageStyle.window.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = MontageStyle.line.withAlphaComponent(0.6).cgColor

        // Preview
        let previewHost = NSView(frame: Self.previewRect)
        previewHost.wantsLayer = true
        previewHost.layer?.cornerRadius = 10
        previewHost.layer?.masksToBounds = true
        previewHost.layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.player = player
        previewLayer.videoGravity = .resizeAspect
        previewLayer.frame = previewHost.bounds
        previewHost.layer?.addSublayer(previewLayer)
        addSubview(previewHost)

        // Duration chip
        chipBox.wantsLayer = true
        chipBox.layer?.cornerRadius = 6
        chipBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        chipBox.isHidden = true
        chip.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        chip.textColor = MontageStyle.ink
        chipBox.addSubview(chip)
        addSubview(chipBox)

        // Close
        closeButton.isBordered = false
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 11
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Fermer")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        closeButton.contentTintColor = MontageStyle.ink
        closeButton.frame = NSRect(x: Self.previewRect.maxX - 28, y: Self.previewRect.maxY - 28, width: 22, height: 22)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Fermer"
        addSubview(closeButton)

        // Buttons
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.toolTip = "Copier la vidéo pour la coller dans Slack, un mail…"
        editButton.target = self
        editButton.action = #selector(editClicked)
        editButton.toolTip = "Couper, déplacer la caméra, exporter"
        let half = (Self.previewRect.width - 8) / 2
        copyButton.frame = NSRect(x: 11, y: 11, width: half, height: 33)
        editButton.frame = NSRect(x: 11 + half + 8, y: 11, width: half, height: 33)
        addSubview(copyButton)
        addSubview(editButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setCopyTitle(_ title: String, symbol: String) { copyButton.set(title: title, symbol: symbol) }
    func setCopyEnabled(_ enabled: Bool) { copyButton.isEnabled = enabled }

    private func layoutChip() {
        chip.sizeToFit()
        let w = chip.frame.width + 12
        chipBox.frame = NSRect(x: Self.previewRect.minX + 8, y: Self.previewRect.minY + 8, width: w, height: 20)
        chip.setFrameOrigin(NSPoint(x: 6, y: (20 - chip.frame.height) / 2))
    }

    @objc private func copyClicked() { onCopy?() }
    @objc private func editClicked() { onEdit?() }
    @objc private func closeClicked() { onClose?() }

    // Click on the preview: edit. Drag it: the video file, once written.
    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let url = fileURL, canDrag?() == true else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        dragStart = nil
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: Self.previewRect.size)
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: Self.previewRect.size).fill()
        image.unlockFocus()
        if let snapshot = bitmapImageRepForCachingDisplay(in: Self.previewRect) {
            cacheDisplay(in: Self.previewRect, to: snapshot)
            let picture = NSImage(size: Self.previewRect.size)
            picture.addRepresentation(snapshot)
            dragging.setDraggingFrame(Self.previewRect, contents: picture)
        } else {
            dragging.setDraggingFrame(Self.previewRect, contents: image)
        }
        let session = beginDraggingSession(with: [dragging], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil, Self.previewRect.contains(convert(event.locationInWindow, from: nil)) {
            onEdit?()
        }
        dragStart = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
