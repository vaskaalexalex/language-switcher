import AppKit

enum FrontmostApp {
    private static let electronCacheLimit = 64
    private static var electronCache: [String: Bool] = [:]
    private static var electronCacheOrder: [String] = []

    static func bundleId() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    static func name() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    static func isElectron(_ app: NSRunningApplication?) -> Bool {
        guard let app,
              let bundleId = app.bundleIdentifier,
              let bundleURL = app.bundleURL
        else {
            return false
        }

        if let cached = electronCache[bundleId] {
            return cached
        }

        let electronFramework = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Frameworks")
            .appendingPathComponent("Electron Framework.framework")
        let exists = FileManager.default.fileExists(atPath: electronFramework.path)
        cacheElectronResult(exists, for: bundleId)
        return exists
    }

    /// Modern terminals whose Accessibility layer is unreliable for *writes*
    /// (AXValue is the whole scrollback buffer and doesn't reflect our edits),
    /// so the AX-write cascade flails for ~1s and can mis-fire the duplicate
    /// guard. Route these through the synth+paste pipeline like Electron.
    /// (Apple Terminal and iTerm2 are skipped entirely via the default
    /// blacklist; these are the terminals not on that list.)
    private static let forcePasteBundleIds: Set<String> = [
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Beta",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    /// True for apps that should bypass AX writes and use the paste pipeline,
    /// even though they aren't Electron.
    static func isForcePasteApp(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return forcePasteBundleIds.contains(id)
    }

    static func isForcePasteBundleId(_ bundleId: String) -> Bool {
        forcePasteBundleIds.contains(bundleId)
    }

    static func isElectronBundle(at bundleURL: URL) -> Bool {
        let electronFramework = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Frameworks")
            .appendingPathComponent("Electron Framework.framework")
        return FileManager.default.fileExists(atPath: electronFramework.path)
    }

    private static func cacheElectronResult(_ value: Bool, for bundleId: String) {
        if electronCache[bundleId] == nil {
            electronCacheOrder.append(bundleId)
        }
        electronCache[bundleId] = value

        while electronCacheOrder.count > electronCacheLimit {
            let oldest = electronCacheOrder.removeFirst()
            electronCache.removeValue(forKey: oldest)
        }
    }
}
