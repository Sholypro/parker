import Cocoa

class AboutWindowController {
    static let shared = AboutWindowController()

    func show() {
        let credits = NSMutableAttributedString()

        let descAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        credits.append(NSAttributedString(
            string: "Capture, annotation et capture défilante pour macOS.\nBasé sur ScreenCap (open source, licence MIT).\n\n",
            attributes: descAttrs
        ))

        let featureAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let features = [
            "Capture d'écran et de zone",
            "Capture défilante",
            "Annotation",
            "Vidéo et GIF",
            "Fonds et mise en valeur",
            "OCR",
            "Pipette couleur"
        ]
        credits.append(NSAttributedString(
            string: features.joined(separator: " · "),
            attributes: featureAttrs
        ))

        // Use paragraph style to center the text
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Parker",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            .version: "",
            .credits: credits,
        ])
    }
}
