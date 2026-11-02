import Cocoa
import AVFoundation
import AVKit

/// Window shown at the end of a screen recording: watch it, cut the start and the end, move or
/// resize the camera bubble, then copy, share or show the video. Everything stays on the Mac.
final class RecordingEditorController: NSObject, NSWindowDelegate {
    /// Called each time the finished video is written (history, menu).
    var onRendered: ((URL) -> Void)?

    private static var open: [RecordingEditorController] = []

    private var project: RecordingProject
    private var window: NSWindow?
    private let player = AVPlayer()
    private var baseComposition: AVVideoComposition?
    private var renderSize = CGSize(width: 16, height: 9)
    private var duration: Double = 0
    private var timeObserver: Any?

    private var renderer: RecordingRenderer?
    private var isRendering = false
    private var isRendered = false
    private var isDirty = false
    private var afterRender: [() -> Void] = []

    // Views
    private var playerView: AVPlayerView!
    private var overlay: CameraDragView!
    private var trimBar: TrimBarView!
    private var playButton: NSButton!
    private var timeLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var saveButton: NSButton!
    private var copyButton: NSButton!
    private var shareButton: NSButton!
    private var finderButton: NSButton!
    private var cameraCheck: NSButton?
    private var sizeSlider: NSSlider?
    private var layoutWork: DispatchWorkItem?
    private var cutButton: NSButton!
    private var removeButton: NSButton!

    // Cuts in the middle
    private var segments: [Segment] = []
    private var selectedSegment: Int?

    init(project: RecordingProject) {
        self.project = project
        super.init()
    }

    /// Opens the editor (one at a time: a new recording closes the previous editor).
    static func present(_ project: RecordingProject, onRendered: @escaping (URL) -> Void) {
        open.forEach { $0.window?.close() }
        let controller = RecordingEditorController(project: project)
        controller.onRendered = onRendered
        open.append(controller)
        controller.show()
    }

