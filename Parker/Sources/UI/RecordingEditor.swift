import Cocoa
import AVFoundation
import AVKit

/// Colors of the editing window and of the video thumbnail (same values as Parker's settings).
enum MontageStyle {
    static let ink = NSColor(srgbRed: 0.961, green: 0.969, blue: 0.992, alpha: 1)      // #F5F7FD
    static let muted = NSColor(srgbRed: 0.651, green: 0.694, blue: 0.784, alpha: 1)    // #A6B1C8
    static let window = NSColor(srgbRed: 0.067, green: 0.094, blue: 0.153, alpha: 1)   // #111827
    static let field = NSColor(srgbRed: 0.106, green: 0.141, blue: 0.224, alpha: 1)    // #1B2439
    static let accent = NSColor(srgbRed: 0.184, green: 0.329, blue: 0.965, alpha: 1)   // #2F54F6
    static let line = NSColor(srgbRed: 0.259, green: 0.306, blue: 0.4, alpha: 1)       // #424E66
    static let handle = NSColor(srgbRed: 1, green: 0.78, blue: 0.161, alpha: 1)        // #FFC729
}

/// Button of the editor and the thumbnail: primary (blue), secondary (field + border) or ghost.
/// Reacts to the first click even when its window is not active.
final class MontageButton: NSButton {
    enum Kind { case primary, secondary, ghost }
    private let kind: Kind
    private var label = ""
    private var symbol: String?

    init(_ title: String, symbol: String?, kind: Kind, target: AnyObject?, action: Selector?) {
        self.kind = kind
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 9
        imagePosition = .imageLeading
        imageHugsTitle = true
        setContentHuggingPriority(.required, for: .horizontal)
        set(title: title, symbol: symbol)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func set(title: String, symbol: String?) {
        label = title
        self.symbol = symbol
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) }
        refresh()
        invalidateIntrinsicContentSize()
    }

    override var isEnabled: Bool { didSet { refresh() } }

    private func refresh() {
        switch kind {
        case .primary: layer?.backgroundColor = MontageStyle.accent.cgColor; layer?.borderWidth = 0
        case .secondary:
            layer?.backgroundColor = MontageStyle.field.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = MontageStyle.line.withAlphaComponent(0.7).cgColor
        case .ghost: layer?.backgroundColor = NSColor.clear.cgColor; layer?.borderWidth = 0
        }
        contentTintColor = MontageStyle.ink
        attributedTitle = NSAttributedString(string: image == nil ? label : " " + label, attributes: [
            .foregroundColor: MontageStyle.ink,
            .font: NSFont.systemFont(ofSize: 13, weight: kind == .primary ? .semibold : .medium),
        ])
        alphaValue = isEnabled ? 1 : 0.45
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + 26, height: 33)
    }

    override func mouseDown(with event: NSEvent) {
        layer?.opacity = 0.75
        super.mouseDown(with: event)
        layer?.opacity = 1
    }
}

/// Blue capsule over the timeline: "Couper ici ⌘B", "Supprimer ⌫".
final class MontagePill: NSButton {
    init(_ title: String, symbol: String, shortcut: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = MontageStyle.accent.cgColor
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.35)
            s.shadowOffset = NSSize(width: 0, height: -4)
            s.shadowBlurRadius = 6
            return s
        }()
        imagePosition = .imageLeading
        imageHugsTitle = true
        contentTintColor = MontageStyle.ink
        set(title: title, symbol: symbol, shortcut: shortcut)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func set(title: String, symbol: String, shortcut: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        let text = NSMutableAttributedString(string: " " + title, attributes: [
            .foregroundColor: MontageStyle.ink, .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ])
        if !shortcut.isEmpty {
            text.append(NSAttributedString(string: "  " + shortcut, attributes: [
                .foregroundColor: MontageStyle.ink.withAlphaComponent(0.6), .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            ]))
        }
        attributedTitle = text
        invalidateIntrinsicContentSize()
    }

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.4 } }

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width + 22, height: 28)
    }
}

