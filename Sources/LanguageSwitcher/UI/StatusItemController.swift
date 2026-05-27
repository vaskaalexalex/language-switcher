import AppKit
import ApplicationServices

final class StatusItemController: NSObject, NSMenuDelegate {
    private let onConvert: () -> Void
    private let onOpenSettings: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onOpenAccessibility: () -> Void
    private let onQuit: () -> Void
    private let isRunning: () -> Bool
    private let canCheckForUpdates: () -> Bool

    private var statusItem: NSStatusItem?

    init(
        onConvert: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onOpenAccessibility: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        isRunning: @escaping () -> Bool,
        canCheckForUpdates: @escaping () -> Bool
    ) {
        self.onConvert = onConvert
        self.onOpenSettings = onOpenSettings
        self.onCheckForUpdates = onCheckForUpdates
        self.onOpenAccessibility = onOpenAccessibility
        self.onQuit = onQuit
        self.isRunning = isRunning
        self.canCheckForUpdates = canCheckForUpdates
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "LanguageSwitcher")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildMenu()
    }

    func refresh() {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let enabledItem = NSMenuItem(
            title: "Enabled",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        enabledItem.target = self
        enabledItem.state = Preferences.shared.isEnabled ? .on : .off
        menu.addItem(enabledItem)

        menu.addItem(NSMenuItem.separator())

        let convert = NSMenuItem(
            title: "Convert Last Word",
            action: #selector(handleConvert),
            keyEquivalent: ""
        )
        convert.target = self
        menu.addItem(convert)

        menu.addItem(NSMenuItem.separator())

        if !isRunning() {
            let warn = NSMenuItem(
                title: "Grant Accessibility Permission…",
                action: #selector(handleOpenAccessibility),
                keyEquivalent: ""
            )
            warn.target = self
            menu.addItem(warn)
            menu.addItem(NSMenuItem.separator())
        }

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(handleOpenSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let updates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(handleCheckForUpdates),
            keyEquivalent: ""
        )
        updates.target = self
        updates.isEnabled = canCheckForUpdates()
        menu.addItem(updates)

        menu.addItem(NSMenuItem.separator())

        let version = NSMenuItem(
            title: "Version \(AppVersion.displayString)",
            action: nil,
            keyEquivalent: ""
        )
        version.isEnabled = false
        menu.addItem(version)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit LanguageSwitcher",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() {
        Preferences.shared.isEnabled.toggle()
        rebuildMenu()
    }

    @objc private func handleConvert() { onConvert() }
    @objc private func handleOpenSettings() { onOpenSettings() }
    @objc private func handleCheckForUpdates() { onCheckForUpdates() }
    @objc private func handleOpenAccessibility() { onOpenAccessibility() }
    @objc private func handleQuit() { onQuit() }
}
