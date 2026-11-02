import Cocoa
import AVFoundation

/// Bar shown after choosing what to record, before the recording starts (Screen Studio style):
/// a big Start button, then a camera tile and a microphone tile, each with an On/Off switch.
/// The bubble is the live camera preview; the microphone tile fills up with your voice level.
/// Clicking a tile lists the devices. The bar belongs to Parker, so it never appears in the video.
final class RecordingSetupPanel: NSObject {
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    /// nil: no camera.
    var onCameraChange: ((AVCaptureDevice?) -> Void)?

    private var panel: NSPanel?
    private var cameraTile: DeviceTile?
    private var micTile: DeviceTile?
    private var soundButton: RoundIconButton?
    private let micMonitor = MicLevelMonitor()

    static var microphoneSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    private static let width: CGFloat = 520
    private static let cardHeight: CGFloat = 76
    private static let gap: CGFloat = 10

    /// `area`: what will be recorded, in Cocoa coordinates. The bar sits just below it.
    func show(near area: NSRect) {
        let width = Self.width
        let height = Self.cardHeight * 2 + Self.gap
        let center = NSPoint(x: area.midX, y: area.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? area

        var y = area.minY - height - 14
        if y < visible.minY + 8 {
            y = area.maxY + 14
            if y + height > visible.maxY - 8 {
                y = max(area.minY, visible.minY) + 32 // no room around: inside the area, at the bottom
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

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // Top card: close, Start, Mac sound
        let top = Self.card(frame: NSRect(x: 0, y: Self.cardHeight + Self.gap, width: width, height: Self.cardHeight))
        root.addSubview(top)

        let close = RoundIconButton(frame: NSRect(x: 14, y: 14, width: 48, height: 48), symbol: "xmark", light: true)
        close.toolTip = "Annuler (Échap)"
        close.onClick = { [weak self] in self?.onCancel?() }
        top.addSubview(close)

        let start = StartButton(frame: NSRect(x: 74, y: 12, width: width - 148, height: 52))
        start.onClick = { [weak self] in self?.onStart?() }
        top.addSubview(start)

        let sound = RoundIconButton(frame: NSRect(x: width - 62, y: 14, width: 48, height: 48), symbol: "speaker.wave.2.fill", light: false)
        sound.onClick = { [weak self] in self?.toggleSystemAudio() }
        top.addSubview(sound)
        soundButton = sound
        updateSoundButton()

        // Bottom card: camera and microphone tiles
        let bottom = Self.card(frame: NSRect(x: 0, y: 0, width: width, height: Self.cardHeight))
        root.addSubview(bottom)
        let tileWidth = (width - 28 - 10) / 2

        let camera = DeviceTile(frame: NSRect(x: 14, y: 14, width: tileWidth, height: 48), symbol: "video")
        camera.onToggle = { [weak self] in self?.toggleCamera() }
        camera.onPick = { [weak self] in self?.showCameraMenu() }
        bottom.addSubview(camera)
        cameraTile = camera

        let mic = DeviceTile(frame: NSRect(x: 24 + tileWidth, y: 14, width: tileWidth, height: 48), symbol: "mic")
        mic.onToggle = { [weak self] in self?.toggleMicrophone() }
        mic.onPick = { [weak self] in self?.showMicMenu() }
        bottom.addSubview(mic)
        micTile = mic

        panel.contentView = root
        self.panel = panel

        refreshCameraTile()
        refreshMicTile()

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }

        if micIsOn {
            startMeter()
        }
    }

    func close() {
        micMonitor.stop()
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
    }

    private static func card(frame: NSRect) -> NSView {
        let effect = NSVisualEffectView(frame: frame)
        effect.blendingMode = .behindWindow
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        let tint = NSView(frame: NSRect(origin: .zero, size: frame.size))
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.55).cgColor
        tint.autoresizingMask = [.width, .height]
        effect.addSubview(tint)
        return effect
    }

    // MARK: - Mac sound

    private func toggleSystemAudio() {
        Defaults.shared.recordSystemAudio.toggle()
        updateSoundButton()
        Toast.show(message: Defaults.shared.recordSystemAudio ? "Son du Mac enregistré" : "Son du Mac coupé", style: .info)
    }

    private func updateSoundButton() {
        let on = Defaults.shared.recordSystemAudio
        soundButton?.symbol = on ? "speaker.wave.2.fill" : "speaker.slash.fill"
        soundButton?.dimmed = !on
        soundButton?.toolTip = on ? "Son du Mac : enregistré (clic pour couper)" : "Son du Mac : coupé (clic pour l’enregistrer)"
    }

    // MARK: - Camera

    private var cameraIsOn: Bool { Defaults.shared.recordWithCamera && CameraBubble.preferredCamera() != nil }

    private func refreshCameraTile() {
        guard let tile = cameraTile else { return }
        let device = CameraBubble.preferredCamera()
        tile.title = device?.localizedName ?? "Aucune caméra"
        tile.isOn = cameraIsOn
        tile.isAvailable = device != nil
        tile.toolTip = "Caméra : la bulle sert d’aperçu. Clic pour choisir une autre caméra."
    }

    private func toggleCamera() {
        if cameraIsOn {
            Defaults.shared.recordWithCamera = false
            onCameraChange?(nil)
        } else if let device = CameraBubble.preferredCamera() {
            Defaults.shared.cameraID = device.uniqueID
            Defaults.shared.recordWithCamera = true
            onCameraChange?(device)
        }
        refreshCameraTile()
    }

    private func showCameraMenu() {
        let menu = NSMenu()
        let current = CameraBubble.preferredCamera()?.uniqueID
        for device in CameraBubble.availableCameras() {
            let item = NSMenuItem(title: device.localizedName, action: #selector(cameraPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uniqueID
            item.state = device.uniqueID == current ? .on : .off
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "Aucune caméra trouvée", action: nil, keyEquivalent: "")
        }
        cameraTile.map { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: $0.bounds.height + 4), in: $0) }
    }

    @objc private func cameraPicked(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let device = AVCaptureDevice(uniqueID: id) else { return }
        Defaults.shared.cameraID = id
        Defaults.shared.recordWithCamera = true
        onCameraChange?(device) // turns the camera on with this device
        refreshCameraTile()
    }

    /// Called by the recorder when the camera could not be turned on (access refused, unplugged).
    func cameraDidFail() {
        Defaults.shared.recordWithCamera = false
        refreshCameraTile()
    }

    // MARK: - Microphone

    private var micIsOn: Bool {
        Self.microphoneSupported && Defaults.shared.recordMicrophone
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && MicLevelMonitor.preferredMicrophone() != nil
    }

    private func refreshMicTile() {
        guard let tile = micTile else { return }
        let device = MicLevelMonitor.preferredMicrophone()
        tile.title = device?.localizedName ?? "Aucun micro"
        tile.isOn = micIsOn
        tile.isAvailable = Self.microphoneSupported && device != nil
        tile.toolTip = Self.microphoneSupported
            ? "Micro : la tuile se remplit quand il t’entend. Clic pour choisir un autre micro."
            : "L’enregistrement du micro demande macOS 15 ou plus récent"
        if !tile.isOn { tile.level = 0 }
    }

    private func toggleMicrophone() {
        if micIsOn {
            Defaults.shared.recordMicrophone = false
            micMonitor.stop()
            refreshMicTile()
        } else if let device = MicLevelMonitor.preferredMicrophone() {
            turnMicrophoneOn(device)
        }
    }

    private func turnMicrophoneOn(_ device: AVCaptureDevice) {
        Defaults.shared.microphoneID = device.uniqueID
        MicLevelMonitor.requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                Defaults.shared.recordMicrophone = false
                self.refreshMicTile()
                Toast.show(message: "Autorise Parker à utiliser le micro", style: .error, duration: 3)
                MicLevelMonitor.openMicrophonePrivacySettings()
                return
            }
            Defaults.shared.recordMicrophone = true
            self.refreshMicTile()
            self.startMeter()
        }
    }

    private func showMicMenu() {
        guard Self.microphoneSupported else { return }
        let menu = NSMenu()
        let current = MicLevelMonitor.preferredMicrophone()?.uniqueID
        for device in MicLevelMonitor.availableMicrophones() {
            let item = NSMenuItem(title: device.localizedName, action: #selector(micPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uniqueID
            item.state = device.uniqueID == current ? .on : .off
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "Aucun micro trouvé", action: nil, keyEquivalent: "")
        }
        micTile.map { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: $0.bounds.height + 4), in: $0) }
    }

    @objc private func micPicked(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let device = AVCaptureDevice(uniqueID: id) else { return }
        turnMicrophoneOn(device)
    }

    private func startMeter() {
        guard let device = MicLevelMonitor.preferredMicrophone() else { return }
        micMonitor.onLevel = { [weak self] level in
            guard let tile = self?.micTile, tile.isOn else { return }
            tile.level = level
        }
        micMonitor.start(device: device)
    }
}

