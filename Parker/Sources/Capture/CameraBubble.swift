import Cocoa
import AVFoundation

/// Round webcam bubble shown on screen during a recording (Loom style).
/// It is a real window, so it appears in the video exactly where it sits on screen: the recorder
/// adds it back to its capture filter (Parker's other windows stay excluded).
/// Drag it anywhere; double-click to switch between three sizes.
final class CameraBubble {
    private var panel: NSPanel?
    private var session: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "parker.camera.session")
    private var sizeIndex = 1
    private static let sizes: [CGFloat] = [120, 180, 260]

    var isVisible: Bool { panel != nil }

    /// Window number of the bubble, used to keep it in the recording.
    var windowID: CGWindowID? {
        guard let panel else { return nil }
        return CGWindowID(panel.windowNumber)
    }

    /// Asks for camera access if needed. `done(true)` when the camera can be used.
    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { done(granted) }
            }
        default:
            done(false)
        }
    }

    static func openCameraPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shows the bubble in the bottom-right corner of `area` (Cocoa coordinates).
    /// Returns false when no camera is available.
    @discardableResult
    func show(in area: NSRect) -> Bool {
        guard panel == nil else { return true }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }

        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        session.commitConfiguration()

        let size = Self.sizes[sizeIndex]
        let margin: CGFloat = 24
        let frame = NSRect(
            x: max(area.minX + margin, area.maxX - size - margin),
            y: area.minY + margin,
            width: size,
            height: size
        )

        let panel = CameraBubblePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = CameraBubbleView(frame: NSRect(origin: .zero, size: frame.size), session: session)
        view.onDoubleClick = { [weak self] in self?.cycleSize() }
        view.autoresizingMask = [.width, .height]
        panel.contentView = view

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        self.session = session
        sessionQueue.async { session.startRunning() }
        return true
    }

    func hide() {
        guard let panel else { return }
        self.panel = nil
        let session = self.session
        self.session = nil
        sessionQueue.async { session?.stopRunning() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    /// Small, medium, large: keeps the bubble's center where it is.
    private func cycleSize() {
        guard let panel else { return }
        sizeIndex = (sizeIndex + 1) % Self.sizes.count
        let size = Self.sizes[sizeIndex]
        let old = panel.frame
        var frame = NSRect(x: old.midX - size / 2, y: old.midY - size / 2, width: size, height: size)
        if let visible = panel.screen?.frame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().setFrame(frame, display: true)
        }
    }
}

private final class CameraBubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Round, mirrored camera preview with a thin white ring. Drag moves the window.
private final class CameraBubbleView: NSView {
    var onDoubleClick: (() -> Void)?
    private let preview: AVCaptureVideoPreviewLayer
    private let ring = CALayer()

    init(frame: NSRect, session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        preview.videoGravity = .resizeAspectFill
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true // selfie view, like FaceTime
        }
        layer?.addSublayer(preview)

        ring.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        ring.borderWidth = 3
        layer?.addSublayer(ring)

        setAccessibilityLabel("Caméra")
        toolTip = "Glisser pour déplacer, double-clic pour changer la taille"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.width / 2
        preview.frame = bounds
        ring.frame = bounds
        ring.cornerRadius = bounds.width / 2
        CATransaction.commit()
        window?.invalidateShadow()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }
}
