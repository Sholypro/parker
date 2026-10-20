import Cocoa

/// Where a capture comes from: the app that was in front (not Parker) and the title of its
/// front window, shown in the history panel ("Safari", "Une parenthèse dans les Dolomites").
enum CaptureSource {
    /// Last app activated by the user other than Parker (updated by the app delegate).
    static var lastExternalApp: NSRunningApplication?

    struct Info {
        let appName: String?
        let bundleID: String?
        let windowTitle: String?

        var dictionary: [String: String] {
            var d: [String: String] = [:]
            d["app"] = appName
            d["bundle"] = bundleID
            d["title"] = windowTitle
            return d
        }

        init(appName: String?, bundleID: String?, windowTitle: String?) {
            self.appName = appName
            self.bundleID = bundleID
            self.windowTitle = windowTitle
        }

        init(_ dictionary: [String: String]) {
            appName = dictionary["app"]
            bundleID = dictionary["bundle"]
            windowTitle = dictionary["title"]
        }

        /// Icon of the source app, if it is still installed.
        var appIcon: NSImage? {
            guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    /// The app in front and its front window title, read at capture time.
    static func current() -> Info {
        let app = lastExternalApp.flatMap { $0.isTerminated ? nil : $0 }
        guard let app else { return Info(appName: nil, bundleID: nil, windowTitle: nil) }
        return Info(appName: app.localizedName, bundleID: app.bundleIdentifier, windowTitle: frontWindowTitle(pid: app.processIdentifier))
    }

    /// Title of the app's front window (window titles need the screen recording permission,
    /// which Parker has; without it the title is simply missing).
    private static func frontWindowTitle(pid: pid_t) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let title = window[kCGWindowName as String] as? String else { continue }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
