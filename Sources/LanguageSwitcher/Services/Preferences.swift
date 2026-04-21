import Foundation
import Combine

final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Keys {
        static let isEnabled = "puntoSwitcher.isEnabled"
        static let blacklist = "puntoSwitcher.blacklist"
        static let launchAtLogin = "puntoSwitcher.launchAtLogin"
        static let hasLaunchedBefore = "puntoSwitcher.hasLaunchedBefore"
        static let seededDefaults = "puntoSwitcher.seededDefaults"
        static let seededLaunchAtLogin = "puntoSwitcher.seededLaunchAtLogin"
        static let switchKeyboardLayout = "puntoSwitcher.switchKeyboardLayout"
    }

    private let defaults = UserDefaults.standard

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }

    @Published var blacklist: [String] {
        didSet { defaults.set(blacklist, forKey: Keys.blacklist) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            LoginItem.apply(launchAtLogin)
        }
    }

    @Published var switchKeyboardLayout: Bool {
        didSet { defaults.set(switchKeyboardLayout, forKey: Keys.switchKeyboardLayout) }
    }

    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Keys.hasLaunchedBefore) }
        set { defaults.set(newValue, forKey: Keys.hasLaunchedBefore) }
    }

    private init() {
        if defaults.object(forKey: Keys.isEnabled) == nil {
            defaults.set(true, forKey: Keys.isEnabled)
        }
        if defaults.object(forKey: Keys.switchKeyboardLayout) == nil {
            defaults.set(true, forKey: Keys.switchKeyboardLayout)
        }
        self.isEnabled = defaults.bool(forKey: Keys.isEnabled)
        self.blacklist = (defaults.array(forKey: Keys.blacklist) as? [String]) ?? []
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        self.switchKeyboardLayout = defaults.bool(forKey: Keys.switchKeyboardLayout)
    }

    func seedDefaultsIfNeeded() {
        if !defaults.bool(forKey: Keys.seededDefaults) {
            let seeded: [String] = [
                "com.apple.Terminal",
                "com.googlecode.iterm2",
                "com.apple.keychainaccess",
                "com.1password.1password",
                "com.1password.1password7",
                "com.agilebits.onepassword7",
                "com.bitwarden.desktop"
            ]
            var merged = Set(blacklist)
            for id in seeded { merged.insert(id) }
            blacklist = Array(merged).sorted()
            defaults.set(true, forKey: Keys.seededDefaults)
        }

        // Enable launch-at-login once, the first time the app runs from a
        // stable location (i.e. /Applications). Registering from /Volumes/…
        // would point the login item at a DMG that eventually gets ejected,
        // so we wait until the user installs the app properly.
        if !defaults.bool(forKey: Keys.seededLaunchAtLogin),
           Installer.isInstalledInApplications {
            launchAtLogin = true
            defaults.set(true, forKey: Keys.seededLaunchAtLogin)
        }
    }

    func addBlacklistedApp(_ bundleId: String) {
        guard !bundleId.isEmpty, !blacklist.contains(bundleId) else { return }
        blacklist = (blacklist + [bundleId]).sorted()
    }

    func removeBlacklistedApp(_ bundleId: String) {
        blacklist.removeAll { $0 == bundleId }
    }
}
