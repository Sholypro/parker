import Cocoa
import ApplicationServices

/// Permission onboarding, "drag the app into the list" style.
///
/// Instead of a chain of system prompts, Parker opens the right page of System Settings and
/// floats a small card next to it holding Parker's icon: the user drags the icon into the list
/// and the permission is granted. Parker detects it and moves on to the next one.
///
/// Order: Accessibility first (macOS reports it live), then Screen Recording (macOS only applies
/// it after a relaunch, so Parker offers to relaunch itself at the end).
final class PermissionAssistant: NSObject, NSWindowDelegate {
    static let shared = PermissionAssistant()

    enum Step: CaseIterable {
        case accessibility
        case screenRecording

        var title: String {
            switch self {
            case .accessibility: return "Accessibilité"
            case .screenRecording: return "Enregistrement de l'écran"
            }
        }

        var detail: String {
            switch self {
            case .accessibility: return "Raccourcis clavier partout et défilement automatique de la capture défilante."
            case .screenRecording: return "Indispensable pour capturer ton écran."
            }
        }

        var symbol: String {
            switch self {
            case .accessibility: return "hand.raised.fill"
            case .screenRecording: return "rectangle.dashed.badge.record"
            }
        }

        var settingsURL: URL {
            switch self {
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .screenRecording:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            }
        }
    }

    private var window: NSWindow?
    private var rows: [Step: PermissionRow] = [:]
    private var footer: NSButton?
    private var helper: NSPanel?
    private var helperStep: Step?
    private var pollTimer: Timer?
    /// Screen Recording is only applied after a relaunch: remember the user said it's done.
    private var screenRecordingAwaitingRelaunch = false

    // MARK: - Status

    func isGranted(_ step: Step) -> Bool {
        switch step {
        case .accessibility: return AXIsProcessTrusted()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        }
    }

    var allGranted: Bool { Step.allCases.allSatisfy { isGranted($0) } }

    // MARK: - Show

    /// At launch: only when something is missing.
    func showIfNeeded() {
        guard !allGranted else { return }
        show()
    }

    func show() {
        if let window = window {
            refresh()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let width: CGFloat = 460
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSVisualEffectView()
        content.material = .windowBackground
        content.blendingMode = .behindWindow
        content.state = .active
        window.contentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 14
        header.alignment = .centerY
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let titles = NSStackView()
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let title = NSTextField(labelWithString: "Deux autorisations et c'est parti")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "Pour chacune : clique sur Autoriser, puis glisse l'icône de Parker dans la liste qui s'ouvre.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = width - 56 - 14 - 56
        titles.addArrangedSubview(title)
        titles.addArrangedSubview(subtitle)
        header.addArrangedSubview(icon)
        header.addArrangedSubview(titles)
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(22, after: header)

        for step in Step.allCases {
            let row = PermissionRow(step: step)
            row.onAuthorize = { [weak self] in self?.begin(step) }
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rows[step] = row
        }

        let footer = NSButton(title: "Plus tard", target: self, action: #selector(footerClicked))
        footer.bezelStyle = .rounded
        footer.controlSize = .large
        stack.setCustomSpacing(22, after: rows[.screenRecording]!)
        stack.addArrangedSubview(footer)
        self.footer = footer

        window.setContentSize(NSSize(width: width, height: stack.fittingSize.height + 70))
        window.center()
        self.window = window
        refresh()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        startPolling()
    }

    // MARK: - Flow

    private func begin(_ step: Step) {
        // No system prompt here on purpose: the drag into the list replaces the chain of dialogs.
        if step == .screenRecording { screenRecordingAwaitingRelaunch = true }
        NSWorkspace.shared.open(step.settingsURL)
        showHelper(for: step)
        refresh()
    }

    private func refresh() {
        for (step, row) in rows {
            let state: PermissionRow.State
            if isGranted(step) {
                state = .granted
            } else if step == .screenRecording && screenRecordingAwaitingRelaunch {
                state = .needsRelaunch
            } else {
                state = .pending
            }
            row.state = state
        }

        let needsRelaunch = !isGranted(.screenRecording) && screenRecordingAwaitingRelaunch
        if allGranted {
            footer?.title = "Terminé"
            footer?.keyEquivalent = "\r"
        } else if needsRelaunch {
            footer?.title = "Relancer Parker"
            footer?.keyEquivalent = "\r"
        } else {
            footer?.title = "Plus tard"
            footer?.keyEquivalent = ""
        }
    }

    @objc private func footerClicked() {
        if !isGranted(.screenRecording) && screenRecordingAwaitingRelaunch {
            relaunch()
        } else {
            close()
        }
    }

    private func close() {
        stopPolling()
        hideHelper()
        window?.orderOut(nil)
        window = nil
        rows.removeAll()
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
        hideHelper()
        window = nil
        rows.removeAll()
    }

    private func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func tick() {
        refresh()
        guard let step = helperStep else { return }

        if step == .accessibility && isGranted(.accessibility) {
            // Done: chain straight into the next missing permission
            hideHelper()
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            if !isGranted(.screenRecording) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.begin(.screenRecording)
                }
            }
            return
        }
        positionHelper()
    }