    private func show() {
        let width: CGFloat = 980
        let height: CGFloat = 720
        let window = EditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Montage"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.09, alpha: 1)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.onSpace = { [weak self] in self?.togglePlay() }
        window.onDelete = { [weak self] in self?.removeClicked() }
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // Video
        let videoFrame = NSRect(x: 20, y: 176, width: width - 40, height: height - 176 - 44)
        let backdrop = NSView(frame: videoFrame)
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.cgColor
        backdrop.layer?.cornerRadius = 12
        backdrop.layer?.masksToBounds = true
        content.addSubview(backdrop)

        playerView = AVPlayerView(frame: backdrop.bounds)
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.player = player
        backdrop.addSubview(playerView)

        overlay = CameraDragView(frame: backdrop.bounds)
        overlay.onLayoutChange = { [weak self] layout in self?.setLayout(layout, applyNow: true) }
        overlay.onClick = { [weak self] in self?.togglePlay() }
        backdrop.addSubview(overlay)

        // Play + time, camera options
        playButton = iconButton("play.fill", action: #selector(togglePlayClicked))
        playButton.frame = NSRect(x: 20, y: 126, width: 36, height: 36)
        playButton.toolTip = "Lecture / pause (Espace)"
        content.addSubview(playButton)

        timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = .white.withAlphaComponent(0.7)
        timeLabel.frame = NSRect(x: 62, y: 135, width: 160, height: 18)
        content.addSubview(timeLabel)

        if project.hasCamera {
            let check = NSButton(checkboxWithTitle: "Caméra", target: self, action: #selector(cameraToggled))
            check.state = project.layout.visible ? .on : .off
            check.frame = NSRect(x: width - 330, y: 133, width: 90, height: 22)
            content.addSubview(check)
            cameraCheck = check

            let sizeLabel = NSTextField(labelWithString: "Taille")
            sizeLabel.font = .systemFont(ofSize: 12)
            sizeLabel.textColor = .white.withAlphaComponent(0.6)
            sizeLabel.frame = NSRect(x: width - 232, y: 135, width: 40, height: 18)
            content.addSubview(sizeLabel)

            let slider = NSSlider(value: project.layout.size, minValue: CameraLayout.minSize,
                                  maxValue: CameraLayout.maxSize, target: self, action: #selector(sizeChanged))
            slider.isContinuous = true
            slider.frame = NSRect(x: width - 188, y: 133, width: 168, height: 22)
            content.addSubview(slider)
            sizeSlider = slider

            overlay.toolTip = "Glisse la bulle pour la déplacer"
        }

        // Cut in the middle: split at the playhead, then remove the selected piece
        cutButton = textButton("Couper ici", action: #selector(splitClicked))
        cutButton.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)
        cutButton.imagePosition = .imageLeading
        cutButton.frame = NSRect(x: 226, y: 128, width: 130, height: 32)
        cutButton.keyEquivalent = "b"
        cutButton.keyEquivalentModifierMask = .command
        cutButton.toolTip = "Couper la vidéo à la tête de lecture (⌘B)"
        content.addSubview(cutButton)

        removeButton = textButton("Supprimer le passage", action: #selector(removeClicked))
        removeButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        removeButton.imagePosition = .imageLeading
        removeButton.frame = NSRect(x: 362, y: 128, width: 200, height: 32)
        removeButton.toolTip = "Retirer le passage sélectionné de la vidéo (touche Suppr)"
        content.addSubview(removeButton)

        // Trim bar
        trimBar = TrimBarView(frame: NSRect(x: 20, y: 66, width: width - 40, height: 52))
        trimBar.onSeek = { [weak self] t in self?.seek(to: t) }
        trimBar.onTrimChange = { [weak self] start, end, edge in self?.trimChanged(start: start, end: end, edge: edge) }
        trimBar.onSelect = { [weak self] index in self?.selectSegment(index) }
        trimBar.onSplitMove = { [weak self] index, time in self?.moveSplit(index, to: time) }
        content.addSubview(trimBar)

        // Bottom row: status, actions
        statusLabel = NSTextField(labelWithString: "Préparation…")
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .white.withAlphaComponent(0.55)
        statusLabel.frame = NSRect(x: 20, y: 24, width: 360, height: 18)
        content.addSubview(statusLabel)

        finderButton = textButton("Finder", action: #selector(finderClicked))
        finderButton.frame = NSRect(x: width - 470, y: 16, width: 90, height: 32)
        finderButton.toolTip = "Afficher la vidéo dans le Finder"
        copyButton = textButton("Copier", action: #selector(copyClicked))
        copyButton.frame = NSRect(x: width - 372, y: 16, width: 90, height: 32)
        copyButton.toolTip = "Copier la vidéo, à coller dans une conversation"
        shareButton = textButton("Partager", action: #selector(shareClicked))
        shareButton.frame = NSRect(x: width - 274, y: 16, width: 100, height: 32)
        saveButton = textButton("Enregistrer", action: #selector(saveClicked))
        saveButton.frame = NSRect(x: width - 166, y: 16, width: 146, height: 32)
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.toolTip = "Enregistrer les modifications (⌘S)"
        saveButton.wantsLayer = true
        saveButton.layer?.backgroundColor = NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1).cgColor
        saveButton.layer?.cornerRadius = 8
        saveButton.contentTintColor = .white
        [finderButton, copyButton, shareButton, saveButton].forEach { content.addSubview($0) }

        window.contentView = content
        self.window = window
        updateButtons()
        SpaceSafeFocus.present(window, firstResponder: nil)

        Task { await load() }
    }

    // MARK: - Loading and rendering

    private func load() async {
        do {
            let built = try await RecordingComposer.build(project)
            let size: CGSize
            if let comp = built.videoComposition {
                size = comp.renderSize
            } else if let track = try? await built.asset.loadTracks(withMediaType: .video).first,
                      let natural = try? await track.load(.naturalSize) {
                size = natural
            } else {
                size = CGSize(width: 16, height: 9)
            }
            let frames = await Self.thumbnails(of: project.screenURL, count: 14)
            await MainActor.run {
                self.baseComposition = built.videoComposition
                self.renderSize = size
                self.duration = max(0.1, built.duration.seconds)
                let item = AVPlayerItem(asset: built.asset)
                item.videoComposition = built.videoComposition.map {
                    RecordingComposer.videoComposition($0, with: self.project.layout)
                }
                self.player.replaceCurrentItem(with: item)
                self.trimBar.duration = self.duration
                self.trimBar.start = self.project.trimStart
                self.trimBar.end = self.project.trimEnd ?? self.duration
                self.trimBar.thumbnails = frames
                self.segments = self.project.allSegments(duration: self.duration)
                self.syncSegments()
                self.overlay.videoSize = size
                self.overlay.layout = self.project.hasCamera ? self.project.layout : nil
                self.observeTime()
                self.updateTime()
            }
        } catch {
            await MainActor.run { self.statusLabel.stringValue = "Impossible d’ouvrir la vidéo" }
            return
        }
        // The finished video is written right away, so it is ready to copy or share
        startRender()
    }

    private func startRender() {
        renderer?.cancel()
        let renderer = RecordingRenderer()
        self.renderer = renderer
        isRendering = true
        isRendered = false
        statusLabel.stringValue = "Finalisation de la vidéo…"
        updateButtons()
        let snapshot = project
        snapshot.save()
        Task { [self] in
            do {
                try await renderer.render(snapshot)
                await MainActor.run {
                    guard self.renderer === renderer else { return }
                    self.isRendering = false
                    self.isRendered = true
                    self.statusLabel.stringValue = self.isDirty ? "Modifications non enregistrées" : "Vidéo prête"
                    self.updateButtons()
                    self.onRendered?(snapshot.outputURL)
                    let pending = self.afterRender
                    self.afterRender = []
                    pending.forEach { $0() }
                    self.releaseIfClosed()
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    guard self.renderer === renderer else { return }
                    self.isRendering = false
                    self.statusLabel.stringValue = "Échec de l’enregistrement de la vidéo"
                    self.afterRender = []
                    self.updateButtons()
                    self.releaseIfClosed()
                }
            }
        }
    }

    /// Runs `action` once the finished video matches the edits.
    private func whenReady(_ action: @escaping () -> Void) {
        if isDirty {
            isDirty = false
            afterRender.append(action)
            startRender()
        } else if isRendered {
            action()
        } else {
            afterRender.append(action)
        }
    }

    private func markDirty() {
        isDirty = true
        statusLabel.stringValue = "Modifications non enregistrées"
        updateButtons()
    }

    private func updateButtons() {
        let busy = !isRendered && !isDirty
        saveButton?.isEnabled = isDirty
        saveButton?.attributedTitle = NSAttributedString(string: isDirty ? "Enregistrer" : "Enregistré", attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(isDirty ? 1 : 0.6),
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ])
        saveButton?.layer?.backgroundColor = (isDirty
            ? NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1)
            : NSColor.white.withAlphaComponent(0.1)).cgColor
        for button in [copyButton, shareButton, finderButton] {
            button?.isEnabled = !busy
        }
    }

    // MARK: - Playback

    private func observeTime() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
            guard let self else { return }
            let t = self.player.currentTime().seconds
            let end = self.project.trimEnd ?? self.duration
            if self.player.rate > 0 {
                if t >= end - 0.02 {
                    self.player.pause()
                    self.seek(to: self.project.trimStart)
                } else if let removed = self.segments.first(where: { $0.removed && t >= $0.start && t < $0.end - 0.02 }) {
                    // Jump over a removed piece, like in the final video
                    if removed.end >= end - 0.02 {
                        self.player.pause()
                        self.seek(to: self.project.trimStart)
                    } else {
                        self.player.seek(to: CMTime(seconds: removed.end, preferredTimescale: 600),
                                         toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
            }
            self.updateTime()
        }
    }

    private func updateTime() {
        let t = player.currentTime().seconds
        trimBar.playhead = t.isFinite ? t : 0
        // Times of the final video: removed pieces and trimmed ends do not count
        let kept = project.keptRanges(duration: duration)
        let total = kept.reduce(0) { $0 + ($1.end - $1.start) }
        let elapsed = kept.reduce(0) { $0 + max(0, min(t, $1.end) - $1.start) }
        timeLabel.stringValue = "\(Self.format(elapsed)) / \(Self.format(total))"
        let playing = player.rate > 0
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
    }

    private func togglePlay() {
        if player.rate > 0 {
            player.pause()
        } else {
            let t = player.currentTime().seconds
            let end = project.trimEnd ?? duration
            if t >= end - 0.05 || t < project.trimStart {
                seek(to: project.trimStart)
            }
            player.play()
        }
        updateTime()
    }

    private func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        trimBar.playhead = seconds
        updateTime()
        updateCutButtons()
    }

    // MARK: - Edits

    private func trimChanged(start: Double, end: Double, edge: TrimBarView.Edge) {
        project.trimStart = start
        project.trimEnd = end >= duration - 0.01 ? nil : end
        player.pause()
        seek(to: edge == .start ? start : end)
        markDirty()
    }

    private func setLayout(_ layout: CameraLayout, applyNow: Bool) {
        project.layout = layout
        overlay.layout = layout
        markDirty()
        layoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyLayout() }
        layoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (applyNow ? 0 : 0.06), execute: work)
    }

    private func applyLayout() {
        guard let base = baseComposition, let item = player.currentItem else { return }
        item.videoComposition = RecordingComposer.videoComposition(base, with: project.layout)
        if player.rate == 0 {
            // Redraw the paused frame with the new layout
            player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func syncSegments() {
        project.segments = segments.count > 1 ? segments : nil
        trimBar.segments = segments
        trimBar.selected = selectedSegment
        updateCutButtons()
        updateTime()
    }

    private func updateCutButtons() {
        let t = player.currentTime().seconds
        let canSplit = segments.contains { t > $0.start + 0.2 && t < $0.end - 0.2 }
        cutButton?.isEnabled = canSplit
        if let index = selectedSegment, segments.indices.contains(index), segments.count > 1 {
            removeButton?.isEnabled = true
            removeButton?.title = segments[index].removed ? "Remettre le passage" : "Supprimer le passage"
            removeButton?.image = NSImage(systemSymbolName: segments[index].removed ? "arrow.uturn.backward" : "trash",
                                          accessibilityDescription: nil)
        } else {
            removeButton?.isEnabled = false
            removeButton?.title = "Supprimer le passage"
            removeButton?.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        }
    }

    @objc private func splitClicked() {
        let t = player.currentTime().seconds
        guard let index = segments.firstIndex(where: { t > $0.start + 0.2 && t < $0.end - 0.2 }) else { return }
        player.pause()
        let piece = segments[index]
        segments[index].end = t
        segments.insert(Segment(start: t, end: piece.end, removed: piece.removed), at: index + 1)
        selectedSegment = index + 1
        syncSegments()
        markDirty()
    }

    @objc private func removeClicked() {
        guard let index = selectedSegment, segments.indices.contains(index), segments.count > 1 else { return }
        segments[index].removed.toggle()
        var check = project
        check.segments = segments
        if check.keptRanges(duration: duration).isEmpty && segments[index].removed {
            // Never remove everything
            segments[index].removed = false
            Toast.show(message: "Il faut garder au moins un passage", style: .error)
            return
        }
        // Two neighbours with the same state become one piece again
        var merged: [Segment] = []
        for piece in segments {
            if let last = merged.last, last.removed == piece.removed, !piece.removed {
                merged[merged.count - 1].end = piece.end
            } else {
                merged.append(piece)
            }
        }
        let keepSelection = merged.count == segments.count
        segments = merged
        selectedSegment = keepSelection ? index : nil
        syncSegments()
        markDirty()
    }

    private func selectSegment(_ index: Int?) {
        selectedSegment = index
        trimBar.selected = index
        updateCutButtons()
    }

    /// Moves the cut between piece `index` and `index + 1`.
    private func moveSplit(_ index: Int, to time: Double) {
        guard index >= 0, index + 1 < segments.count else { return }
        let lo = segments[index].start + 0.2
        let hi = segments[index + 1].end - 0.2
        let t = min(max(time, lo), hi)
        segments[index].end = t
        segments[index + 1].start = t
        player.pause()
        seek(to: t)
        syncSegments()
        markDirty()
    }

    @objc private func cameraToggled() {
        var layout = project.layout
        layout.visible = cameraCheck?.state == .on
        setLayout(layout, applyNow: true)
    }

    @objc private func sizeChanged() {
        var layout = project.layout
        layout.size = sizeSlider?.doubleValue ?? layout.size
        setLayout(layout, applyNow: false)
    }

    // MARK: - Actions

    @objc private func togglePlayClicked() { togglePlay() }

    @objc private func saveClicked() {
        guard isDirty else { return }
        isDirty = false
        startRender()
    }

    @objc private func copyClicked() {
        whenReady { [weak self] in
            guard let self else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([self.project.outputURL as NSURL])
            Toast.show(message: "Vidéo copiée")
        }
    }

    @objc private func shareClicked() {
        whenReady { [weak self] in
            guard let self, let button = self.shareButton else { return }
            let picker = NSSharingServicePicker(items: [self.project.outputURL])
            picker.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }

    @objc private func finderClicked() {
        whenReady { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.activateFileViewerSelecting([self.project.outputURL])
        }
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        player.replaceCurrentItem(with: nil)
        window = nil
        // Unsaved edits are kept: the finished video is written in the background
        if isDirty {
            isDirty = false
            startRender()
        }
        releaseIfClosed()
    }

    /// The controller stays alive after its window closes until the video is written.
    private func releaseIfClosed() {
        guard window == nil, !isRendering else { return }
        Self.open.removeAll { $0 === self }
    }

    // MARK: - Helpers

    private func iconButton(_ symbol: String, action: Selector) -> NSButton {
        let button = NSButton(frame: .zero)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        button.contentTintColor = .white
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.cornerRadius = 18
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        return button
    }

    private func textButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        return button
    }

    private static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func thumbnails(of url: URL, count: Int) async -> [CGImage] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var images: [CGImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: duration.seconds * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            if let image = try? await generator.image(at: t).image {
                images.append(image)
            }
        }
        return images
    }
}

private final class EditorWindow: NSWindow {
    var onSpace: (() -> Void)?
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { // Space
            onSpace?()
        } else if event.keyCode == 51 || event.keyCode == 117 { // Delete, Forward delete
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Camera bubble drag over the video

final class CameraDragView: NSView {
    var onLayoutChange: ((CameraLayout) -> Void)?
    var onClick: (() -> Void)?
    var videoSize = CGSize(width: 16, height: 9) { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    /// nil: no camera in this recording.
    var layout: CameraLayout? { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }

    private var dragOffset: CGPoint?
    private var dragLayout: CameraLayout?
    private var hovering = false

    override var isFlipped: Bool { false }

    private var videoRect: NSRect {
        AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
    }

    /// Bubble circle in view coordinates.
    private func circle(for layout: CameraLayout) -> NSRect {
        let v = videoRect
        let d = CGFloat(layout.size) * min(v.width, v.height)
        let cx = v.minX + CGFloat(layout.centerX) * v.width
        let cy = v.minY + (1 - CGFloat(layout.centerY)) * v.height
        return NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        if let layout, layout.visible {
            addCursorRect(circle(for: layout), cursor: .openHand)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let layout, layout.visible else { return }
        let inside = isInside(convert(event.locationInWindow, from: nil), layout)
        if inside != hovering { hovering = inside; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovering { hovering = false; needsDisplay = true }
    }

    private func isInside(_ p: NSPoint, _ layout: CameraLayout) -> Bool {
        let c = circle(for: layout)
        let dx = p.x - c.midX, dy = p.y - c.midY
        return dx * dx + dy * dy <= (c.width / 2) * (c.width / 2)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let layout, layout.visible, isInside(p, layout) {
            let c = circle(for: layout)
            dragOffset = CGPoint(x: p.x - c.midX, y: p.y - c.midY)
            dragLayout = layout
            NSCursor.closedHand.set()
        } else {
            dragOffset = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let offset = dragOffset, var layout = dragLayout else { return }
        let p = convert(event.locationInWindow, from: nil)
        let v = videoRect
        guard v.width > 0, v.height > 0 else { return }
        let d = CGFloat(layout.size) * min(v.width, v.height)
        let r = d / 2
        let cx = min(max(p.x - offset.x, v.minX + r), v.maxX - r)
        let cy = min(max(p.y - offset.y, v.minY + r), v.maxY - r)
        layout.centerX = Double((cx - v.minX) / v.width)
        layout.centerY = Double(1 - (cy - v.minY) / v.height)
        dragLayout = layout
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let layout = dragLayout, dragOffset != nil {
            dragOffset = nil
            dragLayout = nil
            NSCursor.openHand.set()
            onLayoutChange?(layout)
        } else if event.clickCount == 1 {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // While dragging: where the bubble will go. On hover: a hint that it can be moved.
        if let layout = dragLayout {
            let c = circle(for: layout)
            let path = NSBezierPath(ovalIn: c.insetBy(dx: 1, dy: 1))
            NSColor.white.withAlphaComponent(0.18).setFill()
            path.fill()
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.white.setStroke()
            path.stroke()
        } else if hovering, let layout, layout.visible {
            let path = NSBezierPath(ovalIn: circle(for: layout).insetBy(dx: -3, dy: -3))
            path.lineWidth = 2
            NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 0.9).setStroke()
            path.stroke()
        }
    }
}

// MARK: - Trim bar (frames strip with start and end handles, like QuickTime)

final class TrimBarView: NSView {
    enum Edge { case start, end }

    var onSeek: ((Double) -> Void)?
    var onTrimChange: ((Double, Double, Edge) -> Void)?
    var onSelect: ((Int?) -> Void)?
    /// Index of the cut that moved (between piece i and i + 1), new time.
    var onSplitMove: ((Int, Double) -> Void)?

    var segments: [Segment] = [] { didSet { needsDisplay = true } }
    var selected: Int? { didSet { needsDisplay = true } }

    var duration: Double = 1 { didSet { needsDisplay = true } }
    var start: Double = 0 { didSet { needsDisplay = true } }
    var end: Double = 1 { didSet { needsDisplay = true } }
    var playhead: Double = 0 { didSet { needsDisplay = true } }
    var thumbnails: [CGImage] = [] { didSet { needsDisplay = true } }

    private enum Drag { case start, end, playhead, split(Int) }
    private var drag: Drag?
    private let handleWidth: CGFloat = 12
    private let accent = NSColor(red: 1.0, green: 0.78, blue: 0.16, alpha: 1)

    private var track: NSRect { bounds.insetBy(dx: handleWidth, dy: 4) }

    private func x(for t: Double) -> CGFloat {
        track.minX + CGFloat(t / max(duration, 0.001)) * track.width
    }

    private func time(at x: CGFloat) -> Double {
        let f = (x - track.minX) / max(track.width, 1)
        return min(max(Double(f) * duration, 0), duration)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = track
        let clip = NSBezierPath(roundedRect: t, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        NSColor.white.withAlphaComponent(0.06).setFill()
        t.fill()
        if !thumbnails.isEmpty, let ctx = NSGraphicsContext.current?.cgContext {
            let w = t.width / CGFloat(thumbnails.count)
            for (i, image) in thumbnails.enumerated() {
                let cell = NSRect(x: t.minX + CGFloat(i) * w, y: t.minY, width: w, height: t.height)
                let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
                var draw = cell
                draw.size.width = max(cell.width, cell.height * aspect)
                draw.origin.x = cell.midX - draw.width / 2
                ctx.saveGState()
                ctx.clip(to: cell)
                ctx.draw(image, in: draw)
                ctx.restoreGState()
            }
        }
        // Removed pieces: dark with red stripes
        for piece in segments where piece.removed {
            let r = NSRect(x: x(for: piece.start), y: t.minY, width: x(for: piece.end) - x(for: piece.start), height: t.height)
            NSColor.black.withAlphaComponent(0.7).setFill()
            r.fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: r).addClip()
            NSColor.systemRed.withAlphaComponent(0.45).setStroke()
            var sx = r.minX - r.height
            while sx < r.maxX {
                let stripe = NSBezierPath()
                stripe.move(to: NSPoint(x: sx, y: r.minY))
                stripe.line(to: NSPoint(x: sx + r.height, y: r.maxY))
                stripe.lineWidth = 2
                stripe.stroke()
                sx += 9
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        // Selected piece
        if let index = selected, segments.indices.contains(index), segments.count > 1 {
            let piece = segments[index]
            let r = NSRect(x: x(for: piece.start), y: t.minY, width: x(for: piece.end) - x(for: piece.start), height: t.height)
            NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 0.22).setFill()
            r.fill()
            let border = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1).setStroke()
            border.stroke()
        }
        // Dim what is trimmed
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSRect(x: t.minX, y: t.minY, width: x(for: start) - t.minX, height: t.height).fill()
        NSRect(x: x(for: end), y: t.minY, width: t.maxX - x(for: end), height: t.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Kept range: yellow frame with two handles
        let kept = NSRect(x: x(for: start) - handleWidth, y: bounds.minY + 1,
                          width: x(for: end) - x(for: start) + handleWidth * 2, height: bounds.height - 2)
        let frame = NSBezierPath(roundedRect: kept.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7)
        frame.lineWidth = 3
        accent.setStroke()
        frame.stroke()
        for hx in [kept.minX, kept.maxX - handleWidth] {
            let handle = NSBezierPath(roundedRect: NSRect(x: hx, y: kept.minY, width: handleWidth, height: kept.height), xRadius: 6, yRadius: 6)
            accent.setFill()
            handle.fill()
            let grip = NSRect(x: hx + handleWidth / 2 - 1, y: kept.midY - 7, width: 2, height: 14)
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: grip, xRadius: 1, yRadius: 1).fill()
        }

        // Cuts: white markers with a small grip, draggable
        for piece in segments.dropLast() {
            let cx = x(for: piece.end)
            NSColor.white.setFill()
            NSRect(x: cx - 1, y: bounds.minY + 2, width: 2, height: bounds.height - 4).fill()
            NSBezierPath(ovalIn: NSRect(x: cx - 5, y: bounds.maxY - 12, width: 10, height: 10)).fill()
            if let scissors = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 7, weight: .bold)) {
                scissors.draw(in: NSRect(x: cx - 4, y: bounds.maxY - 11, width: 8, height: 8))
            }
        }

        // Playhead
        let px = x(for: min(max(playhead, 0), duration))
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: px - 1.5, y: bounds.minY, width: 3, height: bounds.height), xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let sx = x(for: start), ex = x(for: end)
        if let cut = segments.dropLast().indices.first(where: { abs(x(for: segments[$0].end) - p.x) <= 5 }) {
            drag = .split(cut)
        } else if p.x >= sx - handleWidth - 4 && p.x <= sx + 4 {
            drag = .start
        } else if p.x >= ex - 4 && p.x <= ex + handleWidth + 4 {
            drag = .end
        } else {
            drag = .playhead
            let t = time(at: p.x)
            onSelect?(segments.firstIndex { t >= $0.start && t < $0.end })
            onSeek?(min(max(t, start), end))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let t = time(at: p.x)
        let minLength = min(0.5, duration / 2)
        switch drag {
        case .start:
            start = min(max(0, t), end - minLength)
            onTrimChange?(start, end, .start)
        case .end:
            end = max(min(duration, t), start + minLength)
            onTrimChange?(start, end, .end)
        case .playhead:
            onSeek?(min(max(t, start), end))
        case .split(let index):
            onSplitMove?(index, t)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }
}
