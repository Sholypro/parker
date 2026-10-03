import SwiftUI
import Cocoa

// Settings window, redesigned in Figma (file "Parker", section "Section 1", v2.1):
// dark translucent window, sidebar navigation (Général, Capture, Raccourcis, Export),
// grouped rows with French copy. Every control is bound to the existing UserDefaults keys.

// MARK: - Window

class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        let size = NSSize(width: SettingsMetrics.windowWidth, height: min(980, max(560, visibleHeight - 60)))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Réglages de Parker"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: SettingsMetrics.windowWidth, height: 520)
        window.maxSize = NSSize(width: SettingsMetrics.windowWidth, height: 1400)
        window.isReleasedWhenClosed = false
        window.delegate = self

        // Blurred, tinted background (rgba(17, 24, 39, 0.68) over the desktop)
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: SettingsRootView())
        hosting.frame = blur.bounds
        hosting.autoresizingMask = [.width, .height]
        blur.addSubview(hosting)

        window.contentView = blur
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - Tokens (from the Figma variables)

enum SettingsMetrics {
    static let windowWidth: CGFloat = 822
    static let sidebarWidth: CGFloat = 216
    static let contentWidth: CGFloat = 532
}

enum SettingsColor {
    static let ink = Color(red: 0xF5 / 255, green: 0xF7 / 255, blue: 0xFD / 255)
    static let muted = Color(red: 0xA6 / 255, green: 0xB1 / 255, blue: 0xC8 / 255)
    static let control = Color(red: 0x1B / 255, green: 0x24 / 255, blue: 0x39 / 255)   // "sidebar" token
    static let accent = Color(red: 0x2F / 255, green: 0x54 / 255, blue: 0xF6 / 255)
    static let line = Color(red: 0x42 / 255, green: 0x4E / 255, blue: 0x66 / 255)
    static let windowTint = Color(red: 17 / 255, green: 24 / 255, blue: 39 / 255).opacity(0.68)
    static let sidebarFill = Color(red: 170 / 255, green: 188 / 255, blue: 232 / 255).opacity(0.05)
    static let groupFill = Color(red: 204 / 255, green: 217 / 255, blue: 1).opacity(0.05)
    static let groupStroke = Color(red: 205 / 255, green: 220 / 255, blue: 1).opacity(0.12)
    static let navSelectedFill = Color(red: 65 / 255, green: 108 / 255, blue: 1).opacity(0.22)
    static let navSelectedStroke = Color(red: 137 / 255, green: 168 / 255, blue: 1).opacity(0.23)
    static let navSelectedText = Color(red: 0xB5 / 255, green: 0xC9 / 255, blue: 1)
    static let heroFill = Color(red: 69 / 255, green: 107 / 255, blue: 244 / 255).opacity(0.12)
    static let heroStroke = Color(red: 141 / 255, green: 168 / 255, blue: 1).opacity(0.17)
}

// MARK: - Navigation

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, capture, shortcuts, export
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Général"
        case .capture: return "Capture"
        case .shortcuts: return "Raccourcis"
        case .export: return "Export"
        }
    }

    var glyph: String {
        switch self {
        case .general: return "◉"
        case .capture: return "⌗"
        case .shortcuts: return "⌘"
        case .export: return "↗"
        }
    }
}

final class SettingsNavigation: ObservableObject {
    @Published var section: SettingsSection = .general
}

struct SettingsRootView: View {
    @StateObject private var navigation: SettingsNavigation
    /// Static rendering (no scroll view) for `Parker --render-settings`.
    var snapshot = false

