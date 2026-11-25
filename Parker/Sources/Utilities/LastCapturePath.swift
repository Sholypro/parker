import Cocoa

/// Copies the full path of the most recent screenshot (images only, not videos) to the clipboard,
/// ready to paste in a terminal, a chat or a "Choose file" field.
enum LastCapturePath {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "webp", "pdf"]

    static func copy() {
        let fm = FileManager.default
        guard let url = Defaults.shared.recentCaptures.first(where: {
            imageExtensions.contains($0.pathExtension.lowercased()) && fm.fileExists(atPath: $0.path)
        }) else {
            Toast.show(message: "Aucune capture à copier", style: .info)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.path, forType: .string)
        Toast.show(message: "Chemin copié : \(url.lastPathComponent)")
    }
}
