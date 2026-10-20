import Cocoa
import SwiftUI
import AVFoundation
import ImageIO

/// "Captures récentes" panel: the last 20 captures, opened with Shift + profile modifier + H.
/// Layout from the Figma design "Panneau ancré": header, the selected capture large with its
/// details and actions, then a film strip of the 20 captures (selected one centered and larger).
///
/// Docked at the bottom of the main screen, slides up when it opens.
/// - ← →, the mouse wheel / two-finger scroll or the chevrons: browse; click a thumbnail: select it;
///   double-click: copy and close;
/// - Return or Cmd+C: copy the selected capture and close (the app you were in stays in front);
/// - drag the preview or a thumbnail into any app; right click: more actions;
/// - Esc, the shortcut again or a click elsewhere: close.
final class CaptureHistoryController: NSObject, NSWindowDelegate {
    private var panel: CaptureHistoryPanel?
    private let model = CaptureHistoryModel()

    /// Opens the annotation editor on an image.
    var onEdit: ((URL) -> Void)?
    /// Called when the history list changes (an entry removed), to refresh the menu bar.
    var onHistoryChanged: (() -> Void)?

    var isVisible: Bool { panel != nil }

    override init() {
        super.init()
        model.onCopy = { [weak self] url in
            self?.dismiss()
            FloatingThumbnailController.copy(url: url)
        }
        model.onOpen = { [weak self] url in
            self?.dismiss()
            NSWorkspace.shared.open(url)
        }
        model.onEdit = { [weak self] url in
            self?.dismiss()
            self?.onEdit?(url)
        }
        model.onReveal = { [weak self] url in
            self?.dismiss()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        model.onSaveAs = { [weak self] url in
            self?.dismiss()
            FloatingThumbnailController.saveAs(url: url)
        }
        model.onShowAll = { [weak self] in
            self?.dismiss()
            NSWorkspace.shared.open(Defaults.shared.captureDirectory)
        }
        model.onClose = { [weak self] in self?.dismiss() }
        model.onRemove = { [weak self] url in
            Defaults.shared.removeRecentCapture(url)
            self?.model.reload()
            self?.resizePanelToFit()
            self?.onHistoryChanged?()
        }
    }

    func toggle() {
        if isVisible {
            dismiss()
        } else {
            show()
        }
    }

    /// Gap between the panel and the bottom of the screen (above the Dock when it is shown).
    private let bottomMargin: CGFloat = 14
    /// Apple-like deceleration (fast start, long soft landing).
    private let slideInTiming = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

    func show() {
        guard !isVisible else { return }
        // Main screen (the one with the menu bar), docked at its bottom like a sheet
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }

        model.reload()

        let width = min(HistoryStyle.panelWidth, screen.visibleFrame.width - 48)
        let hosting = NSHostingView(rootView: CaptureHistoryView(model: model, width: width))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let frame = NSRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.minY + bottomMargin,
            width: size.width,
            height: size.height
        )
        // Starts just below the bottom edge of the screen, then slides up
        var startFrame = frame
        startFrame.origin.y = screen.frame.minY - size.height * 0.35
        let panel = CaptureHistoryPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = hosting
        panel.delegate = self
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        panel.onScroll = { [weak self] event in self?.handleScroll(event) }

