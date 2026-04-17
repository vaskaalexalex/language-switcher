import AppKit

enum FrontmostApp {
    static func bundleId() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    static func name() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }
}