    init(initial: SettingsSection = .general, snapshot: Bool = false) {
        let navigation = SettingsNavigation()
        navigation.section = initial
        _navigation = StateObject(wrappedValue: navigation)
        self.snapshot = snapshot
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(navigation: navigation)
                .frame(width: SettingsMetrics.sidebarWidth)
                .frame(maxHeight: .infinity)
                .background(SettingsColor.sidebarFill)

            if snapshot {
                page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView(.vertical, showsIndicators: true) { page }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(SettingsColor.windowTint)
        .foregroundColor(SettingsColor.ink)
        .ignoresSafeArea()
    }

    private var page: some View {
        Group {
            switch navigation.section {
            case .general: GeneralSettingsPage()
            case .capture: CaptureSettingsPage()
            case .shortcuts: ShortcutSettingsPage()
            case .export: ExportSettingsPage()
            }
        }
        .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
        .padding(36)
    }
}

/// `Parker --render-settings <folder>`: writes one PNG per settings page (design review).
enum SettingsSnapshot {
    @MainActor
    static func render(to folder: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for section in SettingsSection.allCases {
            let view = SettingsRootView(initial: section, snapshot: true)
                .frame(width: SettingsMetrics.windowWidth, height: 980)
                .background(Color(red: 0.10, green: 0.12, blue: 0.17))
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(section.rawValue).png"))
        }
    }
}

struct SettingsSidebar: View {
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Room for the window's own close / minimize / zoom buttons
            Color.clear.frame(width: 46, height: 10)

            HStack(spacing: 10) {
                ParkerSettingsLogo().frame(width: 44, height: 44)
                Text("parker")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(SettingsColor.ink)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(SettingsSection.allCases) { section in
                    SettingsNavItem(section: section, selected: navigation.section == section) {
                        navigation.section = section
                    }
                }
            }

            Spacer(minLength: 0)

            Text("PARKER POUR MAC")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(SettingsColor.muted)
            Text("Réglé pour votre quotidien.")
                .font(.system(size: 11))
                .foregroundColor(SettingsColor.muted)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SettingsNavItem: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(section.glyph)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 16)
                Text(section.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundColor(selected ? SettingsColor.navSelectedText : SettingsColor.ink)
            .padding(12)
            .frame(width: 176, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? SettingsColor.navSelectedFill : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? SettingsColor.navSelectedStroke : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pages

struct GeneralSettingsPage: View {
    @StateObject private var launchAtLogin = LaunchAtLoginManager()
    @AppStorage("saveLocation") private var saveLocationPath: String = NSHomeDirectory() + "/Desktop"
    @AppStorage("imageFormat") private var imageFormat: String = "png"
    @AppStorage("copyToClipboard") private var copyToClipboard: Bool = true
    @AppStorage("playSound") private var playSound: Bool = true
    @AppStorage("showThumbnail") private var showThumbnail: Bool = true
    @AppStorage("thumbnailPosition") private var thumbnailPosition: String = "bottomLeft"
    @AppStorage("thumbnailAutoHide") private var thumbnailAutoHide: Bool = false
    @AppStorage("thumbnailDuration") private var thumbnailDuration: Double = 5.0

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(title: "À votre façon.", subtitle: "Les essentiels, au même endroit.")

            SettingsGroup(title: "FICHIERS") {
                SettingsRow(title: "Enregistrer dans", subtitle: folderDescription) {
                    SettingsPillButton(title: "Modifier…") { chooseSaveLocation() }
                }
                SettingsDivider()
                SettingsRow(title: "Format d’image", subtitle: formatDescription) {
                    SettingsChoice(
                        options: [("PNG", "png"), ("JPEG", "jpeg"), ("TIFF", "tiff")],
                        selection: $imageFormat
                    )
                }
            }

            SettingsGroup(title: "AU QUOTIDIEN") {
                SettingsRow(title: "Ouvrir Parker à la connexion", subtitle: loginSubtitle) {
                    SettingsSwitch(isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    ))
                    .disabled(!launchAtLogin.canManage)
                }
                SettingsDivider()
                SettingsRow(title: "Copier après la capture", subtitle: "Prêt à coller, où vous voulez.") {
                    SettingsSwitch(isOn: $copyToClipboard)
                }
                SettingsDivider()
                SettingsRow(title: "Jouer un son") {
                    SettingsSwitch(isOn: $playSound)
                }
            }

            SettingsGroup(title: "VIGNETTE FLOTTANTE") {
                SettingsRow(title: "Afficher un aperçu", subtitle: "Retrouvez les options de votre capture.") {
                    SettingsSwitch(isOn: $showThumbnail)
                }
                SettingsDivider()
                SettingsRow(title: "Position") {
                    SettingsChoice(
                        options: [("Gauche", "bottomLeft"), ("Droite", "bottomRight")],
                        selection: $thumbnailPosition
                    )
                }
                SettingsDivider()
                SettingsRow(title: "Masquer automatiquement") {
                    SettingsSwitch(isOn: $thumbnailAutoHide)
                }
                SettingsRow(title: "Masquer après") {
                    SettingsMenuButton(
                        title: durationTitle,
                        options: [3.0, 5.0, 10.0, 15.0].map { (Self.seconds($0), $0) },
                        onSelect: { thumbnailDuration = $0 }
                    )
                }
                .opacity(thumbnailAutoHide ? 1 : 0.45)
                .disabled(!thumbnailAutoHide)
            }

            if !thumbnailAutoHide {
                Text("Activez le masquage automatique pour ajuster le délai.")
                    .font(.system(size: 12))
                    .foregroundColor(SettingsColor.muted)
            }
        }
        .onAppear { launchAtLogin.refresh() }
    }