        // "Reduce motion" (Accessibility): fade in place, no slide
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(reduceMotion ? frame : startFrame, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.15 : 0.5
            ctx.timingFunction = slideInTiming
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
        self.panel = panel
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        scrollAccumulator = 0
        // Slides back down while fading out
        var endFrame = panel.frame
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            endFrame.origin.y -= min(120, endFrame.height * 0.25)
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(endFrame, display: true)
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // MARK: - Mouse wheel / trackpad: browse the captures

    private var scrollAccumulator: CGFloat = 0
    private var lastScrollStep = Date.distantPast

    private func handleScroll(_ event: NSEvent) {
        if event.phase == .began || event.phase == .ended || event.phase == .cancelled {
            scrollAccumulator = 0
        }
        // Momentum after a trackpad flick would skip many captures: ignore it
        guard event.momentumPhase == [] else { return }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        // Down / right = older captures, up / left = more recent
        let delta = abs(dx) > abs(dy) ? -dx : -dy
        guard delta != 0 else { return }

        if !event.hasPreciseScrollingDeltas {
            // Mouse wheel: one notch = one capture
            guard Date().timeIntervalSince(lastScrollStep) > 0.06 else { return }
            lastScrollStep = Date()
            model.moveSelection(by: delta > 0 ? 1 : -1)
            return
        }
        // Trackpad: one capture every 40 points of movement
        scrollAccumulator += delta
        let threshold: CGFloat = 40
        while abs(scrollAccumulator) >= threshold {
            let step = scrollAccumulator > 0 ? 1 : -1
            model.moveSelection(by: step)
            scrollAccumulator -= CGFloat(step) * threshold
        }
    }

    // A click in another window or app closes the panel.
    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    private func resizePanelToFit() {
        guard let panel, let content = panel.contentView else { return }
        let size = content.fittingSize
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.origin.x += (frame.width - size.width) / 2
        frame.size = size
        panel.setFrame(frame, display: true, animate: false)
    }

    /// Returns true when the key was handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Esc
            dismiss()
            return true
        case 36, 76: // Return, Enter
            model.copySelected()
            return true
        case 123, 126: // left, up: more recent
            model.moveSelection(by: -1)
            return true
        case 124, 125: // right, down: older
            model.moveSelection(by: 1)
            return true
        default:
            break
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            model.copySelected()
            return true
        }
        return false
    }
}

/// Borderless panel that can take keyboard input without activating Parker,
/// so the app the user was in stays in front.
private final class CaptureHistoryPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onScroll: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        if event.type == .scrollWheel, let onScroll {
            // The wheel browses the captures (the film strip follows the selection)
            onScroll(event)
            return
        }
        super.sendEvent(event)
    }
}

// MARK: - Style (Figma "Panneau ancré")

enum HistoryStyle {
    static let panelWidth: CGFloat = 1160
    static let horizontalPadding: CGFloat = 28

    static let panelFill = Color(red: 35 / 255, green: 37 / 255, blue: 42 / 255).opacity(0.96)
    static let panelStroke = Color.white.opacity(0.14)
    static let textPrimary = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
    static let textSecondary = Color(red: 0xA5 / 255, green: 0xA8 / 255, blue: 0xB0 / 255)
    static let textTertiary = Color(red: 0x70 / 255, green: 0x74 / 255, blue: 0x7D / 255)
    static let accent = Color(red: 0x40 / 255, green: 0x9C / 255, blue: 1)
    static let control = Color.white.opacity(0.05)
    static let hairline = Color.white.opacity(0.08)

    static let previewSize = CGSize(width: 434, height: 244)
}

// MARK: - Model

enum CaptureHistoryKind {
    case image, gif, video

    init(url: URL) {
        switch url.pathExtension.lowercased() {
        case "gif": self = .gif
        case "mp4", "mov", "m4v": self = .video
        default: self = .image
        }
    }

    var label: String {
        switch self {
        case .image: return "Capture d’écran"
        case .gif: return "GIF animé"
        case .video: return "Enregistrement vidéo"
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .gif: return "photo.stack"
        case .video: return "video"
        }
    }
}

struct CaptureHistoryItem: Identifiable {
    let url: URL
    let kind: CaptureHistoryKind
    let date: Date?
    let source: CaptureSource.Info?
    let fileSize: Int64?
    var pixelSize: CGSize?
    var thumbnail: NSImage?
    var preview: NSImage?

    var id: URL { url }

    var title: String {
        if let title = source?.windowTitle, !title.isEmpty { return title }
        return kind.label
    }

    var format: String { url.pathExtension.uppercased() }
}

final class CaptureHistoryModel: ObservableObject {
    @Published var items: [CaptureHistoryItem] = []
    @Published var selected: Int = 0

    var onCopy: ((URL) -> Void)?
    var onOpen: ((URL) -> Void)?
    var onEdit: ((URL) -> Void)?
    var onReveal: ((URL) -> Void)?
    var onSaveAs: ((URL) -> Void)?
    var onRemove: ((URL) -> Void)?
    var onShowAll: (() -> Void)?
    var onClose: (() -> Void)?

    private static let thumbnailCache = NSCache<NSURL, NSImage>()
    private static let previewCache = NSCache<NSURL, NSImage>()

    var current: CaptureHistoryItem? {
        items.indices.contains(selected) ? items[selected] : nil
    }