/// Small bar shown above the camera bubble while it is hovered: sizes S, M, L and hide.
final class BubbleToolbar: NSView {
    var onSize: ((Double) -> Void)?
    var onHide: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    static let sizes: [(String, Double)] = [("S", 0.16), ("M", 0.24), ("L", 0.34)]
    private var buttons: [NSButton] = []

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 136, height: 34))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = MontageStyle.window.withAlphaComponent(0.92).cgColor
        var x: CGFloat = 4
        for (index, (label, _)) in Self.sizes.enumerated() {
            let b = FirstClickButton(title: label, target: self, action: #selector(sizeClicked(_:)))
            b.tag = index
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 7
            b.frame = NSRect(x: x, y: 4, width: label == "M" ? 31 : 28, height: 26)
            b.toolTip = ["Petite", "Moyenne", "Grande"][index]
            addSubview(b)
            buttons.append(b)
            x += b.frame.width + 2
        }
        let sep = NSView(frame: NSRect(x: x, y: 8, width: 1, height: 18))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = MontageStyle.line.cgColor
        addSubview(sep)
        let eye = FirstClickButton(frame: NSRect(x: x + 3, y: 4, width: 32, height: 26))
        eye.isBordered = false
        eye.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Masquer la caméra")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        eye.contentTintColor = MontageStyle.ink
        eye.target = self
        eye.action = #selector(hideClicked)
        eye.toolTip = "Masquer la caméra"
        addSubview(eye)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func select(size: Double) {
        let nearest = Self.sizes.enumerated().min { abs($0.element.1 - size) < abs($1.element.1 - size) }?.offset
        for (i, b) in buttons.enumerated() {
            let on = i == nearest
            b.layer?.backgroundColor = (on ? MontageStyle.accent : .clear).cgColor
            b.attributedTitle = NSAttributedString(string: Self.sizes[i].0, attributes: [
                .foregroundColor: MontageStyle.ink, .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            ])
        }
    }

    @objc private func sizeClicked(_ sender: NSButton) { onSize?(Self.sizes[sender.tag].1) }
    @objc private func hideClicked() { onHide?() }
    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}

/// Editing window, opened from the video thumbnail's "Modifier": watch, cut the start and the
/// end, cut in the middle, move or resize the camera, then export. Edits apply by themselves
/// (no save button): the finished video is rewritten in the background, and Annuler undoes.
final class RecordingEditorController: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSMenuDelegate {
    /// Called each time the finished video is written, with the previous URL when it was renamed.
    var onRendered: ((URL, URL?) -> Void)?

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
    private var renderWork: DispatchWorkItem?
    private var afterRender: [() -> Void] = []
    private var progressTimer: Timer?
    private var loadFailed = false
    private var renamedFrom: URL?

    // Undo: whole edit states, newest last
    private struct EditState { var trimStart: Double; var trimEnd: Double?; var segments: [Segment]; var layout: CameraLayout; var quality: Int? }
    private var undoStack: [EditState] = []
    private var undoCoalesceUntil = Date.distantPast

    // Views
    private var nameField: NSTextField!
    private var infoLabel: NSTextField!
    private var undoButton: MontageButton!
    private var qualityButton: MontageButton!
    private var exportButton: MontageButton!
    private var videoBox: NSView!
    private var playerView: AVPlayerView!
    private var overlay: CameraDragView!
    private var bubbleBar: BubbleToolbar!
    private var bubbleBarHideWork: DispatchWorkItem?
    private var trimBar: TrimBarView!
    private var playButton: NSButton!
    private var timeLabel: NSTextField!
    private var totalLabel: NSTextField!
    private var cutPill: MontagePill!
    private var deletePill: MontagePill!
    private var cameraPill: MontagePill!

    // Cuts in the middle
    private var segments: [Segment] = []
    private var selectedSegment: Int?
    private var cameraMissing = false

    init(project: RecordingProject) {
        self.project = project
        super.init()
    }

    /// Opens the editor (one at a time). `rendered`: the finished video already matches the project.
    static func present(_ project: RecordingProject, rendered: Bool = false, onRendered: @escaping (URL, URL?) -> Void) {
        open.forEach { $0.window?.close() }
        let controller = RecordingEditorController(project: project)
        controller.onRendered = onRendered
        controller.isRendered = rendered && FileManager.default.fileExists(atPath: project.outputPath)
        open.append(controller)
        controller.show()
    }

    // MARK: - Window and layout

