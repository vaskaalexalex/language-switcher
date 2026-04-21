import AppKit
import SwiftUI
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var hotkeyMonitor: HotkeyMonitor?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var permissionPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("=== LanguageSwitcher launching (pid=\(ProcessInfo.processInfo.processIdentifier)) ===")
        NSApp.setActivationPolicy(.accessory)

        Installer.performPostInstallHousekeeping()

        Preferences.shared.seedDefaultsIfNeeded()

        statusItemController = StatusItemController(
            onConvert: { [weak self] in self?.performConversion() },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onOpenAccessibility: { Self.openAccessibilitySettings() },
            onQuit: { NSApp.terminate(nil) },
            isRunning: { [weak self] in self?.hotkeyMonitor != nil }
        )
        statusItemController?.install()

        // Probe real access by trying to install the event tap. Don't trust
        // AXIsProcessTrustedWithOptions — it caches.
        if !tryStartHotkeyMonitoring() {
            // Trigger the system Accessibility prompt so TCC adds our entry
            // (and shows "Open System Settings" button). Safe to call on every
            // launch; it's a no-op once the entry already exists.
            _ = AccessibilityBridge.isTrusted(prompt: true)
            Preferences.shared.hasLaunchedBefore = true
            showOnboarding()
            startPermissionPolling()
        } else {
            Preferences.shared.hasLaunchedBefore = true
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
        permissionPollTimer?.invalidate()
    }

    // MARK: - Hotkey

    /// Attempts to start the hotkey monitor. Returns true if it succeeded
    /// (meaning the app is currently trusted by the Accessibility system).
    @discardableResult
    private func tryStartHotkeyMonitoring() -> Bool {
        if hotkeyMonitor != nil { return true }
        let monitor = HotkeyMonitor { [weak self] in
            self?.performConversion()
        }
        do {
            try monitor.start()
            hotkeyMonitor = monitor
            statusItemController?.refresh()
            Log.info("Event tap created — Accessibility is granted")
            return true
        } catch {
            Log.info("Event tap creation failed (\(error)) — permission missing")
            return false
        }
    }

    private func performConversion() {
        guard Preferences.shared.isEnabled else {
            Log.info("Disabled, ignoring")
            return
        }

        if let bundleId = FrontmostApp.bundleId(),
           Preferences.shared.blacklist.contains(bundleId) {
            Log.info("Blacklisted app \(bundleId), ignoring")
            return
        }

        TextReplacer.shared.convertCurrentTextOrLastWord()
    }

    // MARK: - Settings window

    private func openSettings() {
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let view = SettingsView().environmentObject(Preferences.shared)
        let hosting = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "LanguageSwitcher Settings"
        window.setContentSize(NSSize(width: 520, height: 400))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        if let win = onboardingWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = OnboardingView(
            onOpenAccessibility: { Self.openAccessibilitySettings() },
            onRecheck: { [weak self] in self?.recheckPermission() }
        )
        let hosting = NSHostingController(rootView: content)

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "LanguageSwitcher"
        window.setContentSize(NSSize(width: 480, height: 320))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.tryStartHotkeyMonitoring() {
                self.permissionPollTimer?.invalidate()
                self.permissionPollTimer = nil
                self.onboardingWindow?.close()
            }
        }
    }

    private func recheckPermission() {
        Log.info("Manual recheck requested")
        if tryStartHotkeyMonitoring() {
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
            onboardingWindow?.close()
        }
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow { settingsWindow = nil }
        if window === onboardingWindow { onboardingWindow = nil }
    }
}