    func reload() {
        let fm = FileManager.default
        items = Defaults.shared.recentCaptures
            .filter { fm.fileExists(atPath: $0.path) }
            .prefix(20)
            .map { url in
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
                return CaptureHistoryItem(
                    url: url,
                    kind: CaptureHistoryKind(url: url),
                    date: values?.creationDate ?? values?.contentModificationDate,
                    source: Defaults.shared.captureInfo(for: url),
                    fileSize: values?.fileSize.map { Int64($0) },
                    pixelSize: nil,
                    thumbnail: Self.thumbnailCache.object(forKey: url as NSURL),
                    preview: Self.previewCache.object(forKey: url as NSURL)
                )
            }
        if !items.indices.contains(selected) { selected = 0 }

        for item in items {
            let url = item.url
            let kind = item.kind
            Task.detached(priority: .userInitiated) { [weak self] in
                let size = await Self.pixelSize(url: url, kind: kind)
                let thumb = item.thumbnail == nil ? await Self.makeImage(url: url, kind: kind, maxPixels: 360) : nil
                await MainActor.run {
                    if let thumb { Self.thumbnailCache.setObject(thumb, forKey: url as NSURL) }
                    guard let self, let index = self.items.firstIndex(where: { $0.url == url }) else { return }
                    if let thumb { self.items[index].thumbnail = thumb }
                    self.items[index].pixelSize = size
                }
            }
        }
        loadPreviewForSelection()
    }

    func select(_ index: Int) {
        guard items.indices.contains(index), index != selected else { return }
        selected = index
        loadPreviewForSelection()
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        select(min(max(selected + delta, 0), items.count - 1))
    }

    func copySelected() {
        guard let item = current else { return }
        onCopy?(item.url)
    }

    /// Large image of the selected capture (loaded once, cached).
    private func loadPreviewForSelection() {
        guard let item = current, item.preview == nil else { return }
        let url = item.url
        let kind = item.kind
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let image = await Self.makeImage(url: url, kind: kind, maxPixels: 1100) else { return }
            await MainActor.run {
                Self.previewCache.setObject(image, forKey: url as NSURL)
                guard let self, let index = self.items.firstIndex(where: { $0.url == url }) else { return }
                self.items[index].preview = image
            }
        }
    }

    private static func makeImage(url: URL, kind: CaptureHistoryKind, maxPixels: CGFloat) async -> NSImage? {
        if kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            guard let result = try? await generator.image(at: .zero) else { return nil }
            return NSImage(cgImage: result.image, size: .zero)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    private static func pixelSize(url: URL, kind: CaptureHistoryKind) async -> CGSize? {
        if kind == .video {
            guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize) else { return nil }
            return size
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }
}

// MARK: - Panel view

struct CaptureHistoryView: View {
    @ObservedObject var model: CaptureHistoryModel
    let width: CGFloat

    private var contentWidth: CGFloat { width - 2 * HistoryStyle.horizontalPadding }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)

            header

            if let item = model.current {
                SelectedCaptureView(item: item, model: model, availableWidth: contentWidth)
                VStack(spacing: 10) {
                    FilmStrip(model: model, width: contentWidth)
                    Capsule()
                        .fill(HistoryStyle.accent)
                        .frame(width: 68, height: 2)
                    HStack {
                        Text("Plus récentes")
                        Spacer()
                        Text("Plus anciennes")
                    }
                    .font(.system(size: 10))
                    .foregroundColor(HistoryStyle.textSecondary)
                }
            } else {
                emptyState
            }

            footer
        }
        .padding(.top, 10)
        .padding(.bottom, 16)
        .padding(.horizontal, HistoryStyle.horizontalPadding)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(HistoryStyle.panelFill))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(HistoryStyle.panelStroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo")
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(HistoryStyle.textPrimary)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HistoryStyle.control))

            VStack(alignment: .leading, spacing: 4) {
                Text("Captures récentes")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(HistoryStyle.textPrimary)
                Text("Vos 20 dernières captures, à portée de main.")
                    .font(.system(size: 11))
                    .foregroundColor(HistoryStyle.textSecondary)
            }

            Spacer(minLength: 12)

            if !model.items.isEmpty {
                Text("\(model.selected + 1) sur \(model.items.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(HistoryStyle.textSecondary)
                    .monospacedDigit()
                HStack(spacing: 6) {
                    SquareIconButton(symbol: "chevron.left", help: "Capture plus récente") { model.moveSelection(by: -1) }
                        .disabled(model.selected == 0)
                    SquareIconButton(symbol: "chevron.right", help: "Capture plus ancienne") { model.moveSelection(by: 1) }
                        .disabled(model.selected >= model.items.count - 1)
                }
                Rectangle()
                    .fill(HistoryStyle.hairline)
                    .frame(width: 1, height: 18)
            }
            SquareIconButton(symbol: "xmark", help: "Fermer (Échap)", fill: Color.white.opacity(0.03)) { model.onClose?() }
        }
        .frame(height: 40)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(HistoryStyle.textSecondary)
            Text("Aucune capture pour l’instant")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(HistoryStyle.textPrimary)
            Text("Vos 20 dernières captures apparaîtront ici.")
                .font(.system(size: 12))
                .foregroundColor(HistoryStyle.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 7) {
                KeyCap(text: "← →", size: 10)
                Text("Parcourir")
                KeyCap(text: "esc", size: 9)
                Text("Fermer")
            }
            .font(.system(size: 10))
            .foregroundColor(HistoryStyle.textSecondary)

            Spacer()

            Button { model.onShowAll?() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11))
                    Text("Toutes les captures")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(HistoryStyle.accent)
            }
            .buttonStyle(.plain)
            .help("Ouvrir le dossier des captures")
        }
        .frame(height: 22)
    }
}

