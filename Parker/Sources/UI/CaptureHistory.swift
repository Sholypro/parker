import Cocoa
import SwiftUI
import AVFoundation
import ImageIO

/// History panel: the last 20 captures (Defaults.recentCaptures) in a grid, opened with the
/// "history" shortcut (Shift + profile modifier + H).
///
/// - click or Return: copy to the clipboard and close (the app you were in stays active,
///   so Cmd+V works right away);
/// - 1 to 9: copy that capture directly;
/// - arrows: move the selection;
/// - drag a capture into any app;
/// - right click: open, annotate, show in Finder, remove from history;
/// - Esc, the shortcut again, or a click elsewhere: close.
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

    func show() {
        guard !isVisible else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }

        model.reload()

        let hosting = NSHostingView(rootView: CaptureHistoryView(model: model))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let frame = NSRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2 + 40,
            width: size.width,
            height: size.height
        )
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
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = hosting
        panel.delegate = self
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        self.panel = panel
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
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
        let columns = CaptureHistoryLayout.columns
        switch event.keyCode {
        case 53: // Esc
            dismiss()
            return true
        case 36, 76: // Return, Enter
            model.copySelected()
            return true
        case 123: // left
            model.moveSelection(by: -1)
            return true
        case 124: // right
            model.moveSelection(by: 1)
            return true
        case 125: // down
            model.moveSelection(by: columns)
            return true
        case 126: // up
            model.moveSelection(by: -columns)
            return true
        default:
            break
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            model.copySelected()
            return true
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let chars = event.charactersIgnoringModifiers, let digit = Int(chars), (1...9).contains(digit) {
            model.copy(at: digit - 1)
            return true
        }
        return false
    }
}

/// Borderless panel that can take keyboard input without activating Parker,
/// so the app the user was in stays in front.
private final class CaptureHistoryPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

// MARK: - Model

enum CaptureHistoryLayout {
    static let columns = 5
    static let tileWidth: CGFloat = 148
    static let tileHeight: CGFloat = 96
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 20
    static var panelWidth: CGFloat {
        CGFloat(columns) * tileWidth + CGFloat(columns - 1) * spacing + 2 * padding
    }
}

enum CaptureHistoryKind {
    case image, gif, video

    init(url: URL) {
        switch url.pathExtension.lowercased() {
        case "gif": self = .gif
        case "mp4", "mov", "m4v": self = .video
        default: self = .image
        }
    }

    var badge: String? {
        switch self {
        case .image: return nil
        case .gif: return "GIF"
        case .video: return "Vidéo"
        }
    }

    var placeholderSymbol: String {
        self == .image ? "photo" : "film"
    }
}

struct CaptureHistoryItem: Identifiable {
    let url: URL
    let kind: CaptureHistoryKind
    let date: Date?
    var thumbnail: NSImage?

    var id: URL { url }
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

    private static let thumbnailCache = NSCache<NSURL, NSImage>()

    var shortcutSymbol: String {
        ShortcutCatalog.definition(for: .history).symbol
    }

    func reload() {
        let fm = FileManager.default
        items = Defaults.shared.recentCaptures
            .filter { fm.fileExists(atPath: $0.path) }
            .prefix(20)
            .map { url in
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                return CaptureHistoryItem(
                    url: url,
                    kind: CaptureHistoryKind(url: url),
                    date: values?.creationDate ?? values?.contentModificationDate,
                    thumbnail: Self.thumbnailCache.object(forKey: url as NSURL)
                )
            }
        selected = min(selected, max(items.count - 1, 0))
        if items.indices.contains(selected) == false { selected = 0 }

        for item in items where item.thumbnail == nil {
            let url = item.url
            let kind = item.kind
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let image = await Self.makeThumbnail(url: url, kind: kind) else { return }
                await MainActor.run {
                    Self.thumbnailCache.setObject(image, forKey: url as NSURL)
                    guard let self, let index = self.items.firstIndex(where: { $0.url == url }) else { return }
                    self.items[index].thumbnail = image
                }
            }
        }
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selected = min(max(selected + delta, 0), items.count - 1)
    }

    func copySelected() {
        copy(at: selected)
    }

    func copy(at index: Int) {
        guard items.indices.contains(index) else { return }
        onCopy?(items[index].url)
    }

    private static func makeThumbnail(url: URL, kind: CaptureHistoryKind) async -> NSImage? {
        let maxPixels: CGFloat = 480
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
}

