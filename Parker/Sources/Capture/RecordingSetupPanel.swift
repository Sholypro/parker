import Cocoa
import AVFoundation

/// Bar shown after choosing what to record, before the recording starts (CleanShot / Loom style):
/// pick the camera (the bubble is the live preview), the microphone (a level meter shows it hears
/// you), the Mac's sound, then Start. The bar belongs to Parker, so it never appears in the video.
final class RecordingSetupPanel: NSObject {
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    /// nil: no camera.
    var onCameraChange: ((AVCaptureDevice?) -> Void)?

    private var panel: NSPanel?
    private var cameraPopup: NSPopUpButton?
    private var micPopup: NSPopUpButton?
    private var systemAudioCheck: NSButton?
    private var meter: LevelMeterView?
    private let micMonitor = MicLevelMonitor()

    static var microphoneSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// `area`: what will be recorded, in Cocoa coordinates. The bar sits just below it.
    func show(near area: NSRect) {
        let width: CGFloat = 560
        let height: CGFloat = 96
        let center = NSPoint(x: area.midX, y: area.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? area

        var y = area.minY - height - 14
        if y < visible.minY + 8 {
            y = area.maxY + 14
            if y + height > visible.maxY - 8 {
                y = max(area.minY, visible.minY) + 24 // no room around: inside the area, at the bottom
            }
        }
        var x = area.midX - width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)

        let panel = SetupPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.blendingMode = .behindWindow
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        // Row 1: camera, microphone + level meter
        effect.addSubview(icon("video.fill", x: 14, y: 56))
        let camera = NSPopUpButton(frame: NSRect(x: 38, y: 51, width: 210, height: 28), pullsDown: false)
        camera.target = self
        camera.action = #selector(cameraChanged)
        camera.toolTip = "Caméra (la bulle sert d’aperçu)"
        effect.addSubview(camera)
        cameraPopup = camera

        effect.addSubview(icon("mic.fill", x: 264, y: 56))
        let mic = NSPopUpButton(frame: NSRect(x: 288, y: 51, width: 190, height: 28), pullsDown: false)
        mic.target = self
        mic.action = #selector(micChanged)
        effect.addSubview(mic)
        micPopup = mic

        let meter = LevelMeterView(frame: NSRect(x: 488, y: 61, width: 58, height: 8))
        meter.toolTip = "Niveau du micro"
        effect.addSubview(meter)
        self.meter = meter

        // Row 2: Mac sound, Cancel, Start
        let system = NSButton(checkboxWithTitle: "Son du Mac", target: self, action: #selector(systemAudioChanged))
        system.state = Defaults.shared.recordSystemAudio ? .on : .off
        system.frame = NSRect(x: 14, y: 16, width: 140, height: 22)
        system.toolTip = "Enregistrer aussi le son joué par le Mac (vidéo, musique, appel)"
        effect.addSubview(system)
        systemAudioCheck = system

        let hint = NSTextField(labelWithString: "Entrée pour démarrer, Échap pour annuler")
        hint.font = .systemFont(ofSize: 10, weight: .regular)
        hint.textColor = .white.withAlphaComponent(0.35)
        hint.frame = NSRect(x: 150, y: 19, width: 210, height: 14)
        effect.addSubview(hint)

        let cancel = NSButton(title: "Annuler", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .accessoryBarAction
        cancel.isBordered = false
        cancel.contentTintColor = .white.withAlphaComponent(0.6)
        cancel.font = .systemFont(ofSize: 12, weight: .medium)
        cancel.frame = NSRect(x: 362, y: 12, width: 70, height: 30)
        effect.addSubview(cancel)

        let start = NSButton(title: "Démarrer", target: self, action: #selector(startClicked))
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
        start.frame = NSRect(x: 438, y: 11, width: 108, height: 32)
        start.toolTip = "Lancer l’enregistrement (Entrée)"
        effect.addSubview(start)

        panel.contentView = effect
        self.panel = panel

        fillCameraMenu()
        fillMicMenu()

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }

        if Self.microphoneSupported, Defaults.shared.recordMicrophone,
           AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            startMeter()
        }
    }

    func close() {
        micMonitor.stop()
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
    }

    // MARK: - Menus

    private func fillCameraMenu() {
        guard let popup = cameraPopup else { return }
        popup.removeAllItems()
        popup.addItem(withTitle: "Pas de caméra")
        popup.lastItem?.representedObject = nil
        let cameras = CameraBubble.availableCameras()
        for device in cameras {
            popup.addItem(withTitle: device.localizedName)
            popup.lastItem?.representedObject = device.uniqueID
        }
        if Defaults.shared.recordWithCamera, let current = CameraBubble.preferredCamera(),
           let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == current.uniqueID }) {
            popup.selectItem(at: index)
        } else {
            popup.selectItem(at: 0)
        }
        popup.isEnabled = !cameras.isEmpty
        if cameras.isEmpty { popup.toolTip = "Aucune caméra trouvée" }
    }

    private func fillMicMenu() {
        guard let popup = micPopup else { return }
        popup.removeAllItems()
        popup.addItem(withTitle: "Pas de micro")
        popup.lastItem?.representedObject = nil
        guard Self.microphoneSupported else {
            popup.isEnabled = false
            popup.toolTip = "L’enregistrement du micro demande macOS 15 ou plus récent"
            return
        }
        let mics = MicLevelMonitor.availableMicrophones()
        for device in mics {
            popup.addItem(withTitle: device.localizedName)
            popup.lastItem?.representedObject = device.uniqueID
        }
        if Defaults.shared.recordMicrophone, let current = MicLevelMonitor.preferredMicrophone(),
           let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == current.uniqueID }) {
            popup.selectItem(at: index)
        } else {
            popup.selectItem(at: 0)
        }
        popup.toolTip = mics.isEmpty ? "Aucun micro trouvé" : "Micro enregistré avec la vidéo"
    }

    @objc private func cameraChanged() {
        guard let id = cameraPopup?.selectedItem?.representedObject as? String,
              let device = AVCaptureDevice(uniqueID: id) else {
            Defaults.shared.recordWithCamera = false
            onCameraChange?(nil)
            return
        }
        Defaults.shared.cameraID = id
        onCameraChange?(device)
    }

    @objc private func micChanged() {
        guard let id = micPopup?.selectedItem?.representedObject as? String else {
            Defaults.shared.recordMicrophone = false
            micMonitor.stop()
            meter?.level = 0
            return
        }
        Defaults.shared.microphoneID = id
        MicLevelMonitor.requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                Defaults.shared.recordMicrophone = false
                self.micPopup?.selectItem(at: 0)
                Toast.show(message: "Autorise Parker à utiliser le micro", style: .error, duration: 3)
                MicLevelMonitor.openMicrophonePrivacySettings()
                return
            }
            Defaults.shared.recordMicrophone = true
            self.startMeter()
        }
    }

    @objc private func systemAudioChanged() {
        Defaults.shared.recordSystemAudio = systemAudioCheck?.state == .on
    }

    @objc private func startClicked() { onStart?() }
    @objc private func cancelClicked() { onCancel?() }

    private func startMeter() {
        guard let device = MicLevelMonitor.preferredMicrophone() else { return }
        micMonitor.onLevel = { [weak self] level in self?.meter?.level = level }
        micMonitor.start(device: device)
    }

    private func icon(_ name: String, x: CGFloat, y: CGFloat) -> NSImageView {
        let view = NSImageView(frame: NSRect(x: x, y: y, width: 18, height: 18))
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        view.contentTintColor = .white.withAlphaComponent(0.7)
        return view
    }
}

