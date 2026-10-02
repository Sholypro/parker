import Cocoa
import ApplicationServices

/// Scrolling capture, CleanShot style:
/// select an area, then either scroll yourself (the area is streamed at up to 30 fps and
/// stitched live) or press "Auto" to let the app scroll for you until the end of the page.
/// A live preview of the stitched result is shown next to the area.
/// If a scroll is too fast, the capture resumes by itself as soon as the view shows
/// something already captured (scrolling back up a little is enough).
class ScrollCapture {
    var completion: ((Result<URL, Error>) -> Void)?

    private var captureRect: CGRect = .zero   // global coordinates, top-left origin (points)
    private var nsRect: NSRect = .zero        // Cocoa coordinates, bottom-left origin
    private let stitcher = ScrollStitcher()
    private let workQueue = DispatchQueue(label: "parker.scroll.stitch", qos: .userInitiated)
    private var source: ScrollFrameSource?

    private var isCapturing = false
    private var isProcessing = false
    private var autoScrolling = false
    private var autoUnchangedCount = 0
    private var autoNoMatchCount = 0
    private var lastHeight = 0
    private var lastPreviewTime = Date.distantPast   // workQueue only
    private var recovering = false

    private var activeAreaSelector: AreaSelector?
    private var borderWindow: NSWindow?
    private var hudPanel: NSPanel?
    private var hudView: ScrollHUDView?
    private var previewPanel: NSPanel?
    private var previewView: ScrollPreviewView?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var warningResetWork: DispatchWorkItem?

    private let maxOutputHeight = 40_000
    private let autoSettleDelay: TimeInterval = 0.35
    private let previewInterval: TimeInterval = 0.25

    private var pixelScale: CGFloat { source?.pixelScale ?? 2 }

    // MARK: - Public