    private var folderDescription: String {
        let name = FileManager.default.displayName(atPath: saveLocationPath)
        return "\(name) · dossier local"
    }

    private var formatDescription: String {
        switch imageFormat {
        case "jpeg": return "JPEG allège le fichier."
        case "tiff": return "TIFF garde une qualité maximale."
        default: return "PNG conserve chaque détail."
        }
    }

    private var loginSubtitle: String? {
        if let error = launchAtLogin.errorMessage { return error }
        if launchAtLogin.showsApprovalButton { return "À autoriser dans Réglages Système > Ouverture." }
        return nil
    }

    private var durationTitle: String { Self.seconds(thumbnailDuration) }

    private static func seconds(_ value: Double) -> String {
        let v = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        return "\(v) secondes"
    }

    private func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choisir"
        panel.directoryURL = URL(fileURLWithPath: saveLocationPath)
        if panel.runModal() == .OK, let url = panel.url {
            saveLocationPath = url.path
        }
    }
}

struct CaptureSettingsPage: View {
    @AppStorage("captureDelay") private var captureDelay: Int = 0
    @AppStorage("hideDesktopIcons") private var hideDesktopIcons: Bool = false
    @AppStorage("includeWindowShadow") private var includeWindowShadow: Bool = true
    @AppStorage("freezeScreen") private var freezeScreen: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(title: "Le bon instant.", subtitle: "Des captures propres, dès le premier essai.")

            SettingsHeroCard(
                eyebrow: "PRÊT À CAPTURER",
                title: "Juste ce qui compte.",
                text: "Un bureau net. Une fenêtre bien détachée.",
                titleSize: 24,
                padding: 24,
                spacing: 12,
                cornerRadius: 16
            )

            SettingsGroup(title: "AVANT LA CAPTURE") {
                SettingsRow(title: "Retardateur", subtitle: "Un instant pour préparer votre écran.") {
                    SettingsMenuButton(
                        title: delayTitle(captureDelay),
                        options: [0, 3, 5, 10].map { (delayTitle($0), $0) },
                        onSelect: { captureDelay = $0 }
                    )
                }
                SettingsDivider()
                SettingsRow(title: "Masquer les icônes du bureau", subtitle: "Elles réapparaissent après la capture.") {
                    SettingsSwitch(isOn: $hideDesktopIcons)
                }
            }