// MARK: - Views

struct CaptureHistoryView: View {
    @ObservedObject var model: CaptureHistoryModel

    private let columns = Array(
        repeating: GridItem(.fixed(CaptureHistoryLayout.tileWidth), spacing: CaptureHistoryLayout.spacing),
        count: CaptureHistoryLayout.columns
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Historique")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(SettingsColor.ink)
                Text(model.items.isEmpty ? "" : "\(model.items.count) capture\(model.items.count > 1 ? "s" : "")")
                    .font(.system(size: 12))
                    .foregroundColor(SettingsColor.muted)
                Spacer()
                Text(model.shortcutSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(SettingsColor.muted)
            }

            if model.items.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: CaptureHistoryLayout.spacing) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        CaptureHistoryTile(item: item, index: index, isSelected: index == model.selected)
                            .onHover { inside in
                                if inside { model.selected = index }
                            }
                            .onTapGesture { model.copy(at: index) }
                            .onDrag { NSItemProvider(object: item.url as NSURL) }
                            .contextMenu { contextMenu(for: item) }
                    }
                }
            }

            HStack(spacing: 18) {
                hint(key: "Clic", text: "copier")
                hint(key: "1 à 9", text: "copier directement")
                hint(key: "Glisser", text: "déposer dans une app")
                hint(key: "Clic droit", text: "plus d’options")
                Spacer(minLength: 0)
                hint(key: "Esc", text: "fermer")
            }
        }
        .padding(CaptureHistoryLayout.padding)
        .frame(width: CaptureHistoryLayout.panelWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 17 / 255, green: 24 / 255, blue: 39 / 255).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(SettingsColor.groupStroke, lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(SettingsColor.muted)
            Text("Aucune capture pour l’instant")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SettingsColor.ink)
            Text("Tes 20 dernières captures apparaîtront ici.")
                .font(.system(size: 12))
                .foregroundColor(SettingsColor.muted)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
    }

    @ViewBuilder
    private func contextMenu(for item: CaptureHistoryItem) -> some View {
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

    private func hint(key: String, text: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(SettingsColor.ink.opacity(0.75))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(SettingsColor.control))
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(SettingsColor.muted)
        }
    }
}

private struct CaptureHistoryTile: View {
    let item: CaptureHistoryItem
    let index: Int
    let isSelected: Bool

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                preview
                    .frame(width: CaptureHistoryLayout.tileWidth, height: CaptureHistoryLayout.tileHeight)
                    .clipped()

                if index < 9 {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .padding(6)
                }

                if let badge = item.kind.badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .padding(6)
                        .frame(width: CaptureHistoryLayout.tileWidth, height: CaptureHistoryLayout.tileHeight, alignment: .bottomTrailing)
                }
            }
            .frame(width: CaptureHistoryLayout.tileWidth, height: CaptureHistoryLayout.tileHeight)
            .background(SettingsColor.control)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? SettingsColor.accent : SettingsColor.groupStroke, lineWidth: isSelected ? 2 : 1)
            )

            Text(caption)
                .font(.system(size: 10))
                .foregroundColor(isSelected ? SettingsColor.ink : SettingsColor.muted)
                .lineLimit(1)
                .frame(width: CaptureHistoryLayout.tileWidth, alignment: .leading)
        }
        .contentShape(Rectangle())
        .help(item.url.lastPathComponent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Capture \(index + 1), \(caption)")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail = item.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: item.kind.placeholderSymbol)
                .font(.system(size: 20, weight: .light))
                .foregroundColor(SettingsColor.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var caption: String {
        guard let date = item.date else { return item.url.lastPathComponent }
        if Date().timeIntervalSince(date) < 60 { return "À l’instant" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
