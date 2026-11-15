import Foundation

/// Anonymous usage count, with no server of our own.
///
/// Once a day, Parker downloads a tiny text file attached to the latest GitHub release
/// (`stats-mac.txt`). GitHub counts the downloads of each release file, so that file's counter is
/// the number of Mac installations that ran Parker each day while that version was the latest.
/// Nothing is sent: no identifier, no name, no capture. Only GitHub sees the request, like for
/// the update check. The "Partager des statistiques anonymes" setting turns it off.
enum UsagePing {
    private static let repo = "Sholypro/parker"
    private static let lastPingKey = "lastUsagePingDay"
    private static var timer: Timer?

    /// Called at launch: one ping a day, then a check every hour while Parker runs.
    static func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { pingIfNeeded() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in pingIfNeeded() }
    }

    static func pingIfNeeded() {
        guard Defaults.shared.shareAnonymousStats else { return }
        let today = dayStamp()
        guard UserDefaults.standard.string(forKey: lastPingKey) != today else { return }
        guard let url = URL(string: "https://github.com/\(repo)/releases/latest/download/stats-mac.txt") else { return }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("Parker/\(appVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { _, response, _ in
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            UserDefaults.standard.set(today, forKey: lastPingKey)
        }.resume()
    }

    private static func dayStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