            SettingsGroup(title: "PENDANT LA CAPTURE") {
                SettingsRow(title: "Conserver l’ombre des fenêtres", subtitle: "Ajoute du relief aux captures de fenêtre.") {
                    SettingsSwitch(isOn: $includeWindowShadow)
                }
                SettingsDivider()
                SettingsRow(title: "Figer l’écran à la sélection", subtitle: "Le contenu reste immobile pendant le cadrage.") {
                    SettingsSwitch(isOn: $freezeScreen)
                }
            }
        }
    }

    private func delayTitle(_ seconds: Int) -> String {
        seconds == 0 ? "Aucun délai" : "\(seconds) secondes"
    }
}

struct ShortcutSettingsPage: View {
    @AppStorage("shortcutProfile") private var shortcutProfileRaw: String = ShortcutModifierProfile.controlShift.rawValue

    private var profile: ShortcutModifierProfile {
        ShortcutModifierProfile(rawValue: shortcutProfileRaw) ?? .controlShift
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(title: "Au bout des doigts.", subtitle: "Un même profil pour tous vos raccourcis.")

            SettingsGroup(title: "PROFIL") {
                SettingsRow(title: "Touches de raccourci") {
                    SettingsChoice(
                        options: [("Ctrl ⇧", ShortcutModifierProfile.controlShift.rawValue),
                                  ("⌘ ⇧", ShortcutModifierProfile.commandShift.rawValue)],
                        selection: Binding(
                            get: { shortcutProfileRaw },
                            set: {
                                shortcutProfileRaw = $0
                                postShortcutConfigurationDidChange()
                            }
                        )
                    )
                }
            }

            Text(profile == .controlShift
                 ? "Ctrl + Maj évite les raccourcis de capture de macOS."
                 : "⌘ + Maj : désactivez d’abord les raccourcis de capture de macOS.")
                .font(.system(size: 12))
                .foregroundColor(SettingsColor.muted)

            SettingsGroup(title: "ACCÈS RAPIDE & CAPTURE") {
                ForEach(ShortcutAction.quickAccess + ShortcutAction.capture) { action in
                    shortcutRow(action)
                }
            }

            SettingsGroup(title: "ENREGISTREMENT & OUTILS") {
                ForEach(ShortcutAction.recording + ShortcutAction.tools) { action in
                    shortcutRow(action)
                }
            }
        }
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        SettingsRow(title: Self.frenchTitle(action)) {
            SettingsKeyBadge(text: badge(for: action))
        }
    }

    private func badge(for action: ShortcutAction) -> String {
        let modifier = profile == .controlShift ? "⌃" : "⌘"
        return "\(modifier)  ⇧  \(action.keyEquivalent)"
    }

    static func frenchTitle(_ action: ShortcutAction) -> String {
        switch action {
        case .allInOne: return "Ouvrir la barre d’outils"
        case .captureFullscreen: return "Capturer tout l’écran"
        case .captureArea: return "Capturer une zone"
        case .captureWindow: return "Capturer une fenêtre"
        case .captureScrolling: return "Capture défilante"
        case .recordScreen: return "Enregistrer l’écran"
        case .recordArea: return "Enregistrer une zone"
        case .ocr: return "Extraire le texte (OCR)"
        case .colorPicker: return "Prélever une couleur"
        }
    }
}

struct ExportSettingsPage: View {
    @AppStorage("gifMaxWidth") private var gifMaxWidth: Int = 640
    @AppStorage("gifFrameRate") private var gifFrameRate: Int = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(title: "Prêt à partager.", subtitle: "Des exports légers, des détails préservés.")

            SettingsGroup(title: "EXPORT GIF") {
                SettingsRow(title: "Largeur maximale", subtitle: "Une largeur réduite allège le fichier.") {
                    SettingsMenuButton(
                        title: "\(gifMaxWidth) px",
                        options: [320, 480, 640, 800, 1024].map { ("\($0) px", $0) },
                        onSelect: { gifMaxWidth = $0 }
                    )
                }
                SettingsDivider()
                SettingsRow(title: "Fluidité", subtitle: fpsDescription) {
                    SettingsMenuButton(
                        title: "\(gifFrameRate) images/s",
                        options: [10, 15, 20, 25].map { ("\($0) images/s", $0) },
                        onSelect: { gifFrameRate = $0 }
                    )
                }
            }

