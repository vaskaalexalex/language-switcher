import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var prefs: Preferences
    @State private var selection: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            exceptionsTab
                .tabItem { Label("Exceptions", systemImage: "xmark.app") }
        }
        .frame(width: 520, height: 380)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Toggle("Enable LanguageSwitcher", isOn: $prefs.isEnabled)
            Toggle("Launch at login", isOn: $prefs.launchAtLogin)
            Toggle("Switch keyboard layout after conversion", isOn: $prefs.switchKeyboardLayout)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Hotkey")
                    .font(.headline)
                Text("Tap and release the Option (⌥) key with no other keys pressed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("• With a selection: converts the selected text.")
                Text("• Without a selection: converts the word to the left of the caret.")
            }
            .padding(.top, 4)
        }
        .padding()
    }

    private var exceptionsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LanguageSwitcher will be disabled when these apps are frontmost.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach(prefs.blacklist, id: \.self) { bundleId in
                    HStack(spacing: 10) {
                        if let icon = appIcon(for: bundleId) {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "app.dashed")
                                .frame(width: 20, height: 20)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(appName(for: bundleId) ?? bundleId)
                            Text(bundleId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(bundleId)
                }
            }
            .frame(minHeight: 180)

            HStack {
                Button {
                    addApp()
                } label: {
                    Label("Add App…", systemImage: "plus")
                }
                Button {
                    if let sel = selection { prefs.removeBlacklistedApp(sel) }
                    selection = nil
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selection == nil)
                Spacer()
            }
        }
        .padding()
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url {
            if let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
                prefs.addBlacklistedApp(id)
            }
        }
    }

    private func appName(for bundleId: String) -> String? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
           let bundle = Bundle(url: url) {
            return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
        }
        return nil
    }

    private func appIcon(for bundleId: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