    private func show() {
        let window = EditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1160, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = project.outputURL.deletingPathExtension().lastPathComponent
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar gives a 52 pt title bar: the window buttons sit centered in the top bar
        window.toolbar = NSToolbar(identifier: "ParkerMontage")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = MontageStyle.window
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 620)
        window.delegate = self
        window.onSpace = { [weak self] in self?.togglePlay() }
        window.onDelete = { [weak self] in self?.removeClicked() }
        window.onUndo = { [weak self] in self?.undoClicked() }
        window.onCut = { [weak self] in self?.splitClicked() }
        window.onCopy = { [weak self] in self?.copyClicked() }
        window.onSave = { [weak self] in self?.saveAsClicked() }
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            window.setContentSize(NSSize(width: min(1160, v.width - 80), height: min(840, v.height - 60)))
        }
        window.center()

        let content = NSView()
        content.wantsLayer = true
        window.contentView = content

        // ---- Top bar
        let nameBox = NSView()
        nameBox.wantsLayer = true
        nameBox.layer?.cornerRadius = 6
        nameBox.layer?.backgroundColor = MontageStyle.field.cgColor
        nameField = NSTextField(string: project.outputURL.deletingPathExtension().lastPathComponent)
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.font = .systemFont(ofSize: 14, weight: .semibold)
        nameField.textColor = MontageStyle.ink
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(nameCommitted)
        nameField.toolTip = "Nom de la vidéo (clic pour le modifier)"
        nameField.cell?.lineBreakMode = .byTruncatingTail
        let pen = NSImageView(image: NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))!)
        pen.contentTintColor = MontageStyle.ink
        pen.alphaValue = 0.5
        let nameStack = NSStackView(views: [nameField, pen])
        nameStack.spacing = 6
        nameStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        nameBox.addSubview(nameStack)
        nameStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            nameStack.leadingAnchor.constraint(equalTo: nameBox.leadingAnchor),
            nameStack.trailingAnchor.constraint(equalTo: nameBox.trailingAnchor),
            nameStack.topAnchor.constraint(equalTo: nameBox.topAnchor),
            nameStack.bottomAnchor.constraint(equalTo: nameBox.bottomAnchor),
            nameField.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        infoLabel = label("", size: 12, weight: .medium, color: MontageStyle.muted)
        undoButton = MontageButton("Annuler", symbol: "arrow.uturn.backward", kind: .ghost, target: self, action: #selector(undoClicked))
        undoButton.toolTip = "Annuler la dernière modification (⌘Z)"
        qualityButton = MontageButton("Qualité ▾", symbol: "film", kind: .secondary, target: self, action: #selector(qualityClicked))
        qualityButton.toolTip = "Taille de la vidéo exportée"
        exportButton = MontageButton("Exporter", symbol: "square.and.arrow.down", kind: .primary, target: self, action: #selector(exportClicked))
        exportButton.toolTip = "Copier, enregistrer, partager…"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [nameBox, infoLabel, spacer, undoButton, qualityButton, exportButton])
        top.spacing = 12
        top.alignment = .centerY
        top.edgeInsets = NSEdgeInsets(top: 0, left: 88, bottom: 0, right: 16)
        top.setCustomSpacing(10, after: undoButton)
        top.setCustomSpacing(10, after: qualityButton)

        // ---- Video
        videoBox = NSView()
        videoBox.wantsLayer = true
        videoBox.layer?.backgroundColor = NSColor.black.cgColor
        playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.player = player
        overlay = CameraDragView()
        overlay.onLayoutChange = { [weak self] layout in self?.setLayout(layout) }
        overlay.onClick = { [weak self] in self?.togglePlay() }
        overlay.onBubbleHover = { [weak self] rect in self?.bubbleHovered(rect) }
        bubbleBar = BubbleToolbar()
        bubbleBar.isHidden = true
        bubbleBar.onSize = { [weak self] size in self?.setBubbleSize(size) }
        bubbleBar.onHide = { [weak self] in self?.setBubbleVisible(false) }
        bubbleBar.onHoverChanged = { [weak self] inside in
            if inside { self?.bubbleBarHideWork?.cancel() } else { self?.scheduleBubbleBarHide() }
        }
        for v in [playerView!, overlay!] {
            videoBox.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: videoBox.leadingAnchor, constant: 20),
                v.trailingAnchor.constraint(equalTo: videoBox.trailingAnchor, constant: -20),
                v.topAnchor.constraint(equalTo: videoBox.topAnchor, constant: 5),
                v.bottomAnchor.constraint(equalTo: videoBox.bottomAnchor, constant: -5),
            ])
        }
        videoBox.addSubview(bubbleBar)

        // ---- Pills + player row
        cutPill = MontagePill("Couper ici", symbol: "scissors", shortcut: "⌘B", target: self, action: #selector(splitClicked))
        cutPill.toolTip = "Couper la vidéo à la tête de lecture"
        deletePill = MontagePill("Supprimer", symbol: "trash", shortcut: "⌫", target: self, action: #selector(removeClicked))
        deletePill.toolTip = "Retirer le passage sélectionné de la vidéo"
        cameraPill = MontagePill("Afficher la caméra", symbol: "eye", shortcut: "", target: self, action: #selector(showCameraClicked))
        cameraPill.toolTip = "Remettre la bulle caméra sur la vidéo"
        let pills = NSStackView(views: [deletePill, cutPill, cameraPill])
        pills.spacing = 8

        playButton = FirstClickButton(frame: .zero)
        playButton.isBordered = false
        playButton.wantsLayer = true
        playButton.layer?.cornerRadius = 20
        playButton.layer?.backgroundColor = MontageStyle.field.cgColor
        playButton.layer?.borderWidth = 1
        playButton.layer?.borderColor = MontageStyle.line.cgColor
        playButton.contentTintColor = MontageStyle.ink
        playButton.target = self
        playButton.action = #selector(togglePlayClicked)
        playButton.toolTip = "Lecture / pause (Espace)"
        timeLabel = label("0:00", size: 12, weight: .semibold, color: MontageStyle.ink)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        totalLabel = label("0:00", size: 12, weight: .medium, color: MontageStyle.muted)
        totalLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        trimBar = TrimBarView()
        trimBar.onSeek = { [weak self] t in self?.seek(to: t) }
        trimBar.onTrimChange = { [weak self] start, end, edge in self?.trimChanged(start: start, end: end, edge: edge) }
        trimBar.onSelect = { [weak self] index in self?.selectSegment(index) }
        trimBar.onSplitMove = { [weak self] index, time in self?.moveSplit(index, to: time) }
        let row = NSStackView(views: [playButton, timeLabel, trimBar, totalLabel])
        row.spacing = 14
        row.alignment = .centerY

        for v in [top, videoBox!, pills, row] {
            content.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            top.heightAnchor.constraint(equalToConstant: 52),
            nameBox.heightAnchor.constraint(equalToConstant: 26),

            videoBox.topAnchor.constraint(equalTo: top.bottomAnchor),
            videoBox.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            videoBox.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            pills.topAnchor.constraint(equalTo: videoBox.bottomAnchor, constant: 16),
            pills.leadingAnchor.constraint(equalTo: trimBar.leadingAnchor, constant: 12),
            pills.heightAnchor.constraint(equalToConstant: 28),

            row.topAnchor.constraint(equalTo: pills.bottomAnchor, constant: 18),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            playButton.widthAnchor.constraint(equalToConstant: 40),
            playButton.heightAnchor.constraint(equalToConstant: 40),
            trimBar.heightAnchor.constraint(equalToConstant: 60),
        ])
        trimBar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        self.window = window
        updatePills()
        updateInfo()
        SpaceSafeFocus.present(window, firstResponder: nil)
        if #available(macOS 14.0, *) { NSApp.activate() }

        Task { await load() }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
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
                self.cameraMissing = self.project.hasCamera && built.videoComposition == nil
                self.updatePills()
                self.updateTime()
                self.updateInfo()
                if !self.isRendered { self.startRender() }
            }
        } catch {
            await MainActor.run {
                self.loadFailed = true
                self.infoLabel.stringValue = "Impossible d’ouvrir la vidéo"
                self.exportButton.isEnabled = false
            }
        }
    }

    /// Edits are applied by themselves, a moment after the last change.
    private func scheduleRender() {
        isRendered = false
        renderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startRender() }
        renderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        updateInfo()
    }

    private func startRender() {
        renderWork?.cancel()
        renderWork = nil
        renderer?.cancel()
        let renderer = RecordingRenderer()
        self.renderer = renderer
        isRendering = true
        isRendered = false
        startProgress()
        let snapshot = project
        snapshot.save()
        Task { [self] in
            do {
                try await renderer.render(snapshot)
                await MainActor.run {
                    guard self.renderer === renderer else { return }
                    self.isRendering = false
                    self.stopProgress()
                    self.isRendered = self.renderWork == nil
                    self.onRendered?(snapshot.outputURL, self.renamedFrom)
                    self.renamedFrom = nil
                    if self.isRendered {
                        let pending = self.afterRender
                        self.afterRender = []
                        pending.forEach { $0() }
                    }
                    self.updateInfo()
                    self.releaseIfClosed()
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    guard self.renderer === renderer else { return }
                    self.isRendering = false
                    self.stopProgress()
                    self.afterRender = []
                    self.updateInfo(failed: true)
                    self.releaseIfClosed()
                }
            }
        }
    }

    /// Runs `action` once the finished video matches the edits.
    private func whenReady(_ action: @escaping () -> Void) {
        if isRendered && !isRendering && renderWork == nil {
            action()
        } else {
            afterRender.append(action)
            if renderWork != nil { startRender() }
            updateInfo()
        }
    }

    private func startProgress() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateInfo()
        }
        updateInfo()
    }

    private func stopProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    /// "0:39 · 1440p", plus the preparation progress while the video is being written.
    private func updateInfo(failed: Bool = false) {
        guard infoLabel != nil else { return }
        let kept = project.keptRanges(duration: duration)
        let total = kept.reduce(0) { $0 + ($1.end - $1.start) }
        var height = Int(renderSize.height)
        let limit = project.effectiveExportHeight
        if limit > 0 { height = min(height, limit) }
        var text = "\(Self.format(total))  ·  \(height)p"
        if failed {
            text += "  ·  échec de la préparation"
        } else if isRendering, let renderer {
            text += "  ·  préparation \(Int((renderer.progress * 100).rounded())) %"
        } else if cameraMissing {
            text += "  ·  caméra introuvable"
        }
        infoLabel.stringValue = text
        let waiting = !afterRender.isEmpty && (isRendering || renderWork != nil)
        if waiting, let renderer {
            exportButton.set(title: "Préparation \(Int((renderer.progress * 100).rounded())) %", symbol: "hourglass")
        } else {
            exportButton.set(title: "Exporter", symbol: "square.and.arrow.down")
        }
        undoButton.isEnabled = !undoStack.isEmpty
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
        timeLabel.stringValue = Self.format(elapsed)
        totalLabel.stringValue = Self.format(total)
        let playing = player.rate > 0
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
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
        updatePills()
    }

    // MARK: - Undo

    private var currentState: EditState {
        EditState(trimStart: project.trimStart, trimEnd: project.trimEnd, segments: segments,
                  layout: project.layout, quality: project.exportMaxHeight)
    }

    /// Saves the state before an edit. Continuous gestures (dragging a handle) count as one edit.
    private func recordUndo() {
        let now = Date()
        if now > undoCoalesceUntil {
            undoStack.append(currentState)
            if undoStack.count > 50 { undoStack.removeFirst() }
        }
        undoCoalesceUntil = now.addingTimeInterval(0.6)
    }

    @objc private func undoClicked() {
        guard let state = undoStack.popLast() else { return }
        undoCoalesceUntil = .distantPast
        project.trimStart = state.trimStart
        project.trimEnd = state.trimEnd
        project.exportMaxHeight = state.quality
        trimBar.start = state.trimStart
        trimBar.end = state.trimEnd ?? duration
        segments = state.segments
        selectedSegment = nil
        project.layout = state.layout
        overlay.layout = project.hasCamera ? state.layout : nil
        applyLayout()
        syncSegments()
        scheduleRender()
    }

    // MARK: - Edits

    private func edited() {
        scheduleRender()
    }

    private func trimChanged(start: Double, end: Double, edge: TrimBarView.Edge) {
        recordUndo()
        project.trimStart = start
        project.trimEnd = end >= duration - 0.01 ? nil : end
        player.pause()
        seek(to: edge == .start ? start : end)
        edited()
    }

    private func setLayout(_ layout: CameraLayout) {
        recordUndo()
        project.layout = layout
        overlay.layout = layout
        applyLayout()
        bubbleBar.select(size: layout.size)
        edited()
    }

    private func setBubbleSize(_ size: Double) {
        var layout = project.layout
        layout.size = size
        setLayout(layout)
        DispatchQueue.main.async { [weak self] in
            guard let self, let rect = self.overlay.bubbleRect else { return }
            self.positionBubbleBar(over: rect)
        }
    }

    private func setBubbleVisible(_ visible: Bool) {
        var layout = project.layout
        layout.visible = visible
        bubbleBar.isHidden = true
        setLayout(layout)
        updatePills()
    }

    @objc private func showCameraClicked() { setBubbleVisible(true) }

    private func applyLayout() {
        guard let base = baseComposition, let item = player.currentItem else { return }
        item.videoComposition = RecordingComposer.videoComposition(base, with: project.layout)
        if player.rate == 0 {
            // Redraw the paused frame with the new layout
            player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    // Bubble toolbar: shown above the bubble while it (or the bar) is hovered
    private func bubbleHovered(_ rect: NSRect?) {
        if let rect {
            bubbleBarHideWork?.cancel()
            positionBubbleBar(over: rect)
            bubbleBar.select(size: project.layout.size)
            bubbleBar.isHidden = false
        } else {
            scheduleBubbleBarHide()
        }
    }

    private func positionBubbleBar(over rect: NSRect) {
        let r = overlay.convert(rect, to: videoBox)
        var origin = NSPoint(x: r.midX - bubbleBar.frame.width / 2, y: r.maxY + 10)
        origin.x = min(max(origin.x, 8), videoBox.bounds.width - bubbleBar.frame.width - 8)
        if origin.y + bubbleBar.frame.height > videoBox.bounds.height - 6 { origin.y = r.minY - bubbleBar.frame.height - 10 }
        bubbleBar.setFrameOrigin(origin)
    }

    private func scheduleBubbleBarHide() {
        bubbleBarHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window else { return }
            let mouse = self.videoBox.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if !self.bubbleBar.frame.contains(mouse) { self.bubbleBar.isHidden = true }
        }
        bubbleBarHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func syncSegments() {
        project.segments = segments.count > 1 ? segments : nil
        trimBar.segments = segments
        trimBar.selected = selectedSegment
        updatePills()
        updateTime()
        updateInfo()
    }

    private var canSplit: Bool {
        let t = player.currentTime().seconds
        return segments.contains { t > $0.start + 0.2 && t < $0.end - 0.2 }
    }

    private func updatePills() {
        guard cutPill != nil else { return }
        cameraPill.isHidden = !(project.hasCamera && !project.layout.visible && !cameraMissing)
        cutPill.isEnabled = canSplit
        if let index = selectedSegment, segments.indices.contains(index), segments.count > 1 {
            deletePill.isHidden = false
            let removed = segments[index].removed
            deletePill.set(title: removed ? "Remettre" : "Supprimer", symbol: removed ? "arrow.uturn.backward" : "trash", shortcut: "⌫")
        } else {
            deletePill.isHidden = true
        }
    }

    @objc private func splitClicked() {
        let t = player.currentTime().seconds
        guard let index = segments.firstIndex(where: { t > $0.start + 0.2 && t < $0.end - 0.2 }) else { return }
        recordUndo()
        undoCoalesceUntil = .distantPast
        player.pause()
        let piece = segments[index]
        segments[index].end = t
        segments.insert(Segment(start: t, end: piece.end, removed: piece.removed), at: index + 1)
        selectedSegment = index + 1
        syncSegments()
        edited()
    }

    @objc private func removeClicked() {
        guard let index = selectedSegment, segments.indices.contains(index), segments.count > 1 else { return }
        var next = segments
        next[index].removed.toggle()
        var check = project
        check.segments = next
        if next[index].removed && check.keptRanges(duration: duration).isEmpty {
            Toast.show(message: "Il faut garder au moins un passage", style: .error)
            return
        }
        recordUndo()
        undoCoalesceUntil = .distantPast
        // Two kept neighbours become one piece again
        var merged: [Segment] = []
        for piece in next {
            if let last = merged.last, last.removed == piece.removed, !piece.removed {
                merged[merged.count - 1].end = piece.end
            } else {
                merged.append(piece)
            }
        }
        let keepSelection = merged.count == next.count
        segments = merged
        selectedSegment = keepSelection ? index : nil
        syncSegments()
        edited()
    }

    private func selectSegment(_ index: Int?) {
        selectedSegment = index
        trimBar.selected = index
        updatePills()
    }

    /// Moves the cut between piece `index` and `index + 1`.
    private func moveSplit(_ index: Int, to time: Double) {
        guard index >= 0, index + 1 < segments.count else { return }
        recordUndo()
        let lo = segments[index].start + 0.2
        let hi = segments[index + 1].end - 0.2
        let t = min(max(time, lo), hi)
        segments[index].end = t
        segments[index + 1].start = t
        player.pause()
        seek(to: t)
        syncSegments()
        edited()
    }

    // MARK: - Quality

    private static let qualities: [(String, Int)] = [("Full HD (1080p)", 1080), ("QHD (1440p)", 1440), ("Maximum (4K)", 0)]

    @objc private func qualityClicked() {
        let menu = NSMenu()
        let source = Int(renderSize.height)
        let current = project.effectiveExportHeight
        for (title, height) in Self.qualities {
            let item = NSMenuItem(title: title, action: #selector(qualityPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = height
            item.state = height == current ? .on : .off
            // Always selectable: a smaller recording simply keeps its own size (never enlarged)
            if height > 0 && height >= source {
                item.toolTip = "La vidéo enregistrée fait \(source)p : elle garde cette taille"
            }
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: qualityButton.bounds.height + 6), in: qualityButton)
    }

    @objc private func qualityPicked(_ item: NSMenuItem) {
        let value = item.tag
        guard value != project.effectiveExportHeight else { return }
        recordUndo()
        undoCoalesceUntil = .distantPast
        project.exportMaxHeight = value
        edited()
    }

    // MARK: - Export

    @objc private func exportClicked() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ symbol: String, _ action: Selector, _ key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = key.isEmpty ? [] : .command
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        add("Copier la vidéo", "doc.on.doc", #selector(copyClicked), "c")
        add("Enregistrer sous… (MP4)", "film", #selector(saveAsClicked), "s")
        add("Exporter en GIF", "photo.stack", #selector(gifClicked))
        add("Partager…", "square.and.arrow.up", #selector(shareClicked))
        add("Afficher dans le Finder", "folder", #selector(finderClicked))
        menu.popUp(positioning: nil, at: NSPoint(x: exportButton.bounds.width - 260, y: exportButton.bounds.height + 6), in: exportButton)
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

    @objc private func saveAsClicked() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = project.outputURL.lastPathComponent
        panel.canCreateDirectories = true
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let dest = panel.url else { return }
            self?.whenReady { [weak self] in
                guard let self else { return }
                do {
                    if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                    try FileManager.default.copyItem(at: self.project.outputURL, to: dest)
                    Toast.show(message: "Vidéo enregistrée")
                } catch {
                    Toast.show(message: "Impossible d’enregistrer la vidéo", style: .error)
                }
            }
        }
    }

    @objc private func gifClicked() {
        whenReady { [weak self] in
            guard let self else { return }
            Toast.showActivity(message: "Conversion en GIF…", state: .working)
            GIFExporter.exportToGIF(videoURL: self.project.outputURL, maxWidth: Defaults.shared.gifMaxWidth,
                                    fps: Defaults.shared.gifFrameRate) { result in
                switch result {
                case .success(let gifURL):
                    Defaults.shared.addRecentCapture(gifURL)
                    Toast.show(message: "GIF enregistré : \(gifURL.lastPathComponent)")
                case .failure:
                    Toast.show(message: "Échec de l’export GIF", style: .error)
                }
            }
        }
    }

    @objc private func shareClicked() {
        whenReady { [weak self] in
            guard let self, let button = self.exportButton else { return }
            let picker = NSSharingServicePicker(items: [self.project.outputURL])
            picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func finderClicked() {
        whenReady { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.activateFileViewerSelecting([self.project.outputURL])
        }
    }

    // MARK: - Name

    func controlTextDidEndEditing(_ obj: Notification) { nameCommitted() }

    @objc private func nameCommitted() {
        let raw = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let old = project.outputURL
        guard !clean.isEmpty else { nameField.stringValue = old.deletingPathExtension().lastPathComponent; return }
        guard clean != old.deletingPathExtension().lastPathComponent else { return }
        var dest = old.deletingLastPathComponent().appendingPathComponent(clean).appendingPathExtension("mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = old.deletingLastPathComponent().appendingPathComponent("\(clean) \(n)").appendingPathExtension("mp4")
            n += 1
        }
        let wasRendering = isRendering
        renderer?.cancel()
        isRendering = false
        stopProgress()
        if FileManager.default.fileExists(atPath: old.path) {
            do { try FileManager.default.moveItem(at: old, to: dest) } catch {
                Toast.show(message: "Impossible de renommer la vidéo", style: .error)
                nameField.stringValue = old.deletingPathExtension().lastPathComponent
                return
            }
        }
        project.outputPath = dest.path
        project.save()
        renamedFrom = old
        window?.title = dest.deletingPathExtension().lastPathComponent
        nameField.stringValue = dest.deletingPathExtension().lastPathComponent
        window?.makeFirstResponder(nil)
        if wasRendering || !isRendered {
            startRender()
        } else {
            onRendered?(dest, old)
            renamedFrom = nil
        }
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        player.replaceCurrentItem(with: nil)
        window = nil
        // Pending edits are applied now, in the background
        if renderWork != nil { startRender() }
        releaseIfClosed()
    }

    /// The controller stays alive after its window closes until the video is written.
    private func releaseIfClosed() {
        guard window == nil, !isRendering else { return }
        Self.open.removeAll { $0 === self }
    }

    // MARK: - Helpers

    @objc private func togglePlayClicked() { togglePlay() }

    static func format(_ seconds: Double) -> String {
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

/// Button that reacts to the first click even when the window is not active yet. Since macOS 14
/// an app cannot always bring itself to the front, so the editor can open behind the active app:
/// a plain button then needs one click to activate the window and a second one to work.
final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class EditorWindow: NSWindow {
    var onSpace: (() -> Void)?
    var onDelete: (() -> Void)?
    var onUndo: (() -> Void)?
    var onCut: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?

    /// ⌘Z, ⌘B, ⌘C, ⌘S, except while the name is being typed (the text field handles them then).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command, !(firstResponder is NSText) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z": onUndo?(); return true
        case "b": onCut?(); return true
        case "c": onCopy?(); return true
        case "s": onSave?(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if firstResponder is NSText {
            super.keyDown(with: event)
        } else if event.keyCode == 49 { // Space
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var onLayoutChange: ((CameraLayout) -> Void)?
    var onClick: (() -> Void)?
    /// Bubble rectangle while the mouse is over it, nil when it leaves.
    var onBubbleHover: ((NSRect?) -> Void)?
    var bubbleRect: NSRect? {
        guard let layout, layout.visible else { return nil }
        return circle(for: layout)
    }
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
        if inside != hovering {
            hovering = inside
            needsDisplay = true
            if dragOffset == nil { onBubbleHover?(inside ? circle(for: layout) : nil) }
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hovering { hovering = false; needsDisplay = true; onBubbleHover?(nil) }
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
            onBubbleHover?(nil)
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
            MontageStyle.accent.setStroke()
            path.stroke()
        }
    }
}

// MARK: - Trim bar (frames strip with start and end handles, like QuickTime)

final class TrimBarView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
    private let accent = MontageStyle.handle

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
        MontageStyle.field.setFill()
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
            MontageStyle.accent.withAlphaComponent(0.25).setFill()
            r.fill()
            let border = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            MontageStyle.accent.setStroke()
            border.stroke()
            // Small dots at both ends of the selected piece
            MontageStyle.ink.setFill()
            for dx in [r.minX + 1, r.maxX - 1] {
                NSBezierPath(ovalIn: NSRect(x: dx - 3, y: r.midY - 3, width: 6, height: 6)).fill()
            }
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