            SettingsHeroCard(
                eyebrow: nil,
                title: "Petit fichier. Belle impression.",
                text: "Ces réglages s’appliquent aux prochains GIF exportés.",
                titleSize: 19,
                padding: 20,
                spacing: 8,
                cornerRadius: 14,
                textSize: 13
            )

            SettingsGroup(title: "RÉINITIALISATION") {
                SettingsRow(title: "Rétablir les réglages par défaut", subtitle: "Une confirmation sera demandée.") {
                    SettingsPillButton(title: "Rétablir…") { confirmReset() }
                }
            }
        }
    }

    private var fpsDescription: String {
        switch gifFrameRate {
        case ..<15: return "\(gifFrameRate) images/s privilégie un fichier léger."
        case 15: return "15 images/s équilibre poids et fluidité."
        default: return "\(gifFrameRate) images/s privilégie la fluidité."
        }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Rétablir les réglages par défaut ?"
        alert.informativeText = "Tous les réglages de Parker reviennent à leur valeur d’origine. Vos captures ne sont pas touchées."
        alert.addButton(withTitle: "Rétablir")
        alert.addButton(withTitle: "Annuler")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let defaults = UserDefaults.standard
        for key in ["saveLocation", "imageFormat", "jpegQuality", "copyToClipboard", "showThumbnail", "playSound",
                    "includeWindowShadow", "thumbnailDuration", "thumbnailAutoHide", "captureDelay", "hideDesktopIcons",
                    "thumbnailPosition", "freezeScreen", "gifMaxWidth", "gifFrameRate", "shortcutProfile"] {
            defaults.removeObject(forKey: key)
        }
        postShortcutConfigurationDidChange()
    }
}

// MARK: - Building blocks

struct SettingsHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(SettingsColor.ink)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(SettingsColor.muted)
        }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(SettingsColor.muted)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SettingsColor.groupFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(SettingsColor.groupStroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// Separator between two rows of a group (456 pt, aligned on the left edge, as in the design).
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsColor.line)
            .frame(width: 456, height: 1)
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String?
    let control: Control

    init(title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(SettingsColor.ink)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(SettingsColor.muted)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(16)
        .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
    }
}

/// 32×19 switch: accent when on, "line" color when off.
struct SettingsSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? SettingsColor.accent : SettingsColor.line)
                    .frame(width: 32, height: 19)
                Circle()
                    .fill(Color.white)
                    .frame(width: 17, height: 17)
                    .shadow(color: Color.black.opacity(0.25), radius: 0.75, x: 0, y: 0.5)
                    .padding(1)
            }
            .frame(width: 32, height: 19)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "Activé" : "Désactivé")
    }
}

/// Segmented choice ("Choix" in the design): 3 pt inset, selected item in accent blue.
struct SettingsChoice: View {
    let options: [(String, String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<options.count, id: \.self) { index in
                let option = options[index]
                let selected = option.1 == selection
                Button {
                    selection = option.1
                } label: {
                    Text(option.0)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(selected ? .white : SettingsColor.ink)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(selected ? SettingsColor.accent : SettingsColor.control)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(SettingsColor.control))
    }
}

struct SettingsPillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsPill(text: title)
        }
        .buttonStyle(.plain)
    }
}

struct SettingsPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(SettingsColor.ink)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SettingsColor.control))
            .contentShape(Rectangle())
    }
}

struct SettingsKeyBadge: View {
    let text: String
    var body: some View { SettingsPill(text: text) }
}