// MARK: - Selected capture

private struct SelectedCaptureView: View {
    let item: CaptureHistoryItem
    @ObservedObject var model: CaptureHistoryModel
    let availableWidth: CGFloat

    private let shareAnchor = ShareAnchor()

    private var previewSize: CGSize {
        // The preview keeps the design size, and shrinks on narrow screens
        let width = min(HistoryStyle.previewSize.width, availableWidth * 0.42)
        return CGSize(width: width, height: width * HistoryStyle.previewSize.height / HistoryStyle.previewSize.width)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            preview
            details
                .frame(height: previewSize.height)
        }
        .frame(height: previewSize.height)
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.03))
            if let image = item.preview ?? item.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(HistoryStyle.textSecondary)
            }
            if item.kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.31), radius: 12, x: 0, y: 8)
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .onTapGesture(count: 2) { model.onOpen?(item.url) }
        .contextMenu { CaptureContextMenu(item: item, model: model) }
        .help("Glisser vers une app, double-clic pour ouvrir")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HStack(spacing: 7) {
                        if let icon = item.source?.appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: item.kind.symbol)
                                .font(.system(size: 11))
                                .foregroundColor(HistoryStyle.accent)
                        }
                        Text(item.source?.appName ?? item.kind.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(HistoryStyle.textSecondary)
                    }
                    Spacer()
                    Text(HistoryFormat.date(item.date))
                        .font(.system(size: 11))
                        .foregroundColor(HistoryStyle.textSecondary)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(item.title)
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundColor(HistoryStyle.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.url.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 12))
                        .foregroundColor(HistoryStyle.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 8) {
                    ForEach(Array(metadata.enumerated()), id: \.offset) { index, value in
                        if index > 0 { Text("·") }
                        Text(value)
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(HistoryStyle.textTertiary)
            }
            .padding(.top, 8)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                ActionButton(title: "Ouvrir", symbol: "arrow.up.left.and.arrow.down.right", primary: true) {
                    model.onOpen?(item.url)
                }
                ActionButton(title: "Copier", symbol: "doc.on.doc") {
                    model.onCopy?(item.url)
                }
                ActionButton(title: "Partager", symbol: "square.and.arrow.up") {
                    shareAnchor.share(item.url)
                }
                .background(ShareAnchorView(anchor: shareAnchor))
            }
            .padding(.bottom, 5)
        }
    }

    private var metadata: [String] {
        var values = [item.format]
        if let size = item.pixelSize {
            values.append("\(HistoryFormat.number(Int(size.width))) × \(HistoryFormat.number(Int(size.height)))")
        }
        if let bytes = item.fileSize {
            values.append(HistoryFormat.bytes(bytes))
        }
        return values
    }
}

private struct CaptureContextMenu: View {
    let item: CaptureHistoryItem
    let model: CaptureHistoryModel

    var body: some View {
        Button("Copier") { model.onCopy?(item.url) }
        Button("Ouvrir") { model.onOpen?(item.url) }
        if item.kind == .image {
            Button("Annoter") { model.onEdit?(item.url) }
        }
        Button("Enregistrer sous…") { model.onSaveAs?(item.url) }
        Button("Afficher dans le Finder") { model.onReveal?(item.url) }
        Divider()
        Button("Retirer de l’historique") { model.onRemove?(item.url) }
    }
}

