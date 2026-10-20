import Cocoa
import AVFoundation
import ScreenCaptureKit
import ThinkingOrbsKit

class ScreenRecorder: NSObject {
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private let lock = NSLock()
    private var _isRecording = false
    private var _isPaused = false

    private var isRecording: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isRecording }
        set { lock.lock(); _isRecording = newValue; lock.unlock() }
    }
    private var isPaused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isPaused }
        set { lock.lock(); _isPaused = newValue; lock.unlock() }
    }

    // Timestamp remapping state
    private var firstSampleTime: CMTime?
    private var pauseBeginTime: CMTime?
    private var totalPausedCMTime: CMTime = .zero

    private var startTime: Date?
    private var totalPausedDuration: TimeInterval = 0
    private var pauseStartDate: Date?
    private var recordingURL: URL?
    private var toolbarWindow: NSWindow?
    private var pauseButton: NSButton?
    private var timerLabel: NSTextField?
    private var statusDot: NSView?
    private var statusLabel: NSTextField?
    private var updateTimer: Timer?
    private var borderWindow: NSWindow?
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var gifButton: NSButton?

    private var activeAreaSelector: AreaSelector?

    // Webcam bubble: a real window kept in the video (see makeFilter)
    private let cameraBubble = CameraBubble()
    private var bubbleWindowID: CGWindowID?
    private var cameraButton: NSButton?
    private var recordingDisplay: SCDisplay?
    private var recordingArea: NSRect = .zero   // Cocoa coordinates, where the bubble starts

    var onRecordingFinished: ((URL) -> Void)?

    func startFullscreen() {
        Task {
            do {
                var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = displayForMouseLocation(content.displays) else {
                    throw CaptureError.noDisplay
                }
                let cameraShown = await prepareCamera(display: display, cropRect: nil)
                if cameraShown {
                    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                }
                let filter = makeFilter(display: display, content: content)
                if cameraShown {
                    // With the camera: wait for the user to place it and press Start
                    await MainActor.run { self.showReadyBar(filter: filter, display: display, cropRect: nil) }
                } else {
                    try await startRecording(filter: filter, display: display)
                }
            } catch {
                NSLog("Recording failed: \(error)")
                await handleStartFailure()
            }
        }
    }

    func startArea() {
        let selector = AreaSelector { [weak self] result in
            self?.activeAreaSelector = nil
            guard let self = self else { return }
            switch result {
            case .success(let (rect, _)):
                Task {
                    do {
                        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                        guard let display = self.display(containing: rect, in: content.displays)
                                ?? self.displayForMouseLocation(content.displays) else {
                            throw CaptureError.noDisplay
                        }
                        let cameraShown = await self.prepareCamera(display: display, cropRect: rect)
                        if cameraShown {
                            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                        }
                        let filter = self.makeFilter(display: display, content: content)
                        if cameraShown {
                            await MainActor.run { self.showReadyBar(filter: filter, display: display, cropRect: rect) }
                        } else {
                            try await self.startRecording(filter: filter, display: display, cropRect: rect)
                        }
                    } catch {
                        NSLog("Area recording failed: \(error)")
                        await self.handleStartFailure()
                    }
                }
            case .failure:
                break
            }
        }
        activeAreaSelector = selector
        selector.show()
    }

    /// Excludes Parker's own application (toolbar, area border, toasts, thumbnails) from the video.
    /// `sharingType = .none` is ignored by ScreenCaptureKit on macOS 15+, so the filter is the only
    /// reliable way to keep these windows out of the recording (same approach as ScreenGrabber).
    /// The webcam bubble is the one Parker window kept in the video.
    private func makeFilter(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        let bubble = bubbleWindowID
        let kept = bubble == nil ? [] : content.windows.filter { $0.windowID == bubble }
        return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: kept)
    }

    // MARK: - Ready bar (camera on: the user places the bubble, then presses Start)

    private var readyWindow: NSPanel?
    private var readyLocalMonitor: Any?
    private var readyGlobalMonitor: Any?
    private var pendingStart: (() -> Void)?

    private func showReadyBar(filter: SCContentFilter, display: SCDisplay, cropRect: CGRect?) {
        if let crop = cropRect, borderWindow == nil {
            showAreaBorder(cgRect: crop)
        }
        pendingStart = { [weak self] in
            Task {
                guard let self = self else { return }
                do {
                    try await self.startRecording(filter: filter, display: display, cropRect: cropRect)
                } catch {
                    NSLog("Recording failed: \(error)")
                    await self.handleStartFailure()
                }
            }
        }

        let center = NSPoint(x: recordingArea.midX, y: recordingArea.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else { return }
        let width: CGFloat = 440
        let height: CGFloat = 56
        let panel = NSPanel(
            contentRect: NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height - 12, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.blendingMode = .behindWindow
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "Place ta caméra, puis lance l’enregistrement")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white.withAlphaComponent(0.8)
        label.frame = NSRect(x: 16, y: 19, width: 220, height: 18)
        label.lineBreakMode = .byTruncatingTail
        effect.addSubview(label)

        let cancel = NSButton(title: "Annuler", target: self, action: #selector(readyCancelClicked))
        cancel.bezelStyle = .accessoryBarAction
        cancel.isBordered = false
        cancel.contentTintColor = .white.withAlphaComponent(0.6)
        cancel.font = .systemFont(ofSize: 12, weight: .medium)
        cancel.frame = NSRect(x: 246, y: 14, width: 70, height: 28)
        cancel.toolTip = "Annuler (Échap)"
        effect.addSubview(cancel)

        let start = NSButton(title: "Démarrer", target: self, action: #selector(readyStartClicked))
        start.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        start.imagePosition = .imageLeading
        start.bezelStyle = .accessoryBarAction
        start.isBordered = false
        start.wantsLayer = true
        start.layer?.backgroundColor = NSColor.systemRed.cgColor
        start.layer?.cornerRadius = 8
        start.contentTintColor = .white
        start.attributedTitle = NSAttributedString(string: " Démarrer", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ])
        start.frame = NSRect(x: 322, y: 12, width: 104, height: 32)
        start.toolTip = "Lancer l’enregistrement (Entrée)"
        effect.addSubview(start)

        panel.contentView = effect
        panel.orderFrontRegardless()
        readyWindow = panel

        readyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.readyWindow != nil else { return event }
            switch event.keyCode {
            case 36, 76: self.readyStartClicked(); return nil   // Return / Enter
            case 53: self.readyCancelClicked(); return nil      // Escape
            default: return event
            }
        }
        readyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            DispatchQueue.main.async { self?.readyCancelClicked() }
        }
    }

    @objc private func readyStartClicked() {
        let start = pendingStart
        dismissReadyBar()
        start?()
    }

    @objc private func readyCancelClicked() {
        guard readyWindow != nil else { return }
        dismissReadyBar()
        borderWindow?.orderOut(nil)
        borderWindow = nil
        hideCamera()
    }

    private func dismissReadyBar() {
        pendingStart = nil
        readyWindow?.orderOut(nil)
        readyWindow = nil
        if let monitor = readyLocalMonitor { NSEvent.removeMonitor(monitor); readyLocalMonitor = nil }
        if let monitor = readyGlobalMonitor { NSEvent.removeMonitor(monitor); readyGlobalMonitor = nil }
    }

    // MARK: - Webcam bubble

    /// Remembers where the recording happens and, if the camera option is on, shows the bubble
    /// before the stream starts. Returns true when the bubble is on screen (content must be re-read).
    private func prepareCamera(display: SCDisplay, cropRect: CGRect?) async -> Bool {
        let area = await MainActor.run { () -> NSRect in
            let area = self.cocoaArea(display: display, cropRect: cropRect)
            self.recordingDisplay = display
            self.recordingArea = area
            return area
        }
        guard Defaults.shared.recordWithCamera else { return false }
        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.main.async {
                CameraBubble.requestAccess { continuation.resume(returning: $0) }
            }
        }
        guard granted else {
            await MainActor.run { self.reportCameraDenied() }
            return false
        }
        let shown = await MainActor.run { () -> Bool in
            guard self.cameraBubble.show(in: area) else {
                Toast.show(message: "Aucune caméra trouvée", style: .error)
                return false
            }
            self.bubbleWindowID = self.cameraBubble.windowID
            return true
        }
        if shown {
            // Let the window server list the new window before reading the shareable content
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return shown
    }

    private func cocoaArea(display: SCDisplay, cropRect: CGRect?) -> NSRect {
        if let crop = cropRect {
            let ph = NSScreen.primaryHeight
            return NSRect(x: crop.minX, y: ph - crop.maxY, width: crop.width, height: crop.height)
        }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? CGDirectDisplayID) == display.displayID }
        return (screen ?? NSScreen.main)?.frame ?? .zero
    }

    private func reportCameraDenied() {
        Toast.show(message: "Autorise Parker à utiliser la caméra", style: .error, duration: 3)
        CameraBubble.openCameraPrivacySettings()
    }

    /// Camera button / C key during a recording.
    private func toggleCamera() {
        guard isRecording else { return }
        if cameraBubble.isVisible {
            cameraBubble.hide()
            bubbleWindowID = nil
            Defaults.shared.recordWithCamera = false
            updateCameraButton()
            refreshStreamFilter()
            return
        }
        CameraBubble.requestAccess { [weak self] granted in
            guard let self = self, self.isRecording else { return }
            guard granted else { self.reportCameraDenied(); return }
            guard self.cameraBubble.show(in: self.recordingArea) else {
                Toast.show(message: "Aucune caméra trouvée", style: .error)
                return
            }
            self.bubbleWindowID = self.cameraBubble.windowID
            Defaults.shared.recordWithCamera = true
            self.updateCameraButton()
            self.refreshStreamFilter()
        }
    }

    /// Re-reads the windows on screen so the bubble enters (or leaves) the running video.
    private func refreshStreamFilter() {
        guard let stream = stream, let display = recordingDisplay else { return }
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            let filter = self.makeFilter(display: display, content: content)
            try? await stream.updateContentFilter(filter)
        }
    }

    private func updateCameraButton() {
        let on = cameraBubble.isVisible
        cameraButton?.contentTintColor = on ? .systemBlue : .white.withAlphaComponent(0.5)
        cameraButton?.toolTip = on ? "Masquer la caméra" : "Afficher la caméra"
    }

    private func hideCamera() {
        cameraBubble.hide()
        bubbleWindowID = nil
        recordingDisplay = nil
    }

    /// Cleans up a half-started recording and tells the user why nothing happens.
    @MainActor
    private func handleStartFailure() {
        if let stream = stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        isRecording = false
        isPaused = false
        if let writer = assetWriter {
            if writer.status == .writing {
                writer.cancelWriting()
            }
            // Only remove the file this writer created (empty or partial).
            try? FileManager.default.removeItem(at: writer.outputURL)
        }
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        recordingURL = nil

        hideCamera()
        Toast.show(message: "Impossible de lancer l'enregistrement", style: .error)
        if !CGPreflightScreenCaptureAccess() {
            PermissionAssistant.shared.show()
        }
    }

    /// Display holding the center of a rect given in CG global coordinates.
    private func display(containing cgRect: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
        let center = CGPoint(x: cgRect.midX, y: cgRect.midY)
        return displays.first(where: { $0.frame.contains(center) })
    }

    /// Video size in pixels: the display's real pixel density (1x on most ultra-wide monitors,
    /// 2x on Retina) instead of a fixed 2x, kept within the H.264 limit (4096 x 2304) and even.
    private static func videoSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        var width = points.width * scale
        var height = points.height * scale
        let fit = min(1, 4096 / max(width, 1), 2304 / max(height, 1))
        width *= fit
        height *= fit
        return (max(2, Int(width) & ~1), max(2, Int(height) & ~1))
    }

    private func displayForMouseLocation(_ displays: [SCDisplay]) -> SCDisplay? {
        let mouse = NSEvent.mouseLocation
        let ph = NSScreen.primaryHeight
        // Convert NS mouse to CG coords for comparison with SCDisplay frames (CG coords)
        let cgMouse = CGPoint(x: mouse.x, y: ph - mouse.y)
        for d in displays {
            let frame = CGRect(x: CGFloat(d.frame.origin.x),
                               y: CGFloat(d.frame.origin.y),
                               width: CGFloat(d.width),
                               height: CGFloat(d.height))
            if frame.contains(cgMouse) { return d }
        }
        return displays.first
    }

    private func startRecording(filter: SCContentFilter, display: SCDisplay, cropRect: CGRect? = nil) async throws {
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true

        if let crop = cropRect {
            // cropRect is in CG global coords; sourceRect needs display-relative coords
            let displayOrigin = CGPoint(x: CGFloat(display.frame.origin.x),
                                        y: CGFloat(display.frame.origin.y))
            let sourceRect = CGRect(
                x: crop.origin.x - displayOrigin.x,
                y: crop.origin.y - displayOrigin.y,
                width: crop.width,
                height: crop.height
            )
            config.sourceRect = sourceRect
            let size = Self.videoSize(points: crop.size, scale: CGFloat(filter.pointPixelScale))
            config.width = size.width
            config.height = size.height
        } else {
            let size = Self.videoSize(points: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))
            config.width = size.width
            config.height = size.height
        }

        // Enable system audio capture
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        let recFormatter = DateFormatter()
        recFormatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        let filename = "Recording \(recFormatter.string(from: Date()))"
        let url = Defaults.shared.captureDirectory.appendingPathComponent("\(filename).mp4")
        recordingURL = url

        let writer = try AVAssetWriter(url: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        writer.add(vInput)
        self.videoInput = vInput

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000,
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aInput.expectsMediaDataInRealTime = true
        writer.add(aInput)
        self.audioInput = aInput

        self.assetWriter = writer

        writer.startWriting()

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()

        self.stream = stream
        self.isRecording = true
        self.isPaused = false
        self.startTime = Date()
        self.totalPausedDuration = 0
        self.pauseStartDate = nil
        self.firstSampleTime = nil
        self.pauseBeginTime = nil
        self.totalPausedCMTime = .zero

        let areaRect = cropRect
        await MainActor.run {
            showRecordingToolbar()
            if let rect = areaRect, borderWindow == nil {
                showAreaBorder(cgRect: rect)
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        if let pauseStart = pauseStartDate {
            totalPausedDuration += Date().timeIntervalSince(pauseStart)
            pauseStartDate = nil
        }

        Task {
            try? await stream?.stopCapture()
            stream = nil

            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            await assetWriter?.finishWriting()

            await MainActor.run {
                dismissToolbar()
                if let url = recordingURL {
                    Defaults.shared.addRecentCapture(url)
                    onRecordingFinished?(url)
                }
            }
        }
    }

    func togglePause() {
        if isPaused {
            if let pauseStart = pauseStartDate {
                totalPausedDuration += Date().timeIntervalSince(pauseStart)
                pauseStartDate = nil
            }
            isPaused = false
            DispatchQueue.main.async {
                self.pauseButton?.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Mettre en pause")
                self.pauseButton?.contentTintColor = .white.withAlphaComponent(0.85)
                self.statusLabel?.stringValue = "En cours"
                self.statusDot?.layer?.backgroundColor = NSColor.systemRed.cgColor
                self.resumeDotPulse()
            }
        } else {
            pauseStartDate = Date()
            isPaused = true
            DispatchQueue.main.async {
                self.pauseButton?.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Reprendre")
                self.pauseButton?.contentTintColor = .systemGreen
                self.statusLabel?.stringValue = "En pause"
                self.statusDot?.layer?.removeAnimation(forKey: "pulse")
                self.statusDot?.layer?.backgroundColor = NSColor.systemYellow.cgColor
                self.statusDot?.layer?.opacity = 1.0
            }
        }
    }

    // MARK: - Recording Toolbar

    private func showRecordingToolbar() {
        let screen = screenForMouseLocation() ?? NSScreen.main
        guard let screen = screen else { return }

        let toolbarWidth: CGFloat = 388
        let toolbarHeight: CGFloat = 64

        let window = NSWindow(
            contentRect: NSRect(
                x: screen.frame.midX - toolbarWidth / 2,
                y: screen.frame.maxY - toolbarHeight - 12,
                width: toolbarWidth,
                height: toolbarHeight
            ),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.sharingType = .none

        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: NSSize(width: toolbarWidth, height: toolbarHeight)))
        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 14
        effectView.layer?.masksToBounds = true

        var x: CGFloat = 16

        // Recording status dot
        let dot = NSView(frame: NSRect(x: x, y: 30, width: 10, height: 10))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        effectView.addSubview(dot)
        statusDot = dot
        resumeDotPulse()
        x += 16

        // Status label
        let status = NSTextField(labelWithString: "En cours")
        status.textColor = .white.withAlphaComponent(0.6)
        status.font = .systemFont(ofSize: 10, weight: .medium)
        status.frame = NSRect(x: x, y: 38, width: 70, height: 14)
        effectView.addSubview(status)
        statusLabel = status

        // Timer
        let timer = NSTextField(labelWithString: "00:00")
        timer.textColor = .white
        timer.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        timer.frame = NSRect(x: x, y: 18, width: 70, height: 20)
        effectView.addSubview(timer)
        timerLabel = timer
        x += 76

        // Divider
        addDivider(to: effectView, x: x)
        x += 13

        // Pause button + shortcut
        let pauseBtn = makeToolbarButton(
            icon: "pause.fill", tooltip: "Mettre en pause",
            action: #selector(pauseClicked), tint: .white.withAlphaComponent(0.85)
        )
        let pauseCol = makeButtonColumn(button: pauseBtn, shortcut: "P", x: x)
        effectView.addSubview(pauseCol)
        pauseButton = pauseBtn
        x += 48

        // Stop button + shortcut
        let stopBtn = makeToolbarButton(
            icon: "stop.fill", tooltip: "Arrêter l'enregistrement",
            action: #selector(stopClicked), tint: .systemRed
        )
        let stopCol = makeButtonColumn(button: stopBtn, shortcut: "S", x: x)
        effectView.addSubview(stopCol)
        x += 48

        // Divider
        addDivider(to: effectView, x: x)
        x += 13

        // GIF toggle + shortcut
        let gifBtn = makeToolbarButton(
            icon: "photo.badge.arrow.down", tooltip: "Exporter en GIF (activer ou désactiver)",
            action: #selector(exportGIFClicked), tint: .white.withAlphaComponent(0.5)
        )
        gifButton = gifBtn
        let gifCol = makeButtonColumn(button: gifBtn, shortcut: "G", x: x)
        effectView.addSubview(gifCol)
        x += 48

        // Webcam bubble toggle + shortcut
        let cameraBtn = makeToolbarButton(
            icon: "video.circle", tooltip: "Afficher la caméra",
            action: #selector(cameraClicked), tint: .white.withAlphaComponent(0.5)
        )
        cameraButton = cameraBtn
        let cameraCol = makeButtonColumn(button: cameraBtn, shortcut: "C", x: x)
        effectView.addSubview(cameraCol)
        updateCameraButton()

        window.contentView = effectView

        window.alphaValue = 0
        window.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            window.animator().alphaValue = 1.0
        }
        toolbarWindow = window

        // Global key monitor for hotkeys
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isRecording else { return event }
            let char = event.charactersIgnoringModifiers?.lowercased()
            if char == "p" {
                self.togglePause()
                return nil
            }
            if char == "s" || event.keyCode == 53 { // S or Escape
                self.stopClicked()
                return nil
            }
            if char == "g" {
                self.exportGIFClicked()
                return nil
            }
            if char == "c" {
                self.toggleCamera()
                return nil
            }
            return event
        }

        // The local monitor only sees keys while Parker is active. During a recording the user is
        // usually in another app, so Escape is also watched globally (needs the Accessibility
        // permission to receive events; without it this monitor stays silent).
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isRecording, event.keyCode == 53 else { return }
            DispatchQueue.main.async {
                self.stopClicked()
            }
        }

        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self, self.isRecording, let start = self.startTime else {
                timer.invalidate()
                return
            }
            let totalElapsed = Date().timeIntervalSince(start)
            let currentPauseDuration = self.isPaused ? Date().timeIntervalSince(self.pauseStartDate ?? Date()) : 0
            let activeTime = Int(totalElapsed - self.totalPausedDuration - currentPauseDuration)
            let minutes = max(0, activeTime) / 60
            let seconds = max(0, activeTime) % 60
            DispatchQueue.main.async {
                self.timerLabel?.stringValue = String(format: "%02d:%02d", minutes, seconds)
            }
        }
    }

    private func makeToolbarButton(icon: String, tooltip: String, action: Selector, tint: NSColor) -> NSButton {
        let btn = NSButton(frame: NSRect(x: 4, y: 16, width: 36, height: 36))
        btn.bezelStyle = .accessoryBarAction
        btn.isBordered = false
        btn.imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: tooltip)?.withSymbolConfiguration(config)
        btn.contentTintColor = tint
        btn.toolTip = tooltip
        btn.target = self
        btn.action = action
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 8
        return btn
    }

    private func makeButtonColumn(button: NSButton, shortcut: String, x: CGFloat) -> NSView {
        let col = NSView(frame: NSRect(x: x, y: 0, width: 44, height: 64))

        button.frame = NSRect(x: 4, y: 18, width: 36, height: 36)
        col.addSubview(button)

        let label = NSTextField(labelWithString: shortcut)
        label.font = .systemFont(ofSize: 9, weight: .medium)
        label.textColor = .white.withAlphaComponent(0.3)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 4, width: 44, height: 12)
        col.addSubview(label)

        return col
    }

    private func addDivider(to view: NSView, x: CGFloat) {
        let div = NSView(frame: NSRect(x: x, y: 16, width: 1, height: 32))
        div.wantsLayer = true
        div.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        view.addSubview(div)
    }

    private func resumeDotPulse() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        statusDot?.layer?.add(pulse, forKey: "pulse")
    }

    private func dismissToolbar() {
        updateTimer?.invalidate()
        updateTimer = nil
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
        toolbarWindow?.orderOut(nil)
        toolbarWindow = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil
        hideCamera()
        cameraButton = nil
        pauseButton = nil
        gifButton = nil
        timerLabel = nil
        statusDot = nil
        statusLabel = nil
    }

    private func showAreaBorder(cgRect: CGRect) {
        // Convert CG rect to NS screen coordinates
        let ph = NSScreen.primaryHeight
        let nsRect = NSRect(
            x: cgRect.origin.x,
            y: ph - cgRect.origin.y - cgRect.height,
            width: cgRect.width,
            height: cgRect.height
        )

        let center = NSPoint(x: nsRect.midX, y: nsRect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                ?? NSScreen.screens.first(where: { $0.frame.intersects(nsRect) })
                ?? NSScreen.main else { return }

        // No `screen:` argument here: with it, AppKit reads contentRect relative to that screen's
        // origin, which shifted the whole overlay on any display that is not the main one.
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
        window.sharingType = .none  // Don't appear in the recording

        let localRect = NSRect(
            x: nsRect.origin.x - screen.frame.origin.x,
            y: nsRect.origin.y - screen.frame.origin.y,
            width: nsRect.width,
            height: nsRect.height
        )

        let borderView = RecordingBorderView(frame: NSRect(origin: .zero, size: screen.frame.size), recordingRect: localRect)
        window.contentView = borderView
        window.orderFront(nil)
        self.borderWindow = window
    }

    private func screenForMouseLocation() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) })
    }

    private var shouldExportGIF = false

    @objc private func pauseClicked() { togglePause() }
    @objc private func stopClicked() {
        if shouldExportGIF {
            stopAndExportGIF()
        } else {
            stopRecording()
        }
    }
    @objc private func cameraClicked() { toggleCamera() }
    @objc private func exportGIFClicked() {
        shouldExportGIF.toggle()
        gifButton?.contentTintColor = shouldExportGIF ? .systemPurple : .white.withAlphaComponent(0.5)
        Toast.show(message: shouldExportGIF ? "Export en GIF à l'arrêt" : "Enregistrement en MP4", style: .info)
    }

    private func stopAndExportGIF() {
        guard isRecording else { return }
        isRecording = false
        shouldExportGIF = false

        Task {
            try? await stream?.stopCapture()
            stream = nil

            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            await assetWriter?.finishWriting()

            await MainActor.run {
                dismissToolbar()

                guard let url = recordingURL else {
                    Toast.show(message: "Échec de l'export GIF", style: .error)
                    return
                }

                Toast.showActivity(message: "Conversion en GIF…", state: .working)
                let maxW = Defaults.shared.gifMaxWidth
                let fps = Defaults.shared.gifFrameRate
                GIFExporter.exportToGIF(videoURL: url, maxWidth: maxW, fps: fps) { [weak self] result in
                    switch result {
                    case .success(let gifURL):
                        Defaults.shared.addRecentCapture(gifURL)
                        Toast.show(message: "GIF enregistré : \(gifURL.lastPathComponent)")
                        self?.onRecordingFinished?(gifURL)
                    case .failure:
                        Toast.show(message: "Échec de l'export GIF", style: .error)
                        Defaults.shared.addRecentCapture(url)
                        self?.onRecordingFinished?(url)
                    }
                }
            }
        }
    }
}

