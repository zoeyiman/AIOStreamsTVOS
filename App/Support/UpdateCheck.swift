import Foundation

/**
 * Whether a newer release is out, read from the sideloading source the build workflow keeps
 * (altstore/source.json on main, `scripts/update-source.py`): its newest version against this
 * build's. Asked once as the app launches; each newer version is told of once, ever.
 *
 * Stable releases only: the source lists only `v*` tags (the workflow's update-source step runs
 * for those alone), and a version that isn't all numbers, a `1.4.0-beta` say, is passed over.
 */
enum UpdateCheck {
    static let source = URL(string: "https://raw.githubusercontent.com/mickey2266/AIOStreamsTVOS/main/altstore/source.json")!
    static let releases = "github.com/mickey2266/AIOStreamsTVOS/releases"
    /// The release page for a version: the workflow tags each `v<MARKETING_VERSION>` (scripts/update-source.py).
    static func releasePage(_ version: String) -> URL? {
        URL(string: "https://github.com/mickey2266/AIOStreamsTVOS/releases/tag/v\(version)")
    }
    private static let bundleID = "io.github.aiostreams.tvos"
    /// The newest version the app has told of.
    private static let shownKey = "update.shownVersion"

    /// The newest release's version if it's newer than this build and hasn't been told of; nil otherwise or on any failure.
    static func newer(than current: String, done: @escaping @MainActor (String?) -> Void) {
        var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            var found: String?
            if let data, (response as? HTTPURLResponse)?.statusCode == 200,
               let latest = latestVersion(data),
               isNewer(latest, than: current),
               UserDefaults.standard.string(forKey: shownKey) != latest {
                found = latest
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(found) } }
        }.resume()
    }

    /// Called once the notice is shown, so this version isn't told of again.
    static func markShown(_ version: String) {
        UserDefaults.standard.set(version, forKey: shownKey)
    }

    /// The highest version the source lists for this app.
    static func latestVersion(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = root["apps"] as? [[String: Any]],
              let app = apps.first(where: { $0["bundleIdentifier"] as? String == bundleID }) ?? apps.first,
              let versions = app["versions"] as? [[String: Any]] else { return nil }
        let listed = versions.compactMap { $0["version"] as? String }.filter { parts($0) != nil }
        return listed.max { isNewer($1, than: $0) }
    }

    /// `a` is a later version than `b`, compared number by number ("1.10.0" after "1.9.2").
    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parts(a), let y = parts(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int]? {
        let numbers = version.trimmingCharacters(in: .whitespaces).split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return numbers.compactMap { $0 }
    }
}