    // MARK: - Drag helper (floating card next to System Settings)

    private func showHelper(for step: Step) {
        hideHelper()
        helperStep = step

        let size = NSSize(width: 300, height: 190)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = DragHelperView(frame: NSRect(origin: .zero, size: size), step: step)
        view.onDone = { [weak self] in
            guard let self = self else { return }
            self.hideHelper()
            if step == .screenRecording {
                self.screenRecordingAwaitingRelaunch = true
                self.refresh()
            }
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
        }
        panel.contentView = view
        helper = panel
        positionHelper()
        panel.orderFrontRegardless()

        // System Settings may take a moment to open: reposition once it's there
        for delay in [0.4, 1.0, 1.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.positionHelper() }
        }
    }

    private func hideHelper() {
        helper?.orderOut(nil)
        helper = nil
        helperStep = nil
    }

    /// Places the card next to the System Settings window (right side, else left, else below).
    private func positionHelper() {
        guard let helper = helper else { return }
        let size = helper.frame.size
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 40)
        if let settings = Self.systemSettingsFrame() {
            let gap: CGFloat = 16
            if settings.maxX + gap + size.width <= visible.maxX {
                origin = NSPoint(x: settings.maxX + gap, y: settings.midY - size.height / 2)
            } else if settings.minX - gap - size.width >= visible.minX {
                origin = NSPoint(x: settings.minX - gap - size.width, y: settings.midY - size.height / 2)
            } else {
                origin = NSPoint(x: settings.midX - size.width / 2, y: max(visible.minY + 12, settings.minY - size.height - gap))
            }
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        if helper.frame.origin != origin {
            helper.setFrameOrigin(origin)
        }
    }

    /// Frame of the System Settings main window in Cocoa coordinates (bounds need no permission).
    private static func systemSettingsFrame() -> NSRect? {
        let ids = ["com.apple.systempreferences", "com.apple.SystemSettings"]
        let pids = Set(NSWorkspace.shared.runningApplications
            .filter { ids.contains($0.bundleIdentifier ?? "") }
            .map { $0.processIdentifier })
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        var best: CGRect?
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 300, bounds.height > 200 else { continue }
            if best == nil || bounds.width * bounds.height > best!.width * best!.height { best = bounds }
        }
        guard let cg = best else { return nil }
        return NSRect(x: cg.minX, y: NSScreen.primaryHeight - cg.maxY, width: cg.width, height: cg.height)
    }
}

// MARK: - Row in the main window

private final class PermissionRow: NSView {
    enum State { case pending, needsRelaunch, granted }

    var onAuthorize: (() -> Void)?
    var state: State = .pending { didSet { if state != oldValue { apply() } } }