// MARK: - Recording area border overlay

private class RecordingBorderView: NSView {
    let recordingRect: NSRect

    init(frame: NSRect, recordingRect: NSRect) {
        self.recordingRect = recordingRect
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Dim area outside recording region
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)

        // Top
        context.fill(NSRect(x: 0, y: recordingRect.maxY, width: bounds.width, height: bounds.height - recordingRect.maxY))
        // Bottom
        context.fill(NSRect(x: 0, y: 0, width: bounds.width, height: recordingRect.origin.y))
        // Left
        context.fill(NSRect(x: 0, y: recordingRect.origin.y, width: recordingRect.origin.x, height: recordingRect.height))
        // Right
        context.fill(NSRect(x: recordingRect.maxX, y: recordingRect.origin.y, width: bounds.width - recordingRect.maxX, height: recordingRect.height))

        context.restoreGState()

        // Red border around recording area
        context.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(2)
        context.stroke(recordingRect.insetBy(dx: -1, dy: -1))

        // Corner brackets for visual clarity
        let bracketLen: CGFloat = 16
        let r = recordingRect
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(3)

        // Top-left
        context.move(to: CGPoint(x: r.minX, y: r.maxY - bracketLen))
        context.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        context.addLine(to: CGPoint(x: r.minX + bracketLen, y: r.maxY))
        context.strokePath()