    func start(completion: @escaping (Result<URL, Error>) -> Void) {
        guard !isCapturing else { return }
        self.completion = completion

        let selector = AreaSelector { [weak self] result in
            guard let self = self else { return }
            self.activeAreaSelector = nil
            switch result {
            case .success(let (rect, _)):
                guard rect.width >= 40, rect.height >= 60 else {
                    completion(.failure(CaptureError.cancelled))
                    return
                }
                self.captureRect = rect.integral
                // Let the selection overlay disappear before the first frame
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.beginCapture()
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
        activeAreaSelector = selector
        selector.show()
    }

    // MARK: - Session

    private func beginCapture() {
        let ph = NSScreen.primaryHeight
        nsRect = NSRect(
            x: captureRect.minX,
            y: ph - captureRect.maxY,
            width: captureRect.width,
            height: captureRect.height
        )

        workQueue.sync {
            stitcher.reset()
            lastPreviewTime = .distantPast
        }
        isCapturing = true
        isProcessing = false
        autoScrolling = false
        autoUnchangedCount = 0
        autoNoMatchCount = 0
        lastHeight = 0
        recovering = false

        showBorderOverlay()
        showHUD()
        showPreview()
        installKeyMonitors()
        hudView?.setStatus("Fais défiler, ou lance l'auto-scroll", warning: false)

        let source = ScrollFrameSource(rect: captureRect)
        source.onFrame = { [weak self] in
            DispatchQueue.main.async { self?.processPendingFrames() }
        }
        self.source = source
        source.start { [weak self] ok in
            guard let self = self, self.isCapturing, !ok else { return }
            // The fallback still works, just with fewer frames per second
            if !CGPreflightScreenCaptureAccess() {
                ScreenGrabber.reportFailureIfNeeded()
            }
        }
    }

    /// Manual mode: stitches every frame received since the last pass.
    private func processPendingFrames() {
        guard isCapturing, !autoScrolling, !isProcessing, let source = source else { return }
        let frames = source.drain()
        guard !frames.isEmpty else { return }
        process(frames, expectedDelta: nil) { [weak self] _ in
            // Frames that arrived meanwhile
            self?.processPendingFrames()
        }
    }

    private func process(_ frames: [CGImage], expectedDelta: Int?, done: ((ScrollStitcher.AddResult) -> Void)?) {
        isProcessing = true
        workQueue.async { [weak self] in
            guard let self = self else { return }
            let result = self.stitcher.addBatch(frames, expectedDelta: expectedDelta)
            let height = self.stitcher.totalHeight
            var preview: CGImage?
            if result.grew, Date().timeIntervalSince(self.lastPreviewTime) >= self.previewInterval {
                preview = self.stitcher.compose(maxWidth: 340)
                self.lastPreviewTime = Date()
            }
            DispatchQueue.main.async {
                self.isProcessing = false
                guard self.isCapturing else { return }
                self.handle(result: result, height: height, preview: preview)
                done?(result)
            }
        }
    }

    private var normalStatus: String {
        autoScrolling ? "Auto-scroll en cours…" : "Capture en cours, continue de défiler"
    }

    private func handle(result: ScrollStitcher.AddResult, height: Int, preview: CGImage?) {
        lastHeight = height
        if let preview = preview {
            previewView?.image = preview
        }
        previewView?.heightText = "\(height) px"

        switch result {
        case .noMatch where !autoScrolling:
            recovering = true
            showWarning("Trop rapide : remonte un peu, la capture reprendra toute seule")
        case .repositioned where !autoScrolling:
            warningResetWork?.cancel()
            recovering = true
            hudView?.setStatus("Zone déjà capturée : redescends pour continuer", warning: false)
        case .appended:
            warningResetWork?.cancel()
            if recovering {
                recovering = false
                hudView?.setStatus("C'est reparti, continue de défiler", warning: false)
            } else if hudView?.isShowingWarning == true || hudView?.statusText != normalStatus {
                hudView?.setStatus(normalStatus, warning: false)
            }
        default:
            break
        }

        if height >= maxOutputHeight {
            hudView?.setStatus("Hauteur max atteinte", warning: true)
            finishCapture()
        }
    }

    private func showWarning(_ text: String) {
        hudView?.setStatus(text, warning: true)
        warningResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isCapturing else { return }
            self.hudView?.setStatus(self.autoScrolling ? "Auto-scroll en cours…" : "Remonte un peu pour reprendre la capture", warning: !self.autoScrolling)
        }
        warningResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: - Auto-scroll

    private func toggleAutoScroll() {
        guard isCapturing else { return }
        if autoScrolling {
            autoScrolling = false
            hudView?.setAuto(false)
            hudView?.setStatus("Auto-scroll en pause", warning: false)
            processPendingFrames()
            return
        }

        // Synthetic scroll events require Accessibility permission
        guard AXIsProcessTrusted() else {
            showWarning("Autorise Parker dans Accessibilité (fenêtre d'aide ouverte)")
            PermissionAssistant.shared.show()
            return
        }

        autoScrolling = true
        autoUnchangedCount = 0
        autoNoMatchCount = 0
        recovering = false
        hudView?.setAuto(true)
        hudView?.setStatus("Auto-scroll en cours…", warning: false)

        // Put the cursor over the content so scroll events reach the right view
        let center = CGPoint(x: captureRect.midX, y: captureRect.midY)
        CGWarpMouseCursorPosition(center)
        CGAssociateMouseAndMouseCursorPosition(1)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.autoStep()
        }
    }

    private func autoStep() {
        guard isCapturing, autoScrolling else { return }

        let amount = max(40, Int(captureRect.height * 0.5))
        postScroll(points: amount)

        DispatchQueue.main.asyncAfter(deadline: .now() + autoSettleDelay) { [weak self] in
            guard let self = self, self.isCapturing, self.autoScrolling else { return }
            let expected = Int((CGFloat(amount) * self.pixelScale).rounded())
            self.autoProcess(expectedDelta: expected) { [weak self] result in
                guard let self = self, self.isCapturing, self.autoScrolling else { return }
                switch result {
                case .unchanged:
                    self.autoUnchangedCount += 1
                    self.autoNoMatchCount = 0
                case .noMatch:
                    self.autoNoMatchCount += 1
                default:
                    self.autoUnchangedCount = 0
                    self.autoNoMatchCount = 0
                }

                if self.autoUnchangedCount >= 2 {
                    // Nothing moves anymore: end of the page
                    self.finishCapture()
                } else if self.autoNoMatchCount >= 3 {
                    self.autoScrolling = false
                    self.hudView?.setAuto(false)
                    self.showWarning("Auto-scroll arrêté : contenu impossible à raccorder")
                } else {
                    self.autoStep()
                }
            }
        }
    }

    private func autoProcess(expectedDelta: Int, done: @escaping (ScrollStitcher.AddResult) -> Void) {
        guard isCapturing, let source = source else { return }
        if isProcessing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.autoProcess(expectedDelta: expectedDelta, done: done)
            }
            return
        }
        var frames = source.drain()
        if frames.isEmpty, let latest = source.latestFrame {
            // The stream only sends frames when something changes: nothing new means nothing moved
            frames = [latest]
        }
        guard !frames.isEmpty else {
            done(.noMatch)
            return
        }
        process(frames, expectedDelta: expectedDelta, done: done)
    }

    private func postScroll(points: Int) {
        let location = CGPoint(x: captureRect.midX, y: captureRect.midY)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(-points),
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.location = location
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Finish / Cancel

    private func finishCapture() {
        guard isCapturing else { return }
        isCapturing = false
        autoScrolling = false
        let source = self.source
        self.source = nil
        source?.stop()
        teardownUI()

        // Serial queue: runs after any batch still being stitched
        workQueue.async { [weak self] in
            guard let self = self else { return }
            var frames = source?.drain() ?? []
            if frames.isEmpty, let latest = source?.latestFrame { frames = [latest] }
            if !frames.isEmpty {
                _ = self.stitcher.addBatch(frames, expectedDelta: nil)
            }
            let result = self.stitcher.compose(maxWidth: nil)
            self.stitcher.reset()

            DispatchQueue.main.async {
                guard let image = result else {
                    self.completion?(.failure(CaptureError.captureFailed))
                    return
                }
                do {
                    let url = try ImageUtilities.save(image: image)
                    if Defaults.shared.copyToClipboard {
                        ImageUtilities.copyToClipboard(image: image)
                    }
                    if Defaults.shared.playSound {
                        NSSound(named: "Tink")?.play()
                    }
                    self.completion?(.success(url))
                } catch {
                    self.completion?(.failure(error))
                }
            }
        }
    }

    private func cancelCapture() {
        guard isCapturing else { return }
        isCapturing = false
        autoScrolling = false
        source?.stop()
        source = nil
        teardownUI()
        workQueue.async { [weak self] in self?.stitcher.reset() }
        completion?(.failure(CaptureError.cancelled))
    }

    private func teardownUI() {
        warningResetWork?.cancel()
        warningResetWork = nil
        hudPanel?.orderOut(nil)
        hudPanel = nil
        hudView = nil
        previewPanel?.orderOut(nil)
        previewPanel = nil
        previewView = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
    }

    private func installKeyMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isCapturing else { return event }
            switch event.keyCode {
            case 53: self.cancelCapture(); return nil          // Esc
            case 36, 76: self.finishCapture(); return nil      // Return / Enter
            default: return event
            }
        }
        // Esc also works while the scrolled app is frontmost (needs Accessibility)
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isCapturing else { return }
            if event.keyCode == 53 {
                DispatchQueue.main.async { self.cancelCapture() }
            }
        }
    }

    // MARK: - UI

    private var targetScreen: NSScreen? {
        let center = NSPoint(x: nsRect.midX, y: nsRect.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
    }

    private func makePanel(frame: NSRect) -> NSPanel {
        let panel = ScrollHUDPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.sharingType = .none  // never captured
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func showBorderOverlay() {
        guard let screen = targetScreen else { return }
        let localRect = NSRect(
            x: nsRect.origin.x - screen.frame.origin.x,
            y: nsRect.origin.y - screen.frame.origin.y,
            width: nsRect.width,
            height: nsRect.height
        )

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.setFrame(screen.frame, display: false)
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = ScrollBorderView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            highlightRect: localRect
        )
        window.orderFront(nil)
        borderWindow = window
    }

    private func showHUD() {
        guard let screen = targetScreen else { return }
        let size = NSSize(width: 420, height: 46)
        let gap: CGFloat = 12
        let visible = screen.visibleFrame

        var x = nsRect.midX - size.width / 2
        var y = nsRect.minY - size.height - gap
        if y < visible.minY + 8 {
            y = nsRect.maxY + gap
            if y + size.height > visible.maxY - 8 {
                // Area covers the whole screen: float inside, at the bottom (excluded from capture anyway)
                y = nsRect.minY + 24
            }
        }
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))

        let panel = makePanel(frame: NSRect(origin: NSPoint(x: x, y: y), size: size))
        let view = ScrollHUDView(frame: NSRect(origin: .zero, size: size))
        view.onAuto = { [weak self] in self?.toggleAutoScroll() }
        view.onDone = { [weak self] in self?.finishCapture() }
        view.onCancel = { [weak self] in self?.cancelCapture() }
        panel.contentView = view
        panel.orderFrontRegardless()
        hudPanel = panel
        hudView = view
    }

    private func showPreview() {
        guard let screen = targetScreen else { return }
        let visible = screen.visibleFrame
        let width: CGFloat = 170
        let height: CGFloat = min(max(nsRect.height, 200), 440)
        let gap: CGFloat = 14

        var x: CGFloat
        if visible.maxX - nsRect.maxX >= width + gap + 8 {
            x = nsRect.maxX + gap
        } else if nsRect.minX - visible.minX >= width + gap + 8 {
            x = nsRect.minX - width - gap
        } else {
            x = nsRect.maxX - width - 16  // inside the area, top-right
        }
        var y = nsRect.maxY - height
        y = max(visible.minY + 8, min(y, visible.maxY - height - 8))
        x = max(visible.minX + 8, min(x, visible.maxX - width - 8))

        let panel = makePanel(frame: NSRect(x: x, y: y, width: width, height: height))
        panel.ignoresMouseEvents = true
        let view = ScrollPreviewView(frame: NSRect(origin: .zero, size: NSSize(width: width, height: height)))
        panel.contentView = view
        panel.orderFrontRegardless()
        previewPanel = panel
        previewView = view
    }
}

