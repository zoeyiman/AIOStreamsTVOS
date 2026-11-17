import Foundation

/**
 * The pictures the app fetches for the page (ImageFit, ArtWash), kept on disk. The page's own saved
 * artwork can't be used on tvOS (its copies come back as blob URLs, which this WebKit doesn't draw), so
 * the page's Settings > Cache decides this cache instead (BridgeScript's `__aioArtworkCache`,
 * patches/web/0071):
 *
 * - "Save what you browse" and "Artwork" on: kept, up to "Space to use" less what the page saves itself.
 *   Off: nothing is kept, and what was is cleared.
 * - Artwork's Clear and "Clear everything" clear it, and the artwork row counts its size.
 *
 * Kept in the user defaults too, so the cache is set as the app starts, before the page has said.
 */
enum ArtworkCache {
    /// The page's default "Space to use", 500 MB, in its own (decimal) megabytes.
    static let defaultLimit = 500_000_000
    private static let settingsKey = "artworkCache.settings"

    static let disk: URLCache = {
        let saved = UserDefaults.standard.dictionary(forKey: settingsKey)
        let on = saved?["on"] as? Bool ?? true
        let limit = saved?["limit"] as? Int ?? defaultLimit
        return URLCache(memoryCapacity: 8 << 20, diskCapacity: on ? max(0, limit) : 0,
                        directory: AppFolders.caches.appendingPathComponent("image-fit", isDirectory: true))
    }()

    /**
     * The page's settings: whether artwork is saved, and the bytes it may take. A capacity under what's
     * kept has URLCache drop the oldest past it; off drops it all.
     */
    static func configure(on: Bool, limit: Int) {
        let capacity = on ? max(0, limit) : 0
        let saved = UserDefaults.standard.dictionary(forKey: settingsKey)
        guard saved?["on"] as? Bool != on || saved?["limit"] as? Int != limit || disk.diskCapacity != capacity
        else { return }
        UserDefaults.standard.set(["on": on, "limit": limit], forKey: settingsKey)
        disk.diskCapacity = capacity
        if !on { disk.removeAllCachedResponses() }
        NSLog("[artwork] cache \(on ? "up to \(capacity / 1_000_000) MB" : "off"), \(disk.currentDiskUsage / 1_000_000) MB kept")
    }

    /// The bytes kept on disk.
    static var bytes: Int { disk.currentDiskUsage }

    /// Everything kept, on disk and the fitted copies in memory. Off the main thread: it deletes files.
    static func clear() {
        disk.removeAllCachedResponses()
        ImageFit.forgetKept()
        NSLog("[artwork] cache cleared")
    }

    /// As the app's data is reset: everything kept goes, and the settings go back to the page's defaults.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: settingsKey)
        disk.diskCapacity = defaultLimit
        clear()
    }
}