        // Top-right
        context.move(to: CGPoint(x: r.maxX - bracketLen, y: r.maxY))
        context.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        context.addLine(to: CGPoint(x: r.maxX, y: r.maxY - bracketLen))
        context.strokePath()

        // Bottom-left
        context.move(to: CGPoint(x: r.minX, y: r.minY + bracketLen))
        context.addLine(to: CGPoint(x: r.minX, y: r.minY))
        context.addLine(to: CGPoint(x: r.minX + bracketLen, y: r.minY))
        context.strokePath()

        // Bottom-right
        context.move(to: CGPoint(x: r.maxX - bracketLen, y: r.minY))
        context.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        context.addLine(to: CGPoint(x: r.maxX, y: r.minY + bracketLen))
        context.strokePath()
    }
}

extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isRecording, sampleBuffer.isValid else { return }

        // Only complete screen frames carry new pixels. Idle/blank/suspended frames have no
        // image buffer and would make the writer fail (same check as ScrollFrameSource).
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRaw),
                  status == .complete,
                  sampleBuffer.imageBuffer != nil
            else { return }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if firstSampleTime == nil {
            firstSampleTime = pts
            assetWriter?.startSession(atSourceTime: .zero)
        }

        if isPaused {
            if pauseBeginTime == nil {
                pauseBeginTime = pts
            }
            return
        }

        if let begin = pauseBeginTime {
            let gap = CMTimeSubtract(pts, begin)
            totalPausedCMTime = CMTimeAdd(totalPausedCMTime, gap)
            pauseBeginTime = nil
        }

        guard let first = firstSampleTime else { return }
        let remapped = CMTimeSubtract(CMTimeSubtract(pts, first), totalPausedCMTime)

        guard remapped.value >= 0 else { return }

        guard CMSampleBufferGetFormatDescription(sampleBuffer) != nil else { return }
        let timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: remapped,
            decodeTimeStamp: .invalid
        )

        switch type {
        case .screen:
            guard let videoInput = videoInput, videoInput.isReadyForMoreMediaData else { return }
            if let remappedBuffer = try? CMSampleBuffer(copying: sampleBuffer, withNewTiming: [timingInfo]) {
                videoInput.append(remappedBuffer)
            }
        case .audio:
            guard let audioInput = audioInput, audioInput.isReadyForMoreMediaData else { return }
            if let remappedBuffer = try? CMSampleBuffer(copying: sampleBuffer, withNewTiming: [timingInfo]) {
                audioInput.append(remappedBuffer)
            }
        case .microphone:
            guard let audioInput = audioInput, audioInput.isReadyForMoreMediaData else { return }
            if let remappedBuffer = try? CMSampleBuffer(copying: sampleBuffer, withNewTiming: [timingInfo]) {
                audioInput.append(remappedBuffer)
            }
        @unknown default:
            break
        }
    }
}