// MARK: - Film strip

private struct FilmStrip: View {
    @ObservedObject var model: CaptureHistoryModel
    let width: CGFloat

    private let spacing: CGFloat = 11
    private let height: CGFloat = 139

    var body: some View {
        // Side room so the first and the last thumbnails can sit in the center
        let sidePadding = max(0, width / 2 - FilmTile.size(distance: 0).width / 2)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: spacing) {
                    Color.clear.frame(width: max(0, sidePadding - spacing), height: 1)
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        FilmTile(item: item, distance: abs(index - model.selected))
                            .id(item.id)
                            .onTapGesture(count: 2) { model.onCopy?(item.url) }
                            .simultaneousGesture(TapGesture().onEnded { model.select(index) })
                            .onDrag { NSItemProvider(object: item.url as NSURL) }
                            .contextMenu { CaptureContextMenu(item: item, model: model) }
                            .help("Clic : afficher. Double-clic : copier.")
                    }
                    Color.clear.frame(width: max(0, sidePadding - spacing), height: 1)
                }
                .frame(height: height, alignment: .bottom)
                .animation(.easeOut(duration: 0.2), value: model.selected)
            }
            .frame(width: width, height: height)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.16),
                        .init(color: .black, location: 0.84),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .onAppear {
                if let id = model.current?.id { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: model.selected) { _, _ in
                guard let id = model.current?.id else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

private struct FilmTile: View {
    let item: CaptureHistoryItem
    let distance: Int

    /// Selected, its neighbours, then the others (sizes from the design).
    static func size(distance: Int) -> CGSize {
        switch distance {
        case 0: return CGSize(width: 167, height: 138)
        case 1: return CGSize(width: 116, height: 97)
        default: return CGSize(width: 94, height: 78)
        }
    }

    private var isSelected: Bool { distance == 0 }

    var body: some View {
        let size = Self.size(distance: distance)
        let scale = size.width / 94
        let outerRadius = 12 * scale
        let padding = 6 * scale

        ZStack {
            if let image = item.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 14 * scale, weight: .light))
                    .foregroundColor(HistoryStyle.textSecondary)
            }
            if item.kind != .image {
                Image(systemName: item.kind == .video ? "play.fill" : "photo.stack")
                    .font(.system(size: 7 * scale))
                    .foregroundColor(.white)
                    .padding(4 * scale)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(3 * scale)
            }
        }
        .frame(width: size.width - 2 * padding, height: size.height - 2 * padding)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: outerRadius / 2, style: .continuous))
        .padding(padding)
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                .fill(isSelected ? HistoryStyle.accent.opacity(0.13) : Color.white.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                .stroke(isSelected ? HistoryStyle.accent : HistoryStyle.hairline, lineWidth: isSelected ? 1 : 2)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Controls

private struct SquareIconButton: View {
    let symbol: String
    let help: String
    var fill: Color = HistoryStyle.control
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(HistoryStyle.textPrimary.opacity(isEnabled ? 1 : 0.35))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: primary ? .semibold : .medium))
            }
            .foregroundColor(primary ? .white : HistoryStyle.textPrimary)
            .padding(.horizontal, primary ? 16 : 14)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(primary ? HistoryStyle.accent : HistoryStyle.control)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct KeyCap: View {
    let text: String
    let size: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: size))
            .foregroundColor(HistoryStyle.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(HistoryStyle.hairline, lineWidth: 1))
    }
}

/// Gives the share button an AppKit view to anchor the system share menu.
private final class ShareAnchor {
    weak var view: NSView?

    func share(_ url: URL) {
        guard let view else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

private struct ShareAnchorView: NSViewRepresentable {
    let anchor: ShareAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

// MARK: - Formatting

enum HistoryFormat {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()

    private static let numbers: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.numberStyle = .decimal
        return f
    }()

    /// "Aujourd’hui à 14:28", "Hier à 09:12", "12 oct. à 18:40".
    static func date(_ date: Date?) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        let prefix: String
        if calendar.isDateInToday(date) {
            prefix = "Aujourd’hui"
        } else if calendar.isDateInYesterday(date) {
            prefix = "Hier"
        } else {
            prefix = day.string(from: date)
        }
        return "\(prefix) à \(time.string(from: date))"
    }

    static func number(_ value: Int) -> String {
        numbers.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func bytes(_ value: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: value)
    }
}
