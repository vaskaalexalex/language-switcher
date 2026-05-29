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