    private let step: PermissionAssistant.Step
    private let statusIcon = NSImageView()
    private let button = NSButton()
    private let detail = NSTextField(wrappingLabelWithString: "")

    init(step: PermissionAssistant.Step) {
        self.step = step
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor

        let symbol = NSImageView(image: NSImage(systemSymbolName: step.symbol, accessibilityDescription: nil) ?? NSImage())
        symbol.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        symbol.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: step.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.stringValue = step.detail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor

        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.target = self
        button.action = #selector(clicked)
        button.setContentHuggingPriority(.required, for: .horizontal)

        statusIcon.symbolConfiguration = .init(pointSize: 18, weight: .semibold)

        let row = NSStackView(views: [symbol, texts, button, statusIcon])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            symbol.widthAnchor.constraint(equalToConstant: 26),
        ])
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func apply() {
        switch state {
        case .pending:
            button.isHidden = false
            button.title = "Autoriser"
            statusIcon.isHidden = true
            detail.stringValue = step.detail
        case .needsRelaunch:
            button.isHidden = false
            button.title = "Réessayer"
            statusIcon.isHidden = true
            detail.stringValue = "Ajouté ? Relance Parker pour l'activer (bouton en bas)."
        case .granted:
            button.isHidden = true
            statusIcon.isHidden = false
            statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Autorisé")
            statusIcon.contentTintColor = .systemGreen
            detail.stringValue = "Autorisé"
        }
    }

    @objc private func clicked() { onAuthorize?() }
}

// MARK: - Floating card with the draggable app icon

private final class DragHelperView: NSView, NSDraggingSource {
    var onDone: (() -> Void)?
    private let step: PermissionAssistant.Step
    private let iconView = NSImageView()
    private let arrow = NSImageView()

    init(frame: NSRect, step: PermissionAssistant.Step) {
        self.step = step
        super.init(frame: frame)

        let bg = NSVisualEffectView(frame: bounds)
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 16
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]
        addSubview(bg)

        let title = NSTextField(labelWithString: "Glisse Parker dans la liste")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 12, y: bounds.height - 34, width: bounds.width - 24, height: 20)
        addSubview(title)

        let sub = NSTextField(labelWithString: "« \(step.title) », puis active l'interrupteur")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center
        sub.lineBreakMode = .byTruncatingTail
        sub.frame = NSRect(x: 12, y: bounds.height - 52, width: bounds.width - 24, height: 16)
        addSubview(sub)

        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = NSRect(x: bounds.midX - 32, y: 56, width: 64, height: 64)
        iconView.toolTip = "Glisse-moi dans la liste des Réglages"
        addSubview(iconView)

        arrow.image = NSImage(systemSymbolName: "hand.draw.fill", accessibilityDescription: nil)
        arrow.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        arrow.contentTintColor = .secondaryLabelColor
        arrow.frame = NSRect(x: bounds.midX + 30, y: 52, width: 22, height: 22)
        addSubview(arrow)

        let done = NSButton(title: step == .screenRecording ? "C'est fait" : "Je l'ai fait", target: self, action: #selector(doneClicked))
        done.bezelStyle = .rounded
        done.controlSize = .small
        done.frame = NSRect(x: bounds.midX - 50, y: 14, width: 100, height: 24)
        addSubview(done)

        // Gentle bounce to show the icon can be grabbed
        iconView.wantsLayer = true
        let bounce = CABasicAnimation(keyPath: "transform.translation.y")
        bounce.fromValue = 0
        bounce.toValue = 6
        bounce.duration = 0.7
        bounce.autoreverses = true
        bounce.repeatCount = .infinity
        bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        iconView.layer?.add(bounce, forKey: "bounce")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard iconView.frame.insetBy(dx: -16, dy: -16).contains(point) else { return }
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(iconView.frame, contents: NSApp.applicationIconImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }

    @objc private func doneClicked() { onDone?() }
}