// MARK: - Panel that can take clicks without activating the app

private final class ScrollHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Border overlay

private final class ScrollBorderView: NSView {
    let highlightRect: NSRect

    init(frame: NSRect, highlightRect: NSRect) {
        self.highlightRect = highlightRect
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Drawn strictly outside the captured area
        let outer = highlightRect.insetBy(dx: -3, dy: -3)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2)
        context.setLineDash(phase: 0, lengths: [7, 4])
        context.stroke(outer)
    }
}

// MARK: - HUD

private final class ScrollHUDView: NSView {
    var onAuto: (() -> Void)?
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    private(set) var isShowingWarning = false
    var statusText: String { statusLabel.stringValue }

    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let autoButton = FirstMouseButton()
    private let doneButton = FirstMouseButton()
    private let cancelButton = FirstMouseButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        let bg = NSVisualEffectView(frame: bounds)
        bg.blendingMode = .behindWindow
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]
        addSubview(bg)

        let h = bounds.height
        let btnH: CGFloat = 28
        let btnY = (h - btnH) / 2

        cancelButton.frame = NSRect(x: bounds.width - 8 - 30, y: btnY, width: 30, height: btnH)
        cancelButton.bezelStyle = .accessoryBarAction
        cancelButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Annuler")
        cancelButton.imagePosition = .imageOnly
        cancelButton.toolTip = "Annuler (Esc)"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        addSubview(cancelButton)

        doneButton.frame = NSRect(x: cancelButton.frame.minX - 6 - 92, y: btnY, width: 92, height: btnH)
        doneButton.bezelStyle = .rounded
        doneButton.title = "Terminer"
        doneButton.font = .systemFont(ofSize: 12, weight: .semibold)
        doneButton.keyEquivalent = "\r"
        doneButton.toolTip = "Terminer et enregistrer (Entrée)"
        doneButton.target = self
        doneButton.action = #selector(doneClicked)
        addSubview(doneButton)

        autoButton.frame = NSRect(x: doneButton.frame.minX - 6 - 74, y: btnY, width: 74, height: btnH)
        autoButton.bezelStyle = .rounded
        autoButton.title = "Auto"
        autoButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Auto-scroll")
        autoButton.imagePosition = .imageLeading
        autoButton.font = .systemFont(ofSize: 12, weight: .medium)
        autoButton.toolTip = "Défilement automatique jusqu'en bas de la page"
        autoButton.target = self
        autoButton.action = #selector(autoClicked)
        addSubview(autoButton)

        statusIcon.frame = NSRect(x: 12, y: (h - 16) / 2, width: 16, height: 16)
        statusIcon.image = NSImage(systemSymbolName: "arrow.up.and.down.text.horizontal", accessibilityDescription: nil)
        statusIcon.contentTintColor = .secondaryLabelColor
        addSubview(statusIcon)

        statusLabel.frame = NSRect(x: 34, y: (h - 30) / 2, width: autoButton.frame.minX - 40, height: 30)
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .labelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.cell?.wraps = true
        addSubview(statusLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func setStatus(_ text: String, warning: Bool) {
        isShowingWarning = warning
        statusLabel.stringValue = text
        statusLabel.textColor = warning ? .systemOrange : .labelColor
        statusIcon.image = NSImage(
            systemSymbolName: warning ? "exclamationmark.triangle.fill" : "arrow.up.and.down.text.horizontal",
            accessibilityDescription: nil
        )
        statusIcon.contentTintColor = warning ? .systemOrange : .secondaryLabelColor
    }

    func setAuto(_ on: Bool) {
        autoButton.title = on ? "Pause" : "Auto"
        autoButton.image = NSImage(systemSymbolName: on ? "pause.fill" : "play.fill", accessibilityDescription: nil)
    }

    @objc private func autoClicked() { onAuto?() }
    @objc private func doneClicked() { onDone?() }
    @objc private func cancelClicked() { onCancel?() }
}

// MARK: - Live preview

private final class ScrollPreviewView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var heightText: String = "" { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(white: 0.1, alpha: 0.92).setFill()
        bounds.fill()

        let inset: CGFloat = 8
        let labelH: CGFloat = 22
        let area = NSRect(x: inset, y: inset, width: bounds.width - inset * 2, height: bounds.height - inset * 2 - labelH)

        if let image = image, image.width > 0 {
            let scale = area.width / CGFloat(image.width)
            let drawH = CGFloat(image.height) * scale
            ctx.saveGState()
            ctx.clip(to: area)
            // Short image: pinned to the top. Tall image: show the most recent (bottom) part.
            let y = drawH <= area.height ? area.maxY - drawH : area.minY
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: area.minX, y: y, width: area.width, height: drawH))
            ctx.restoreGState()
        } else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let text = "Aperçu" as NSString
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2), withAttributes: attrs)
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let text = (heightText.isEmpty ? "0 px" : heightText) as NSString
        text.draw(at: NSPoint(x: inset + 2, y: bounds.height - labelH + 3), withAttributes: attrs)
    }
}
