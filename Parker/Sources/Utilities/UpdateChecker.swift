import Cocoa

/// Self-update from GitHub Releases (no third-party dependency).
///
/// Release convention (produced by .github/workflows/release.yml):
///   tag "v1.2" or "1.2", with an asset named "Parker.zip" that contains Parker.app.
/// The repository is read from the Info.plist key `PKUpdateRepository` ("owner/repo").
/// It must be public: colleagues have no GitHub token.
final class UpdateChecker {
    static let shared = UpdateChecker()

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private let lastCheckKey = "updateLastCheck"
    private let skippedVersionKey = "updateSkippedVersion"
    private var isChecking = false
    private var progressWindow: NSPanel?

    var repository: String? {
        guard let repo = Bundle.main.object(forInfoDictionaryKey: "PKUpdateRepository") as? String,
              repo.contains("/"), !repo.contains("REMPLACER") else { return nil }
        return repo
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Public

    /// Silent check at launch, at most once every 6 hours.
    func checkInBackgroundIfNeeded() {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 6 * 3600 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.check(userInitiated: false)
        }
    }

    /// Menu "Rechercher des mises à jour…"
    func checkNow() {
        check(userInitiated: true)
    }

    // MARK: - Check

    private func check(userInitiated: Bool) {
        guard !isChecking else { return }
        guard let repo = repository,
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            if userInitiated {
                alert(title: "Mises à jour non configurées",
                      text: "Le dépôt GitHub n'est pas renseigné dans cette version de l'app.")
            }
            return
        }

        isChecking = true
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Parker/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isChecking = false
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.lastCheckKey)

                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, status == 200, let data = data,
                      let release = try? JSONDecoder().decode(Release.self, from: data),
                      !release.draft, !release.prerelease else {
                    if userInitiated {
                        let detail = status == 404
                            ? "Aucune version publiée pour l'instant."
                            : "Impossible de joindre GitHub. Vérifie ta connexion et réessaie."
                        self.alert(title: "Vérification impossible", text: detail)
                    }
                    return
                }

                let latest = Self.normalize(release.tag_name)
                guard Self.compare(latest, Self.normalize(self.currentVersion)) == .orderedDescending else {
                    if userInitiated {
                        self.alert(title: "Parker est à jour",
                                   text: "Tu as la dernière version (\(self.currentVersion)).")
                    }
                    return
                }

                if !userInitiated, UserDefaults.standard.string(forKey: self.skippedVersionKey) == latest {
                    return
                }
                self.offer(release, version: latest)
            }
        }.resume()
    }

    private func offer(_ release: Release, version: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Parker \(version) est disponible"
        var notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 900 { notes = String(notes.prefix(900)) + "…" }
        alert.informativeText = "Tu as la version \(currentVersion).\n\n" + (notes.isEmpty ? "" : notes)
        alert.addButton(withTitle: "Installer et relancer")
        alert.addButton(withTitle: "Plus tard")
        alert.addButton(withTitle: "Ignorer cette version")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // The release also carries the Windows build: take the Mac archive explicitly
            let names = release.assets.map { $0.name.lowercased() }
            let preferred = ["parker-mac.zip", "parker.zip"].first(where: { names.contains($0) })
            let fallback = release.assets.first(where: {
                let n = $0.name.lowercased()
                return n.hasSuffix(".zip") && !n.contains("windows")
            })
            guard let asset = release.assets.first(where: { $0.name.lowercased() == preferred }) ?? fallback else {
                NSWorkspace.shared.open(release.html_url)
                return
            }
            install(from: asset.browser_download_url)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(version, forKey: skippedVersionKey)
        default:
            break
        }
    }

    // MARK: - Install

    private func install(from url: URL) {
        showProgress()
        URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, status == 200, let tempURL = tempURL else {
                DispatchQueue.main.async { self.fail("Le téléchargement a échoué.") }
                return
            }
            do {
                let fm = FileManager.default
                let work = fm.temporaryDirectory.appendingPathComponent("ParkerUpdate-\(UUID().uuidString)")
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("Parker.zip")
                try fm.moveItem(at: tempURL, to: zip)

                guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) == 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                guard let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                        .first(where: { $0.pathExtension == "app" }) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                DispatchQueue.main.async { self.replaceAndRelaunch(with: newApp) }
            } catch {
                DispatchQueue.main.async { self.fail("L'archive téléchargée est invalide.") }
            }
        }.resume()
    }

    private func replaceAndRelaunch(with newApp: URL) {
        let current = Bundle.main.bundleURL
        // Running from a build folder: install into /Applications instead of overwriting it
        let target = current.path.hasPrefix("/Applications/")
            ? current
            : URL(fileURLWithPath: "/Applications/Parker.app")

        let parent = target.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else {
            fail("Pas le droit d'écrire dans \(parent). Installe la mise à jour à la main depuis GitHub.")
            return
        }

        // Swap the bundle once this process has exited, then relaunch.
        let script = """
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "\(target.path).old"
        if [ -d "\(target.path)" ]; then /bin/mv "\(target.path)" "\(target.path).old"; fi
        if /usr/bin/ditto "\(newApp.path)" "\(target.path)"; then
          /bin/rm -rf "\(target.path).old"
        else
          /bin/mv "\(target.path).old" "\(target.path)"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "\(target.path)" 2>/dev/null
        /usr/bin/open "\(target.path)"
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", script]
        do {
            try task.run()
        } catch {
            fail("Impossible de lancer l'installation.")
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - UI helpers

    private func showProgress() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Mise à jour"
        panel.level = .floating
        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 28, width: 24, height: 24))
        spinner.style = .spinning
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Téléchargement de la nouvelle version…")
        label.frame = NSRect(x: 54, y: 30, width: 230, height: 20)
        panel.contentView?.addSubview(spinner)
        panel.contentView?.addSubview(label)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        progressWindow = panel
    }

    private func fail(_ text: String) {
        progressWindow?.orderOut(nil)
        progressWindow = nil
        alert(title: "Mise à jour impossible", text: text)
    }

    private func alert(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Versions

    static func normalize(_ version: String) -> String {
        var v = version.trimmingCharacters(in: .whitespaces)
        if v.lowercased().hasPrefix("v") { v.removeFirst() }
        return v
    }

    /// Numeric comparison: "1.10" > "1.9", "1.2" == "1.2.0"
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