private final class SetupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Controls

/// Round button (close in light grey, Mac sound in dark grey).
final class RoundIconButton: NSView {
    var onClick: (() -> Void)?
    var symbol: String { didSet { updateImage() } }
    var dimmed = false { didSet { updateImage() } }
    private let light: Bool
    private let imageView = NSImageView()

    init(frame: NSRect, symbol: String, light: Bool) {
        self.symbol = symbol
        self.light = light
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.height / 2
        layer?.backgroundColor = light
            ? NSColor(white: 0.92, alpha: 1).cgColor
            : NSColor.white.withAlphaComponent(0.12).cgColor
        imageView.frame = bounds.insetBy(dx: 12, dy: 12)
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)
        updateImage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func updateImage() {
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
        imageView.contentTintColor = light ? .black : .white.withAlphaComponent(dimmed ? 0.4 : 0.9)
    }

    override func mouseDown(with event: NSEvent) { alphaValue = 0.7 }
    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// Big blue "Start" pill.
final class StartButton: NSView {
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.frame = bounds
        gradient.cornerRadius = frame.height / 2
        gradient.colors = [
            NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1).cgColor,
            NSColor(red: 0.20, green: 0.62, blue: 1.0, alpha: 1).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(gradient)

        let icon = NSImageView(frame: NSRect(x: 24, y: (frame.height - 22) / 2, width: 22, height: 22))
        icon.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .semibold))
        icon.contentTintColor = .white
        addSubview(icon)

        let title = NSTextField(labelWithString: "Démarrer l’enregistrement")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: 58, y: 25, width: frame.width - 70, height: 20)
        addSubview(title)

        let subtitle = NSTextField(labelWithString: "Entrée")
        subtitle.font = .systemFont(ofSize: 11, weight: .medium)
        subtitle.textColor = .white.withAlphaComponent(0.75)
        subtitle.frame = NSRect(x: 58, y: 9, width: frame.width - 70, height: 14)
        addSubview(subtitle)

        toolTip = "Lancer l’enregistrement (Entrée)"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func mouseDown(with event: NSEvent) { alphaValue = 0.8 }
    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// Camera or microphone tile: icon, device name, On/Off pill. Clicking the pill switches the