private final class SetupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Microphone preview

/// Listens to a microphone only to show its level in the setup bar (nothing is recorded here).
final class MicLevelMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onLevel: ((CGFloat) -> Void)?
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "parker.mic.level")

    static func availableMicrophones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
    }

    static func preferredMicrophone() -> AVCaptureDevice? {
        if let id = Defaults.shared.microphoneID, let device = AVCaptureDevice(uniqueID: id) {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { done(granted) }
            }
        default:
            done(false)
        }
    }

    static func openMicrophonePrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func start(device: AVCaptureDevice) {
        stop()
        guard let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        self.session = session
        queue.async { session.startRunning() }
    }

    func stop() {
        guard let session else { return }
        self.session = nil
        queue.async { session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let channel = connection.audioChannels.first else { return }
        // averagePowerLevel is in dB (about -60 silent, 0 loudest)
        let db = CGFloat(channel.averagePowerLevel)
        let level = max(0, min(1, (db + 55) / 50))
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }
}

/// Small horizontal bar: green, then orange when loud.
final class LevelMeterView: NSView {
    var level: CGFloat = 0 {
        didSet {
            // Smooth fall, instant rise
            shown = level > shown ? level : shown * 0.8 + level * 0.2
            needsDisplay = true
        }
    }
    private var shown: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.white.withAlphaComponent(0.12).setFill()
        track.fill()
        guard shown > 0.01 else { return }
        let fill = NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * shown), height: bounds.height)
        let bar = NSBezierPath(roundedRect: fill, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (shown > 0.85 ? NSColor.systemOrange : NSColor.systemGreen).setFill()
        bar.fill()
    }
}