/// Pill showing the current value followed by "⌄"; a click opens a native menu.
struct SettingsMenuButton<Value: Equatable>: View {
    let title: String
    let options: [(String, Value)]
    let onSelect: (Value) -> Void

    var body: some View {
        Button {
            SettingsMenuPresenter.show(items: options.map { option in
                (option.0, option.0 == title, { onSelect(option.1) })
            })
        } label: {
            SettingsPill(text: "\(title)  ⌄")
        }
        .buttonStyle(.plain)
    }
}

enum SettingsMenuPresenter {
    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }

    static func show(items: [(String, Bool, () -> Void)]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, checked, action) in items {
            let target = Target(action)
            let item = NSMenuItem(title: title, action: #selector(Target.fire), keyEquivalent: "")
            item.target = target
            item.representedObject = target   // keeps the target alive with the item
            item.state = checked ? .on : .off
            menu.addItem(item)
        }
        menu.appearance = NSAppearance(named: .darkAqua)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// Highlighted card ("Aperçu de capture" and "Conseil" in the design).
struct SettingsHeroCard: View {
    let eyebrow: String?
    let title: String
    let text: String
    let titleSize: CGFloat
    let padding: CGFloat
    let spacing: CGFloat
    let cornerRadius: CGFloat
    var textSize: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let eyebrow = eyebrow {
                Text(eyebrow)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(SettingsColor.muted)
            }
            Text(title)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundColor(SettingsColor.ink)
            Text(text)
                .font(.system(size: textSize))
                .foregroundColor(SettingsColor.muted)
        }
        .padding(padding)
        .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(SettingsColor.heroFill))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(SettingsColor.heroStroke, lineWidth: 1))
    }
}

/// Parker logo from the design (Parker/Support/SettingsLogo.svg, 44×44), drawn as vectors.
struct ParkerSettingsLogo: View {
    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .interpolation(.high)
    }

    static let image: NSImage = NSImage(size: NSSize(width: 44, height: 44), flipped: true) { _ in
        let blue = NSColor(srgbRed: 0x2F / 255, green: 0x54 / 255, blue: 0xF6 / 255, alpha: 1)
        let cream = NSColor(srgbRed: 0xFA / 255, green: 0xF9 / 255, blue: 0xF5 / 255, alpha: 1)

        // Background: rounded square, 10.4615 radius
        blue.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 44, height: 44), xRadius: 10.4615, yRadius: 10.4615).fill()

        cream.setStroke()
        // Lenses: x 7.53857…20.0001 and 24.1538…36.6153, y 12.3077…23.3846, radius 3.0769
        for x in [7.53857, 24.1538] {
            let lens = NSBezierPath(roundedRect: NSRect(x: x, y: 12.3077, width: 12.4615, height: 11.0769),
                                    xRadius: 3.07692, yRadius: 3.07692)
            lens.lineWidth = 2.07692
            lens.stroke()
        }

        // Bridge
        let bridge = NSBezierPath()
        bridge.move(to: NSPoint(x: 20, y: 17.5385))
        bridge.curve(to: NSPoint(x: 24.1538, y: 17.5385),
                     controlPoint1: NSPoint(x: 21.3333, y: 16.8205),
                     controlPoint2: NSPoint(x: 22.7179, y: 16.8205))
        bridge.lineWidth = 2.07692
        bridge.stroke()

        // Viewfinder corners
        let marks = NSBezierPath()
        marks.move(to: NSPoint(x: 10.769, y: 19.2308))
        marks.line(to: NSPoint(x: 10.769, y: 15.6923))
        marks.line(to: NSPoint(x: 14.4614, y: 15.6923))
        marks.move(to: NSPoint(x: 30.3075, y: 20.3077))
        marks.line(to: NSPoint(x: 33.0767, y: 20.3077))
        marks.line(to: NSPoint(x: 33.0767, y: 16.7692))
        marks.lineWidth = 1.53846
        marks.stroke()
        return true
    }
}