/// device on or off, clicking elsewhere lists the devices. `level` fills the tile (voice meter).
final class DeviceTile: NSView {
    var onToggle: (() -> Void)?
    var onPick: (() -> Void)?

    var title: String = "" { didSet { nameLabel.stringValue = title } }
    var isOn = false { didSet { updateState() } }
    var isAvailable = true { didSet { updateState() } }
    var level: CGFloat = 0 {
        didSet {
            shownLevel = level > shownLevel ? level : shownLevel * 0.8 + level * 0.2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            levelLayer.frame = NSRect(x: 0, y: 0, width: bounds.width * shownLevel, height: bounds.height)
            CATransaction.commit()
        }
    }
    private var shownLevel: CGFloat = 0

    private let symbol: String
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let pill = NSView()
    private let pillLabel = NSTextField(labelWithString: "Off")
    private let levelLayer = CALayer()

    init(frame: NSRect, symbol: String) {
        self.symbol = symbol
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        levelLayer.backgroundColor = NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 0.35).cgColor
        levelLayer.frame = NSRect(x: 0, y: 0, width: 0, height: frame.height)
        layer?.addSublayer(levelLayer)

        iconView.frame = NSRect(x: 14, y: (frame.height - 20) / 2, width: 20, height: 20)
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: 42, y: (frame.height - 18) / 2, width: frame.width - 42 - 82, height: 18)
        addSubview(nameLabel)

        pill.frame = NSRect(x: frame.width - 74, y: (frame.height - 30) / 2, width: 62, height: 30)
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 15
        addSubview(pill)
        pillLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        pillLabel.alignment = .center
        pillLabel.frame = NSRect(x: 0, y: 7, width: 62, height: 16)
        pill.addSubview(pillLabel)

        updateState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func updateState() {
        let name = isOn ? (symbol + ".fill") : symbol
        iconView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        iconView.contentTintColor = .white.withAlphaComponent(isOn ? 0.9 : 0.5)
        nameLabel.textColor = .white.withAlphaComponent(isAvailable ? (isOn ? 1 : 0.6) : 0.35)
        pillLabel.stringValue = isOn ? "On" : "Off"
        pillLabel.textColor = isOn ? .white : .white.withAlphaComponent(0.6)
        pill.layer?.backgroundColor = isOn
            ? NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1).cgColor
            : NSColor.white.withAlphaComponent(0.12).cgColor
        alphaValue = isAvailable ? 1 : 0.6
        if !isOn { level = 0 }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard isAvailable else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if pill.frame.insetBy(dx: -6, dy: -6).contains(point) {
            onToggle?()
        } else {
            onPick?()
        }
    }
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
