import AppKit
import Foundation

/// Helpers that tidy up the one-off install experience:
///
/// - If the app was launched from a mounted DMG volume (`/Volumes/…`), we
///   offer to copy it into `/Applications` and relaunch from there so the
///   user doesn't unknowingly run the app from a disk image.
/// - Once the app is running from `/Applications`, we eject any lingering
///   LanguageSwitcher DMG volumes and move the source `.dmg` in
///   `~/Downloads` to the Trash. This runs at most once per install (a
///   flag in `UserDefaults` guards against re-trashing on every launch).
enum Installer {
    private static let cleanupDoneKey = "puntoSwitcher.dmgCleanupDone"

    @MainActor
    static func performPostInstallHousekeeping() {
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasPrefix("/Volumes/") {
            offerInstallFromDMG(bundlePath: bundlePath)
        } else if bundlePath.hasPrefix("/Applications/") {
            runCleanupOnce()
        }
    }

    /// True when the running binary is located under `/Applications`.
    /// Used as a precondition for auto-enabling login-item registration —
    /// registering a DMG-mounted copy would break after eject.
    static var isInstalledInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    // MARK: - DMG → /Applications flow

    @MainActor
    private static func offerInstallFromDMG(bundlePath: String) {
        let appURL = URL(fileURLWithPath: bundlePath)
        let destURL = URL(fileURLWithPath: "/Applications/\(appURL.lastPathComponent)")

        let alert = NSAlert()
        alert.messageText = "Move LanguageSwitcher to Applications?"
        alert.informativeText = """
            The app is running from a disk image. Click Install to copy it to \
            /Applications, eject the DMG, and remove the .dmg file from your \
            Downloads folder.
            """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        let choice = alert.runModal()
        guard choice == .alertFirstButtonReturn else { return }

        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: appURL, to: destURL)
        } catch {
            let fail = NSAlert()
            fail.messageText = "Couldn't install to /Applications"
            fail.informativeText = error.localizedDescription
            fail.alertStyle = .warning
            fail.runModal()
            return
        }

        // Best-effort: strip quarantine from the freshly copied bundle so the
        // user doesn't get a Gatekeeper prompt on the relaunch.
        _ = runSync("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destURL.path])

        // Launch the installed copy.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: destURL, configuration: config) { _, _ in }

        // Eject the source volume and schedule self-termination.
        if let volume = volumePrefix(of: bundlePath) {
            _ = runSync("/usr/bin/hdiutil", ["detach", volume, "-force"])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Cleanup when we're already in /Applications

    private static func runCleanupOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: cleanupDoneKey) else { return }

        ejectLanguageSwitcherVolumes()
        trashDownloadedDMGs()

        defaults.set(true, forKey: cleanupDoneKey)
    }

    private static func ejectLanguageSwitcherVolumes() {
        let fm = FileManager.default
        guard let volumes = try? fm.contentsOfDirectory(atPath: "/Volumes") else { return }
        for name in volumes where name.lowercased().hasPrefix("languageswitcher") {
            _ = runSync("/usr/bin/hdiutil", ["detach", "/Volumes/\(name)", "-force"])
        }
    }

    private static func trashDownloadedDMGs() {
        let fm = FileManager.default
        let downloads = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        guard let entries = try? fm.contentsOfDirectory(
            at: downloads,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in entries {
            let name = url.lastPathComponent.lowercased()
            guard name.hasPrefix("languageswitcher"), name.hasSuffix(".dmg") else { continue }
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                NSLog("[LanguageSwitcher] Trashed post-install: \(url.lastPathComponent)")
            } catch {
                NSLog("[LanguageSwitcher] Failed to trash \(url.lastPathComponent): \(error)")
            }
        }
    }

    // MARK: - Utilities

    /// Given `/Volumes/MyDisk/My.app/...`, returns `/Volumes/MyDisk`.
    private static func volumePrefix(of path: String) -> String? {
        let comps = path.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false)
        // ["", "Volumes", "MyDisk", "rest..."]
        guard comps.count >= 3, comps[1] == "Volumes" else { return nil }
        return "/\(comps[1])/\(comps[2])"
    }

    @discardableResult
    private static func runSync(_ path: String, _ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        do {
            try proc.run()
        } catch {
            NSLog("[LanguageSwitcher] spawn \(path) failed: \(error)")
            return -1
        }
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
